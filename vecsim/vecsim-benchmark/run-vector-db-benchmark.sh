#!/bin/bash

#=======================================================================================================================
# Simplified Vector Database Benchmark Script
# Main entry point for running vector database benchmarks
#=======================================================================================================================

# Script identification for logging
SCRIPT_NAME="benchmark"

# Get script directory and source utilities
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/config_loader.sh"
source "$SCRIPT_DIR/redis_utils.sh"
source "$SCRIPT_DIR/benchmark_utils.sh"

# Constants
VENV_DIR_NAME="venv-redis-benchmark"

#=======================================================================================================================
# Benchmark-specific Functions
#=======================================================================================================================

# Function to setup vector-db-benchmark repository
setup_vectordb_benchmark() {
    log_info "Setting up vector-db-benchmark repository..."
    
    if [[ ! -d "$VECTORDB_BENCHMARK_PATH" ]]; then
        log_info "Cloning vector-db-benchmark..."
        git clone https://github.com/redis-performance/vector-db-benchmark "$VECTORDB_BENCHMARK_PATH" || { log_error "Failed to clone repository"; return 1; }
    else
        log_info "Updating vector-db-benchmark..."
        cd "$VECTORDB_BENCHMARK_PATH" && git fetch origin && cd - || { log_error "Failed to update repository"; return 1; }
    fi
    
    # Switch to specified branch
    cd "$VECTORDB_BENCHMARK_PATH" || return 1
    log_info "Switching to branch: $VECTORDB_BENCHMARK_BRANCH"
    git checkout "$VECTORDB_BENCHMARK_BRANCH" && git pull origin "$VECTORDB_BENCHMARK_BRANCH" 2>/dev/null || true
    cd - >/dev/null
}


# Function to setup and activate Python virtual environment (for remote benchmark client only)
setup_python_environment() {
    # Local mode uses environment from redis_setup.sh
    [[ "$SERVER_REMOTE" != "true" ]] && return 0
    
    local venv_path="$HOME_PATH/$VENV_DIR_NAME"
    log_info "Setting up Python virtual environment for remote benchmark client..."
    
    # Create and setup virtual environment
    setup_python_venv "localhost" "$venv_path"
    
    # Activate and install packages
    source "$venv_path/bin/activate"
    [[ "$VIRTUAL_ENV" != "$venv_path" ]] && { log_error "Failed to activate virtual environment"; return 1; }
    
    python -m pip install --upgrade pip poetry || { log_error "Failed to install pip/poetry"; return 1; }
    python -m pip install -r "$SCRIPT_DIR/requirements-vdb.txt" || { log_error "Failed to install requirements"; return 1; }
    
    log_info "Python environment setup completed successfully"
}

# Function to prepare benchmark configuration
prepare_benchmark_config() {
    # Download dataset
    download_dataset "$DATASET" "$DATASET_NAME" "$VECTORDB_BENCHMARK_PATH" || exit 1
    
    # Generate dynamic configuration if needed
    if [ "$CREATE_DYNAMICALLY" -eq 1 ]; then
        log_info "Generating dynamic benchmark configuration..."
        generate_benchmark_config "$VECTOR_SEARCH" "$M" "$EF_CONSTRUCTION" "$PARALLEL" "$DATA_TYPE" "$EF_SEARCH" \
            "$VECTORDB_BENCHMARK_PATH/experiments/configurations/redis-intel.json"
    fi
}

# Function to setup benchmark execution environment
setup_benchmark_environment() {
    # Set up NUMA prefix for client
    NUMACTL_PREFIX=""
    [ "$USE_NUMACTL_CLIENT" -eq 1 ] && NUMACTL_PREFIX="numactl -N $NUMA_NODES_CLIENT -m $NUMA_NODES_CLIENT"
    
    # Construct engine name
    local engine_append=""
    [ "$CREATE_DYNAMICALLY" -eq 1 ] && engine_append="-parallel-$PARALLEL-${DATA_TYPE}"
    ENGINE_NAME="redis-m-$M-ef-$EF_CONSTRUCTION$engine_append"
    
    # Setup SSH command for remote monitoring
    SSH_COMMAND=""
    [[ "$SERVER_REMOTE" == "true" ]] && SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${TARGET}"
}

# Function to run complete benchmark with monitoring
run_complete_benchmark() {
    # Start monitoring
    start_emon_monitoring "$DATASET" "$M" "$EF_CONSTRUCTION" "$SERVER_REMOTE" "$EMON_FOLDER" "$SSH_COMMAND" "$HOME_PATH"
    
    # Run benchmark stages
    run_benchmark_upload "$VECTORDB_BENCHMARK_PATH" "$ENGINE_NAME" "$DATASET_NAME" "$TARGET" \
        "$REDIS_CLUSTER" "$PORT" "$NUMACTL_PREFIX" "$SKIP_UPLOAD" "$SKIP_SETUP"
    
    run_benchmark_search "$VECTORDB_BENCHMARK_PATH" "$ENGINE_NAME" "$DATASET_NAME" "$TARGET" \
        "$QUERIES" "$REPETITIONS" "$REDIS_CLUSTER" "$PORT" "$NUMACTL_PREFIX"
    
    # Stop monitoring
    stop_emon_monitoring "$SERVER_REMOTE" "$EMON_FOLDER" "$SSH_COMMAND" "$SSH_KEY_PATH" "$SSH_KEY_NAME" \
        "$LOGIN_ID" "$TARGET" "$HOME_PATH" "$EMON_CONFIG_FILE" "$EMON_HOME"
}

#=======================================================================================================================
# Main Benchmark Execution
#=======================================================================================================================

main() {
    log_info "Starting vector database benchmark..."
    
    # Load configuration and setup environment
    load_benchmark_configuration "${1:-}" || exit 1
    display_config_summary
    
    # Handle Redis Enterprise vs Open Source setup
    if [ "$REDIS_ENTERPRISE" -eq 1 ]; then
        SOURCE_SCRIPT=$(dirname $(dirname "$SCRIPT_DIR"))/shared-scripts/set_ssh.sh
        for server in "${RE_SERVERS[@]}"; do
            SERVER_IP=$server
            source $SOURCE_SCRIPT
        done
        source "./re_setup.sh"
    else
        # Setup Redis using the new modular approach
        local servers=($(get_server_list))
        setup_redis_environment "${servers[@]}"
    fi
    
    # Setup benchmark components
    setup_vectordb_benchmark
    setup_python_environment
    wait_for_redis "$TARGET" "$PORT"
    
    # Prepare and execute benchmark
    prepare_benchmark_config
    setup_benchmark_environment
    run_complete_benchmark
    
    log_info "Vector database benchmark completed successfully!"
}

# Run main function
main "$@"
