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
	SRV_PKG="apt"
elif $SSH_COMMAND command -v "zypper" &>/dev/null; then
	SRV_PKG="zypper"
	# Disable SCC services to prevent refresh timeouts; set repos to no-refresh but keep them enabled
	$SSH_COMMAND bash -c 'for svc in $(zypper ls --uri 2>/dev/null | grep -i "suse\.com" | cut -d"|" -f2 | tr -d " "); do zypper ms -d "$svc" 2>/dev/null; done' || true
	$SSH_COMMAND bash -c 'zypper mr --no-refresh --all 2>/dev/null' || true
else
	SRV_PKG="yum"
fi

# Only install Redis server if this is not a client-only installation
if [[ "${skip_redis_installation}" != "true" ]] && ! $SSH_COMMAND command -v "$REDIS_PATH/src/redis-server" &>/dev/null; then
	echo "Redis is not installed. Attempting to install."
	if [[ $SRV_PKG == "apt" ]]; then
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install make -y
		$SSH_COMMAND apt install gcc -y
		$SSH_COMMAND apt install g++ -y
		$SSH_COMMAND apt install pkg-config -y
	elif [[ $SRV_PKG == "zypper" ]]; then
		$SSH_COMMAND zypper --no-refresh install -y make gcc gcc-c++ pkg-config
	else
		$SSH_COMMAND yum install make -y
		$SSH_COMMAND yum install gcc -y
		$SSH_COMMAND yum install gcc-c++ -y
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
	if [[ $SRV_PKG == "apt" ]]; then
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install numactl -y
	elif [[ $SRV_PKG == "zypper" ]]; then
		$SSH_COMMAND zypper --no-refresh install -y numactl
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
	if [[ $SRV_PKG == "apt" ]]; then
		$SSH_COMMAND apt-get update
		$SSH_COMMAND apt install lsof -y
	elif [[ $SRV_PKG == "zypper" ]]; then
		$SSH_COMMAND zypper --no-refresh install -y lsof
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
		if [[ $SRV_PKG == "apt" ]]; then
			$SSH_COMMAND apt-get update
			$SSH_COMMAND apt install sysstat -y
		elif [[ $SRV_PKG == "zypper" ]]; then
			$SSH_COMMAND zypper --no-refresh install -y sysstat
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
		if [[ $SRV_PKG == "yum" ]]; then
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
			if [[ $SRV_PKG == "apt" ]]; then
				$SSH_COMMAND apt install linux-tools-common -y
				$SSH_COMMAND "apt install linux-tools-`uname -r` -y"
			elif [[ $SRV_PKG == "zypper" ]]; then
				$SSH_COMMAND zypper --no-refresh install -y perf
			else
				$SSH_COMMAND yum install perf -y
			fi
			$SSH_COMMAND "echo 0 > /proc/sys/kernel/perf_event_paranoid"
			$SSH_COMMAND "echo \"kernel.perf_event_paranoid = 1\" >> /etc/sysctl.conf"
		fi
	else
		if ! command -v "perf" &>/dev/null; then
			if [[ $SRV_PKG == "apt" ]]; then
				apt install linux-tools-common -y
				apt install linux-tools-`uname -r` -y
			elif [[ $SRV_PKG == "zypper" ]]; then
				zypper --no-refresh install -y perf
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

EMON_VENV_PATH="${HOME_DIR}/.venv/emon"
export EMON_VENV_PATH

if [[ $RUN_EMON == true ]] ; then
	if ! $SSH_COMMAND command -v "${EMON_FOLDER}/emon" &>/dev/null; then
    		echo "EMON is configured to run, but it is not installed on the client. Please install it after this script completes."
		echo "You will likely need these python packages, so we will go ahead and install them."
		if [[ $SRV_PKG == "apt" ]]; then
			$SSH_COMMAND apt install python3-dev python3-pip python3-venv -y
		elif [[ $SRV_PKG == "zypper" ]]; then
			$SSH_COMMAND zypper --no-refresh install -y python3-devel python3-pip python3-virtualenv
		else
			$SSH_COMMAND yum install python3-devel python3-pip -y
		fi
		$SSH_COMMAND "python3 -m venv ${EMON_VENV_PATH}"
		$SSH_COMMAND "${EMON_VENV_PATH}/bin/pip install --upgrade pip"
		$SSH_COMMAND "${EMON_VENV_PATH}/bin/pip install 'numpy<2.0; python_version < \"3.10\"' 'numpy; python_version >= \"3.10\"' pandas defusedxml pytz xlsxwriter jsonschema multiprocess tables natsort tqdm polars pyarrow jinja2 openpyxl certifi tdigest"
    		exit 1
	else
		if ! $SSH_COMMAND "${EMON_VENV_PATH}/bin/python3 -c 'import numpy, pandas, defusedxml, pytz, xlsxwriter, jsonschema, multiprocess, tables, natsort, tqdm, polars, pyarrow, jinja2, openpyxl, certifi, tdigest'" &>/dev/null; then
			echo "EMON is installed but one or more MPP python dependencies are missing. Installing into venv."
			if [[ $SRV_PKG == "apt" ]]; then
				$SSH_COMMAND apt install python3-dev python3-pip python3-venv -y
			elif [[ $SRV_PKG == "zypper" ]]; then
				$SSH_COMMAND zypper --no-refresh install -y python3-devel python3-pip python3-virtualenv
			else
				$SSH_COMMAND yum install python3-devel python3-pip -y
			fi
			$SSH_COMMAND "python3 -m venv ${EMON_VENV_PATH}"
			$SSH_COMMAND "${EMON_VENV_PATH}/bin/pip install --upgrade pip"
			$SSH_COMMAND "${EMON_VENV_PATH}/bin/pip install 'numpy<2.0; python_version < \"3.10\"' 'numpy; python_version >= \"3.10\"' pandas defusedxml pytz xlsxwriter jsonschema multiprocess tables natsort tqdm polars pyarrow jinja2 openpyxl certifi tdigest"
		fi
	fi
fi

# All prerequisites are installed, continue with the script
echo "All prerequisites are installed on the server."

echo "Check pre-requisites on the client"
if command -v "apt" &>/dev/null; then
	CLI_PKG="apt"
elif command -v "zypper" &>/dev/null; then
	CLI_PKG="zypper"
	# Disable SCC services to prevent refresh timeouts; set repos to no-refresh but keep them enabled
	bash -c 'for svc in $(zypper ls --uri 2>/dev/null | grep -i "suse\.com" | cut -d"|" -f2 | tr -d " "); do zypper ms -d "$svc" 2>/dev/null; done' || true
	bash -c 'zypper mr --no-refresh --all 2>/dev/null' || true
else
	CLI_PKG="yum"
fi

if ! command -v "${MEMTIER_PATH}/memtier_benchmark" &>/dev/null && ! command -v memtier_benchmark &>/dev/null; then
	echo "The prerequisite memtier-benchmark is not installed. Attempting to install."
	if [[ $CLI_PKG == "apt" ]]; then
		apt-get update
		apt-get install build-essential autoconf automake libpcre3-dev libevent-dev pkg-config zlib1g-dev libssl-dev -y
	elif [[ $CLI_PKG == "zypper" ]]; then
		zypper --no-refresh install -y autoconf automake make gcc-c++ libtool
		zypper --no-refresh install -y pcre2-devel zlib-devel libevent-devel pkg-config
		zypper --no-refresh install -y libopenssl-devel || zypper --no-refresh install -y libopenssl-3-devel || true

		# Fallback: if autotools/libs not available via zypper, build from source
		if ! command -v autoreconf &>/dev/null; then
			echo "autotools not available via zypper, building from source..."
			DEPS_BUILD_DIR=$(mktemp -d)
			DEPS_BASE_URL="https://github.com/slice4e/redis-scripts/releases/download/build-deps-v1"
			pushd $DEPS_BUILD_DIR
			curl -sL ${DEPS_BASE_URL}/m4-1.4.19.tar.gz | tar xz && cd m4-1.4.19 && ./configure --prefix=/usr/local && make -j$(nproc) && make install && cd ..
			curl -sL ${DEPS_BASE_URL}/autoconf-2.72.tar.gz | tar xz && cd autoconf-2.72 && ./configure --prefix=/usr/local && make -j$(nproc) && make install && cd ..
			curl -sL ${DEPS_BASE_URL}/automake-1.17.tar.gz | tar xz && cd automake-1.17 && ./configure --prefix=/usr/local && make -j$(nproc) && make install && cd ..
			curl -sL ${DEPS_BASE_URL}/libtool-2.5.4.tar.gz | tar xz && cd libtool-2.5.4 && ./configure --prefix=/usr/local && make -j$(nproc) && make install && cd ..
			popd
			rm -rf $DEPS_BUILD_DIR
			ldconfig
		fi

		# Build missing library deps from source if not available
		if ! pkg-config --exists libevent 2>/dev/null; then
			echo "libevent-devel not available, building from source..."
			DEPS_BUILD_DIR=$(mktemp -d)
			DEPS_BASE_URL="https://github.com/slice4e/redis-scripts/releases/download/build-deps-v1"
			pushd $DEPS_BUILD_DIR
			curl -sL ${DEPS_BASE_URL}/libevent-2.1.12-stable.tar.gz | tar xz
			cd libevent-2.1.12-stable && ./configure --prefix=/usr/local && make -j$(nproc) && make install && cd ..
			popd
			rm -rf $DEPS_BUILD_DIR
			ldconfig
		fi

		if ! pkg-config --exists libpcre2-8 2>/dev/null && ! pkg-config --exists libpcre 2>/dev/null; then
			echo "pcre-devel not available, building from source..."
			DEPS_BUILD_DIR=$(mktemp -d)
			DEPS_BASE_URL="https://github.com/slice4e/redis-scripts/releases/download/build-deps-v1"
			pushd $DEPS_BUILD_DIR
			curl -sL ${DEPS_BASE_URL}/pcre2-10.44.tar.gz | tar xz
			cd pcre2-10.44 && ./configure --prefix=/usr/local --enable-jit && make -j$(nproc) && make install && cd ..
			popd
			rm -rf $DEPS_BUILD_DIR
			ldconfig
		fi
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

		if [[ $CLI_PKG == "apt" ]]; then
			apt-get update
			apt install python3-pip -y
			apt install docker.io -y
		elif [[ $CLI_PKG == "zypper" ]]; then
			zypper --no-refresh install -y python3-pip docker
			systemctl start docker
		else
			yum install -y yum-utils
			yum install -y yum-utils
			yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			yum install python3-pip -y
			yum install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			systemctl start docker
		fi
		python3 -m venv ${HOME_DIR}/.venv/bench-spec
		${HOME_DIR}/.venv/bench-spec/bin/pip install --upgrade pip
		${HOME_DIR}/.venv/bench-spec/bin/pip install cryptography==38.0.4
		${HOME_DIR}/.venv/bench-spec/bin/pip install pyopenssl --upgrade
		${HOME_DIR}/.venv/bench-spec/bin/pip install redis-benchmarks-specification --ignore-installed blinker
		ln -sf ${HOME_DIR}/.venv/bench-spec/bin/redis-benchmarks-spec-client-runner /usr/local/bin/redis-benchmarks-spec-client-runner
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
		if [[ $CLI_PKG == "apt" ]]; then
			apt install python3-dev python3-pip python3-venv -y
		elif [[ $CLI_PKG == "zypper" ]]; then
			zypper --no-refresh install -y python3-devel python3-pip python3-virtualenv
		else
			yum install python3-devel python3-pip -y
		fi
		python3 -m venv ${EMON_VENV_PATH}
		${EMON_VENV_PATH}/bin/pip install --upgrade pip
		${EMON_VENV_PATH}/bin/pip install "numpy<2.0; python_version < '3.10'" "numpy; python_version >= '3.10'" pandas defusedxml pytz xlsxwriter jsonschema multiprocess tables natsort tqdm polars pyarrow jinja2 openpyxl certifi tdigest
    		exit 1
	else
		if ! ${EMON_VENV_PATH}/bin/python3 -c "import numpy, pandas, defusedxml, pytz, xlsxwriter, jsonschema, multiprocess, tables, natsort, tqdm, polars, pyarrow, jinja2, openpyxl, certifi, tdigest" &>/dev/null; then
			echo "EMON is installed but one or more MPP python dependencies are missing. Installing into venv."
			if [[ $CLI_PKG == "apt" ]]; then
				apt install python3-dev python3-pip python3-venv -y
			elif [[ $CLI_PKG == "zypper" ]]; then
				zypper --no-refresh install -y python3-devel python3-pip python3-virtualenv
			else
				yum install python3-devel python3-pip -y
			fi
			python3 -m venv ${EMON_VENV_PATH}
			${EMON_VENV_PATH}/bin/pip install --upgrade pip
			${EMON_VENV_PATH}/bin/pip install "numpy<2.0; python_version < '3.10'" "numpy; python_version >= '3.10'" pandas defusedxml pytz xlsxwriter jsonschema multiprocess tables natsort tqdm polars pyarrow jinja2 openpyxl certifi tdigest
		fi
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
