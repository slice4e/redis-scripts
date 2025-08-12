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

#=======================================================================================================================
# Python Environment Setup Functions
#=======================================================================================================================

# Function to setup Python virtual environment
setup_python_venv() {
    local target_server="$1"
    local venv_path="$2"
    
    log_info "Setting up Python virtual environment on $target_server at $venv_path..."

    # Check if virtual environment exists and is valid
    if [ ! -d "$venv_path" ] || [ ! -x "$venv_path/bin/python" ]; then
        log_info "Virtual environment missing or invalid, creating new one at $venv_path..."
        rm -rf "$venv_path"
        if ! python3 -m venv --upgrade-deps "$venv_path"; then
            log_error "Failed to create virtual environment"
            return 1
        fi
    else
        log_info "Virtual environment already exists at $venv_path"
    fi

    # Verify pip is available and upgrade it
    if ! "$venv_path/bin/python" -m pip --version; then
        log_info "Virtual environment pip is not working, recreating..."
        rm -rf "$venv_path"
        python3 -m venv --upgrade-deps "$venv_path"
    fi

    # Upgrade pip in the virtual environment
    "$venv_path/bin/python" -m pip install --upgrade pip
}

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

# Function to setup and activate Python virtual environment for benchmarking
setup_python_environment() {
    
    log_info "Setting up Python virtual environment for benchmark client..."
    
    # Create and setup virtual environment
    setup_python_venv "localhost" "$venv_path"
    
    # Activate and install packages
    source "$venv_path/bin/activate"
    [[ "$VIRTUAL_ENV" != "$venv_path" ]] && { log_error "Failed to activate virtual environment"; return 1; }

    "$venv_path/bin/python" -m pip install --upgrade pip poetry || { log_error "Failed to install pip/poetry"; return 1; }

    "$venv_path/bin/python" -m pip install -r "$SCRIPT_DIR/requirements-vdb.txt" || { log_error "Failed to install requirements"; return 1; }
    log_success "Python environment setup completed successfully"
}

# Function to activate Python virtual environment (for manual use)
activate_python_environment() {
    local venv_path="$HOME_PATH/${VENV_DIR_NAME:-venv-redis-benchmark}"
    
    if [ -d "$venv_path" ]; then
        log_info "Activating Python virtual environment at: $venv_path"
        source "$venv_path/bin/activate"
        log_info "Virtual environment activated. Python path: $(which python)"
        log_info "To deactivate, run: deactivate"
        return 0
    else
        log_error "Virtual environment not found at: $venv_path"
        log_error "Please run the Redis setup script first to create the virtual environment."
        return 1
    fi
}

# Function to setup complete benchmark environment
setup_benchmark_environment() {
    log_step "Setting Up Benchmark Environment"
    
    # Setup vector-db-benchmark repository
    setup_vectordb_benchmark
    
    # Setup Python environment
    setup_python_environment
    
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
        local venv_path="$HOME_PATH/${VENV_DIR_NAME:-venv-redis-benchmark}"
        log_info "Running benchmark upload stage..."
        log_info "REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port $numactl_prefix $venv_path/bin/python $vectordb_benchmark_path/run.py --engines \"$engine_name\" --datasets \"$dataset_name\" --host \"$target\" --no-skip-if-exists --skip-search"
        REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port $numactl_prefix $venv_path/bin/python $vectordb_benchmark_path/run.py \
            --engines "$engine_name" \
            --datasets "$dataset_name" \
            --host "$target" \
            --no-skip-if-exists \
            --skip-search
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
    local venv_path="$HOME_PATH/${VENV_DIR_NAME:-venv-redis-benchmark}"
    
    log_info "Running benchmark search stage..."
    log_info "REPETITIONS=$repetitions REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port $numactl_prefix $venv_path/bin/python $vectordb_benchmark_path/run.py --engines \"$engine_name\" --datasets \"$dataset_name\" --host \"$target\" --no-skip-if-exists --queries \"$queries\" --skip-upload"
    REPETITIONS=$repetitions REDIS_CLUSTER=$redis_cluster REDIS_PORT=$port $numactl_prefix python3 $vectordb_benchmark_path/run.py \
        --engines "$engine_name" \
        --datasets "$dataset_name" \
        --host "$target" \
        --no-skip-if-exists \
        --queries "$queries" \
        --skip-upload
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
  -a, --activate-venv     Activate Python virtual environment only
  -s, --setup             Setup complete benchmark environment (default)

Examples:
  $0                      # Setup complete benchmark environment
  $0 --activate-venv      # Activate virtual environment only
  source <($0 --activate-venv)  # Source activation in current shell

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
            -a|--activate-venv)
                action="activate"
                shift
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
        activate)
            log_step "Activating Python Virtual Environment"
            if activate_python_environment; then
                # Output activation command for sourcing
                local venv_path="$HOME_PATH/${VENV_DIR_NAME:-venv-redis-benchmark}"
                echo "source \"$venv_path/bin/activate\""
            else
                exit 1
            fi
            ;;
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
