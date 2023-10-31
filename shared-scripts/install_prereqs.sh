#!/bin/bash


#---------------------------------------------------------- Pre-requisites --------------------------------------------------------

echo "Check pre-requisites on server"

if $SSH_COMMAND command -v "apt" &>/dev/null; then
	USE_APT=true
else
	USE_APT=false
fi

if ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
	echo "Redis is not installed. Attempting to install."
	if [[ $USE_APT == true ]]; then
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install make -y
		$SSH_COMMAND apt install gcc -y
		$SSH_COMMAND apt install pkg-config -y
	else
		$SSH_COMMAND yum install make -y
		$SSH_COMMAND yum install gcc -y
		$SSH_COMMAND yum install pkg-config -y
	fi
	$SSH_COMMAND git clone --recursive https://github.com/redis/redis.git --branch $REDIS_BRANCH $REDIS_PATH
	if [[ ${SERVER_REMOTE} == true ]] ; then
		$SSH_COMMAND "cd $REDIS_PATH; make $REDIS_BUILD_FLAGS"
		$SSH_COMMAND "cd $REDIS_PATH; cat redis.conf | sed \"s/bind/#bind/\" > redis.conf.new"
		$SSH_COMMAND "cd $REDIS_PATH; cat redis.conf.new | sed \"s/protected-mode yes/protected-mode no/\" > redis.conf.new2"
		$SSH_COMMAND "cd $REDIS_PATH; mv redis.conf.new2 redis.conf; rm -f redis.conf.new"
	else
		cd $REDIS_PATH; make $REDIS_BUILD_FLAGS
		cd $REDIS_PATH; cat redis.conf | sed s/bind/\#bind/ > redis.conf.new
		cd $REDIS_PATH; cat redis.conf.new | sed s/protected-mode yes/protected-mode no/ > redis.conf.new2
		cd $REDIS_PATH; mv redis.conf.new2 redis.conf; rm -f redis.conf.new
	fi

fi
if ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
	echo "Redis is not installed. Unable to automatically install it. Failing."
	exit 1
fi

if ! $SSH_COMMAND command -v "numactl" &>/dev/null; then
	echo "The prerequisite numactl is not installed. Attempting to install."
	if [[ $USE_APT == true ]]; then
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install numactl -y
	else
		$SSH_COMMAND yum install numactl -y
	fi
fi
if ! $SSH_COMMAND command -v "numactl" &>/dev/null; then
	echo "The prerequisite numactl is not installed. Unable to automatically install it. Failing."
	exit 1
fi

if ! $SSH_COMMAND command -v "lsof" &>/dev/null; then
	echo "The prerequisite lsof is not installed. Attempting to install."
	if [[ $USE_APT == true ]]; then
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install lsof -y
	else
		$SSH_COMMAND yum install lsof -y
	fi
fi
if ! $SSH_COMMAND command -v "lsof" &>/dev/null; then
	echo "The prerequisite lsof is not installed. This command is used to verify that the redis server ports are not in use."
	exit 1
fi

if [[ $RUN_SAR == true ]]; then
	if ! $SSH_COMMAND command -v "sar" &>/dev/null; then
		echo "The prerequisite sysstat is not installed. Attempting to install."
		if [[ $USE_APT == true ]]; then
			$SSH_COMMAND apt-get update
			$SSH_COMMAND apt install sysstat -y
		else
			$SSH_COMMAND yum install sysstat -y
		fi
	fi
	if ! $SSH_COMMAND command -v "sar" &>/dev/null; then
		echo "The prerequisite sysstat is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ $RUN_FLAMEGRAPH == true ]]; then
	if ! $SSH_COMMAND command -v "${flamegraph_folder}/flamegraph.pl" &>/dev/null; then
		echo "The prerequisite FlameGraph is not installed. Attempting to install."
		$SSH_COMMAND git clone https://github.com/brendangregg/FlameGraph ${flamegraph_folder}
		if [[ $USE_APT == false ]]; then
			$SSH_COMMAND yum install perl-open.noarch -y
		fi
	fi
	if ! $SSH_COMMAND command -v "${flamegraph_folder}/flamegraph.pl" &>/dev/null; then
		echo "The prerequisite FlameGraph is not installed. Unable to automatically install it. Failing."
		exit 1
	fi
fi

if [[ $RUN_PERF == true ]]; then
	if ! $SSH_COMMAND command -v "perf" &>/dev/null; then
		echo "The prerequisite Perf is not installed. Attempting to install."
		if [[ $USE_APT == true ]]; then
			$SSH_COMMAND apt install linux-tools-common -y
			$SSH_COMMAND "apt install linux-tools-`uname -r` -y"
		else
			$SSH_COMMAND yum install perf -y
		fi
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
    		echo "EMON is configured to run, but it is not installed on the client. Please install it after this script completes."
		echo "You will likely need these python packages, so we will go ahead and install them."
		if [[ $USE_APT == true ]]; then
			$SSH_COMMAND apt install python3-dev -y
			$SSH_COMMAND apt install python3-pip -y
		else
			$SSH_COMMAND yum install python3-devel -y
		fi
		$SSH_COMMAND pip3 install --upgrade pip
		$SSH_COMMAND pip3 install tdigest
		$SSH_COMMAND pip3 install numpy pandas defusedxml pytz xlsxwriter jsonschema multiprocess tables natsort tqdm
    		exit 1
	fi
fi

# All prerequisites are installed, continue with the script
echo "All prerequisites are installed on the server."

echo "Check pre-requisites on the client"
if command -v "apt" &>/dev/null; then
	USE_APT=true
else
	USE_APT=false
fi

if ! command -v "${MEMTIER_PATH}/memtier_benchmark" &>/dev/null; then
	echo "The prerequisite memtier-benchmark is not installed. Attempting to install."
	if [[ $USE_APT == true ]]; then
		apt-get update
		apt-get install build-essential autoconf automake libpcre3-dev libevent-dev pkg-config zlib1g-dev libssl-dev -y
	else
		yum install autoconf automake make gcc-c++ -y 
		yum install pcre-devel zlib-devel libmemcached-devel libevent-devel openssl-devel -y 
	fi

	
	CUR_DIR=`pwd`
	MEMTIER_BASE_PATH=`dirname $MEMTIER_PATH`
	cd $MEMTIER_BASE_PATH
	git clone https://github.com/RedisLabs/memtier_benchmark.git
	cd $MEMTIER_PATH
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

		if [[ $USE_APT == true ]]; then
			apt-get update
			apt install python3-pip -y
			apt install docker.io -y
		else
			yum install -y yum-utils
			yum install -y yum-utils
			yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			yum install python3-pip -y
			yum install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl start docker
		fi
		pip3 install --upgrade pip
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
		SVR_INFO_BASE_PATH=`dirname $SVR_INFO_PATH`
		cd $SVR_INFO_BASE_PATH
		wget -qO- https://github.com/intel/svr-info/releases/latest/download/svr-info.tgz | tar xvz 
		ln -s ${SVR_INFO_PATH}/svr-info /usr/local/bin/svr-info
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
		if [[ $USE_APT == true ]]; then
			apt install python3-dev -y
		else
			yum install python3-devel -y
		fi
		pip3 install tdigest
		pip3 install numpy pandas defusedxml pytz xlsxwriter jsonschema multiprocess tables natsort tqdm
    		exit 1
	fi
fi


echo "All prerequisites are installed on the client."
