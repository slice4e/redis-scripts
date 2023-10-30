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

source ${HOME_DIR}/redis-scripts/shared-scripts/set_ssh.sh


if [ "$SSH_CONNECTED" != "true" ]; then
    echo "Couldn't connect to server, please verify whether server is up or your ssh passwordless login to \"${SERVER_IP}\" is setup properly."
    exit 1
fi

echo "SSH Connection is Successfull!"


$SSH_COMMAND pkill redis-server
while [ `$SSH_COMMAND ps -e | grep -c redis-server` -gt 0 ];do
	ret=`$SSH_COMMAND ps -e | grep -c redis-server`
	echo -e "Waiting for $ret redis-server(s) to stop"
        sleep 5
done

#---------------------------------------------------------- Install Pre-reqs -------------------------------------------------------
source $HOME_DIR/redis-scripts/shared-scripts/install_prereqs.sh

source $HOME_DIR/redis-scripts/shared-scripts/check_numa.sh

mkdir -p ${RESULTS_PATH}
$SSH_COMMAND mkdir -p ${RESULTS_PATH}
cp $config_file ${RESULTS_PATH}

#---------------------------------------------------------- Capture SVR-INFO --------------------------------------------------------
if [[ ${RUN_SVR_INFO} == true ]] ; then
	echo "Capture svr-info from the server."
	CUR_DIR=`pwd`
	cd ${RESULTS_PATH}
	${SVR_INFO_PATH}/svr-info -ip $SERVER_IP -user $LOGIN_ID
	cd $CUR_DIR
	echo "Done capturing svr-info."
fi 


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

#--------------------------set network interrupts ---------------------------------------------------
if [[ $SET_IRQ == true ]]; then
	source $HOME_DIR/redis-scripts/shared-scripts/set_irq.sh $CPUS
fi

$SSH_COMMAND mkdir -p ${REDIS_PATH}/log
for (( iteration=1; iteration <= $ITERATION_NUM; iteration++ ))
do

	mkdir ${RESULTS_PATH}/run${iteration}

	#--------------------------start master servers------------------------------------------------------
	instances=1
	for cpu in $CPUS
	do
		port=$(($START_PORT + ${instances}))
		ret=$($SSH_COMMAND lsof -i:$port)
		ret_code=$(echo $? | tr -d '[:space:]') 
		if [[ $ret_code == 1 ]]; then
			echo -e "starting redis server $instances on vCPU $cpu"
			cmd="numactl -m ${SERVER_SOCKET} taskset -c $cpu  $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --logfile $REDIS_PATH/log/server${instances}.log --port ${port} --save \"\" "
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

	while [ $($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]') -lt $NUM_SERVERS ];do
		echo -e "Waiting for all redis servers to start"
		sleep 5
	done

	echo "$($SSH_COMMAND ps -e | grep -c redis-server | tr -d '[:space:]' ) redis servers started"


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
				cmd="numactl -m ${MEMTIER_SOCKET} taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $SERVER_IP -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=10 --ratio=$RATIO --pipeline=$MEMTIER_PIPELINE -c $MEMTIER_CLIENTS -t $MEMTIER_THREADS --out-file=${RESULTS_PATH}/autotune/benchmark_$instances.log"
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


	while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
		echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
		sleep 5
	done

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
echo "Copying data from remote server. " 
if [[ ${SERVER_REMOTE} == true ]] ; then
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
	source $HOME_DIR/redis-scripts/shared-scripts/emon_process.sh
	cd $CUR_DIR
	echo "Done post processing EMON..."
fi

CUR_DIR=`pwd`
cd ${RESULTS_PATH}
source $HOME_DIR/redis-scripts/shared-scripts/post_process.sh
cd $CUR_DIR




