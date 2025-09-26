#!/bin/bash

#=======================================================================================================================
# Redis Setup and Utilities Script
# Comprehensive Redis setup, configuration, and management functions
# Can be used standalone or as part of the benchmark suite
#
# USAGE:
#   Standalone: ./redis_utils.sh [config_file]
#   As module:  source redis_utils.sh
#=======================================================================================================================

# Set script name for logging
SCRIPT_NAME="${SCRIPT_NAME:-redis_setup}"

# Source common utilities
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common_utils.sh"

# Constants
REDIS_REPO_URL="https://github.com/redis/redis"
REDISEARCH_LIB_PATH="modules/redisearch/src/bin/linux-x64-release/search-community/redisearch.so"
DEFAULT_BUILD_FLAGS="BUILD_TLS=yes BUILD_WITH_MODULES=yes INSTALL_RUST_TOOLCHAIN=yes DISABLE_WERRORS=yes"
DEFAULT_REDIS_CFLAGS="-g -fno-omit-frame-pointer"

#=======================================================================================================================
# Redis Setup Functions
#=======================================================================================================================

# Function to setup Redis on target server
setup_redis() {
    local target_server="$1"
    
    log_info "Setting up Redis on $target_server..."
    
    # Skip if Redis already exists
    if execute_command_quiet "[ -d \"$REDIS_PATH\" ]" "$target_server"; then
        log_info "Redis directory already exists, skipping build"
        return 0
    fi

    log_info "Cloning and building Redis..."
    
    # Ensure parent directory exists and clone
    ensure_directory "$(dirname "$REDIS_PATH")" "$target_server" || return 1
    execute_command "git clone $REDIS_REPO_URL $REDIS_PATH" "$target_server" || { log_error "Failed to clone Redis"; return 1; }
    
    # Build Redis
    local build_cmd="cd $REDIS_PATH && git checkout $REDIS_BRANCH && export $DEFAULT_BUILD_FLAGS && make -j REDIS_CFLAGS=\"$DEFAULT_REDIS_CFLAGS\""
    execute_command "$build_cmd" "$target_server" || { log_error "Failed to build Redis"; return 1; }
    
    log_info "Redis successfully built on $target_server"
}

# Function to setup RediSearch
setup_redisearch() {
    local target_server="$1"
    
    # Skip if using vectorsets
    [[ "$VECTOR_SEARCH" == "vectorsets" ]] && { log_info "Skipping RediSearch (using vectorsets)"; return 0; }
    
    log_info "Setting up RediSearch on $target_server..."
    
    local redisearch_lib="$REDIS_PATH/$REDISEARCH_LIB_PATH"
    
    # Build if library doesn't exist
    if execute_command_quiet "[ ! -f \"$redisearch_lib\" ]" "$target_server"; then
        log_info "Building RediSearch..."
        execute_command "cd $REDIS_PATH/modules/redisearch && make" "$target_server" || { log_error "Failed to build RediSearch"; return 1; }
        log_info "RediSearch successfully built"
    else
        log_info "RediSearch already exists"
    fi
}

# Function to get the appropriate RediSearch library path
get_redisearch_lib() {
    echo "$REDIS_PATH/$REDISEARCH_LIB_PATH"
}

#=======================================================================================================================
# Redis Server Management Functions
#=======================================================================================================================

# Function to cleanup existing Redis instances
cleanup_redis() {
    local target_server="$1"
    
    log_info "Cleaning up existing Redis instances on $target_server..."
    # killall may fail if no redis-server processes are running, so we suppress any error output
    execute_command "killall -9 redis-server 2>/dev/null || echo 'No redis-server processes running'" "$target_server"
    
    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        # Save the current working directory
        local current_dir=$(pwd)
        
        # Copy the script to the target location
        local rediscluster_script="$REDIS_PATH/utils/create-cluster/create-cluster-numa.sh"
        copy_file_to_server "$SCRIPT_DIR/create-cluster-numa.sh" "$rediscluster_script" "$target_server"
        
        # Use absolute paths in the command to avoid directory issues
        execute_command "cd $REDIS_PATH/utils/create-cluster && $rediscluster_script stop && $rediscluster_script clean && cd \"$current_dir\"" "$target_server"
    else
        execute_command "rm -f ${REDIS_PATH}/*.rdb" "$target_server"
    fi
}

# Function to start Redis server (standalone)
start_redis_server() {
    local target_server="$1" redisearch_lib="$2"
    
    local loadmodule_option=""
    [[ "$VECTOR_SEARCH" != "vectorsets" ]] && loadmodule_option="--loadmodule $redisearch_lib WORKERS $REDISEARCH_WORKERS"
    
    local bind_option=""
    [[ "$SERVER_REMOTE" == "true" ]] && bind_option="--bind $target_server"
    
    local numa_prefix=""
    [[ -n "$NUMA_CONFIG" ]] && numa_prefix="$NUMA_CONFIG"
    
    local cmd="$numa_prefix $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} $bind_option --logfile $REDIS_PATH/server.log --save \"\" --protected-mode no --appendonly no $loadmodule_option"
    
    log_info "Starting Redis server: $cmd"
    
    # Verify Redis configuration file exists
    if [[ ! -f "$REDIS_PATH/redis.conf" ]]; then
        log_error "Redis configuration file not found: $REDIS_PATH/redis.conf"
        return 1
    fi
    
    # Verify RediSearch module exists if needed
    if [[ -n "$loadmodule_option" && ! -f "$redisearch_lib" ]]; then
        log_error "RediSearch module not found: $redisearch_lib"
        return 1
    fi
    
    execute_command_background "$cmd" "$target_server"
}

# Function to wait for Redis to be ready
wait_for_redis() {
    local target="${1:-localhost}"
    local port="${2:-6379}"
    local max_attempts="${3:-180}"  # Increased from 60 to 180 seconds (3 minutes)
    
    log_info "Waiting for Redis server at $target:$port to be ready..."
    log_info "This may take up to $max_attempts seconds, especially on first startup with modules..."
    
    # First, check if Redis process is actually running
    if [[ "$target" == "localhost" || "$target" == "127.0.0.1" ]]; then
        local redis_running=$(ps aux | grep "[r]edis-server.*$port" | wc -l)
        if [[ "$redis_running" -eq 0 ]]; then
            log_error "No Redis server process found running on port $port"
            log_info "Checking for any Redis processes:"
            ps aux | grep "[r]edis-server" || log_info "No Redis processes found"
            return 1
        else
            log_info "Found $redis_running Redis server process(es) running on port $port"
        fi
    fi
    
    # Enhanced wait logic with better feedback
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if ${REDIS_PATH}/src/redis-cli -h ${target} -p ${port} ping 2>/dev/null | grep -q PONG; then
            log_info "Redis server is ready! (took $attempt seconds)"
            return 0
        fi
        
        # Provide progress feedback every 10 seconds
        if [[ $((attempt % 10)) -eq 0 && $attempt -gt 0 ]]; then
            log_info "Still waiting for Redis... ($attempt/$max_attempts seconds)"
            
            # Show Redis log output for debugging
            if [[ -f "$REDIS_PATH/server.log" ]]; then
                log_info "Recent Redis log entries:"
                tail -5 "$REDIS_PATH/server.log" 2>/dev/null || log_info "Could not read Redis log"
            fi
        fi
        
        sleep 1
        ((attempt++))
        echo -ne "."
    done
    
    log_error "Redis server did not become ready after $max_attempts seconds"
    
    # Show final diagnostic information
    if [[ "$target" == "localhost" || "$target" == "127.0.0.1" ]]; then
        log_info "Final diagnostics:"
        log_info "Redis processes:"
        ps aux | grep "[r]edis-server" || log_info "No Redis processes found"
        
        if [[ -f "$REDIS_PATH/server.log" ]]; then
            log_info "Last 10 lines of Redis log:"
            tail -10 "$REDIS_PATH/server.log" 2>/dev/null || log_info "Could not read Redis log"
        fi
    fi
    
    return 1
}

#=======================================================================================================================
# Redis Cluster Functions
#=======================================================================================================================

# Function to configure Redis cluster
configure_redis_cluster() {
    local target_server="$1" redisearch_lib="$2"
    
    local loadmodule_option=""
    [[ "$VECTOR_SEARCH" != "vectorsets" ]] && loadmodule_option="--loadmodule $redisearch_lib WORKERS $REDISEARCH_WORKERS"
    
    local config_file="$REDIS_PATH/utils/create-cluster/config.sh"
    local cluster_host_option=""
    [[ "$SERVER_REMOTE" == "true" ]] && cluster_host_option="echo \"CLUSTER_HOST=$target_server\" >> $config_file"
    
    execute_command "cat > $config_file << 'EOF'
PORT=$((PORT-1))
NODES=$CLUSTER_NODES
TIMEOUT=$CLUSTER_TIMEOUT
REPLICAS=$CLUSTER_REPLICAS
NUMA_CONFIG='$NUMA_CONFIG'
ADDITIONAL_OPTIONS='--save \"\" --protected-mode no --appendonly no $loadmodule_option'
EOF" "$target_server"
    
    [[ -n "$cluster_host_option" ]] && execute_command "$cluster_host_option" "$target_server"
}

# Function to build cluster host list for multiple servers
build_cluster_hosts() {
    local hosts=""
    local endport=$((PORT + CLUSTER_NODES - 1))
    
    for port in $(seq $PORT $endport); do
        for server in "${CLUSTER_SERVERS[@]}"; do
            hosts="$hosts $server:$port"
        done
    done
    
    echo "$hosts"
}

# Function to create Redis cluster
# Function to validate Redis cluster creation
validate_cluster_creation() {
    local target_server="$1"
    local redis_cli_path="$REDIS_PATH/src/redis-cli"
    local port=$((PORT))
    
    log_info "Validating Redis cluster creation..."
    
    # Give cluster more time to stabilize
    sleep 3
    
    # Retry cluster state check with timeout
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Checking cluster state (attempt $attempt/$max_attempts)..."
        
        # Check cluster state
        local cluster_info=$(execute_command "$redis_cli_path -p $port cluster info" "$target_server" 2>/dev/null)
        local cluster_state=$(echo "$cluster_info" | grep cluster_state | cut -d: -f2)
        local slots_assigned=$(echo "$cluster_info" | grep cluster_slots_assigned | cut -d: -f2)
        
        if [[ "$cluster_state" == "ok" ]]; then
            log_info "✓ Redis cluster created successfully and is in 'ok' state"
            
            # Check slot coverage
            if [[ "$slots_assigned" == "16384" ]]; then
                log_info "✓ All 16384 hash slots are properly assigned"
            else
                log_info "⚠ Only $slots_assigned slots assigned (expected 16384)"
            fi
            
            # Show cluster nodes
            log_info "Cluster nodes:"
            execute_command "$redis_cli_path -p $port cluster nodes" "$target_server" 2>/dev/null || log_info "Could not retrieve cluster nodes info"
            return 0
            
        elif [[ "$slots_assigned" == "16384" ]]; then
            # Slots are assigned but cluster might still be stabilizing
            log_info "Slots assigned correctly, waiting for cluster to stabilize... (state: $cluster_state)"
            sleep 2
            
        else
            log_info "Cluster state: $cluster_state, slots assigned: $slots_assigned"
            sleep 2
        fi
        
        ((attempt++))
    done
    
    # Final check - if slots are assigned correctly, consider it a success even if state isn't "ok"
    local final_cluster_info=$(execute_command "$redis_cli_path -p $port cluster info" "$target_server" 2>/dev/null)
    local final_slots_assigned=$(echo "$final_cluster_info" | grep cluster_slots_assigned | cut -d: -f2)
    
    if [[ "$final_slots_assigned" == "16384" ]]; then
        log_info "✓ Cluster operational - all slots assigned correctly"
        log_info "Final cluster info:"
        echo "$final_cluster_info"
        return 0
    else
        log_error "✗ Redis cluster creation failed - slots: $final_slots_assigned"
        log_info "Final cluster info:"
        echo "$final_cluster_info"
        return 1
    fi
}

create_redis_cluster() {
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        sleep 2
        local hosts=$(build_cluster_hosts)
        local cluster_cmd="echo \"yes\" | $REDIS_PATH/src/redis-cli --cluster create $hosts --cluster-replicas $CLUSTER_REPLICAS"
        execute_command "$cluster_cmd" "$CLUSTER_MASTER"
    else
        local target_server=$([[ "$SERVER_REMOTE" == "true" ]] && echo "$REDIS_SERVER" || echo "localhost")
        # Save current directory
        local current_dir=$(pwd)
        
        # Start the Redis cluster instances
        log_info "Starting Redis cluster instances..."
        execute_command "cd $REDIS_PATH/utils/create-cluster && ./create-cluster-numa.sh start && cd \"$current_dir\"" "$target_server"
        
        # Wait for Redis instances to fully initialize before creating cluster
        log_info "Waiting 5 seconds for Redis instances to fully initialize..."
        sleep 5
        
        # Create the cluster
        log_info "Creating Redis cluster..."
        execute_command "cd $REDIS_PATH/utils/create-cluster && echo \"yes\" | ./create-cluster-numa.sh create && cd \"$current_dir\"" "$target_server"
        
        # Validate cluster creation
        validate_cluster_creation "$target_server"
    fi
}

#=======================================================================================================================
# Main Redis Setup Function
#=======================================================================================================================

# Function to setup Redis software on all servers
setup_redis_software() {
    local servers=("$@")
    
    # Run MLC before Redis setup if enabled
    for server in "${servers[@]}"; do
        # Skip localhost if using remote servers for MLC
        [[ "$server" == "localhost" && "$SERVER_REMOTE" == "true" ]] && continue
        
        log_info "=== Checking MLC on: $server ==="
        execute_mlc_if_enabled "$server"
    done
    
    for server in "${servers[@]}"; do
        log_info "=== Setting up Redis software on: $server ==="
        install_dependencies "$server"
        setup_redis "$server"
        setup_redisearch "$server"
    done
}

# Function to start Redis instances on appropriate servers
start_redis_instances() {
    local servers=("$@")
    local redisearch_lib=$(get_redisearch_lib)
    
    for server in "${servers[@]}"; do
        # Skip localhost if using remote servers
        [[ "$server" == "localhost" && "$SERVER_REMOTE" == "true" ]] && continue
        
        log_info "=== Starting Redis on: $server ==="
        
        # Skip cleanup when SKIP_UPLOAD=1 to preserve existing Redis instances
        if [ "${SKIP_UPLOAD:-0}" != "1" ]; then
            cleanup_redis "$server"
            # Allow time for the port to be released after cleanup
            log_info "Waiting 3 seconds for port to be released after cleanup..."
            sleep 3
        else
            log_info "SKIP_UPLOAD=1: Preserving existing Redis instances"
        fi
        
        if [ "$REDIS_CLUSTER" -eq 1 ]; then
            configure_redis_cluster "$server" "$redisearch_lib"
            [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]] && execute_command "cd $REDIS_PATH/utils/create-cluster && ./create-cluster-numa.sh start" "$server"
        else
            start_redis_server "$server" "$redisearch_lib"
            # Give Redis extra time to initialize, especially with modules
            log_info "Waiting 5 seconds for Redis to begin initialization..."
            sleep 5
        fi
        
        [[ "$CLUSTER_MULTIPLE_SERVERS" -ne 1 ]] && sleep 2
    done
    
    # Create cluster if needed
    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        log_info "=== Creating Redis cluster ==="
        create_redis_cluster
        sleep 5
    fi
}

# Main function to setup Redis environment
setup_redis_environment() {
    local servers=("$@")
    
    log_info "Setting up Redis environment on servers: ${servers[*]}"
    
    # Validate required variables
    validate_required_vars "REDIS_PATH" "HOME_PATH" "LOGIN_ID" "REDIS_BRANCH" || return 1
    
    # Log configuration summary
    log_info "Redis config: PATH=$REDIS_PATH, BRANCH=$REDIS_BRANCH, VECTOR_SEARCH=$VECTOR_SEARCH"
    # Log configuration summary
    log_info "Redis config: PATH=$REDIS_PATH, BRANCH=$REDIS_BRANCH, VECTOR_SEARCH=$VECTOR_SEARCH"
    
    # Setup Redis software on all servers
    setup_redis_software "${servers[@]}"
    
    # Start Redis instances where needed
    start_redis_instances "${servers[@]}"
    
    log_info "=== Redis setup completed successfully ==="
}

#=======================================================================================================================
# Standalone Execution Support
#=======================================================================================================================

# Main function for standalone execution
main() {
    log_step "Starting Redis Setup Process"
    
    # Load and validate configuration
    if ! load_benchmark_configuration "${1:-}"; then
        exit 1
    fi
    
    # Display configuration summary
    display_config_summary
    
    if [ "${SKIP_UPLOAD:-0}" -eq 1 ]; then
        log_info "Skipping Redis setup (SKIP_UPLOAD=1 implies existing setup)"
        return 0
    fi

    # Get server list and setup Redis environment
    local servers=($(get_server_list))
    setup_redis_environment "${servers[@]}"
    
    log_success "Redis setup completed successfully!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source config loader for standalone execution
    source "$SCRIPT_DIR/config_loader.sh"
    main "$@"
fi
