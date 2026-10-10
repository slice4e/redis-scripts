#!/bin/bash
# Run run_all.sh with several configs at the same time, e.g. one config per socket and its local NIC.
# Usage: ./run_parallel.sh <config1> <config2> [...]

MEMTIER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -lt 2 ]; then
	echo "Usage: $0 <config1> <config2> [...]"
	exit 1
fi
configs=("$@")

read_config() {
	( source "$1" >/dev/null 2>&1
	  echo "${RESULTS_PATH}|${START_PORT}|${NUM_SERVERS}|${RUN_EMON}|${AUTOTUNE}|${BENCHMARK_DURATION}|${ITERATION_NUM}" )
}

declare -A results_owner
port_ranges=()
emon_runs=0
phases=""
for cfg in "${configs[@]}"; do
	if [ ! -f "$cfg" ]; then
		echo "Error: The config file '$cfg' does not exist."
		exit 1
	fi
	IFS='|' read -r results_path start_port num_servers run_emon autotune duration iterations <<< "$(read_config "$cfg")"
	# Autotune takes a different time in each run, so the benchmark phases would no longer overlap.
	if [ "$autotune" != false ]; then
		echo "Error: '$cfg' must set AUTOTUNE=false (and MEMTIER_CLIENTS/MEMTIER_THREADS) so all runs start their phases together."
		exit 1
	fi
	if [ -n "$phases" ] && [ "$phases" != "$duration $iterations" ]; then
		echo "Error: all configs need the same BENCHMARK_DURATION and ITERATION_NUM so their benchmark phases overlap."
		exit 1
	fi
	phases="$duration $iterations"
	if [ -n "${results_owner[$results_path]}" ]; then
		echo "Error: '$cfg' and '${results_owner[$results_path]}' use the same RESULTS_PATH ($results_path). Each config needs its own."
		exit 1
	fi
	results_owner[$results_path]=$cfg
	end_port=$((start_port + num_servers))
	for range in "${port_ranges[@]}"; do
		read -r other_start other_end other_cfg <<< "$range"
		if [ "$start_port" -lt "$other_end" ] && [ "$other_start" -lt "$end_port" ]; then
			echo "Error: ports $((start_port + 1))-${end_port} of '$cfg' overlap the ports of '$other_cfg'."
			exit 1
		fi
	done
	port_ranges+=("$start_port $end_port $cfg")
	[ "$run_emon" == true ] && emon_runs=$((emon_runs + 1))
done
if [ $emon_runs -gt 1 ]; then
	echo "Error: RUN_EMON=true in $emon_runs configs. EMON collects system-wide, so enable it in one config only."
	exit 1
fi

pids=()
for cfg in "${configs[@]}"; do
	name=$(basename "$cfg")
	( set -o pipefail; bash "${MEMTIER_SCRIPT_DIR}/run_all.sh" "$cfg" 2>&1 | sed -u "s|^|[${name}] |" ) &
	pids+=($!)
done

status=0
for i in "${!pids[@]}"; do
	wait "${pids[$i]}"
	rc=$?
	echo "run_all.sh ${configs[$i]} exited with status $rc"
	[ $rc -ne 0 ] && status=1
done
exit $status
