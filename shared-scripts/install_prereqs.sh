#!/bin/bash


#---------------------------------------------------------- Pre-requisites --------------------------------------------------------

echo "Check pre-requisites on server"


if ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
	echo "Redis is not installed. Attempting to install."
	$SSH_COMMAND apt-get update
	$SSH_COMMAND apt install make -y
	$SSH_COMMAND apt install gcc -y
	$SSH_COMMAND apt install pkg-config -y
	$SSH_COMMAND git clone --recursive https://github.com/redis/redis.git --branch $REDIS_BRANCH $REDIS_PATH
	$SSH_COMMAND "cd $REDIS_PATH; make $REDIS_BUILD_FLAGS"
	$SSH_COMMAND "cd $REDIS_PATH; cat redis.conf | sed \"s/bind/#bind/\" > redis.conf.new"
	$SSH_COMMAND "cd $REDIS_PATH; cat redis.conf.new | sed \"s/protected-mode yes/protected-mode no/\" > redis.conf.new2"
	$SSH_COMMAND "cd $REDIS_PATH; mv redis.conf.new2 redis.conf; rm -f redis.conf.new"
fi
if ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
	echo "Redis is not installed. Unable to automatically install it. Failing."
	exit 1
fi

if ! $SSH_COMMAND command -v "numactl" &>/dev/null; then
	echo "The prerequisite numactl is not installed. Attempting to install."
	$SSH_COMMAND apt-get update
	$SSH_COMMAND apt install numactl -y
fi
if ! $SSH_COMMAND command -v "numactl" &>/dev/null; then
	echo "The prerequisite numactl is not installed. Unable to automatically install it. Failing."
	exit 1
fi

if [[ $RUN_SAR == true ]]; then
	if ! $SSH_COMMAND command -v "sar" &>/dev/null; then
		echo "The prerequisite sysstat is not installed. Attempting to install."
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install sysstat -y
	fi
	if ! $SSH_COMMAND command -v "sar" &>/dev/null; then
		echo "The prerequisite sysstat is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ $RUN_FLAMEGRAPH == true ]]; then
	if ! $SSH_COMMAND command -v "${flamegraph_folder}/flamegraph.pl" &>/dev/null; then
		echo "The prerequisite FlameGraph is not installed. Attempting to install."
		$SSH_COMMAND git clone https://github.com/brendangregg/FlameGraph
	fi
	if ! $SSH_COMMAND command -v "${flamegraph_folder}/flamegraph.pl" &>/dev/null; then
		echo "The prerequisite FlameGraph is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ $RUN_PERF == true ]]; then
	if ! $SSH_COMMAND command -v "perf" &>/dev/null; then
		echo "The prerequisite Perf is not installed. Attempting to install."
		$SSH_COMMAND apt install linux-tools-common -y
		$SSH_COMMAND "apt install linux-tools-`uname -r` -y"
		$SSH_COMMAND "echo 0 > /proc/sys/kernel/perf_event_paranoid"
		$SSH_COMMAND "echo \"kernel.perf_event_paranoid = 1\" >> /etc/sysctl.conf"
	fi
	if ! $SSH_COMMAND command -v "perf" &>/dev/null; then
		echo "The prerequisite Perf is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ $RUN_EMON == true ]] ; then
	if ! $SSH_COMMAND command -v "${EMON_FOLDER}/emon" &>/dev/null; then
    		echo "EMON is configured to run, but it is not installed on the server. Please install it."
    		exit 1
	fi
fi

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
if ! command -v "memtier_benchmark" &>/dev/null; then
	echo "The prerequisite memtier-benchmark is not installed. Unable to automatically install it. Failing."
	exit 1
fi

if [[ $RUN_BENCH_SPEC == true ]] ; then
	if ! command -v "redis-benchmarks-spec-client-runner" &>/dev/null; then
		echo "The prerequisite Redis Benchmarks Specification is not installed. Attempting to install."
		apt-get update
		apt install python3-pip -y
		pip3 install --upgrade pip
		apt install docker.io -y
		python3 -m pip install cryptography==38.0.4
		pip install pyopenssl --upgrade
		pip3 install redis-benchmarks-specification --ignore-installed blinker
	fi
	if ! command -v "redis-benchmarks-spec-client-runner" &>/dev/null; then
		echo "The prerequisite Redis Benchmarks Specification is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ ${RUN_SVR_INFO} == true ]] ; then
	if ! command -v "${SVR_INFO_PATH}/svr-info" &>/dev/null; then
		echo "The prerequisite svr-info is not installed. Attempting to install."
		CUR_DIR=`pwd`
		cd /opt
		wget -qO- https://github.com/intel/svr-info/releases/latest/download/svr-info.tgz | tar xvz
		ln -s /opt/svr-info/svr-info /usr/local/bin/svr-info
		cd $CUR_DIR
	fi
	if ! command -v "${SVR_INFO_PATH}/svr-info" &>/dev/null; then
		echo "The prerequisite svr-info is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ $RUN_EMON == true ]] ; then
	if ! command -v "${EMON_FOLDER}/emon" &>/dev/null; then
    		echo "EMON is configured to run, but it is not installed on the client. Please install it after this script completes."
		echo "You will likely need these python packages, so we will go ahead and install them."
		pip3 install --upgrade pip
		apt install python3-dev -y
		pip install defusedxml
		pip install tdigest
		pip install xlsxwriter
    		exit 1
	fi
fi


echo "All prerequisites are installed on the client."
