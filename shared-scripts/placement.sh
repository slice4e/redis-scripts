#!/bin/bash
# Process placement shared by the harnesses. A role (Redis servers, memtier clients) is placed either on whole
# NUMA nodes (<ROLE>_NODES: each process bound to one node, round-robin over the list) or on vCPUs
# (<ROLE>_CORES: one process per listed vCPU, memory on that vCPU's node; "all" leaves the processes unpinned).
# Lists accept ranges, e.g. 0-31,64-95. Find the nodes and their vCPUs with: lscpu | grep NUMA

# "0-3,8" -> "0 1 2 3 8"
expand_list(){
	local part out=()
	for part in ${1//,/ }; do
		if [[ $part == *-* ]]; then out+=($(seq ${part%-*} ${part#*-})); else out+=($part); fi
	done
	echo "${out[@]}"
}

# Usage: placement <ROLE> "<command prefix that runs a shell command on the host>" "<nodes>" "<cores>"
# Sets SLOTS (launch prefix per process, used round-robin), SLOT_CPUS (vCPUs the processes can run on) and
# SLOT_NODES (the NUMA nodes of those vCPUs).
placement(){
	local role=$1 run=$2 nodes=$3 cores=$4 n c map
	SLOTS=(); SLOT_CPUS=""; SLOT_NODES=""
	if [[ -n $nodes && -n $cores ]] || [[ -z $nodes && -z $cores ]]; then
		echo "Error: set exactly one of ${role}_NODES and ${role}_CORES."
		exit 1
	fi
	# "<vCPU> <node>" for every vCPU of the host
	map=$($run 'for d in /sys/devices/system/cpu/cpu[0-9]*/node[0-9]*; do c=${d%/node*}; echo ${c##*cpu} ${d##*node}; done' | tr -d '\r')
	if [[ -n $nodes ]]; then
		for n in $(expand_list $nodes); do
			c=$(awk -v n=$n '$2==n{print $1}' <<< "$map" | sort -n | xargs)
			[[ -z $c ]] && { echo "Error: NUMA node $n in ${role}_NODES has no vCPUs."; exit 1; }
			SLOTS+=("numactl -N $n -m $n")
			SLOT_CPUS+=" $c"
		done
	elif [[ $cores == all ]]; then
		SLOTS=("")
		SLOT_CPUS=$(awk '{print $1}' <<< "$map" | sort -n | xargs)
	else
		for c in $(expand_list $cores); do
			n=$(awk -v c=$c '$1==c{print $2}' <<< "$map")
			[[ -z $n ]] && { echo "Error: vCPU $c in ${role}_CORES does not exist."; exit 1; }
			SLOTS+=("numactl -m $n taskset -c $c")
			SLOT_CPUS+=" $c"
		done
	fi
	SLOT_CPUS=$(echo $SLOT_CPUS)
	SLOT_NODES=$(awk -v cpus=" $SLOT_CPUS " 'index(cpus, " "$1" "){print $2}' <<< "$map" | sort -un | xargs)
}

# memtier harnesses: places the Redis servers (host reached via $1) and the memtier processes (this host; up to $2
# per client, and additional clients reuse it), and checks that they fit. Sets SERVER_SLOTS, CPUS,
# SERVER_NUMA_NODES, MEMTIER_SLOTS, MEMTIER_CPUS and MEMTIER_PROCS (one token per memtier process).
place_servers_and_memtier(){
	local run=$1 per_client=$2 c
	placement SERVER "$run" "$SERVER_NODES" "$SERVER_CORES"
	SERVER_SLOTS=("${SLOTS[@]}"); CPUS=$SLOT_CPUS; SERVER_NUMA_NODES=$SLOT_NODES
	placement MEMTIER "bash -c" "$MEMTIER_NODES" "$MEMTIER_CORES"
	MEMTIER_SLOTS=("${SLOTS[@]}"); MEMTIER_CPUS=$SLOT_CPUS
	echo "Redis server vCPUs: $CPUS"
	echo "Memtier vCPUs: $MEMTIER_CPUS"
	if [[ -n $SERVER_CORES && ${#SERVER_SLOTS[@]} -lt $NUM_SERVERS ]]; then
		echo "SERVER_CORES lists ${#SERVER_SLOTS[@]} vCPUs, fewer than NUM_SERVERS=$NUM_SERVERS."
		exit 1
	fi
	if [[ -n $MEMTIER_CORES && $MEMTIER_CORES != all && ${#MEMTIER_SLOTS[@]} -lt $per_client ]]; then
		echo "Each client drives up to $per_client Redis servers, but MEMTIER_CORES lists only ${#MEMTIER_SLOTS[@]} vCPUs."
		exit 1
	fi
	if [[ ${SERVER_REMOTE} != true && $MEMTIER_CORES != all ]]; then
		for c in $CPUS; do
			if [[ " $MEMTIER_CPUS " == *" $c "* ]]; then
				echo "Redis servers and memtier would share vCPU $c on this host; give them disjoint placements."
				exit 1
			fi
		done
	fi
	MEMTIER_PROCS=$(seq 0 $((NUM_SERVERS - 1)))
}

# Launch prefix for the n-th memtier process on a client
memtier_slot(){ echo "${MEMTIER_SLOTS[$(( $1 % ${#MEMTIER_SLOTS[@]} ))]}"; }
