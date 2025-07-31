#!/bin/bash

#=======================================================================================================================
# Unified Redis Setup Script
# Handles local, remote single server, and remote multiple server configurations
# Replaces: local.sh, remote.sh, remote_multiple_servers.sh
#=======================================================================================================================

# Global variables for logging
LOG_LEVEL=${LOG_LEVEL:-"INFO"}
SCRIPT_NAME="redis_setup"

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] [INFO] $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] [WARN] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] [ERROR] $*" >&2
}

# Constants - using regular variables since this script is sourced
REDIS_REPO_URL="https://github.com/redis/redis"
REDISEARCH_LIB_PATH="modules/redisearch/src/bin/linux-x64-release/search-community/redisearch.so"

# Only define VENV_DIR_NAME if not already defined
if [[ -z "${VENV_DIR_NAME:-}" ]]; then
    VENV_DIR_NAME="venv-redis-benchmark"
fi

# Configuration defaults
DEFAULT_BUILD_FLAGS="BUILD_TLS=yes BUILD_WITH_MODULES=yes INSTALL_RUST_TOOLCHAIN=yes DISABLE_WERRORS=yes"
DEFAULT_REDIS_CFLAGS="-g -fno-omit-frame-pointer"

# Function to validate required environment variables
validate_environment() {
    local required_vars=("REDIS_PATH" "HOME_PATH")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        log_error "Please check your config.file"
        exit 1
    fi
}

# Function to execute commands either locally or remotely
# Args: $1 = command, $2 = target_server
execute_command() {
    local cmd="$1"
    local target_server="$2"
    
    log_info "Executing on $target_server: $cmd"
    
    if [[ "$target_server" == "localhost" ]]; then
        # Local execution
        if ! eval "$cmd"; then
            log_error "Command failed locally: $cmd"
            return 1
        fi
    else
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $USER@${target_server}"
        
        if ! $ssh_cmd "$cmd"; then
            log_error "Command failed on remote server $target_server: $cmd"
            return 1
        fi
    fi
}

# Function to execute commands quietly (no error logging for expected failures)
# Args: $1 = command, $2 = target_server
execute_command_quiet() {
    local cmd="$1"
    local target_server="$2"
    
    if [[ "$target_server" == "localhost" ]]; then
        eval "$cmd" >/dev/null 2>&1
    else
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $USER@${target_server}"
        $ssh_cmd "$cmd" >/dev/null 2>&1
    fi
}

# Function to execute commands in background (for server startup)
# Args: $1 = command, $2 = target_server
execute_command_background() {
    local cmd="$1"
    local target_server="$2"
    
    log_info "Starting background process on $target_server: $cmd"
    
    if [[ "$target_server" == "localhost" ]]; then
        # Local background execution
        eval "$cmd" &
        local pid=$!
        log_info "Background process started locally with PID: $pid"
    else
        # Remote background execution
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $USER@${target_server}"
        
        nohup $ssh_cmd "$cmd" > /dev/null 2>&1 &
        local pid=$!
        log_info "Background process started on remote server with local PID: $pid"
    fi
}

# Function to copy files to remote server
copy_file_to_server() {
    local local_file="$1"
    local remote_path="$2"
    local target_server="$3"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} "$local_file" $USER@${target_server}:"$remote_path"
    else
        cp "$local_file" "$remote_path"
    fi
}

# Function to install system dependencies
install_dependencies() {
    local target_server="$1"
    
    log_info "Installing dependencies on $target_server..."
    
    # For localhost, check if we actually need to install anything first
    if [[ "$target_server" == "localhost" ]]; then
        # Check if all required tools are already available
        local missing_deps=()
        
        if ! execute_command_quiet "command -v numactl" "$target_server"; then
            missing_deps+=("numactl")
        fi
        
        if ! execute_command_quiet "python3 -m venv --help" "$target_server"; then
            missing_deps+=("python3-venv")
        fi
        
        if ! execute_command_quiet "pkg-config --exists openssl" "$target_server"; then
            missing_deps+=("libssl-dev pkg-config")
        fi
        
        # If nothing is missing, skip dependency installation
        if [[ ${#missing_deps[@]} -eq 0 ]]; then
            log_info "All required dependencies are already available on localhost, skipping installation"
            return 0
        fi
        
        # If something is missing, warn user and provide instructions
        log_warn "Missing dependencies on localhost: ${missing_deps[*]}"
        log_warn "Please install them manually with:"
        log_warn "sudo apt-get update && sudo apt-get install -y numactl python3-venv libssl-dev pkg-config"
        log_warn "Or ensure your user has sudo privileges"
        return 1
    fi
    
    # Update package lists first
    log_info "Updating package lists on $target_server..."
    if ! execute_command "sudo apt-get update" "$target_server"; then
        if [[ "$target_server" == "localhost" ]]; then
            log_error "Failed to update package lists. You may need sudo privileges."
            log_error "Try running: sudo apt-get update"
        else
            log_error "Failed to update package lists on $target_server"
            log_error "Ensure the user has passwordless sudo access"
        fi
        return 1
    fi
    
    # Check if numactl is available
    if ! execute_command_quiet "command -v numactl" "$target_server"; then
        log_info "Installing numactl on $target_server..."
        if ! execute_command "sudo apt-get install -y numactl" "$target_server"; then
            log_error "Failed to install numactl on $target_server"
            return 1
        fi
        log_info "Successfully installed numactl on $target_server"
    else
        log_info "numactl is already available on $target_server"
    fi
    
    # Check if OpenSSL development headers are available (required for TLS support)
    if ! execute_command_quiet "pkg-config --exists openssl" "$target_server"; then
        log_info "Installing OpenSSL development packages on $target_server..."
        if ! execute_command "sudo apt-get install -y libssl-dev pkg-config" "$target_server"; then
            log_error "Failed to install OpenSSL development packages on $target_server"
            log_error "OpenSSL development headers are required for TLS support"
            return 1
        fi
        log_info "Successfully installed OpenSSL development packages on $target_server"
    else
        log_info "OpenSSL development packages are already available on $target_server"
    fi
    
    log_info "Installing Redis requirements on $target_server..."
    if ! execute_command "sudo apt-get install -y --no-install-recommends \
        ca-certificates wget dpkg-dev gcc g++ libc6-dev libssl-dev make git cmake \
        python3 python3-pip python3-venv python3-dev unzip rsync clang automake \
        autoconf libtool" "$target_server"; then
        log_error "Failed to install Redis requirements on $target_server"
        return 1
    fi
    log_info "Successfully installed Redis requirements on $target_server"
   
    log_info "All dependencies are available on $target_server"
}

# Function to setup Python virtual environment
setup_python_venv() {
    local target_server="$1"
    local venv_path="$2"
    
    log_info "Setting up Python virtual environment on $target_server at $venv_path..."

    # Check if python3-venv is available
    if ! execute_command_quiet "python3 -m venv --help" "$target_server"; then
        log_info "Installing python3-venv on $target_server..."
        if ! execute_command "sudo apt-get install -y python3-venv" "$target_server"; then
            log_error "Failed to install python3-venv on $target_server"
            log_error "python3-venv is required for virtual environment setup"
            return 1
        fi
        log_info "Successfully installed python3-venv on $target_server"
    else
        log_info "python3-venv is already available on $target_server"
    fi

    # Check if virtual environment exists and is valid
    if execute_command_quiet "[ ! -d \"$venv_path\" ] || [ ! -x \"$venv_path/bin/python\" ]" "$target_server"; then
        log_info "Virtual environment missing or invalid, creating new one at $venv_path..."
        # Remove any incomplete or corrupted venv directory
        execute_command "rm -rf \"$venv_path\"" "$target_server"
        # Create new virtual environment with --upgrade-deps
        if ! execute_command "python3 -m venv --upgrade-deps \"$venv_path\"" "$target_server"; then
            log_error "Failed to create virtual environment"
            return 1
        fi
    else
        log_info "Virtual environment already exists at $venv_path"
    fi
    
    # Verify pip is available and upgrade it
    if ! execute_command_quiet "\"$venv_path/bin/python\" -m pip --version" "$target_server"; then
        log_info "Virtual environment pip is not working, recreating..."
        execute_command "rm -rf \"$venv_path\"" "$target_server"
        execute_command "python3 -m venv --upgrade-deps \"$venv_path\"" "$target_server"
    fi
    
    # Upgrade pip in the virtual environment
    execute_command "\"$venv_path/bin/python\" -m pip install --upgrade pip" "$target_server"
}

# Function to setup Redis on target server
# Args: $1 = target_server
setup_redis() {
    local target_server="$1"
    
    log_info "Setting up Redis on $target_server..."
    
    # Check if Redis directory exists on target server
    if execute_command_quiet "[ -d \"$REDIS_PATH\" ]" "$target_server"; then
        log_info "Redis directory already exists at $REDIS_PATH on $target_server, skipping clone and build"
        return 0
    fi

    log_info "Preparing to clone and build Redis on $target_server..."
    
    # Clone Redis repository
    if ! execute_command "git clone $REDIS_REPO_URL $REDIS_PATH" "$target_server"; then
        log_error "Failed to clone Redis repository on $target_server"
        return 1
    fi
    
    # Build Redis on target server
    local build_cmd="cd $REDIS_PATH && git checkout $REDIS_BRANCH && export $DEFAULT_BUILD_FLAGS && make -j REDIS_CFLAGS=\"$DEFAULT_REDIS_CFLAGS\" && cd -"
    if ! execute_command "$build_cmd" "$target_server"; then
        log_error "Failed to build Redis on $target_server"
        return 1
    fi
    
    log_info "Redis successfully built on $target_server"
}

# Function to setup RediSearch
# Args: $1 = target_server
setup_redisearch() {
    local target_server="$1"
    
    if [[ "$VECTOR_SEARCH" == "vectorsets" ]]; then
        log_info "Skipping RediSearch setup (using vectorsets)"
        return 0
    fi
    
    log_info "Setting up RediSearch on $target_server..."
    
    local redisearch_lib="$REDIS_PATH/$REDISEARCH_LIB_PATH"
    
    if execute_command_quiet "[ ! -f \"$redisearch_lib\" ]" "$target_server"; then
        log_info "RediSearch not found, building..."
        
        local build_cmd="cd $REDIS_PATH/modules/redisearch && make && cd -"
        
        if ! execute_command "$build_cmd" "$target_server"; then
            log_error "Failed to build RediSearch on $target_server"
            return 1
        fi
        
        log_info "RediSearch successfully built on $target_server"
    else
        log_info "RediSearch already exists on $target_server"
    fi
}

# Function to get the appropriate RediSearch library path
get_redisearch_lib() {
    echo "$REDIS_PATH/$REDISEARCH_LIB_PATH"
}

# Function to cleanup existing Redis instances
cleanup_redis() {
    local target_server="$1"
    
    echo "Killing existing redis server instances and removing rdb files on $target_server..."
    # killall may fail if no redis-server processes are running, so we suppress any error output
    execute_command "killall -9 redis-server 2>/dev/null || echo 'No redis-server processes running'" "$target_server"
    
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
        local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q $USER@${CLUSTER_MASTER}"
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
main() {
    log_info "Starting Redis setup process..."
    
    # Validate environment
    validate_environment
    
    if [ "$SKIP_SETUP" -eq 1 ]; then
        log_info "Skipping setup (SKIP_SETUP=1)"
        return 0
    fi

    # Determine ALL servers to work with (always include localhost)
    local servers=("localhost")
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        servers+=("${CLUSTER_SERVERS[@]}")
        log_info "Multiple server cluster setup with servers: ${servers[*]}"
    elif [[ "$SERVER_REMOTE" == "true" ]]; then
        servers+=("$TARGET")
        log_info "Remote server setup with servers: ${servers[*]}"
    else
        log_info "Local server setup with servers: ${servers[*]}"
    fi
    
    # Setup phase: Install dependencies, Redis, and RediSearch on ALL servers
    for server in "${servers[@]}"; do
        log_info "=== Setting up server: $server ==="
        
        install_dependencies "$server"
        setup_redis "$server"
        setup_redisearch "$server"
        
        # Setup Python virtual environment only on localhost (client always runs locally)
        if [[ "$server" == "localhost" ]]; then
            local venv_path="$HOME_PATH/$VENV_DIR_NAME"
            setup_python_venv "$server" "$venv_path"
        fi
        
        log_info "=== Setup completed for server: $server ==="
    done
    
    # Get RediSearch library path
    local redisearch_lib
    redisearch_lib=$(get_redisearch_lib)
    
    # Runtime phase: Start Redis only on servers that should run Redis
    for server in "${servers[@]}"; do
        # Skip localhost if we're doing remote setup (localhost is just for client tools)
        if [[ "$server" == "localhost" && "$SERVER_REMOTE" == "true" ]]; then
            log_info "Skipping Redis startup on localhost (using remote servers)"
            continue
        fi
        
        log_info "=== Starting Redis on server: $server ==="
        
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
        log_info "=== Creating Redis cluster ==="
        create_redis_cluster
        sleep 5
    fi
    
    log_info "=== Redis setup completed successfully ==="
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
