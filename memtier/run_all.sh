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

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source set_ssh.sh from the shared-scripts directory relative to the script location
source "${SCRIPT_DIR}/../shared-scripts/set_ssh.sh"

#---------------------------------------------------------- Multi-Client Helper Functions -------------------------------------------------------

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
    
    # Build command string for remote execution
    local remote_cmd=""
    for ((server=$start_server; server<=$end_server; server++)); do
        local port=$(($START_PORT + $server))
        
        if [ "$phase" = "fill" ]; then
            # Fill phase: use -n allkeys and write-only ratio
            remote_cmd+="memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=$MEMTIER_PIPELINE --key-pattern=P:P --ratio=1:0 --out-file=/tmp/fill_${server}_run${iteration}.log >/dev/null & "
        else
            # Benchmark phase: use test-time and read/write ratio
            local test_duration="${BENCHMARK_DURATION:-300}"
            remote_cmd+="memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$test_duration --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=/tmp/benchmark_${server}_run${iteration}.log >/dev/null & "
        fi
    done
    
    # Debug: show the remote command
    echo "DEBUG: Executing remote command: $remote_cmd"
    
    # Execute remotely and return immediately (background on remote)
    $ssh_cmd "$remote_cmd" &
}

# Wait for remote clients to complete fill phase
wait_for_remote_fill() {
    echo "Waiting for remote clients to complete fill phase..."
    
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local client_ip="${CLIENT_IPS[$i]}"
        local ssh_cmd="${CLIENT_SSH_CMDS[$i]}"
        
        # Wait for memtier processes to finish on remote client with timeout
        echo "Waiting for fill to complete on client $client_ip"
        local timeout=60  # 60 seconds timeout
        local count=0
        
        while [ $count -lt $timeout ]; do
            # Check for actual memtier_benchmark processes (not bash containing the string)
            if $ssh_cmd "pgrep '^memtier_benchmark' > /dev/null"; then
                echo "Fill still running on $client_ip, waiting..."
                sleep 2
                count=$((count + 2))
            else
                break
            fi
        done
        
        if [ $count -ge $timeout ]; then
            echo "Warning: Timeout waiting for fill on client $client_ip"
        else
            echo "Fill completed on client $client_ip"
        fi
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
        
        # Collect benchmark results for this specific run
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} \
            ${LOGIN_ID}@${client_ip}:/tmp/benchmark_*_run${iteration}.log \
            ${RESULTS_PATH}/run${iteration}/ 2>/dev/null
            
        # Also collect fill results for this specific run
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} \
            ${LOGIN_ID}@${client_ip}:/tmp/fill_*_run${iteration}.log \
            ${RESULTS_PATH}/run${iteration}/ 2>/dev/null
            
        # Rename downloaded files to include client IP to avoid conflicts
        cd ${RESULTS_PATH}/run${iteration}/
        for file in benchmark_*_run${iteration}.log fill_*_run${iteration}.log; do
            if [[ -f "$file" && "$file" != *"client_${client_suffix}"* ]]; then
                # Extract the base name and add client suffix
                base_name="${file%_run${iteration}.log}"
                new_name="${base_name}_client_${client_suffix}_run${iteration}.log"
                mv "$file" "$new_name" 2>/dev/null
                echo "Renamed $file to $new_name"
            fi
        done
    done
}

# Wait for remote memtier processes to complete
wait_for_remote_clients() {
    echo "Waiting for remote clients to complete..."
    
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local ssh_cmd="${CLIENT_SSH_CMDS[$i]}"
        local client_ip="${CLIENT_IPS[$i]}"
        
        # Handle localhost clients differently
        if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "localhost" ]]; then
            while pgrep -f "memtier_benchmark" > /dev/null 2>&1; do
                sleep 5
            done
        else
            # Use pgrep to avoid matching bash processes containing "memtier_benchmark"
            while $ssh_cmd "pgrep -f '^[^ ]*memtier_benchmark' > /dev/null 2>&1"; do
                sleep 5
            done
        fi
        echo "Client $client_ip completed"
    done
}

# Aggregate results from multiple clients into combined files
aggregate_multi_client_results() {
    echo "Aggregating results from multiple clients..."
    
    for iteration in 1 2 3; do
        local run_dir="${RESULTS_PATH}/run${iteration}"
        if [ ! -d "$run_dir" ]; then
            continue
        fi
        
        echo "Processing run${iteration}..."
        cd "$run_dir"
        
        # Find all benchmark log files (local and remote clients)
        local benchmark_files=$(ls benchmark_*.log 2>/dev/null)
        if [ -z "$benchmark_files" ]; then
            echo "No benchmark files found in run${iteration}"
            continue
        fi
        
        # Extract and sum ops/sec and average latency from all clients
        local total_ops=0
        local total_latency=0
        local client_count=0
        
        for file in $benchmark_files; do
            echo "Processing $file..."
            
            # Extract ops/sec (from Totals line)
            local ops=$(grep "Totals" "$file" | awk '{print $2}' 2>/dev/null)
            # Extract latency (from Totals line)
            local latency=$(grep "Totals" "$file" | awk '{print $5}' 2>/dev/null)
            
            if [ -n "$ops" ] && [ -n "$latency" ]; then
                total_ops=$(echo "$total_ops + $ops" | bc -l)
                total_latency=$(echo "$total_latency + $latency" | bc -l)
                client_count=$((client_count + 1))
                echo "  Client ops/sec: $ops, latency: $latency"
            fi
        done
        
        if [ $client_count -gt 0 ]; then
            # Calculate average latency
            local avg_latency=$(echo "scale=5; $total_latency / $client_count" | bc -l)
            
            echo "Run${iteration} totals: ${total_ops} ops/sec, ${avg_latency} avg latency (${client_count} clients)"
            
            # Create aggregated result file
            echo "Multi-client aggregated results for run${iteration}:" > "aggregated_run${iteration}.txt"
            echo "Total Ops/sec: $total_ops" >> "aggregated_run${iteration}.txt"
            echo "Average Latency: $avg_latency" >> "aggregated_run${iteration}.txt"
            echo "Number of clients: $client_count" >> "aggregated_run${iteration}.txt"
        fi
    done
    
    echo "Multi-client aggregation complete."
}

#---------------------------------------------------------- End Multi-Client Helper Functions -------------------------------------------------------

# Setup multi-client mode if configured
setup_multi_client

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

$SSH_COMMAND pkill redis-server
while [ `$SSH_COMMAND ps -e | grep -c redis-server` -gt 0 ];do
	ret=`$SSH_COMMAND ps -e | grep -c redis-server`
	echo -e "Waiting for $ret redis-server(s) to stop"
        sleep 5
done

mkdir -p ${RESULTS_PATH}
if [[ ${SERVER_REMOTE} == true ]] ; then
	$SSH_COMMAND mkdir -p ${RESULTS_PATH}
fi
cp $config_file ${RESULTS_PATH}

if [ $PIN == "sub-numa" ]; then
    IFS=',' read -ra nodes_array <<< "$NUMA_NODES"
    nodes_array_len=${#nodes_array[@]}
fi

#---------------------------------------------------------- Install Pre-reqs -------------------------------------------------------
# Note: install_prereqs.sh now automatically handles remote client installation
# when CLIENT_IPS array is populated (set by set_ssh.sh in multi-client mode)
# Set SCRIPT_BASE_DIR for use by install_prereqs.sh
export SCRIPT_BASE_DIR="$(cd "${SCRIPT_DIR}/../shared-scripts" && pwd)"
source "${SCRIPT_DIR}/../shared-scripts/install_prereqs.sh"

source "${SCRIPT_DIR}/../shared-scripts/check_numa.sh"

#---------------------------------------------------------- Disable Huge Pages -------------------------------------------------------
# This is very important. Without disabling huge pages, we can get into a difficult to reproduce situation of bad performance. 
if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Current huge pages policy" 
	$SSH_COMMAND cat /sys/kernel/mm/transparent_hugepage/enabled
	echo "Setting Transparent Huge Pages policy to never." 
	$SSH_COMMAND "echo never >  /sys/kernel/mm/transparent_hugepage/enabled"
	$SSH_COMMAND cat /sys/kernel/mm/transparent_hugepage/enabled
else
	echo "Current huge pages policy" 
	cat /sys/kernel/mm/transparent_hugepage/enabled
	echo "Setting Transparent Huge Pages policy to never." 
	echo never >  /sys/kernel/mm/transparent_hugepage/enabled
	cat /sys/kernel/mm/transparent_hugepage/enabled
fi

#---------------------------------------------------------- Enable Memory Overcommit ------------------------------------------------
if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Current memory overcommit setting" 
	$SSH_COMMAND sysctl vm.overcommit_memory
	echo "Enable memory overcommit" 
	$SSH_COMMAND "sysctl vm.overcommit_memory=1"
else
	echo "Current memory overcommit setting" 
	sysctl vm.overcommit_memory
	echo "Enable memory overcommit" 
	sysctl vm.overcommit_memory=1
fi

#---------------------------check cpu configuration------------------------------------------
if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Redis server and memtier benchmark are on different nodes." 
	NUM_CPUS=$($SSH_COMMAND numactl --hardware | grep "node [$SERVER_SOCKET] cpus" |  awk -F ':' '{print $2}' | wc -w | tr -d '[:space:]')
	CPUS=$($SSH_COMMAND numactl --hardware | grep "node [${SERVER_SOCKET}] cpus" |  awk -F ':' '{print $2}' | tr -d '\n' | tr -d '\r')
	MEMTIER_CPUS=$(numactl --hardware | grep "node [${MEMTIER_SOCKET}] cpus" |  awk -F ':' '{print $2}' | tr -d '\n')
	if [[ $NUM_CPUS -lt $NUM_SERVERS ]]; then
		echo "Use at most $NUM_CPUS Redis servers per socket. " 
		exit 1
	fi
else
	NUM_CPUS=`numactl --hardware | grep "node [$SERVER_SOCKET] cpus" |  awk -F ':' '{print $2}' | wc -w`
	if [[ $SERVER_SOCKET == $MEMTIER_SOCKET ]]; then
		echo "Redis server and memtier benchmark are on the same node and on the same socket." 
		SPLIT_SOCKET=$((NUM_CPUS / 2))
		if [[ $SPLIT_SOCKET -lt $NUM_SERVERS ]]; then
			echo "Since we are sharing the socket between Redis and Memtier, use at most $SPLIT_SOCKET Redis servers. " 
			exit 1
		fi

		CPUS=`numactl --hardware | grep "node [${SERVER_SOCKET}] cpus" |  awk -F ':' '{print $2}' | tr -d '\n'`
		REV_CPUS=""
		for cpu in $CPUS
		do
			REV_CPUS="$cpu $REV_CPUS"
		done
		MEMTIER_CPUS=$REV_CPUS
	else
		echo "Redis server and memtier benchmark are on the same node on different sockets." 
		CPUS=`numactl --hardware | grep "node [${SERVER_SOCKET}] cpus" |  awk -F ':' '{print $2}' | tr -d '\n'`
		MEMTIER_CPUS=`numactl --hardware | grep "node [${MEMTIER_SOCKET}] cpus" |  awk -F ':' '{print $2}' | tr -d '\n'`

		if [[ $NUM_CPUS -lt $NUM_SERVERS ]]; then
			echo "Use at most $NUM_CPUS Redis servers per socket. " 
			exit 1
		fi
	fi
fi

echo "Redis server CPUS: $CPUS" 
echo "Memtier CPUS: $MEMTIER_CPUS" 

if [ -z "$CPUS" ]; then
	echo "Error identifying Redis server CPUs."
	exit 1
fi
if [ -z "$MEMTIER_CPUS" ]; then
	echo "Error identifying memtier server CPUs."
	exit 1
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
	source "${SCRIPT_DIR}/../shared-scripts/set_irq.sh"
fi

$SSH_COMMAND mkdir -p ${REDIS_PATH}/log
for (( iteration=1; iteration <= $ITERATION_NUM; iteration++ ))
do

	mkdir ${RESULTS_PATH}/run${iteration}

	#--------------------------start master servers------------------------------------------------------
	instances=1
    if [ ${PIN} == "cpu" ]; then
        for cpu in $CPUS
            do
                port=$(($START_PORT + ${instances}))
                ret=$($SSH_COMMAND lsof -i:$port)
                ret_code=$(echo $? | tr -d '[:space:]') 
                
                #In the case of more than one NUMA node, discover to which NUMA node this CPU belongs
                cmd="ls /sys/devices/system/cpu/cpu${cpu}"
                if [[ ${SERVER_REMOTE} == true ]] ; then
                    cpu_numa_node=$($SSH_COMMAND "$cmd | grep "^node" | grep -o "[0-9]" | tr -d '[:space:]'")  
                else
                    cpu_numa_node=$($cmd | grep "^node" | grep -o "[0-9]" )
                fi

                if [[ $ret_code == 1 ]]; then
                    echo -e "starting redis server $instances on vCPU $cpu"
                    cmd="numactl -m $cpu_numa_node taskset -c $cpu  $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --logfile $REDIS_PATH/log/server${instances}.log --port ${port} --save \"\" "
                    echo -e $cmd

                    #NOTE: Do not start the Redis servers using SSH if they are not remote. 
                    #For some unknown reason that leads to a performace degradation. 
                    if [[ ${SERVER_REMOTE} == true ]] ; then
                        $SSH_COMMAND $cmd & 
                    else
                        $cmd &
                    fi
                    instances=$((instances + 1))
                else
                    echo "Port: $port is already in use. Will not be able to start redis-server. Exiting." 
                    exit 1      
                fi

                if [ $instances -gt $NUM_SERVERS ]
                then
                    break
                fi
            done
    elif [ ${PIN} == "sub-numa" ]; then
        iter_var=0
        while [ "$instances" -le $NUM_SERVERS ]; do
            port=$(($START_PORT + ${instances}))
            ret=$($SSH_COMMAND lsof -i:$port)
            ret_code=$(echo $? | tr -d '[:space:]') 
            if [[ $ret_code == 1 ]]; then
                echo -e "starting redis server $instances on sub-numa ${nodes_array[$iter_var]}"
                cmd="numactl -m ${nodes_array[$iter_var]} -N ${nodes_array[$iter_var]} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --logfile $REDIS_PATH/log/server${instances}.log --port ${port} --save \"\" "
                echo -e $cmd
                if [[ ${SERVER_REMOTE} == true ]] ; then
                    $SSH_COMMAND $cmd & 
                else
                    $cmd &
                fi
                iter_var=$((iter_var+1))
            else
                echo "Port: $port is already in use. Will not be able to start redis-server. Exiting." 
                exit 1   
            fi
            if [ "$iter_var" -eq "$nodes_array_len" ]; then
                iter_var=0
            fi
            ((instances++))
        done

    fi

	while [ $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') -lt $NUM_SERVERS ];do
		echo -e "Waiting for all redis servers to start"
		sleep 5
	done

	echo "$($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]' ) redis servers started"


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
		for cpu in $MEMTIER_CPUS
		do
			if [ $instances -gt $end_server ]; then break; fi
			
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances on vCPU $cpu"
			
			#In the case of more than one NUMA node, discover to which NUMA node this CPU belongs
			cmd="ls /sys/devices/system/cpu/cpu${cpu}"
			cpu_numa_node=$($cmd | grep "^node" | grep -o "[0-9]")

			cmd="numactl -m $cpu_numa_node taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/run${iteration}/fill_$instances.log"
			instances=$((instances + 1))
			echo -e $cmd
			$cmd >/dev/null &
		done
	else
		# Single client mode - original logic
		instances=1
		for cpu in $MEMTIER_CPUS
		do
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances on vCPU $cpu"
			
			#In the case of more than one NUMA node, discover to which NUMA node this CPU belongs
			cmd="ls /sys/devices/system/cpu/cpu${cpu}"
			cpu_numa_node=$($cmd | grep "^node" | grep -o "[0-9]")

			cmd="numactl -m $cpu_numa_node taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/run${iteration}/fill_$instances.log"
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
	while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
		echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
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

			instances=1
			for cpu in $MEMTIER_CPUS
			do
				port=$(($START_PORT + ${instances}))
				echo -e "AUTOTUNING. starting memtier benchmark $instances on vCPU $cpu"
		
				#In the case of more than one NUMA node, discover to which NUMA node this CPU belongs
				cmd="ls /sys/devices/system/cpu/cpu${cpu}"
				cpu_numa_node=$($cmd | grep "^node" | grep -o "[0-9]")

				cmd="numactl -m $cpu_numa_node taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=10 --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/autotune/benchmark_$instances.log"
				instances=$((instances + 1))
				echo -e $cmd
				$cmd >/dev/null &

				if [ $instances -gt $NUM_SERVERS ]
				then
					break
				fi
			done
			while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
				echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
				sleep 5
			done

			avg_latency=`cat ${RESULTS_PATH}/autotune/benchmark_* | grep Totals | awk -F " " '{total += $5; count++}END{ print total/count}'`
			echo "Average Latency: " 
			echo $avg_latency
			echo "Average Latency: " >> ${RESULTS_PATH}/autotune/autotune.log
			echo $avg_latency >> ${RESULTS_PATH}/autotune/autotune.log
			if ((  $(echo "${avg_latency} > 1.0" | bc -l) )); 
			then
				echo "We have exceeded the SLA using -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS . "
				echo "We have exceeded the SLA using -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS . " >> ${RESULTS_PATH}/autotune/autotune.log
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
		for cpu in $MEMTIER_CPUS
		do
			if [ $instances -gt $end_server ]; then break; fi
			
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances on vCPU $cpu"
			
			cmd="ls /sys/devices/system/cpu/cpu${cpu}"
			cpu_numa_node=$($cmd | grep "^node" | grep -o "[0-9]")

			cmd="numactl -m $cpu_numa_node taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/run${iteration}/benchmark_$instances.log"
			instances=$((instances + 1))
			echo -e $cmd
			$cmd >/dev/null &
		done
	else
		# Original single-client code
		instances=1
		for cpu in $MEMTIER_CPUS
		do
			port=$(($START_PORT + ${instances}))
			echo -e "starting memtier benchmark $instances on vCPU $cpu"

			#In the case of more than one NUMA node, discover to which NUMA node this CPU belongs
			cmd="ls /sys/devices/system/cpu/cpu${cpu}"
			cpu_numa_node=$($cmd | grep "^node" | grep -o "[0-9]")

			cmd="numactl -m $cpu_numa_node taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/run${iteration}/benchmark_$instances.log"
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
		cmd="${EMON_FOLDER}/emon -collect-edp -f ${RESULTS_PATH}/memtier-emon.dat "
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
            	cmd="perf record -o ${RESULTS_PATH}/run${iteration}-perf.data -F 99 -a -g -- sleep 30 &> /dev/null"
		if [[ ${SERVER_REMOTE} == true ]] ; then
			$SSH_COMMAND $cmd  
		else
			$cmd
		fi
            	#perf record -o ${RESULTS_PATH}/run${iteration}-perf-ins.data -a -g -e instructions:ppp -- sleep 30 &> /dev/null
            	echo "Perf recording complete."
            	
	    fi

        fi


	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		# Wait for local memtier to finish
		while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
			echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) local memtier to finish"
			sleep 5
		done
		
		# Wait for remote clients
		wait_for_remote_clients
	else
		# Original single-client wait
		while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
			echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
			sleep 5
		done
	fi

	# Collect results from additional clients if multi-client mode
	if [[ ${MULTI_CLIENT_MODE} == true ]]; then
		collect_client_results $iteration
	fi

	echo "Killing existing redis server instances and remove rdb files..."
	KILL_SIGNAL=15
	$SSH_COMMAND killall $KILL_SIGNAL redis-server
	while [ $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') -gt 1 ];do
		echo -e "Waiting for $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') Redis servers to die"
		sleep 5
	done
	$SSH_COMMAND rm -f ${RDB_PATH}/*.rdb


	if [ $iteration == 1 ] && [ $RUN_EMON == true ]; then 
		cmd="${EMON_FOLDER}/emon -stop "
		$SSH_COMMAND $cmd 
	fi

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
	echo "Copying data from remote server. " 
	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:${RESULTS_PATH}/* ${RESULTS_PATH}/
	#$SSH_COMMAND "rm -rf ${RESULTS_PATH}"
fi

#-------------------------- Process Emon ------------------ ------------------------------------------

echo "Post processing results..."

if [[ $RUN_EMON == true ]] ; then

	echo "Processing EMON results..."
	#dcsomc -n -x alanstu -d ${RESULTS_PATH} -G ${RESULTS_FOLDER}_redis_2lm_${NUM_SERVERS}
	CUR_DIR=`pwd`
	cd ${RESULTS_PATH}
	source "${SCRIPT_DIR}/../shared-scripts/emon_process.sh"
	cd $CUR_DIR
	echo "Done post processing EMON..."
fi

# Aggregate multi-client results if in multi-client mode
if [[ ${MULTI_CLIENT_MODE} == true ]]; then
    echo "Aggregating multi-client results..."
    aggregate_multi_client_results
fi

CUR_DIR=`pwd`
cd ${RESULTS_PATH}
source "${SCRIPT_DIR}/../shared-scripts/post_process.sh"
cd $CUR_DIR




