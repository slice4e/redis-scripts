#!/bin/bash

#------------------------------------------------------ check if user is sudo or root ---------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	  echo "This script must be run as root."
	    exit 1
fi


#------------------------------------------------------ Script Paramaters ---------------------------------------------------------------

# Read the config file
config_file="./config.file"

# Check if the file exists
if [ ! -f "$config_file" ]; then
  echo "Error: The config file '$config_file' does not exist."
  exit 1
fi

source $config_file


#---------------------------------------------------------- SSH Connection --------------------------------------------------------
SSH_CONNECTED=false
SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${SERVER_IP}"

echo "Logging in as \"${LOGIN_ID}\" to $SERVER_IP"
$SSH_COMMAND 'exit'

if [ "$?" -ne 0 ] ; then
        SSH_CONNECTED=false

        read -p "Couldn't connect to server. Do you want to create an ssh-key for the paswordless login? [Y]: " GenerateKey
        GenerateKey=${GenerateKey:-Y}

        case $GenerateKey in
            y|Y)
                echo "Genarating the key..."
                ssh-keygen -t rsa -b 4096 -f ${SSH_KEY_PATH}/${SSH_KEY_NAME} -N "" -q -C ${LOGIN_ID}@${SERVER_IP}
                echo "Copying key to the server..."
                ssh-copy-id -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}

                echo "Logging in as \"${LOGIN_ID}\" to $SERVER_IP"
                $SSH_COMMAND 'exit'
                if [ "$?" -ne 0 ] ; then
                    SSH_CONNECTED=false
                else
                    SSH_CONNECTED=true
                fi
            ;;
            *)
                echo "Quiting..."
                exit 1
            ;;
        esac
else
        SSH_CONNECTED=true
fi

if [ "$SSH_CONNECTED" != "true" ]; then
    echo "Couldn't connect to server, please verify whether server is up or your ssh passwordless login to \"${SERVER_IP}\" is setup properly."
    exit 1
fi

echo "SSH Connection is Successfull!"

#---------------------------------------------------------- Pre-requisites --------------------------------------------------------

echo "Check pre-requisites on server"


if ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
	echo "Redis is not installed. Attempting to install."
	$SSH_COMMAND apt-get update
	$SSH_COMMAND apt install make -y
	$SSH_COMMAND apt install gcc -y
	$SSH_COMMAND apt install pkg-config -y
	$SSH_COMMAND git clone --recursive https://github.com/redis/redis.git
	$SSH_COMMAND "cd $REDIS_PATH; make -j"
	$SSH_COMMAND "cd $REDIS_PATH; cat redis.conf | sed \"s/bind/#bind/\" > redis.conf.new"
	$SSH_COMMAND "cd $REDIS_PATH; cat redis.conf.new | sed \"s/protected-mode yes/protected-mode no/\" > redis.conf.new2"
	$SSH_COMMAND "cd $REDIS_PATH; mv redis.conf.new2 redis.conf; rm -f redis.conf.new"
fi

if ! $SSH_COMMAND command -v "numactl" &>/dev/null; then
	echo "The prerequisite numactl is not installed. Attempting to install."
	$SSH_COMMAND apt-get update
	$SSH_COMMAND apt install numactl -y
fi

if ! $SSH_COMMAND command -v "sar" &>/dev/null; then
	echo "The prerequisite sysstat is not installed. Attempting to install."
	$SSH_COMMAND apt-get update
	$SSH_COMMAND apt install sysstat -y
fi

if ! $SSH_COMMAND command -v "${flamegraph_folder}/flamegraph.pl" &>/dev/null; then
	echo "The prerequisite FlameGraph is not installed. Attempting to install."
	$SSH_COMMAND git clone https://github.com/brendangregg/FlameGraph
fi

if ! $SSH_COMMAND command -v "perf" &>/dev/null; then
	$SSH_COMMAND apt install linux-tools-common -y
	$SSH_COMMAND "apt install linux-tools-`uname -r` -y"
	$SSH_COMMAND "echo 1 > /proc/sys/kernel/perf_event_paranoid"
	$SSH_COMMAND "echo \"kernel.perf_event_paranoid = 1\" >> /etc/sysctl.conf"
fi


prerequisites=(
  "$REDIS_PATH/src/redis-server"
  "numactl"
  "perf"
  "${flamegraph_folder}/flamegraph.pl"
  "sar"
)

# Check if each prerequisite is installed
for prerequisite in "${prerequisites[@]}"; do
  if ! $SSH_COMMAND command -v "$prerequisite" &>/dev/null; then
    echo "Error: The prerequisite '$prerequisite' is not installed."
    exit 1
  fi
done

# All prerequisites are installed, continue with the script
echo "All prerequisites are installed on the server."

echo "Check pre-requisites on the client"

if ! command -v "memtier_benchmark" &>/dev/null; then
	echo "The prerequisite memtier-benchmark is not installed. Attempting to install."
	apt-get update
	apt-get install build-essential autoconf automake libpcre3-dev libevent-dev pkg-config zlib1g-dev libssl-dev -y
	CUR_DIR=`pwd`
	cd /opt
	git clone https://github.com/RedisLabs/memtier_benchmark.git
	cd /opt/memtier_benchmark
	autoreconf -ivf
	./configure
	make
	make install
	cd $CUR_DIR

fi

if ! command -v "redis-benchmarks-spec-client-runner" &>/dev/null; then
	echo "The prerequisite Redis Benchmarks Specification is not installed. Attempting to install."
	apt-get update
	apt install python3-pip -y
	pip3 install --upgrade pip
	apt install docker.io -y
	pip3 install redis-benchmarks-specification
	python3 -m pip install cryptography==38.0.4
	pip install pyopenssl --upgrade
fi

if ! command -v "svr-info" &>/dev/null; then
	echo "The prerequisite svr-info is not installed. Attempting to install."
	CUR_DIR=`pwd`
	cd /opt
	wget -qO- https://github.com/intel/svr-info/releases/latest/download/svr-info.tgz | tar xvz
	ln -s /opt/svr-info/svr-info /usr/local/bin/svr-info
	cd $CUR_DIR
fi

prerequisites=(
  "memtier_benchmark"
  "redis-benchmarks-spec-client-runner"
  "svr-info"
)

# Check if each prerequisite is installed
for prerequisite in "${prerequisites[@]}"; do
  if ! command -v "$prerequisite" &>/dev/null; then
    echo "Error: The prerequisite '$prerequisite' is not installed."
    exit 1
  fi
done


echo "All prerequisites are installed on the client."

#---------------------------------------------------------- Capture SVR-INFO --------------------------------------------------------

mkdir -p $LOG_PATH
echo "Capture svr-info from the server."
CUR_DIR=`pwd`
cd ${LOG_PATH}
svr-info -ip ${SERVER_IP} -user ${LOGIN_ID} -key  ${SSH_KEY_PATH}/${SSH_KEY_NAME}
cd $CUR_DIR
echo "Done capturing svr-info."


#---------------------------------------------------------- CPU configuration --------------------------------------------------------
#ALDERLAKE="12thGenIntel(R)Core(TM)i9-12900HK"

ARCHT=$($SSH_COMMAND lscpu |grep "Model name:"|awk -F ":" '{print $2'}|tr -d '[:space:]')
SOCKETS=$($SSH_COMMAND lscpu |grep "Socket(s):"|awk -F ":" '{print $2'}|tr -d '[:space:]')
CORES=$($SSH_COMMAND lscpu |grep "Core(s) per socket:"|awk -F ":" '{print $2'}|tr -d '[:space:]')
THREADS=$($SSH_COMMAND lscpu |grep "Thread(s) per core:"|awk -F ":" '{print $2'}|tr -d '[:space:]')

SERVER_THREAD=$($SSH_COMMAND lscpu |grep "NUMA node${BIND_SOCKET} CPU(s):"| awk '{print $(NF)}'|awk -F ',' '{print $1}'|awk -F '-' '{print $1}')

echo $ARCHT
echo "Sockets: $SOCKETS"
echo "Cores: $CORES"
echo "Threads: $THREADS"
echo "Big Core (GoldenCove) CPUs: $GOLDENCOVE_CORES"
echo "Atom Core (Gracemont) CPUs: $GRACEMONT_CORES"

#---------------------------------------------------------- Redis instances & Memtier Clients --------------------------------------------------------

if $SSH_COMMAND [ ! -d "$REDIS_PATH" ]; then
    echo "Redis directory not found. Please be sure redis istalled to the path: $REDIS_PATH"
    exit 1
fi

readarray -t lines < $CONFIG_FILE
for line in "${lines[@]}"
do
    IFS=':' read -ra config <<< "$line"
    BENCHMARK_TEST="${config[0]}"
    CPU_IDs="${config[1]}"

    IFS=',' read -ra CPUs <<< "$CPU_IDs"
    REDIS_NUM=${#CPUs[@]}

    CORE_TYPE="glc"
    if [ "${CPUs[0]}" -gt "15" ]; then
        CORE_TYPE="grt"
    fi

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
        SECONDS=0
        for (( instance=1; instance <= $REDIS_NUM; instance++ ))
        do
            CPU=${CPUs[${instance}-1]}
            PORT=$(($START_PORT + ${instance}))

            if [[ $SET_IRQ == true ]]; then    
                echo "Assigning IRQ interruptions to CPU $CPU ...."
                interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}'")
                for i in $interrupts
                do
                        cmd="echo $CPU > /proc/irq/${i:0:-1}/smp_affinity_list"
                        $SSH_COMMAND $cmd
                done

                echo "Printing assigned cpu numbers for each interrupts..."
                interrupts=$($SSH_COMMAND "cat /proc/interrupts | grep $IRQ_INTERFACE | awk -F ':' '{print \$1}'")
                for i in $interrupts
                do
                        cmd="cat /proc/irq/${i:0:-1}/smp_affinity_list"
                        $SSH_COMMAND $cmd
                done
            fi

            echo -e "Starting redis server $instance on CPU $CPU."

            cmd="numactl -m ${BIND_SOCKET} -N ${BIND_SOCKET} --physcpubind=${CPU} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --logfile server.log  --save \"\""
            echo -e $cmd
            $SSH_COMMAND $cmd &
            sleep 1

        done
        duration=$SECONDS
        echo "Starting Redis server(s) completed in $(($duration / 60)) minutes and $(($duration % 60)) seconds."

        #---------------------------------------------------------- Run Benchmarks --------------------------------------------------------
        if [[ $iteration == 1 ]]; then
            echo "Starting emon... (First, try to stop if emon is running)"
            cmd="${emon_folder}/emon -stop "
            $SSH_COMMAND $cmd
            cmd="${emon_folder}/emon -collect-edp -f ${CORE_TYPE}-run${iteration}-emon.dat "
            $SSH_COMMAND $cmd &
        fi
        SECONDS=0

        for (( instance=1; instance <= $REDIS_NUM; instance++ ))
        do
            CPU=${CPUs[${instance}-1]}
            PORT=$(($START_PORT + ${instance}))
            LOG_FILE="${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-cpu${CPU}-run${iteration}"

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
            echo "Starting perf..."
            cmd="perf record -o ${CORE_TYPE}-run${iteration}-perf.data -F 99 -a -g -- sleep 30 "
            $SSH_COMMAND $cmd &> /dev/null
            cmd="perf record -o ${CORE_TYPE}-run${iteration}-perf-ins.data -a -g -e instructions:ppp -- sleep 30 "
            $SSH_COMMAND $cmd &> /dev/null

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

        while [ $(ps -ef | grep -c memtier_benchmark) -gt 1 ];do
            echo -e "Waiting for $(($(ps -ef | grep -c memtier_benchmark)-1)) memtier_benchmark to finish"
            sleep 5
        done

        duration=$SECONDS
        echo "Memtier benchmark comleted in $(($duration / 60)) minutes and $(($duration % 60)) seconds."

        if [[ $iteration == 1 ]]; then
            echo "Stopping emon..."
            cmd="${emon_folder}/emon -stop "
            $SSH_COMMAND $cmd

            echo "Copying emon results..."
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-emon.dat ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-run${iteration}-emon.dat
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-emon.dat"

        fi
        if [[ $iteration == $ITERATION_NUM ]]; then
            echo "Creating perf results..."
            $SSH_COMMAND "perf report -i /root/${CORE_TYPE}-run${iteration}-perf.data > /root/${CORE_TYPE}-run${iteration}-perf.txt"
            $SSH_COMMAND "perf report -i /root/${CORE_TYPE}-run${iteration}-perf-ins.data > /root/${CORE_TYPE}-run${iteration}-perf-ins.txt"

            echo "Creating flame graphs"
            $SSH_COMMAND "perf script -i /root/${CORE_TYPE}-run${iteration}-perf.data | ${flamegraph_folder}/stackcollapse-perf.pl > /root/${CORE_TYPE}-run${iteration}.perf-folded"
            $SSH_COMMAND "${flamegraph_folder}/flamegraph.pl /root/${CORE_TYPE}-run${iteration}.perf-folded > /root/${CORE_TYPE}-run${iteration}.perf-folded.svg"
            $SSH_COMMAND "rm -f /root/${CORE_TYPE}-run${iteration}.perf-folded"

            $SSH_COMMAND "perf script -i /root/${CORE_TYPE}-run${iteration}-perf-ins.data | ${flamegraph_folder}/stackcollapse-perf.pl > /root/${CORE_TYPE}-run${iteration}.perf-ins-folded"
            $SSH_COMMAND "${flamegraph_folder}/flamegraph.pl /root/${CORE_TYPE}-run${iteration}.perf-ins-folded > /root/${CORE_TYPE}-run${iteration}.perf-ins-folded.svg"
            $SSH_COMMAND "rm -f /root/${CORE_TYPE}-run${iteration}.perf-ins-folded"

            echo "Copying perf results..."
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf.data ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf.data
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf.data"
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf-ins.data ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf-ins.data
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf-ins.data"
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf.txt ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf.txt
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf.txt"
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}-perf-ins.txt ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}-perf-ins.txt
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}-perf-ins.txt"
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}.perf-folded.svg ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}.perf-folded.svg
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}.perf-folded.svg"
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${CORE_TYPE}-run${iteration}.perf-ins-folded.svg ${LOG_PATH}/${BENCHMARK_TEST}-${CORE_TYPE}.perf-ins-folded.svg
            $SSH_COMMAND "rm /root/${CORE_TYPE}-run${iteration}.perf-ins-folded.svg"

            echo "Copying sar results..."
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${LOGIN_ID}@${SERVER_IP}:/root/${BENCHMARK_TEST}-${CORE_TYPE}-sar* ${LOG_PATH}/
            $SSH_COMMAND "rm /root/${BENCHMARK_TEST}-${CORE_TYPE}-sar*"
        fi
        mv $LOG_PATH/aggregate-results.csv $LOG_FILE.csv
    done

    echo "Killing existing redis server instances and remove rdb files..."
    $SSH_COMMAND 'killall -9 redis-server'
    $SSH_COMMAND "rm -f ${RDB_PATH}/*.rdb"
done


#---------------------------------------------------------- Post Process --------------------------------------------------------

echo "Post processing results..."
echo "Calculating average ops/sec across runs..."
CUR_DIR=`pwd`
cd ${LOG_PATH}
source $POST_SCRIPT
cd $CUR_DIR
echo "Done post processing results..."





