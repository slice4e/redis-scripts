#!/bin/bash

#=======================================================================================================================
# Unified Redis Setup Script
# Handles local, remote single server, and remote multiple server configurations
# Replaces: local.sh, remote.sh, remote_multiple_servers.sh
#=======================================================================================================================

# Function to execute commands either locally or remotely
execute_command() {
    local cmd="$1"
    local target_server="$2"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${target_server}"
        $ssh_cmd "$cmd"
    else
        eval "$cmd"
    fi
}

# Function to execute commands in background (for server startup)
execute_command_background() {
    local cmd="$1"
    local target_server="$2"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${target_server}"
        nohup $ssh_cmd "$cmd &" &
    else
        eval "$cmd &"
    fi
}

# Function to copy files to remote server
copy_file_to_server() {
    local local_file="$1"
    local remote_path="$2"
    local target_server="$3"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} "$local_file" ${LOGIN_ID}@${target_server}:"$remote_path"
    else
        cp "$local_file" "$remote_path"
    fi
}

# Function to install system dependencies
install_dependencies() {
    local target_server="$1"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        echo "Installing dependencies on $target_server..."
        execute_command "apt-get install -y numactl python3-venv" "$target_server"
    else
        # Check if numactl is available, install if running as root or warn if not available
        if ! command -v numactl >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                apt-get install -y numactl python3-venv
            else
                echo "Warning: numactl is not installed. You may need to install it manually with: sudo apt-get install numactl python3-venv"
                echo "Continuing without numactl..."
            fi
        fi
        
        # Check if python3-venv is available
        if ! python3 -m venv --help >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                apt-get install -y python3-venv
            else
                echo "Warning: python3-venv is not installed. You may need to install it manually with: sudo apt-get install python3-venv"
            fi
        fi
    fi
}

# Function to setup Python virtual environment
setup_python_venv() {
    local target_server="$1"
    local venv_path="$2"
    
    echo "Setting up Python virtual environment on $target_server at $venv_path..."
    
    # Create virtual environment if it doesn't exist
    if execute_command "[ ! -d \"$venv_path\" ]" "$target_server"; then
        execute_command "python3 -m venv \"$venv_path\"" "$target_server"
    fi
    
    # Upgrade pip in the virtual environment
    execute_command "\"$venv_path/bin/python\" -m pip install --upgrade pip" "$target_server"
}

# Function to setup Redis
setup_redis() {
    local target_server="$1"
    
    echo "Setting up Redis on $target_server..."
    
    # Check if Redis exists
    if execute_command "[ ! -d \"$REDIS_PATH\" ]" "$target_server"; then
        echo "Redis not found in $REDIS_PATH, downloading it ..."
        execute_command "git clone https://github.com/redis/redis $REDIS_PATH" "$target_server"
        execute_command "cd $REDIS_PATH && git checkout $REDIS_BRANCH && export BUILD_TLS=yes BUILD_WITH_MODULES=yes INSTALL_RUST_TOOLCHAIN=yes DISABLE_WERRORS=yes && make -j REDIS_CFLAGS=\"-g -fno-omit-frame-pointer\" && cd -" "$target_server"
    fi
    
    # For remote setups, also install Redis locally for redis-cli
    if [[ "$SERVER_REMOTE" == "true" && ! -d "$REDIS_PATH" ]]; then
        echo "Installing Redis locally for redis-cli..."
        git clone https://github.com/redis/redis $REDIS_PATH
        cd $REDIS_PATH
        git checkout $REDIS_BRANCH
        export BUILD_TLS=yes BUILD_WITH_MODULES=yes INSTALL_RUST_TOOLCHAIN=yes DISABLE_WERRORS=yes
        make -j REDIS_CFLAGS="-g -fno-omit-frame-pointer"
        cd -
    fi
}

# Function to setup RediSearch
setup_redisearch() {
    local target_server="$1"
    
    if [[ "$VECTOR_SEARCH" != "vectorsets" ]]; then
        echo "Setting up RediSearch on $target_server..."
        
        # Use consistent RediSearch setup for all remote configurations
        local redisearch_lib="$REDIS_PATH/modules/redisearch/src/bin/linux-x64-release/search-community/redisearch.so"
        
        if execute_command "[ ! -f \"$redisearch_lib\" ]" "$target_server"; then
            echo "RediSearch not found in $redisearch_lib, downloading it ..."
            execute_command "cd $REDIS_PATH/modules/redisearch && make && cd -" "$target_server"
        fi
    fi
}

# Function to get the appropriate RediSearch library path
get_redisearch_lib() {
    echo "$REDIS_PATH/modules/redisearch/src/bin/linux-x64-release/search-community/redisearch.so"
}

# Function to cleanup existing Redis instances
cleanup_redis() {
    local target_server="$1"
    
    echo "Killing existing redis server instances and removing rdb files on $target_server..."
    execute_command "killall -9 redis-server" "$target_server"
    
    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        local rediscluster_script="$REDIS_PATH/utils/create-cluster/create-cluster-numa"
        copy_file_to_server "./create-cluster-numa" "$rediscluster_script" "$target_server"
        execute_command "cd $REDIS_PATH/utils/create-cluster && $rediscluster_script stop && $rediscluster_script clean && cd -" "$target_server"
    else
        execute_command "rm -f ${REDIS_PATH}/*.rdb" "$target_server"
    fi
}

# Function to configure Redis cluster
configure_redis_cluster() {
    local target_server="$1"
    local redisearch_lib="$2"
    
    local loadmodule_option=""
    if [[ "$VECTOR_SEARCH" != "vectorsets" ]]; then
        loadmodule_option="--loadmodule $redisearch_lib WORKERS $REDISEARCH_WORKERS"
    fi
    
    local rediscluster_config="$REDIS_PATH/utils/create-cluster/config.sh"
    execute_command "echo \"PORT=$((PORT-1))\" > $rediscluster_config" "$target_server"
    execute_command "echo \"NODES=$CLUSTER_NODES\" >> $rediscluster_config" "$target_server"
    execute_command "echo \"TIMEOUT=$CLUSTER_TIMEOUT\" >> $rediscluster_config" "$target_server"
    execute_command "echo \"REPLICAS=$CLUSTER_REPLICAS\" >> $rediscluster_config" "$target_server"
    execute_command "echo \"USE_NUMACTL=$USE_NUMACTL\" >> $rediscluster_config" "$target_server"
    execute_command "echo \"NUMA_NODES=$NUMA_NODES\" >> $rediscluster_config" "$target_server"
    execute_command "echo \"ADDITIONAL_OPTIONS='--save \\\"\\\" --protected-mode no --appendonly no $loadmodule_option'\" >> \"$rediscluster_config\"" "$target_server"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        execute_command "echo \"CLUSTER_HOST=$target_server\" >> $rediscluster_config" "$target_server"
    fi
}

# Function to start Redis server (standalone)
start_redis_server() {
    local target_server="$1"
    local redisearch_lib="$2"
    
    local loadmodule_option=""
    if [[ "$VECTOR_SEARCH" != "vectorsets" ]]; then
        loadmodule_option="--loadmodule $redisearch_lib WORKERS $REDISEARCH_WORKERS"
    fi
    
    local bind_option=""
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        bind_option="--bind $target_server"
    fi
    
    if [ "$USE_NUMACTL" -eq 1 ]; then
        local cmd="numactl -m ${NUMA_NODES} -N ${NUMA_NODES} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} $bind_option --logfile $REDIS_PATH/server.log --save \"\" --protected-mode no --appendonly no $loadmodule_option"
    else
        local cmd="$REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} $bind_option --logfile $REDIS_PATH/server.log --save \"\" --protected-mode no --appendonly no $loadmodule_option"
    fi
    
    echo "Starting Redis server: $cmd"
    execute_command_background "$cmd" "$target_server"
}

# Function to create Redis cluster
create_redis_cluster() {
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        # Multiple servers cluster creation
        sleep 2
        local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${CLUSTER_MASTER}"
        local endport=$((PORT+CLUSTER_NODES-1))
        local startport=$PORT
        local hosts=""
        
        while [ $((startport < endport)) != "0" ]; do
            for server in "${CLUSTER_SERVERS[@]}"; do
                hosts="$hosts $server:$startport"
            done
            startport=$((startport+1))
        done
        
        $ssh_cmd "echo \"yes\" | $REDIS_PATH/src/redis-cli --cluster create $hosts --cluster-replicas $CLUSTER_REPLICAS"
    else
        # Single server cluster creation
        local rediscluster_script="$REDIS_PATH/utils/create-cluster/create-cluster-numa"
        if [[ "$SERVER_REMOTE" == "true" ]]; then
            execute_command "cd $REDIS_PATH/utils/create-cluster && $rediscluster_script start && echo \"yes\" | $rediscluster_script create && cd -" "$TARGET"
        else
            execute_command "cd $REDIS_PATH/utils/create-cluster && $rediscluster_script start && echo \"yes\" | $rediscluster_script create && cd -" "localhost"
        fi
    fi
}

#=======================================================================================================================
# Main execution logic
#=======================================================================================================================

if [ ! "$SKIP_SETUP" -eq 1 ]; then
    
    # Determine which servers to configure
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        servers=("${CLUSTER_SERVERS[@]}")
    elif [[ "$SERVER_REMOTE" == "true" ]]; then
        servers=("$TARGET")
    else
        servers=("localhost")
    fi
    
    # Setup phase: Install dependencies, Redis, and RediSearch on all servers
    for server in "${servers[@]}"; do
        echo "=== Setting up server: $server ==="
        
        install_dependencies "$server"
        
        # Set up Python virtual environment
        if [[ "$server" == "localhost" ]]; then
            venv_path="$HOME_PATH/venv-redis-benchmark"
        else
            venv_path="$HOME_PATH/venv-redis-benchmark"
        fi
        setup_python_venv "$server" "$venv_path"
        
        setup_redis "$server"
        setup_redisearch "$server"
        
        echo "=== Setup completed for server: $server ==="
    done
    
    # Get RediSearch library path
    redisearch_lib=$(get_redisearch_lib)
    
    # Cleanup and start phase
    for server in "${servers[@]}"; do
        echo "=== Starting Redis on server: $server ==="
        
        cleanup_redis "$server"
        
        if [ "$REDIS_CLUSTER" -eq 1 ]; then
            configure_redis_cluster "$server" "$redisearch_lib"
            if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
                local rediscluster_script="$REDIS_PATH/utils/create-cluster/create-cluster-numa"
                execute_command "cd $REDIS_PATH/utils/create-cluster && $rediscluster_script start" "$server"
            fi
        else
            start_redis_server "$server" "$redisearch_lib"
        fi
        
        if [[ "$CLUSTER_MULTIPLE_SERVERS" -ne 1 ]]; then
            sleep 2
        fi
    done
    
    # Create cluster if needed
    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        echo "=== Creating Redis cluster ==="
        create_redis_cluster
        sleep 5
    fi
    
    echo "=== Redis setup completed ==="
fi
