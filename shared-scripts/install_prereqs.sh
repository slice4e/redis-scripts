#!/bin/bash


#---------------------------------------------------------- Pre-requisites --------------------------------------------------------

# Check if this is a client-only installation
if [[ "${CLIENT_ONLY}" == "true" ]]; then
    echo "Check pre-requisites on client"
    # Skip Redis server installation on clients, go directly to client prerequisites
    skip_redis_installation=true
else
    echo "Check pre-requisites on server"
    skip_redis_installation=false
fi

if $SSH_COMMAND command -v "apt" &>/dev/null; then
	USE_APT=true
else
	USE_APT=false
fi

# Only install Redis server if this is not a client-only installation
if [[ "${skip_redis_installation}" != "true" ]] && ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
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
		cd $REDIS_PATH; cat redis.conf.new | sed s/protected-mode\ yes/protected-mode\ no/ > redis.conf.new2
		cd $REDIS_PATH; mv redis.conf.new2 redis.conf; rm -f redis.conf.new
	fi

fi
# Only check Redis installation if this is not a client-only installation
if [[ "${skip_redis_installation}" != "true" ]] && ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
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
	if [[ ${SERVER_REMOTE} == true ]] ; then
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
	else
		if ! command -v "perf" &>/dev/null; then
			if [[ $USE_APT == true ]]; then
				apt install linux-tools-common -y
				apt install linux-tools-`uname -r` -y
			else
				yum install perf -y
			fi
			echo 0 > /proc/sys/kernel/perf_event_paranoid
			echo "kernel.perf_event_paranid = 1" >> /etc/sysctl.conf
		fi
	fi

	if [[ ${SERVER_REMOTE} == true ]] ; then
		if ! $SSH_COMMAND command -v "perf" &>/dev/null; then 
			echo "The prerequisite Perf is not installed. Unable to automatically install it. Failing."
			exit 1
		fi
	else
		if ! command -v "perf" &>/dev/null; then
			echo "The prerequisite Perf is not installed. Unable to automatically install it. Failing."
			exit 1
		fi
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

if ! command -v "${MEMTIER_PATH}/memtier_benchmark" &>/dev/null && ! command -v memtier_benchmark &>/dev/null; then
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
	git clone https://github.com/RedisLabs/memtier_benchmark.git --branch $MEMTIER_BRANCH
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

#---------------------------------------------------------- Remote Client Prerequisites --------------------------------------------------------

# Function to install prerequisites on remote memtier client machines
# This function is called when MULTI_CLIENT_MODE is enabled
install_remote_client_prerequisites() {
    if [[ -z "${ADDITIONAL_CLIENT_IPS}" ]]; then
        return
    fi
    
    echo "Installing prerequisites on additional client machines..."
    
    # Build arrays from ADDITIONAL_CLIENT_IPS configuration variable
    IFS=',' read -ra CLIENT_IPS <<< "$ADDITIONAL_CLIENT_IPS"
    
    for ((i=0; i<${#CLIENT_IPS[@]}; i++)); do
        local client_ip="${CLIENT_IPS[$i]}"
        
        # Trim whitespace from IP address
        client_ip=$(echo "$client_ip" | xargs)
        
        # Skip localhost - prerequisites are already installed on the primary client
        if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "localhost" ]]; then
            echo "Skipping prerequisite installation for localhost ($client_ip) - already installed"
            continue
        fi
        
        # Skip server IP - prerequisites are already installed when setting up the server
        if [[ "$client_ip" == "$SERVER_IP" ]]; then
            echo "Skipping prerequisite installation for server ($client_ip) - already installed during server setup"
            continue
        fi
        
        local ssh_cmd="ssh -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${client_ip}"
        
        echo "Installing prerequisites on client $client_ip"
        
        # First check if memtier is already available on the remote client
        if $ssh_cmd "command -v memtier_benchmark &>/dev/null"; then
            echo "Memtier already installed on client $client_ip - skipping installation"
            continue
        fi
        
        # Copy the config file to the remote client
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${config_file} ${LOGIN_ID}@${client_ip}:/tmp/memtier_client.config
        
        # Copy this script to the remote client
        local script_path="${SCRIPT_BASE_DIR:-${HOME_DIR}/redis-scripts/shared-scripts}/install_prereqs.sh"
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q "${script_path}" ${LOGIN_ID}@${client_ip}:/tmp/
        
        # Run install_prereqs.sh on the remote client (it will handle the client section)
        # Set CLIENT_ONLY flag to skip Redis server installation on clients
        ssh -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${client_ip} "source /tmp/memtier_client.config && export CLIENT_ONLY=true && source /tmp/install_prereqs.sh"
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install prerequisites on client $client_ip"
            exit 1
        fi
        
        # Create results directory on client
        $ssh_cmd "mkdir -p ${RESULTS_PATH}"
        
        # Clean up temporary files
        $ssh_cmd "rm -f /tmp/memtier_client.config /tmp/install_prereqs.sh"
        
        echo "Prerequisites installed on client $client_ip"
    done
    
    echo "All additional clients ready"
}

# Call the remote client installation function if ADDITIONAL_CLIENT_IPS is configured
# This happens when the script is sourced from run_all.sh in multi-client mode
if [[ -n "${ADDITIONAL_CLIENT_IPS}" ]]; then
    install_remote_client_prerequisites
fi
