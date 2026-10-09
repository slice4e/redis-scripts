#!/bin/bash

# Read the config file
if [ "$1" != "" ]; then
	config_file=$1
else
	config_file="./redis_bench.config"
fi

# Check if the file exists
if [ ! -f "$config_file" ]; then
	echo "Error: The config file '$config_file' does not exist. Please use the config file template to create one."
	exit 1
fi
# Store environment variable before loading config
ENV_BENCHMARK_DURATION="${BENCHMARK_DURATION:-}"

source $config_file

# Override config values with environment variables if set
if [ ! -z "$ENV_BENCHMARK_DURATION" ]; then
	echo "Using BENCHMARK_DURATION from environment: $ENV_BENCHMARK_DURATION seconds (overriding config value: $BENCHMARK_DURATION)"
	BENCHMARK_DURATION=$ENV_BENCHMARK_DURATION
fi

# Default to redis for configs predating SERVER_TYPE, then derive the
# engine-specific binary name, source repo, and config file from it.
SERVER_TYPE="${SERVER_TYPE:-redis}"
case "$SERVER_TYPE" in
	redis)
		SERVER_BINARY=redis-server
		SERVER_REPO=https://github.com/redis/redis.git
		SERVER_CONF_FILE=redis.conf
		;;
	valkey)
		SERVER_BINARY=valkey-server
		SERVER_REPO=https://github.com/valkey-io/valkey.git
		SERVER_CONF_FILE=valkey.conf
		;;
	*)
		echo "Error: Unknown SERVER_TYPE '$SERVER_TYPE'. Must be 'redis' or 'valkey'."
		exit 1
		;;
esac

# Use a script-specific directory variable so sourced files cannot clobber it.
MEMTIER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source set_ssh.sh from the shared-scripts directory relative to the script location
source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/set_ssh.sh"

#---------------------------------------------------------- Multi-Client Helper Functions -------------------------------------------------------

# memtier processes started by this run; anchored on the binary path so other users' memtier processes are ignored.
MEMTIER_PATTERN="^${MEMTIER_PATH}/memtier_benchmark"
count_local_memtier() {
    pgrep -c -f "$MEMTIER_PATTERN"
}

# Setup multi-client mode based on variables set by set_ssh.sh
setup_multi_client() {
    if [[ -z "${ADDITIONAL_CLIENT_IPS}" ]]; then
        MULTI_CLIENT_MODE=false
        return
    fi
    
    MULTI_CLIENT_MODE=true
    
    # Build CLIENT_IPS and CLIENT_SSH_CMDS arrays from ADDITIONAL_CLIENT_IPS
    IFS=',' read -ra CLIENT_IPS <<< "$ADDITIONAL_CLIENT_IPS"
    CLIENT_SSH_CMDS=()
    for ip in "${CLIENT_IPS[@]}"; do
        # Trim whitespace from IP address
        ip=$(echo "$ip" | xargs)
        if [[ "$ip" == "127.0.0.1" || "$ip" == "localhost" ]]; then
            CLIENT_SSH_CMDS+=("bash -c")  # Local execution
        else
            CLIENT_SSH_CMDS+=("ssh -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${ip}")
        fi
    done
    
    NUM_CLIENTS=$((${#CLIENT_IPS[@]} + 1))  # +1 for primary client
    
    echo "Multi-client mode: $NUM_CLIENTS clients total"
}

# Calculate server range for each client (even split)
get_client_servers() {
    local client_idx=$1  # 0 = primary, 1+ = additional clients
    
    # If we have fewer servers than clients, use round-robin assignment
    if [ $NUM_SERVERS -lt $NUM_CLIENTS ]; then
        local server_for_client=$(( ($client_idx % $NUM_SERVERS) + 1 ))
        echo "${server_for_client}-${server_for_client}"
        return
    fi
    
    local servers_per_client=$(($NUM_SERVERS / $NUM_CLIENTS))
    local remainder=$(($NUM_SERVERS % $NUM_CLIENTS))
    
    local start_server=1
    for ((i=0; i<$client_idx; i++)); do
        local count=$servers_per_client
        if [ $i -lt $remainder ]; then
            ((count++))
        fi
        start_server=$((start_server + count))
    done
    
    local count=$servers_per_client
    if [ $client_idx -lt $remainder ]; then
        ((count++))
    fi
    local end_server=$((start_server + count - 1))
    
    echo "${start_server}-${end_server}"
}

# Launch memtier on remote client via SSH (reuse existing patterns)
launch_remote_memtier() {
    local client_idx=$1  # 1-based for additional clients
    local phase=$2       # "fill" or "benchmark"
    local iteration=$3
    
    local ssh_cmd="${CLIENT_SSH_CMDS[$((client_idx-1))]}"
    local client_ip="${CLIENT_IPS[$((client_idx-1))]}"
    local server_range=$(get_client_servers $client_idx)
    
    IFS='-' read -r start_server end_server <<< "$server_range"
    
    echo "Launching $phase on client $client_ip for servers $start_server to $end_server"
    
    # Build command string for remote execution; results go under the run's RESULTS_PATH on the client
    local out_dir="${RESULTS_PATH}/run${iteration}"
    if [ "$phase" = "autotune" ]; then
        out_dir="${RESULTS_PATH}/autotune"
    fi
    local remote_cmd="mkdir -p ${out_dir}; "
    if [ "$phase" = "autotune" ]; then
        # Autotune steps reuse file names; a memtier that fails to start must not leave the previous step's log behind
        remote_cmd+="rm -f ${out_dir}/benchmark_*.log; "
    fi
    for ((server=$start_server; server<=$end_server; server++)); do
        local port=$(($START_PORT + $server))
        # All clients are assumed to have the primary client's topology, so reuse its memtier CPU list
        local prefix=$(memtier_slot $((server - start_server)))
        
        if [ "$phase" = "fill" ]; then
            # Fill phase: use -n allkeys and write-only ratio
            remote_cmd+="$prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=$MEMTIER_PIPELINE --key-pattern=P:P --ratio=1:0 --out-file=${out_dir}/fill_${server}_run${iteration}.log >/dev/null & "
        else
            # Benchmark/autotune phase: use test-time and read/write ratio
            local test_duration="${BENCHMARK_DURATION:-300}"
            local out_file="${out_dir}/benchmark_${server}_run${iteration}.log"
            if [ "$phase" = "autotune" ]; then
                test_duration=10
                out_file="${out_dir}/benchmark_${server}.log"
            fi
            remote_cmd+="$prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$test_duration --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${out_file} >/dev/null & "
        fi
    done
    
    # Execute remotely and return immediately (background on remote)
    $ssh_cmd "$remote_cmd" &
}

# Wait for remote clients to complete fill phase
wait_for_remote_fill() {
    echo "Waiting for remote clients to complete fill phase..."
    
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local client_ip="${CLIENT_IPS[$i]}"
        local ssh_cmd="${CLIENT_SSH_CMDS[$i]}"
        
        # Wait for this run's memtier processes to finish on the remote client
        echo "Waiting for fill to complete on client $client_ip"
        while $ssh_cmd "pgrep -f '$MEMTIER_PATTERN' > /dev/null"; do
            echo "Fill still running on $client_ip, waiting..."
            sleep 2
        done
        echo "Fill completed on client $client_ip"
    done
    
    echo "All remote clients completed fill phase"
}

# Collect results from additional clients (reuse SCP pattern from server collection)
collect_client_results() {
    local iteration=$1
    
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local client_ip="${CLIENT_IPS[$i]}"
        echo "Collecting results from client $client_ip"
        
        # Create client-specific file names to avoid conflicts
        local client_suffix=$(echo $client_ip | tr '.' '_')
        local run_dir="${RESULTS_PATH}/run${iteration}"
        # Stage this client's files separately, so only they get this client's suffix
        local stage_dir="${run_dir}/client_${client_suffix}"
        mkdir -p "$stage_dir"
        
        if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "localhost" ]]; then
            # A localhost client already wrote into this RESULTS_PATH; pick out the files for its servers
            IFS='-' read -r start_server end_server <<< "$(get_client_servers $((i+1)))"
            for ((server=start_server; server<=end_server; server++)); do
                mv "${run_dir}/benchmark_${server}_run${iteration}.log" "${run_dir}/fill_${server}_run${iteration}.log" "$stage_dir"/ 2>/dev/null
            done
        else
            # Collect benchmark results for this specific run
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} \
                ${LOGIN_ID}@${client_ip}:${run_dir}/benchmark_*_run${iteration}.log \
                "$stage_dir"/ 2>/dev/null
                
            # Also collect fill results for this specific run
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} \
                ${LOGIN_ID}@${client_ip}:${run_dir}/fill_*_run${iteration}.log \
                "$stage_dir"/ 2>/dev/null
        fi
            
        # Rename this client's files to include its IP
        cd ${run_dir}/
        for file in "$stage_dir"/benchmark_*_run${iteration}.log "$stage_dir"/fill_*_run${iteration}.log; do
            [[ -f "$file" ]] || continue
            base_name=$(basename "${file%_run${iteration}.log}")
            new_name="${base_name}_client_${client_suffix}_run${iteration}.log"
            mv "$file" "$new_name"
            echo "Renamed $(basename "$file") to $new_name"
        done
        rmdir "$stage_dir"
    done
}

# The run totals sum whatever benchmark logs exist, so a client that returned fewer would silently undercount
check_client_results() {
    local iteration=$1
    local run_dir="${RESULTS_PATH}/run${iteration}"
    for ((c=0; c<${NUM_CLIENTS:-1}; c++)); do
        local suffix=$PRIMARY_CLIENT_SUFFIX
        local expected=$NUM_SERVERS
        if [ $c -gt 0 ]; then
            suffix=$(echo ${CLIENT_IPS[$((c-1))]} | tr '.' '_')
        fi
        if [[ ${MULTI_CLIENT_MODE} == true ]]; then
            IFS='-' read -r start_server end_server <<< "$(get_client_servers $c)"
            expected=$((end_server - start_server + 1))
        fi
        local found=$(grep -l Totals ${run_dir}/benchmark_*_client_${suffix}_run${iteration}.log 2>/dev/null | wc -l)
        if [ $found -lt $expected ]; then
            echo "WARNING: client ${suffix//_/.} returned $found of $expected benchmark results for run${iteration}; Total Ops/sec is undercounted" | tee -a ${RESULTS_PATH}/warnings.log
        fi
    done
}

# Collect autotune results from additional clients (file names already carry the server number)
collect_autotune_results() {
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local client_ip="${CLIENT_IPS[$i]}"
        if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "localhost" ]]; then
            continue
        fi
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} \
            ${LOGIN_ID}@${client_ip}:${RESULTS_PATH}/autotune/benchmark_*.log \
            ${RESULTS_PATH}/autotune/ 2>/dev/null
    done
}

# Wait for remote memtier processes to complete
wait_for_remote_clients() {
    
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local ssh_cmd="${CLIENT_SSH_CMDS[$i]}"
        local client_ip="${CLIENT_IPS[$i]}"
        
        # Handle localhost clients differently
        if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "localhost" ]]; then
            while pgrep -f "$MEMTIER_PATTERN" > /dev/null 2>&1; do
                sleep 5
            done
        else
            while $ssh_cmd "pgrep -f '$MEMTIER_PATTERN'" > /dev/null 2>&1; do
                echo "Waiting for remote clients to complete..."
                sleep 5
            done
        fi
        echo "Client $client_ip completed"
    done
}

#---------------------------------------------------------- End Multi-Client Helper Functions -------------------------------------------------------

# Setup multi-client mode if configured
setup_multi_client

# Name the primary client's logs by the address it uses to reach the server, like the additional clients' logs
PRIMARY_CLIENT_SUFFIX=$(ip -4 route get "$SERVER_IP" 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2 | tr '.' '_')
PRIMARY_CLIENT_SUFFIX=${PRIMARY_CLIENT_SUFFIX:-$(hostname -s)}

# Display server assignments if multi-client
if [[ ${MULTI_CLIENT_MODE} == true ]]; then
	echo "Server distribution (even-split):"
	for ((i=0; i<$NUM_CLIENTS; i++)); do
		range=$(get_client_servers $i)
		if [ $i -eq 0 ]; then
			echo "  Primary client: servers $range"
		else
			echo "  Client ${CLIENT_IPS[$((i-1))]}: servers $range"
		fi
	done
fi

if [ "$SSH_CONNECTED" != "true" ]; then
	echo "Couldn't connect to server, please verify whether server is up or your ssh passwordless login to \"${SERVER_IP}\" is setup properly."
	exit 1
fi

# Only match servers started from this REDIS_PATH, so other users' servers on a shared host are left alone.
SERVER_PATTERN="^${REDIS_PATH}/src/${SERVER_BINARY}"
count_servers() {
	$SSH_COMMAND pgrep -c -f "$SERVER_PATTERN" | tr -d '[:space:]'
}

$SSH_COMMAND pkill -f "$SERVER_PATTERN"
while [ "$(count_servers)" -gt 0 ];do
	echo -e "Waiting for $(count_servers) $SERVER_BINARY(s) to stop"
	sleep 5
done

mkdir -p ${RESULTS_PATH}
if [[ ${SERVER_REMOTE} == true ]] ; then
	$SSH_COMMAND mkdir -p ${RESULTS_PATH}
fi
cp $config_file ${RESULTS_PATH}
git -C "${MEMTIER_SCRIPT_DIR}" describe --tags --always --dirty > ${RESULTS_PATH}/redis-scripts-version.txt 2>/dev/null

#---------------------------------------------------------- Install Pre-reqs -------------------------------------------------------
# Note: install_prereqs.sh now automatically handles remote client installation
# when CLIENT_IPS array is populated (set by set_ssh.sh in multi-client mode)
# Set SCRIPT_BASE_DIR for use by install_prereqs.sh
export SCRIPT_BASE_DIR="$(cd "${MEMTIER_SCRIPT_DIR}/../shared-scripts" && pwd)"
source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/install_prereqs.sh"

#---------------------------------------------------------- Process placement -------------------------------------------------------
# Additional clients are assumed to have the controller's topology, so they reuse its memtier placement
source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/placement.sh"
place_servers_and_memtier "${SSH_COMMAND:-bash -c}" $(( (NUM_SERVERS + ${NUM_CLIENTS:-1} - 1) / ${NUM_CLIENTS:-1} ))

source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/check_numa.sh"

#---------------------------------------------------------- Disable Huge Pages -------------------------------------------------------
# This is very important. Without disabling huge pages, we can get into a difficult to reproduce situation of bad performance. 
if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Current huge pages policy" 
	$SSH_COMMAND cat /sys/kernel/mm/transparent_hugepage/enabled
	echo "Setting Transparent Huge Pages policy to never." 
	$SSH_COMMAND "echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null"
	$SSH_COMMAND cat /sys/kernel/mm/transparent_hugepage/enabled
else
	echo "Current huge pages policy" 
	cat /sys/kernel/mm/transparent_hugepage/enabled
	echo "Setting Transparent Huge Pages policy to never." 
	echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
	cat /sys/kernel/mm/transparent_hugepage/enabled
fi

#---------------------------------------------------------- Enable Memory Overcommit ------------------------------------------------
if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Current memory overcommit setting" 
	$SSH_COMMAND sudo sysctl vm.overcommit_memory
	echo "Enable memory overcommit" 
	$SSH_COMMAND "sudo sysctl vm.overcommit_memory=1"
else
	echo "Current memory overcommit setting" 
	sudo sysctl vm.overcommit_memory
	echo "Enable memory overcommit" 
	sudo sysctl vm.overcommit_memory=1
fi

#---------------------------------------------------------- Capture SVR-INFO --------------------------------------------------------
if [[ ${RUN_SVR_INFO} == true ]] ; then
	echo "Capture svr-info from the server."
	CUR_DIR=`pwd`
	cd ${RESULTS_PATH}
	if [[ ${SERVER_REMOTE} == true ]] ; then
		${SVR_INFO_PATH}/svr-info -ip $SERVER_IP -user $LOGIN_ID
	else
		${SVR_INFO_PATH}/svr-info 
	fi
	cd $CUR_DIR
	echo "Done capturing svr-info."
fi 


#--------------------------set network interrupts ---------------------------------------------------
if [[ $SET_IRQ == true ]]; then
	source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/set_irq.sh"
fi

$SSH_COMMAND mkdir -p ${REDIS_PATH}/log
for (( iteration=1; iteration <= $ITERATION_NUM; iteration++ ))
do

	mkdir ${RESULTS_PATH}/run${iteration}

	#--------------------------start master servers------------------------------------------------------
	for (( instances=1; instances <= NUM_SERVERS; instances++ ))
	do
		port=$(($START_PORT + ${instances}))
		ret=$($SSH_COMMAND lsof -i:$port)
		ret_code=$(echo $? | tr -d '[:space:]')
		if [[ $ret_code != 1 ]]; then
			echo "Port: $port is already in use. Will not be able to start $SERVER_BINARY. Exiting."
			exit 1
		fi
		slot=${SERVER_SLOTS[$(( (instances - 1) % ${#SERVER_SLOTS[@]} ))]}
		echo -e "starting $SERVER_TYPE server $instances: $slot"
		cmd="$slot $REDIS_PATH/src/$SERVER_BINARY $REDIS_PATH/$SERVER_CONF_FILE --logfile $REDIS_PATH/log/server${instances}.log --port ${port} --save \"\" "
		echo -e $cmd

		#NOTE: Do not start the Redis servers using SSH if they are not remote.
		#For some unknown reason that leads to a performace degradation.
		if [[ ${SERVER_REMOTE} == true ]] ; then
			$SSH_COMMAND $cmd &
		else
			$cmd &
		fi
	done

	while [ "$(count_servers)" -lt $NUM_SERVERS ];do
		echo -e "Waiting for all $SERVER_TYPE servers to start"
		sleep 5
	done

	echo "$(count_servers) $SERVER_TYPE servers started"


	#--------------------------start memtier benchmark FILL ---------------------------------------------
	
	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		# In multi-client mode, all clients need to perform fill to have consistent data
		echo "Multi-client mode: All clients performing fill phase"
		
		# Launch fill on additional clients first (in background)
		for ((i=1; i<$NUM_CLIENTS; i++)); do
			launch_remote_memtier $i "fill" $iteration
		done
		
		# Launch fill on primary client (for its assigned servers)
		server_range=$(get_client_servers 0)
		IFS='-' read -r start_server end_server <<< "$server_range"
		
		instances=$start_server
		for proc in $MEMTIER_PROCS
		do
			if [ $instances -gt $end_server ]; then break; fi
			
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances"
			pin_prefix=$(memtier_slot $proc)

			cmd="$pin_prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/run${iteration}/fill_${instances}_client_${PRIMARY_CLIENT_SUFFIX}_run${iteration}.log"
			instances=$((instances + 1))
			echo -e $cmd
			$cmd >/dev/null &
		done
	else
		# Single client mode - original logic
		instances=1
		for proc in $MEMTIER_PROCS
		do
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances"
			pin_prefix=$(memtier_slot $proc)

			cmd="$pin_prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/run${iteration}/fill_${instances}_client_${PRIMARY_CLIENT_SUFFIX}_run${iteration}.log"
			instances=$((instances + 1))
			echo -e $cmd
			$cmd >/dev/null &
			
			if [ $instances -gt $NUM_SERVERS ]
			then
				break
			fi
		done
	fi

	# Wait for local memtier processes to finish
	while [ $(count_local_memtier) -gt 0 ];do
		echo -e "Waiting for $(count_local_memtier) memtier_benchmark to finish"
		sleep 5
	done
	
	# If multi-client mode, also wait for remote clients to complete fill
	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		wait_for_remote_fill
	fi
	
	#-------------------------- Auto-tune memtier benchmark BENCHMARK----------------------------------------
	# Run memtier by gradually increasing the load until we violate the SLA. Pick a point, just before that. 
	
	TUNING_COMPLETE=false
	TOGGLE=true
	if [ $iteration == 1 ] && [ $AUTOTUNE == true ]; then 
		mkdir ${RESULTS_PATH}/autotune
		echo "AUTOTUNING is enabled. Will execute a few runs to tune for 1ms SLA."
		echo "AUTOTUNING is enabled. Will execute a few runs to tune for 1ms SLA." >> ${RESULTS_PATH}/autotune/autotune.log

		MEMTIER_CLIENTS=1
		MEMTIER_THREADS=1
		PREV_MEMTIER_CLIENTS=1
		PREV_MEMTIER_THREADS=1
		while [ $TUNING_COMPLETE == false ]; do
			
			echo "AUTOTUNING. -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS"
			echo "AUTOTUNING. -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS" >> ${RESULTS_PATH}/autotune/autotune.log
			rm -f ${RESULTS_PATH}/autotune/benchmark_*.log

			if [[ ${MULTI_CLIENT_MODE} == true ]]; then
				# Tune under the same load as the benchmark: every client drives its share of the servers
				for ((i=1; i<$NUM_CLIENTS; i++)); do
					launch_remote_memtier $i "autotune" $iteration
				done
				IFS='-' read -r instances last_server <<< "$(get_client_servers 0)"
			else
				instances=1
				last_server=$NUM_SERVERS
			fi
			for proc in $MEMTIER_PROCS
			do
				if [ $instances -gt $last_server ]; then break; fi

				port=$(($START_PORT + ${instances}))
				echo -e "AUTOTUNING. starting memtier benchmark $instances"
				pin_prefix=$(memtier_slot $proc)

				cmd="$pin_prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=10 --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/autotune/benchmark_$instances.log"
				instances=$((instances + 1))
				echo -e $cmd
				$cmd >/dev/null &
			done
			while [ $(count_local_memtier) -gt 0 ];do
				echo -e "Waiting for $(count_local_memtier) memtier_benchmark to finish"
				sleep 5
			done
			if [[ ${MULTI_CLIENT_MODE} == true ]]; then
				wait_for_remote_clients
				collect_autotune_results
			fi
			autotune_found=$(grep -l Totals ${RESULTS_PATH}/autotune/benchmark_*.log 2>/dev/null | wc -l)
			if [ $autotune_found -lt $NUM_SERVERS ]; then
				echo "WARNING: autotune step -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS returned $autotune_found of $NUM_SERVERS results; its latency is not representative" | tee -a ${RESULTS_PATH}/warnings.log ${RESULTS_PATH}/autotune/autotune.log
			fi

			avg_latency=`cat ${RESULTS_PATH}/autotune/benchmark_* | grep Totals | awk -F " " '{total += $5; count++}END{ print total/count}'`
			echo "Average Latency: " 
			echo $avg_latency
			echo "Average Latency: " >> ${RESULTS_PATH}/autotune/autotune.log
			echo $avg_latency >> ${RESULTS_PATH}/autotune/autotune.log
			if ((  $(echo "${avg_latency} > 1.0" | bc -l) )); 
			then
				echo "We have exceeded the SLA using -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS . "
				echo "We have exceeded the SLA using -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS . " >> ${RESULTS_PATH}/autotune/autotune.log
				if [ $MEMTIER_CLIENTS -eq 1 ] && [ $MEMTIER_THREADS -eq 1 ]; then
					echo "WARNING: the 1ms SLA is exceeded already at the minimum load (-c 1 -t 1, ${avg_latency} ms); this run is not SLA-compliant. Reduce NUM_SERVERS or MEMTIER_PIPELINE." | tee -a ${RESULTS_PATH}/warnings.log ${RESULTS_PATH}/autotune/autotune.log
				fi
				if [ $TOGGLE == true ]; then

					MEMTIER_CLIENTS=$PREV_MEMTIER_CLIENTS
				else
					MEMTIER_THREADS=$PREV_MEMTIER_THREADS
				fi
				echo "We will use -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS . "
				echo "AUTOTUNING is complete."
				echo "We will use -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS . " >> ${RESULTS_PATH}/autotune/autotune.log
				echo "AUTOTUNING is complete." >> ${RESULTS_PATH}/autotune/autotune.log
				TUNING_COMPLETE=true

			else
				if [ $TOGGLE == true ]; then

					PREV_MEMTIER_THREADS=$MEMTIER_THREADS
					MEMTIER_THREADS=$(($MEMTIER_THREADS +1))
					TOGGLE=false
				else
					PREV_MEMTIER_CLIENTS=$MEMTIER_CLIENTS
					MEMTIER_CLIENTS=$(($MEMTIER_CLIENTS +1))
					TOGGLE=true
				fi
			fi
		done
	fi

	#--------------------------start memtier benchmark BENCHMARK ------------------------------------------

	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		# Launch benchmark on additional clients first (in background)
		for ((i=1; i<$NUM_CLIENTS; i++)); do
			launch_remote_memtier $i "benchmark" $iteration
		done
		
		# Then launch on primary client (for its assigned servers)
		server_range=$(get_client_servers 0)
		IFS='-' read -r start_server end_server <<< "$server_range"
		
		instances=$start_server
		for proc in $MEMTIER_PROCS
		do
			if [ $instances -gt $end_server ]; then break; fi
			
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances"
			pin_prefix=$(memtier_slot $proc)

			cmd="$pin_prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/run${iteration}/benchmark_${instances}_client_${PRIMARY_CLIENT_SUFFIX}_run${iteration}.log"
			instances=$((instances + 1))
			echo -e $cmd
			$cmd >/dev/null &
		done
	else
		# Original single-client code
		instances=1
		for proc in $MEMTIER_PROCS
		do
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances"
			pin_prefix=$(memtier_slot $proc)

			cmd="$pin_prefix ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/run${iteration}/benchmark_${instances}_client_${PRIMARY_CLIENT_SUFFIX}_run${iteration}.log"
			instances=$((instances + 1))
			echo -e $cmd
			$cmd >/dev/null &

			if [ $instances -gt $NUM_SERVERS ]
			then
				break
			fi
		done
	fi

	if [ $iteration == 1 ] && [ $RUN_EMON == true ]; then
		echo "Starting emon... (First, try to stop if emon is running)"
		cmd="${EMON_FOLDER}/emon -stop "
		$SSH_COMMAND $cmd
		cmd="${EMON_FOLDER}/emon -collect-edp -f ${RESULTS_PATH}/memtier-emon.dat"
		$SSH_COMMAND $cmd &
	fi

	# Run perf and sar only with the last iteration
	if [[ $iteration == $ITERATION_NUM ]]; then
		sleep 5

		if [[ $RUN_SAR == true ]]; then
			if [[ ${SERVER_REMOTE} == true ]] ; then
				echo "Starting sar..."
				cmd="sar 1 ${SAR_DURATION} > ${RESULTS_PATH}/sar-cpu.log"
				$SSH_COMMAND $cmd &
				cmd="sar 1 -r ${SAR_DURATION} > ${RESULTS_PATH}/sar-mem.log"
				$SSH_COMMAND $cmd &
			else
				echo "Starting sar..."
				sar 1 ${SAR_DURATION} > ${RESULTS_PATH}/sar-cpu.log &
				sar 1 -r ${SAR_DURATION} > ${RESULTS_PATH}/sar-mem.log &
				#cmd="sar -d 1 ${SAR_DURATION} -p --dev=sda > ${RESULTS_PATH}/sar-disk.log"
				#$SSH_COMMAND $cmd &
				#cmd="sar -n DEV --iface=enp3s0f1 1 ${SAR_DURATION} > ${RESULTS_PATH}/sar-net.log"
				#$SSH_COMMAND $cmd &
			fi
		fi

		if [[ $RUN_PERF == true ]]; then
			echo "Starting perf..."
			cmd="sudo perf record -o ${RESULTS_PATH}/run${iteration}-perf.data -F 99 -a -g -- sleep ${PERF_DURATION} &> /dev/null"
			if [[ ${SERVER_REMOTE} == true ]] ; then
				$SSH_COMMAND $cmd
				# perf.data is owned by root since perf record ran via sudo; make it
				# readable so the subsequent (non-sudo) perf report/script steps can access it.
				$SSH_COMMAND "sudo chmod a+r ${RESULTS_PATH}/run${iteration}-perf.data"
			else
				$cmd
				sudo chmod a+r ${RESULTS_PATH}/run${iteration}-perf.data
			fi
			#perf record -o ${RESULTS_PATH}/run${iteration}-perf-ins.data -a -g -e instructions:ppp -- sleep 30 &> /dev/null
			echo "Perf recording complete."
		fi
	fi

	# Stop emon after EMON_DURATION seconds (after all tools are started, before waiting for workload)
	if [ $iteration == 1 ] && [ $RUN_EMON == true ]; then
		echo "Waiting ${EMON_DURATION}s for emon collection..."
		sleep ${EMON_DURATION}
		echo "Stopping emon..."
		cmd="${EMON_FOLDER}/emon -stop "
		$SSH_COMMAND $cmd
	fi

	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		# Wait for local memtier to finish
		while [ $(count_local_memtier) -gt 0 ];do
			echo -e "Waiting for $(count_local_memtier) local memtier to finish"
			sleep 5
		done
		
		# Wait for remote clients
		wait_for_remote_clients
	else
		# Original single-client wait
		while [ $(count_local_memtier) -gt 0 ];do
			echo -e "Waiting for $(count_local_memtier) memtier_benchmark to finish"
			sleep 5
		done
	fi

	# Collect results from additional clients if multi-client mode
	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		collect_client_results $iteration
	fi

	echo "Killing existing $SERVER_TYPE server instances and remove rdb files..."
	KILL_SIGNAL=15
	$SSH_COMMAND pkill -$KILL_SIGNAL -f "$SERVER_PATTERN"
	while [ "$(count_servers)" -gt 0 ];do
		echo -e "Waiting for $(count_servers) $SERVER_TYPE servers to die"
		sleep 5
	done
	$SSH_COMMAND rm -f ${RDB_PATH}/*.rdb

	if [[ $iteration == $ITERATION_NUM ]]; then

		if [[ $RUN_PERF == true ]]; then
			echo "Creating perf results..."
			cmd="perf report --hierarchy -i ${RESULTS_PATH}/run${iteration}-perf.data > ${RESULTS_PATH}/memtier-run${iteration}-perf-hierarchy.txt"
			if [[ ${SERVER_REMOTE} == true ]] ; then
				$SSH_COMMAND $cmd
			else
				perf report --hierarchy -i ${RESULTS_PATH}/run${iteration}-perf.data > ${RESULTS_PATH}/memtier-run${iteration}-perf-hierarchy.txt
			fi
			cmd="perf report --max-stack 0 -i ${RESULTS_PATH}/run${iteration}-perf.data > ${RESULTS_PATH}/memtier-run${iteration}-perf.txt"
			if [[ ${SERVER_REMOTE} == true ]] ; then
				$SSH_COMMAND $cmd
			else
				perf report --max-stack 0 -i ${RESULTS_PATH}/run${iteration}-perf.data > ${RESULTS_PATH}/memtier-run${iteration}-perf.txt
			fi
			#perf report -i ${RESULTS_PATH}/run${iteration}-perf-ins.data > ${RESULTS_PATH}/memtier-run${iteration}-perf-ins.txt

			if [[ $RUN_FLAMEGRAPH == true ]]; then
				echo "Creating flame graphs"
				cmd="perf script -i ${RESULTS_PATH}/run${iteration}-perf.data | ${flamegraph_folder}/stackcollapse-perf.pl > ${RESULTS_PATH}/run${iteration}.perf-folded"
				if [[ ${SERVER_REMOTE} == true ]] ; then
					$SSH_COMMAND $cmd
				else
					perf script -i ${RESULTS_PATH}/run${iteration}-perf.data | ${flamegraph_folder}/stackcollapse-perf.pl > ${RESULTS_PATH}/run${iteration}.perf-folded
				fi
				cmd="${flamegraph_folder}/flamegraph.pl ${RESULTS_PATH}/run${iteration}.perf-folded > ${RESULTS_PATH}/memtier-run${iteration}.perf-folded.svg"
				if [[ ${SERVER_REMOTE} == true ]] ; then
					$SSH_COMMAND $cmd
				else
					${flamegraph_folder}/flamegraph.pl ${RESULTS_PATH}/run${iteration}.perf-folded > ${RESULTS_PATH}/memtier-run${iteration}.perf-folded.svg
				fi
				cmd="rm -f ${RESULTS_PATH}/run${iteration}.perf-folded"
				if [[ ${SERVER_REMOTE} == true ]] ; then
					$SSH_COMMAND $cmd
				else
					rm -f ${RESULTS_PATH}/run${iteration}.perf-folded
				fi

				#perf script -i ${RESULTS_PATH}/run${iteration}-perf-ins.data | ${flamegraph_folder}/stackcollapse-perf.pl > ${RESULTS_PATH}/run${iteration}.perf-ins-folded
				#${flamegraph_folder}/flamegraph.pl ${RESULTS_PATH}/run${iteration}.perf-ins-folded > ${RESULTS_PATH}/memtier-run${iteration}.perf-ins-folded.svg
				#rm -f ${RESULTS_PATH}/run${iteration}.perf-ins-folded
			fi
		fi
	fi

	#-------------------------- Process Results ------------------------------------------------------------

	check_client_results $iteration
	echo "Total Ops/sec"
	total_ops=`cat ${RESULTS_PATH}/run${iteration}/benchmark_* | grep Totals | awk -F " " '{total += $2; count++ } END { print total} '`
	echo $total_ops
	echo "Num_servers_$NUM_SERVERS,Total.Ops/sec,$total_ops" > ${RESULTS_PATH}/memtier-run${iteration}.csv 
	echo "Avg Latency"
	avg_latency=`cat ${RESULTS_PATH}/run${iteration}/benchmark_* | grep Totals | awk -F " " '{total += $5; count++}END{ print total/count}'`
	echo $avg_latency
	echo "Num_servers_$NUM_SERVERS,Avg Latency,$avg_latency" >> ${RESULTS_PATH}/memtier-run${iteration}.csv 

done

#-------------------------- Copy Results from remote server ------------------------------------------------------------
if [[ ${SERVER_REMOTE} == true ]] ; then
	# Check if there are any files to copy
	# ssh -t ends the output with \r
	file_count=$($SSH_COMMAND "ls -1 ${RESULTS_PATH} 2>/dev/null | wc -l" | tr -d '\r')
	if [ "$file_count" -gt 0 ]; then
		echo "Copying data from remote server. " 
		scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:${RESULTS_PATH}/* ${RESULTS_PATH}/
	else
		echo "No files to copy from remote server (directory is empty)."
	fi
	#$SSH_COMMAND "rm -rf ${RESULTS_PATH}"
fi

#-------------------------- Process Emon ------------------ ------------------------------------------

echo "Post processing results..."

if [[ $RUN_EMON == true ]] ; then

	echo "Processing EMON results..."
	#dcsomc -n -x alanstu -d ${RESULTS_PATH} -G ${RESULTS_FOLDER}_redis_2lm_${NUM_SERVERS}
	CUR_DIR=`pwd`
	cd ${RESULTS_PATH}
	source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/emon_process.sh"
	cd $CUR_DIR
	echo "Done post processing EMON..."
fi

CUR_DIR=`pwd`
cd ${RESULTS_PATH}
source "${MEMTIER_SCRIPT_DIR}/../shared-scripts/post_process.sh"
cd $CUR_DIR
