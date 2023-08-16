#!/bin/bash

#for NUM_SERVERS in 64 32; do

pkill redis-server
while [ $(ps -e | grep -c redis-server) -gt 1 ];do
	echo -e "Waiting for $(($(ps -e | grep -c redis-server))) redis-server(s) to stop"
        sleep 5
done

# Read the config file
config_file="./redis_bench.config"
source $config_file

if [[ $RUN_EMON == true ]] ; then
	source /opt/intel/sep/sep_vars.sh
fi

#---------------------------check cpu configuration------------------------------------------
NUM_CPUS=`numactl --hardware | grep "node 0 cpus" |  awk -F ':' '{print $2}' | wc -w`
if [[ $SERVER_SOCKET == $MEMTIER_SOCKET ]]; then
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
	CPUS=`numactl --hardware | grep "node ${SERVER_SOCKET} cpus" |  awk -F ':' '{print $2}'`
	MEMTIER_CPUS=`numactl --hardware | grep "node ${MEMTIER_SOCKET} cpus" |  awk -F ':' '{print $2}'`

	if [[ $NUM_CPUS -lt $NUM_SERVERS ]]; then
		echo "Use at most $NUM_CPUS Redis servers per socket. " 
		exit 1
	fi
fi

mkdir -p ${RESULTS_PATH}


#--------------------------start master servers------------------------------------------------------
instances=1
for cpu in $CPUS
do
	port=$(($START_PORT + ${instances}))
	echo -e "starting redis server $instances on vCPU $cpu"
	cmd="numactl -m ${SERVER_SOCKET} taskset -c $cpu  $REDIS_PATH/src/redis-server --port ${port} --save \"\" "
    	echo -e $cmd
	$cmd & 
	instances=$((instances + 1))

	if [ $instances -gt $NUM_SERVERS ]
	then
		break
	fi
done

while [ $(ps -e | grep -c redis-server) -lt $NUM_SERVERS ];do
	echo -e "Waiting for all redis servers to start"
        sleep 5
done

echo "$(($(ps -e | grep -c redis-server))) redis servers started"


#--------------------------start memtier benchmark FILL ---------------------------------------------
instances=1
for cpu in $MEMTIER_CPUS
do
	port=$(($START_PORT + ${instances}))
	echo -e "starting memtier benchmark $instances on vCPU $cpu"
	cmd="numactl -m ${MEMTIER_SOCKET} taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $HOST -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} -n allkeys --data-size-list=${DATA_SIZE_LIST} --pipeline=15 --key-pattern=P:P --ratio=1:0 --out-file=${RESULTS_PATH}/fill_$instances.log"
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
	cmd="numactl -m ${MEMTIER_SOCKET} taskset -c $cpu ${MEMTIER_PATH}/memtier_benchmark -s $HOST -p ${port} --hide-histogram --key-maximum=${NUM_FILL_REQ} --data-size-list=${DATA_SIZE_LIST} --randomize --distinct-client-seed --key-pattern=$KEY_PATTERN --test-time=$BENCHMARK_DURATION --ratio=4:1 --pipeline=64 -c 2 -t 2 --out-file=${RESULTS_PATH}/benchmark_$instances.log"
	instances=$((instances + 1))
    	echo -e $cmd
	$cmd >/dev/null &

	if [ $instances -gt $NUM_SERVERS ]
	then
		break
	fi
done

if [[ $RUN_EMON == true ]] ; then
	cmd="emon -collect-edp -f ${RESULTS_PATH}/emon.dat "
	$SSH_COMMAND $cmd &
fi


while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
	echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
        sleep 5
done


if [[ $RUN_EMON == true ]] ; then
	cmd="emon -stop "
	$SSH_COMMAND $cmd &
fi

#-------------------------- Process Emon ------------------ ------------------------------------------

if [[ $RUN_EMON == true ]] ; then

	echo "Processing EMON results..."
	#dcsomc -n -x alanstu -d ${RESULTS_PATH} -G ${RESULTS_FOLDER}_redis_2lm_${NUM_SERVERS}
	CUR_DIR=`pwd`
	cd ${LOG_PATH}
	source $EMON_POST_SCRIPT
	cd $CUR_DIR
	echo "Done post processing EMON..."
fi

#-------------------------- Process Results ------------------ ------------------------------------------

echo "Total Ops/sec"
total_ops=`cat ${RESULTS_PATH}/benchmark_* | grep Totals | awk -F " " '{total += $2; count++ } END { print total} '`
echo $total_ops
echo $total_ops > ${RESULTS_PATH}/total_ops.log

#done


