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

# Function to setup benchmark execution parameters
setup_benchmark_execution() {
    # Set up NUMA prefix for client
    NUMACTL_PREFIX=""
    [ -n "$NUMA_CONFIG_CLIENT" ] && NUMACTL_PREFIX="$NUMA_CONFIG_CLIENT"
    
    # Construct engine name
    local engine_append=""
    [ "$CREATE_DYNAMICALLY" -eq 1 ] && engine_append="-parallel-$PARALLEL-${DATA_TYPE}"
    ENGINE_NAME="redis-m-$M-ef-$EF_CONSTRUCTION$engine_append"
    
    # Setup SSH command for remote monitoring
    SSH_COMMAND=""
    [[ "$SERVER_REMOTE" == "true" ]] && SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${REDIS_SERVER}"
}

# Function to run complete benchmark with monitoring
run_complete_benchmark() {
    # Start monitoring
    start_emon_monitoring "$DATASET" "$M" "$EF_CONSTRUCTION" "$SERVER_REMOTE" "$EMON_FOLDER" "$SSH_COMMAND" "$HOME_PATH"
    
    # Run benchmark stages
    run_benchmark_upload "$VECTORDB_BENCHMARK_PATH" "$ENGINE_NAME" "$DATASET_NAME" "$REDIS_SERVER" \
        "$REDIS_CLUSTER" "$PORT" "$NUMACTL_PREFIX" "$SKIP_UPLOAD"
    
    run_benchmark_search "$VECTORDB_BENCHMARK_PATH" "$ENGINE_NAME" "$DATASET_NAME" "$REDIS_SERVER" \
        "$QUERIES" "$REPETITIONS" "$REDIS_CLUSTER" "$PORT" "$NUMACTL_PREFIX"
    
    # Stop monitoring
    stop_emon_monitoring "$SERVER_REMOTE" "$EMON_FOLDER" "$SSH_COMMAND" "$SSH_KEY_PATH" "$SSH_KEY_NAME" \
        "$LOGIN_ID" "$REDIS_SERVER" "$HOME_PATH" "$EMON_CONFIG_FILE" "$EMON_HOME"
}

#=======================================================================================================================
# Main Benchmark Execution
#=======================================================================================================================

main() {
    log_step "Starting Vector Database Benchmark"
    
    # Load configuration and setup environment
    load_benchmark_configuration "${1:-}" || exit 1
    display_config_summary
    
    # Handle Redis Enterprise vs Open Source setup
    if [ "$REDIS_ENTERPRISE" -eq 1 ]; then
        log_step "Setting Up Redis Enterprise"
        SOURCE_SCRIPT=$(dirname $(dirname "$SCRIPT_DIR"))/shared-scripts/set_ssh.sh
        for server in "${RE_SERVERS[@]}"; do
            SERVER_IP=$server
            source $SOURCE_SCRIPT
        done
        source "./re_setup.sh"
    else
        log_step "Setting Up Redis Open Source"
        # Setup Redis using the new modular approach
        local servers=($(get_server_list))
        setup_redis_environment "${servers[@]}"
    fi
    
    # Setup benchmark components with progress tracking
    log_step "Preparing Benchmark Environment"
    setup_benchmark_environment
    
    # Wait for Redis to be ready
    log_step "Waiting for Redis to be Ready"
    wait_for_redis "$REDIS_SERVER" "$PORT"
    
    # Prepare and execute benchmark
    log_step "Executing Benchmark"
    prepare_benchmark_config
    setup_benchmark_execution
    run_complete_benchmark
    

    log_success "Vector database benchmark completed successfully!"
}

# Run main function
main "$@"
