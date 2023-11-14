#!/bin/bash

#------------------------------------------------------ check if user is sudo or root ---------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	  echo "This script must be run as root."
	    exit 1
fi


#------------------------------------------------------ Script Paramaters ---------------------------------------------------------------

# Read the config file
if [ "$1" != "" ]; then
	config_file=$1
else
	config_file="./config.file"
fi

# Check if the file exists
if [ ! -f "$config_file" ]; then
  echo "Error: The config file '$config_file' does not exist. Please use the config file template to create one."
  exit 1
fi

source $config_file

source $HOME_DIR/redis-scripts/shared-scripts/set_ssh.sh

if [ "$SSH_CONNECTED" != "true" ]; then
    echo "Couldn't connect to server, please verify whether server is up or your ssh passwordless login to \"${SERVER_IP}\" is setup properly."
    exit 1
fi

echo "SSH Connection is Successfull!"

#---------------------------------------------------------- Pre-requisites --------------------------------------------------------
source $HOME_DIR/redis-scripts/shared-scripts/install_prereqs.sh

source $HOME_DIR//redis-scripts/shared-scripts/check_numa.sh

mkdir -p $LOG_PATH
cp $config_file $LOG_PATH

#---------------------------------------------------------- Disable Huge Pages -------------------------------------------------------
# This is very important. Without disabling huge pages, we can get into a difficult to reproduce situation of bad performance. 
echo "Current huge pages policy" 
$SSH_COMMAND cat /sys/kernel/mm/transparent_hugepage/enabled
echo "Setting Transparent Huge Pages policy to never." 
$SSH_COMMAND "echo never >  /sys/kernel/mm/transparent_hugepage/enabled"
$SSH_COMMAND cat /sys/kernel/mm/transparent_hugepage/enabled

#---------------------------------------------------------- Enable Memory Overcommit ------------------------------------------------
echo "Current memory overcommit setting" 
$SSH_COMMAND sysctl vm.overcommit_memory
echo "Enable memory overcommit" 
$SSH_COMMAND "sysctl vm.overcommit_memory=1"

#---------------------------------------------------------- Capture SVR-INFO --------------------------------------------------------


if [[ ${RUN_SVR_INFO} == true ]] ; then
	echo "Capture svr-info from the server."
	CUR_DIR=`pwd`
	cd ${LOG_PATH}
	${SVR_INFO_PATH}/svr-info -ip ${SERVER_IP} -user ${LOGIN_ID} -key  ${SSH_KEY_PATH}/${SSH_KEY_NAME}
	cd $CUR_DIR
	echo "Done capturing svr-info."
fi 

#---------------------------------------------------------- CPU configuration --------------------------------------------------------
#ALDERLAKE="12thGenIntel(R)Core(TM)i9-12900HK"

ARCHT=$($SSH_COMMAND lscpu |grep "Model name:"|awk -F ":" '{print $2'}|tr -d '[:space:]')
SOCKETS=$($SSH_COMMAND lscpu |grep "Socket(s):"|awk -F ":" '{print $2'}|tr -d '[:space:]')
CORES=$($SSH_COMMAND lscpu |grep "Core(s) per socket:"|awk -F ":" '{print $2'}|tr -d '[:space:]')
THREADS=$($SSH_COMMAND lscpu |grep "Thread(s) per core:"|awk -F ":" '{print $2'}|tr -d '[:space:]')

SERVER_THREAD=$($SSH_COMMAND lscpu |grep "NUMA node${SERVER_SOCKET} CPU(s):"| awk '{print $(NF)}'|awk -F ',' '{print $1}'|awk -F '-' '{print $1}')

echo $ARCHT
echo "Sockets: $SOCKETS"
echo "Cores: $CORES"
echo "Threads: $THREADS"

#---------------------------------------------------------- Redis instances & Memtier Clients --------------------------------------------------------

if $SSH_COMMAND [ ! -d "$REDIS_PATH" ]; then
    echo "Redis directory not found. Please be sure redis istalled to the path: $REDIS_PATH"
    exit 1
fi

readarray -t lines < $BENCHSPEC_CONFIG_FILE
for line in "${lines[@]}"
do
    IFS=':' read -ra config <<< "$line"
    BENCHMARK_TEST="${config[0]}"
    CPU_IDs="${config[1]}"

    IFS=',' read -ra CPUs <<< "$CPU_IDs"
    REDIS_NUM=${#CPUs[@]}

    CORE_TYPE="glc"

    echo "Redis Server will run on CPU IDs: $CPU_IDs"
    echo "Number of Redis instances=${REDIS_NUM}"

    for (( iteration=1; iteration <= $ITERATION_NUM; iteration++ ))
    do
        echo "Killing existing redis server instances and remove rdb files..."
        $SSH_COMMAND 'killall -9 redis-server'
        $SSH_COMMAND "rm -f ${RDB_PATH}/*.rdb"
        echo "Starting run #$iteration of $ITERATION_NUM"
        sleep 10

        #---------------------------------------------------------- Start Redis Servers --------------------------------------------------------
	#TODO - check ports before starting server. 
        SECONDS=0
        for (( instance=1; instance <= $REDIS_NUM; instance++ ))
        do
            CPU=${CPUs[${instance}-1]}
            PORT=$(($START_PORT + ${instance}))

	    #TODO this is not good. it will set all the IRQs to the last cpu if running more than one intance of redis. 
	    if [[ $SET_IRQ == true ]]; then
	       source $HOME_DIR/redis-scripts/shared-scripts/set_irq.sh $CPU
	    fi


            echo -e "Starting redis server $instance on CPU $CPU."

            cmd="numactl -m ${SERVER_SOCKET} -N ${SERVER_SOCKET} --physcpubind=${CPU} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --logfile $REDIS_PATH/server.log  --save \"\""
            echo -e $cmd
            $SSH_COMMAND $cmd &
            sleep 1

        done
        duration=$SECONDS
        echo "Starting Redis server(s) completed in $(($duration / 60)) minutes and $(($duration % 60)) seconds."

        #---------------------------------------------------------- Run Benchmarks --------------------------------------------------------
        if [ $iteration == 1 ] && [ $RUN_EMON == true ]; then
            echo "Starting emon... (First, try to stop if emon is running)"
            cmd="${EMON_FOLDER}/emon -stop "
            $SSH_COMMAND $cmd
            cmd="${EMON_FOLDER}/emon -collect-edp -f ${CORE_TYPE}-run${iteration}-emon.dat "
            $SSH_COMMAND $cmd &
        fi
        SECONDS=0

        for (( instance=1; instance <= $REDIS_NUM; instance++ ))
        do
            CPU=${CPUs[${instance}-1]}
            PORT=$(($START_PORT + ${instance}))
            LOG_FILE="${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-run${iteration}-cpu${CPU}"

            Redis_Ping=$($SSH_COMMAND "${REDIS_PATH}/src/redis-cli -h ${SERVER_IP} -p ${PORT} ping ")
            echo "Waiting for redis server $instance to be ready..."
            while [[ $Redis_Ping != *"PONG"* ]]; do
                sleep 1
                Redis_Ping=$($SSH_COMMAND "${REDIS_PATH}/src/redis-cli -h ${SERVER_IP} -p ${PORT} ping ")
                echo -ne "."
            done

            echo "Starting benchmark..."
            cmd="redis-benchmarks-spec-client-runner --db_server_host ${SERVER_IP} --db_server_port ${PORT} --flushall_on_every_test_start --client_aggregated_results_folder ${LOG_PATH} --logname ${LOG_FILE}.log --benchmark_local_install --test ${BENCHMARK_TEST}.yml --override-test-runs 1"
            echo -e $cmd
            $cmd &
        done

        # Run perf and sar only with the last iteration
        if [[ $iteration == $ITERATION_NUM ]]; then
            sleep 30
	    
	    if [[ $RUN_PERF == true ]]; then
            	echo "Starting perf..."
            	cmd="perf record -o ${CORE_TYPE}-run${iteration}-perf.data -F 99 -a -g -- sleep 30 "
            	$SSH_COMMAND $cmd &> /dev/null
            	cmd="perf record -o ${CORE_TYPE}-run${iteration}-perf-ins.data -a -g -e instructions:ppp -- sleep 30 "
            	$SSH_COMMAND $cmd &> /dev/null
	    fi

	    if [[ $RUN_SAR == true ]]; then
            	echo "Starting sar..."
	        cmd="sar 1 ${SAR_DURATION} > ${BENCHMARK_TEST}-${CORE_TYPE}-sar-cpu.log"
        	$SSH_COMMAND $cmd &
            	cmd="sar 1 -r ${SAR_DURATION} > ${BENCHMARK_TEST}-${CORE_TYPE}-sar-mem.log"
            	$SSH_COMMAND $cmd &
            	cmd="sar -d 1 ${SAR_DURATION} -p --dev=sda > ${BENCHMARK_TEST}-${CORE_TYPE}-sar-disk.log"
            	$SSH_COMMAND $cmd &
            	cmd="sar -n DEV --iface=enp3s0f1 1 ${SAR_DURATION} > ${BENCHMARK_TEST}-${CORE_TYPE}-sar-net.log"
            	$SSH_COMMAND $cmd &
	    fi
        fi

        while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
            echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
            sleep 5
        done

        duration=$SECONDS
        echo "Memtier benchmark comleted in $(($duration / 60)) minutes and $(($duration % 60)) seconds."

        if [ $iteration == 1 ] && [ $RUN_EMON == true ]; then
            echo "Stopping emon..."
            cmd="${EMON_FOLDER}/emon -stop "
            $SSH_COMMAND $cmd

            echo "Copying emon results..."
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-emon.dat ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-run${iteration}-emon.dat
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-emon.dat"

        fi
        if [[ $iteration == $ITERATION_NUM ]]; then

	    if [[ $RUN_PERF == true ]]; then
            	echo "Creating perf results..."
            	$SSH_COMMAND "perf report --hierarchy -i /root/${CORE_TYPE}-run${iteration}-perf.data > /root/${CORE_TYPE}-run${iteration}-perf-hierarchy.txt"
            	$SSH_COMMAND "perf report --max-stack 0 -i /root/${CORE_TYPE}-run${iteration}-perf.data > /root/${CORE_TYPE}-run${iteration}-perf.txt"
            	$SSH_COMMAND "perf report -i /root/${CORE_TYPE}-run${iteration}-perf-ins.data > /root/${CORE_TYPE}-run${iteration}-perf-ins.txt"

	    	if [[ $RUN_FLAMEGRAPH == true ]]; then
            		echo "Creating flame graphs"
            		$SSH_COMMAND "perf script -i /root/${CORE_TYPE}-run${iteration}-perf.data | ${flamegraph_folder}/stackcollapse-perf.pl > /root/${CORE_TYPE}-run${iteration}.perf-folded"
            		$SSH_COMMAND "${flamegraph_folder}/flamegraph.pl /root/${CORE_TYPE}-run${iteration}.perf-folded > /root/${CORE_TYPE}-run${iteration}.perf-folded.svg"
            		$SSH_COMMAND "rm -f /root/${CORE_TYPE}-run${iteration}.perf-folded"

	            	$SSH_COMMAND "perf script -i /root/${CORE_TYPE}-run${iteration}-perf-ins.data | ${flamegraph_folder}/stackcollapse-perf.pl > /root/${CORE_TYPE}-run${iteration}.perf-ins-folded"
        	    	$SSH_COMMAND "${flamegraph_folder}/flamegraph.pl /root/${CORE_TYPE}-run${iteration}.perf-ins-folded > /root/${CORE_TYPE}-run${iteration}.perf-ins-folded.svg"
            		$SSH_COMMAND "rm -f /root/${CORE_TYPE}-run${iteration}.perf-ins-folded"
	    	fi
	    fi


	    if [[ $RUN_PERF == true ]]; then
            	echo "Copying perf results..."
            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf.data ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf.data
            	$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf.data"
            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf-ins.data ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf-ins.data
            	$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf-ins.data"
            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf.txt ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf.txt
            	$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf.txt"
            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf-hierarchy.txt ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf-hierarchy.txt
            	$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf-hierarchy.txt"
            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf-ins.txt ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf-ins.txt
            	$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf-ins.txt"

	    	if [[ $RUN_FLAMEGRAPH == true ]]; then
	            	echo "Copying flamegraph results..."
        	   	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}.perf-folded.svg ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}.perf-folded.svg
            		$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}.perf-folded.svg"
	            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}.perf-ins-folded.svg ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}.perf-ins-folded.svg
        	    	$SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}.perf-ins-folded.svg"
	    	fi
	    fi

	    if [[ $RUN_SAR == true ]]; then
            	echo "Copying sar results..."
            	scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${BENCHMARK_TEST}-${CORE_TYPE}-sar* ${LOG_PATH}/
            	$SSH_COMMAND "rm /root/${BENCHMARK_TEST}-${CORE_TYPE}-sar*"
	    fi
        fi
        mv $LOG_PATH/aggregate-results.csv $LOG_FILE.csv
    done

    echo "Killing existing redis server instances and remove rdb files..."
    KILL_SIGNAL=15
    $SSH_COMMAND "killall $KILL_SIGNAL redis-server"
    $SSH_COMMAND "rm -f ${RDB_PATH}/*.rdb"
done


#---------------------------------------------------------- Post Process --------------------------------------------------------

echo "Post processing results..."

if [[ $RUN_EMON == true ]]; then
	echo "Processing EMON results..."
	CUR_DIR=`pwd`
	cd ${LOG_PATH}
	source $HOME_DIR/redis-scripts/shared-scripts/emon_process.sh
	cd $CUR_DIR
	echo "Done post processing EMON..."

fi

CUR_DIR=`pwd`
cd ${LOG_PATH}
source $HOME_DIR/redis-scripts/shared-scripts/post_process.sh
cd $CUR_DIR



