#!/bin/bash

#=======================================================================================================================
# Benchmark Util
#=======================================================================================================================
# EMON Monitoring Functions
#=======================================================================================================================tions specific to vector database benchmarking
#=======================================================================================================================

# Source common utilities
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common_utils.sh"

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

# Function to build the vector-db-benchmark (Rust) CLI from the checked-out branch
build_vectordb_benchmark() {
    log_info "Building vector-db-benchmark in $VECTORDB_BENCHMARK_PATH..."

    [ -f ~/.cargo/env ] && . ~/.cargo/env
    if ! command -v cargo >/dev/null; then
        log_info "cargo not found, installing the Rust toolchain with rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal || { log_error "Failed to install Rust"; return 1; }
        . ~/.cargo/env
    fi

    (cd "$VECTORDB_BENCHMARK_PATH" && cargo build --release --bin vector-db-benchmark) || { log_error "Failed to build vector-db-benchmark"; return 1; }
    "$VDB_BIN" --version || return 1
    log_success "vector-db-benchmark built"
}

# Function to setup complete benchmark environment
setup_benchmark_environment() {
    log_step "Setting Up Benchmark Environment"
    
    setup_vectordb_benchmark || return 1
    build_vectordb_benchmark || return 1
    
    log_success "Benchmark environment setup completed"
}

#=======================================================================================================================
# Dataset Management Functions
#=======================================================================================================================

# Note: Dataset downloads are now handled automatically by vector-db-benchmark
# No manual dataset management functions needed




#=======================================================================================================================
# EMON Monitoring Functions
#=======================================================================================================================

# Function to start EMON monitoring
start_emon_monitoring() {
    local dataset="$1" m="$2" ef_construction="$3" server_remote="$4" emon_folder="$5" ssh_command="$6" home_path="$7"
    
    [[ ${RUN_EMON:-false} != true ]] && return 0
    
    log_info "Starting emon monitoring..."
    
    local dataset_id=$(echo "$dataset" | sed 's/.*-\([^-]*\)$/\1/')
    local emon_file="redis-${dataset_id}-m-${m}-ef-${ef_construction}-emon.dat"
    
    if [[ ${server_remote} == false ]]; then
        ${emon_folder}/emon -stop || true
        (${emon_folder}/emon -collect-edp -f "$emon_file") &
    else
        $ssh_command "${emon_folder}/emon -stop || true"
        nohup $ssh_command "${emon_folder}/emon -collect-edp -f ${home_path}/${emon_file} &" &
    fi
    
    log_info "EMON monitoring started with file: $emon_file"
}

# Function to stop EMON monitoring
stop_emon_monitoring() {
    local server_remote="$1" emon_folder="$2" ssh_command="$3" ssh_key_path="$4" 
    local ssh_key_name="$5" login_id="$6" target="$7" home_path="$8" 
    local emon_config_file="$9" emon_home="${10}"
    
    [[ ${RUN_EMON:-false} != true ]] && return 0
    
    log_info "Stopping emon monitoring..."
    
    if [[ ${server_remote} == false ]]; then
        ${emon_folder}/emon -stop || true
        source ../../shared-scripts/emon_process.sh
    else
        $ssh_command "${emon_folder}/emon -stop || true"
        scp -i ${ssh_key_path}/${ssh_key_name} ../../shared-scripts/emon_process.sh $login_id@${target}:${home_path}/emon_process.sh
        scp -i ${ssh_key_path}/${ssh_key_name} ${emon_config_file} $login_id@${target}:${home_path}/pyedp_config.txt
        $ssh_command "cd ${home_path} && EMON_CONFIG_FILE=$home_path/pyedp_config.txt RUN_EMON=true EMON_HOME=$emon_home bash ${home_path}/emon_process.sh"
    fi
    
    log_info "EMON monitoring stopped and processed"
}

#=======================================================================================================================
# Benchmark Execution Functions
#=======================================================================================================================

# Function to run benchmark upload stage
run_benchmark_upload() {
    local vectordb_benchmark_path="$1"
    local engine_name="$2"
    local dataset_name="$3"
    local target="$4"
    local redis_cluster="$5"
    local port="$6"
    local numactl_prefix="$7"
    local skip_upload="$8"
    
    if [ "$skip_upload" -eq 0 ]; then
        log_info "Running benchmark upload stage..."
        # --keep-data: the search stage reuses this index with --skip-upload
        local base_cmd="$numactl_prefix $VDB_BIN --engines \"$engine_name\" --datasets \"$dataset_name\" --host \"$target\" --skip-if-exists false --skip-search --keep-data"
        
        # Add additional parameters if specified
        if [ -n "$VECTORDB_BENCHMARK_PARAMS" ]; then
            base_cmd="$base_cmd $VECTORDB_BENCHMARK_PARAMS"
        fi
        
        log_info "REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port $base_cmd"
        # the CLI reads datasets/ and experiments/ from its working directory
        (cd "$vectordb_benchmark_path" && REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port eval "$base_cmd")
    else
        log_info "Skipping upload stage (SKIP_UPLOAD=1 - using existing data and setup)"
    fi
}

# Function to run benchmark search stage
run_benchmark_search() {
    local vectordb_benchmark_path="$1"
    local engine_name="$2"
    local dataset_name="$3"
    local target="$4"
    local queries="$5"
    local repetitions="$6"
    local redis_cluster="$7"
    local port="$8"
    local numactl_prefix="$9"
    
    log_info "Running benchmark search stage..."
    local base_cmd="$numactl_prefix $VDB_BIN --engines \"$engine_name\" --datasets \"$dataset_name\" --host \"$target\" --skip-if-exists false --queries \"$queries\" --skip-upload"
    
    # Add additional parameters if specified
    if [ -n "$VECTORDB_BENCHMARK_PARAMS" ]; then
        base_cmd="$base_cmd $VECTORDB_BENCHMARK_PARAMS"
    fi
    
    log_info "REPETITIONS=$repetitions REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port $base_cmd"
    (cd "$vectordb_benchmark_path" && REPETITIONS=$repetitions REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port eval "$base_cmd")
}

#=======================================================================================================================
# Standalone Execution Support
#=======================================================================================================================

# Function to show usage information
show_usage() {
    cat << EOF
Redis Vector Database Benchmark Utilities

Usage: $0 [options]

Options:
  -h, --help              Show this help message
  -s, --setup             Clone/update and build vector-db-benchmark (default)

Examples:
  $0                      # Setup complete benchmark environment

EOF
}

# Main function for standalone execution
main() {
    local action="setup"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -s|--setup)
                action="setup"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Load configuration
    source "$SCRIPT_DIR/config_loader.sh"
    if ! load_benchmark_configuration; then
        exit 1
    fi
    
    case $action in
        setup)
            log_step "Setting Up Benchmark Utilities"
            
            # Display configuration summary
            display_config_summary
            
            # Setup complete benchmark environment
            setup_benchmark_environment
            
            log_success "Benchmark utilities setup completed successfully!"
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Set script name for logging
    SCRIPT_NAME="${SCRIPT_NAME:-benchmark_utils}"
    
    main "$@"
fi
