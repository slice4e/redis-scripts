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
IFS='|' read -ra SERVER_IPS <<< "$SERVER_IP"
SERVER_IP=${SERVER_IPS[0]}


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

mkdir -p ${RESULTS_PATH}
if [[ ${SERVER_REMOTE} == true ]] ; then
	$SSH_COMMAND mkdir -p ${RESULTS_PATH}
fi
cp $config_file ${RESULTS_PATH}
git -C "$(dirname "$0")" describe --tags --always --dirty > ${RESULTS_PATH}/redis-scripts-version.txt 2>/dev/null


#---------------------------process placement------------------------------------------
source "$(dirname "$0")/../shared-scripts/placement.sh"
place_servers_and_memtier "${SSH_COMMAND:-bash -c}" $NUM_SERVERS


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
			echo "Port: $port is already in use. Will not be able to start redis-server. Exiting."
			exit 1
		fi
		slot=$(server_slot $instances)
		echo -e "starting redis server $instances: $slot"
		cmd="$slot $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --logfile $REDIS_PATH/log/server${instances}.log --port ${port} --save \"\" "
		echo -e $cmd

		#NOTE: Do not start the Redis servers using SSH if they are not remote.
		#For some unknown reason that leads to a performace degradation.
		if [[ ${SERVER_REMOTE} == true ]] ; then
			$SSH_COMMAND $cmd &
		else
			$cmd &
		fi
	done

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
	for proc in $MEMTIER_PROCS
	do
		port=$(($START_PORT + ${instances}))
		echo -e "starting memtier benchmark $instances"
		cmd="$(memtier_slot $proc $instances) ${MEMTIER_PATH}/memtier_benchmark -s $(server_ip $instances) -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/run${iteration}/fill_$instances.log"
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
	for proc in $MEMTIER_PROCS
	do
		port=$(($START_PORT + ${instances}))
		echo -e "starting memtier benchmark $instances"
		cmd="$(memtier_slot $proc $instances) ${MEMTIER_PATH}/memtier_benchmark -s $(server_ip $instances) -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/run${iteration}/benchmark_$instances.log"
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







