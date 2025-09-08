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
source $config_file


if [[ ${SERVER_REMOTE} == true ]] ; then
	$SSH_COMMAND pkill redis-server
	while [ `$SSH_COMMAND ps -e | grep -c redis-server` -gt 0 ];do
		ret=`$SSH_COMMAND ps -e | grep -c redis-server`
		echo -e "Waiting for $ret redis-server(s) to stop"
		sleep 5
	done
else
	pkill redis-server
	while [ `ps -e | grep -c redis-server` -gt 0 ];do
		ret=`ps -e | grep -c redis-server`
		echo -e "Waiting for $ret redis-server(s) to stop"
		sleep 5
	done
fi

if [ $PIN == "sub-numa" ]; then
    IFS=',' read -ra nodes_array <<< "$NUMA_NODES"
    nodes_array_len=${#nodes_array[@]}
fi

mkdir -p ${RESULTS_PATH}
if [[ ${SERVER_REMOTE} == true ]] ; then
	$SSH_COMMAND mkdir -p ${RESULTS_PATH}
fi
cp $config_file ${RESULTS_PATH}


#---------------------------check cpu configuration------------------------------------------
if [[ ${SERVER_REMOTE} == true ]] ; then
	echo "Redis server and memtier benchmark are on different nodes." 
	NUM_CPUS=$($SSH_COMMAND numactl --hardware | grep "node 0 cpus" |  awk -F ':' '{print $2}' | wc -w | tr -d '[:space:]')
	CPUS=$($SSH_COMMAND numactl --hardware | grep "node ${SERVER_SOCKET} cpus" |  awk -F ':' '{print $2}' | tr -d '\r')
	MEMTIER_CPUS=$(numactl --hardware | grep "node ${MEMTIER_SOCKET} cpus" |  awk -F ':' '{print $2}')
	if [[ $NUM_CPUS -lt $NUM_SERVERS ]]; then
		echo "Use at most $NUM_CPUS Redis servers per socket. " 
		exit 1
	fi
else
	NUM_CPUS=`numactl --hardware | grep "node 0 cpus" |  awk -F ':' '{print $2}' | wc -w`
	if [[ $SERVER_SOCKET == $MEMTIER_SOCKET ]]; then
		echo "Redis server and memtier benchmark are on the same node and on the same socket." 
		SPLIT_SOCKET=$((NUM_CPUS / 2))
		if [[ $SPLIT_SOCKET -lt $NUM_SERVERS ]]; then
			echo "Since we are sharing the socket between Redis and Memtier, use at most $SPLIT_SOCKET Redis servers. " 
			exit 1
		fi

		CPUS=`numactl --hardware | grep "node ${SERVER_SOCKET} cpus" |  awk -F ':' '{print $2}'`
		REV_CPUS=""
		for cpu in $CPUS
		do
			REV_CPUS="$cpu $REV_CPUS"
		done
		MEMTIER_CPUS=$REV_CPUS
	else
		echo "Redis server and memtier benchmark are on the same node on different sockets." 
		CPUS=`numactl --hardware | grep "node ${SERVER_SOCKET} cpus" |  awk -F ':' '{print $2}'`
		MEMTIER_CPUS=`numactl --hardware | grep "node ${MEMTIER_SOCKET} cpus" |  awk -F ':' '{print $2}'`

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

	if [[ ${SERVER_REMOTE} == true ]] ; then
		while [ $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') -lt $NUM_SERVERS ];do
			echo -e "Waiting for all redis servers to start"
			sleep 5
		done
		echo "$($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]' ) redis servers started"
	else
		while [ $(ps -e | grep -c redis-server | tr -d '[:space:]') -lt $NUM_SERVERS ];do
			echo -e "Waiting for all redis servers to start"
			sleep 5
		done
		echo "$(ps -e | grep -c redis-server | tr -d '[:space:]' ) redis servers started"
	fi


	#--------------------------start memtier benchmark FILL ---------------------------------------------
	instances=1
	for cpu in $MEMTIER_CPUS
	do
		port=$(($START_PORT + ${instances}))
		echo -e "starting memtier benchmark $instances on vCPU $cpu"
		cmd="numactl -m ${MEMTIER_SOCKET} taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/run${iteration}/fill_$instances.log"
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
	

	#--------------------------start memtier benchmark BENCHMARK ------------------------------------------
	instances=1
	for cpu in $MEMTIER_CPUS
	do
		port=$(($START_PORT + ${instances}))
		echo -e "starting memtier benchmark $instances on vCPU $cpu"
		cmd="numactl -m ${MEMTIER_SOCKET} taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/run${iteration}/benchmark_$instances.log"
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

	echo "Killing existing redis server instances and remove rdb files..."
	KILL_SIGNAL=15
	if [[ ${SERVER_REMOTE} == true ]] ; then
		$SSH_COMMAND killall $KILL_SIGNAL redis-server
		while [ $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') -gt 1 ];do
			echo -e "Waiting for $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') Redis servers to die"
			sleep 5
		done
		$SSH_COMMAND rm -f ${RDB_PATH}/*.rdb
	else
		killall $KILL_SIGNAL redis-server
		while [ $(ps -e | grep -c redis-server | tr -d '[:space:]') -gt 1 ];do
			echo -e "Waiting for $(ps -e | grep -c redis-server | tr -d '[:space:]') Redis servers to die"
			sleep 5
		done
		rm -f ${RDB_PATH}/*.rdb
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







