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
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${target_server}"
        if ! $ssh_cmd "$cmd"; then
            log_error "Command failed on remote server $target_server: $cmd"
            return 1
        fi
    else
        if ! eval "$cmd"; then
            log_error "Command failed locally: $cmd"
            return 1
        fi
    fi
}

# Function to execute commands in background (for server startup)
# Args: $1 = command, $2 = target_server
execute_command_background() {
    local cmd="$1"
    local target_server="$2"
    
    log_info "Starting background process on $target_server: $cmd"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        local ssh_cmd="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${target_server}"
        nohup $ssh_cmd "$cmd &" > /dev/null 2>&1 &
    else
        eval "$cmd &"
    fi
    
    log_info "Background process started with PID: $!"
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
        log_info "Checking dependencies and sudo access on $target_server..."
        
        # First, check if user has sudo privileges
        if ! execute_command "sudo -n true >/dev/null 2>&1" "$target_server"; then
            log_error "User does not have passwordless sudo access on $target_server"
            log_error "Remote user must be configured as a sudoer for dependency installation"
            log_error "Please ensure the user can run 'sudo' commands without password prompt"
            log_error "You can configure this by adding the user to sudoers file with NOPASSWD option"
            return 1
        fi
        
        log_info "Sudo access confirmed on $target_server"
        
        # Update package lists first
        log_info "Updating package lists on $target_server..."
        if ! execute_command "sudo apt-get update" "$target_server"; then
            log_error "Failed to update package lists on $target_server"
            return 1
        fi
        
        # Check if numactl is available
        if ! execute_command "command -v numactl >/dev/null 2>&1" "$target_server"; then
            log_info "Installing numactl on $target_server..."
            if ! execute_command "sudo apt-get install -y numactl" "$target_server"; then
                log_error "Failed to install numactl on $target_server"
                return 1
            fi
            log_info "Successfully installed numactl on $target_server"
        else
            log_info "numactl is already available on $target_server"
        fi
        
        # Check if python3-venv is available
        if ! execute_command "python3 -m venv --help >/dev/null 2>&1" "$target_server"; then
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
        
        log_info "All dependencies are available on $target_server"
    else
        # Local installation logic remains the same
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
# Args: $1 = target_server
setup_redis() {
    local target_server="$1"
    
    log_info "Setting up Redis on $target_server..."
    
    # Check if Redis exists and build if necessary
    if execute_command "[ ! -d \"$REDIS_PATH\" ]" "$target_server"; then
        log_info "Redis not found in $REDIS_PATH, downloading and building..."
        
        # Clone Redis repository
        execute_command "git clone $REDIS_REPO_URL $REDIS_PATH" "$target_server"
        
        # Build Redis with proper error handling
        local build_cmd="cd $REDIS_PATH && git checkout $REDIS_BRANCH && export $DEFAULT_BUILD_FLAGS && make -j REDIS_CFLAGS=\"$DEFAULT_REDIS_CFLAGS\" && cd -"
        
        if ! execute_command "$build_cmd" "$target_server"; then
            log_error "Failed to build Redis on $target_server"
            return 1
        fi
        
        log_info "Redis successfully built on $target_server"
    else
        log_info "Redis already exists at $REDIS_PATH on $target_server"
    fi
    
    # For remote setups, also install Redis locally for redis-cli
    if [[ "$SERVER_REMOTE" == "true" && ! -d "$REDIS_PATH" ]]; then
        log_info "Installing Redis locally for redis-cli..."
        
        if ! git clone $REDIS_REPO_URL "$REDIS_PATH"; then
            log_error "Failed to clone Redis locally"
            return 1
        fi
        
        cd "$REDIS_PATH"
        git checkout "$REDIS_BRANCH"
        export $DEFAULT_BUILD_FLAGS
        
        if ! make -j REDIS_CFLAGS="$DEFAULT_REDIS_CFLAGS"; then
            log_error "Failed to build Redis locally"
            cd -
            return 1
        fi
        
        cd -
        log_info "Redis successfully installed locally"
    fi
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
    
    if execute_command "[ ! -f \"$redisearch_lib\" ]" "$target_server"; then
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

main() {
    log_info "Starting Redis setup process..."
    
    # Validate environment
    validate_environment
    
    if [ "$SKIP_SETUP" -eq 1 ]; then
        log_info "Skipping setup (SKIP_SETUP=1)"
        return 0
    fi
    
    # Determine which servers to configure
    local servers=()
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        servers=("${CLUSTER_SERVERS[@]}")
        log_info "Multiple server cluster setup with servers: ${servers[*]}"
    elif [[ "$SERVER_REMOTE" == "true" ]]; then
        servers=("$TARGET")
        log_info "Single remote server setup: $TARGET"
    else
        servers=("localhost")
        log_info "Local server setup"
    fi
    
    # Setup phase: Install dependencies, Redis, and RediSearch on all servers
    for server in "${servers[@]}"; do
        log_info "=== Setting up server: $server ==="
        
        install_dependencies "$server"
        
        # Set up Python virtual environment
        local venv_path="$HOME_PATH/$VENV_DIR_NAME"
        setup_python_venv "$server" "$venv_path"
        
        setup_redis "$server"
        setup_redisearch "$server"
        
        log_info "=== Setup completed for server: $server ==="
    done
    
    # Get RediSearch library path
    local redisearch_lib
    redisearch_lib=$(get_redisearch_lib)
    
    # Cleanup and start phase
    for server in "${servers[@]}"; do
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
