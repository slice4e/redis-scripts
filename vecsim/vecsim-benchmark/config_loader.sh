#!/bin/bash

#=======================================================================================================================
# Configuration Loader Script
# Handles loading and validating configuration files
#=======================================================================================================================

# Source common utilities
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common_utils.sh"

#=======================================================================================================================
# Configuration Loading Functions
#=======================================================================================================================

# Function to map dataset identifiers to actual dataset names
get_dataset_name() {
    local dataset="$1"
    echo "${DATASET_DICT[$dataset]:-}"
}

# Function to validate configuration values
validate_configuration() {
    local errors=()
    
    # Basic validation - only check that critical values exist
    [[ -z "$REDIS_SERVER" ]] && errors+=("REDIS_SERVER is required")
    [[ -z "$REDIS_BRANCH" ]] && errors+=("REDIS_BRANCH is required")
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Configuration validation failed:"
        for error in "${errors[@]}"; do
            log_error "  - $error"
        done
        return 1
    fi
    
    return 0
}

# Function to load configuration files with validation
load_benchmark_configuration() {
    local config_file="${1:-./config.file}"
    
    # Load main configuration
    if ! load_config_file "$config_file"; then
        return 1
    fi
    
    # Load variables file (optional)
    [[ -f "./variables.file" ]] && source "./variables.file"
    
    # Set dataset name if dataset is defined
    if [[ -n "${DATASET:-}" ]]; then
        DATASET_NAME=$(get_dataset_name "$DATASET")
        if [[ -n "$DATASET_NAME" ]]; then
            export DATASET_NAME
            log_info "Dataset: $DATASET -> $DATASET_NAME"
        else
            log_warn "Unknown dataset: $DATASET"
        fi
    fi
    
    # Set defaults for optional variables
    set_default_values
    
    # Determine target servers
    determine_target_servers
    
    # Export critical variables
    export DATASET HOME_PATH REDIS_PATH LOGIN_ID SERVER_REMOTE REDIS_SERVER PORT
    export VECTORDB_BENCHMARK_PATH REPETITIONS QUERIES M EF_CONSTRUCTION PARALLEL DATA_TYPE EF_SEARCH
    export CREATE_DYNAMICALLY SKIP_UPLOAD SKIP_SETUP REDIS_CLUSTER NUMA_CONFIG NUMA_CONFIG_CLIENT
    export SSH_KEY_PATH SSH_KEY_NAME
    
    # Validate configuration
    validate_configuration || return 1
    
    log_info "Configuration validation completed successfully"
    return 0
}

# Function to set default values for optional variables
set_default_values() {
    VENV_DIR_NAME=${VENV_DIR_NAME:-"venv-redis-benchmark"}
    SKIP_SETUP=${SKIP_SETUP:-0}
    SKIP_UPLOAD=${SKIP_UPLOAD:-0}
    NUMA_CONFIG=${NUMA_CONFIG:-""}
    NUMA_CONFIG_CLIENT=${NUMA_CONFIG_CLIENT:-""}
    REDIS_CLUSTER=${REDIS_CLUSTER:-0}
    CLUSTER_MULTIPLE_SERVERS=${CLUSTER_MULTIPLE_SERVERS:-0}
    REDIS_ENTERPRISE=${REDIS_ENTERPRISE:-0}
    
    # SSH configuration defaults (removed from template but needed internally)
    SSH_KEY_PATH=${SSH_KEY_PATH:-"~/.ssh"}
    SSH_KEY_NAME=${SSH_KEY_NAME:-"id_rsa"}
}

# Function to determine target servers based on configuration
determine_target_servers() {
    if [[ ${SERVER_REMOTE} == true ]]; then
        if [ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]; then
            REDIS_SERVER=$CLUSTER_MASTER
            log_info "Multiple server cluster mode - target: $REDIS_SERVER"
        else
            REDIS_SERVER=$SERVER_IP
            log_info "Single remote server mode - target: $REDIS_SERVER"
        fi
    else
        REDIS_SERVER="localhost"
        log_info "Local server mode - target: $REDIS_SERVER"
    fi
}

# Function to get server list for setup
get_server_list() {
    local servers=("localhost")
    
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        servers+=("${CLUSTER_SERVERS[@]}")
    elif [[ "$SERVER_REMOTE" == "true" ]]; then
        servers+=("$REDIS_SERVER")
    fi
    
    echo "${servers[@]}"
}

# Function to display enhanced configuration summary
display_config_summary() {
    log_step "Configuration Summary"
    
    # Core Configuration
    echo "  Target Server:           $REDIS_SERVER"
    echo "  Remote Deployment:       $SERVER_REMOTE"
    echo "  Redis Branch:            $REDIS_BRANCH"
    echo "  Redis Path:              $REDIS_PATH"
    echo "  Port:                    ${PORT:-6379}"
    
    # Vector Configuration
    echo "  Vector Search Engine:    $VECTOR_SEARCH"
    echo "  Vector Size:             $VECTOR_SIZE"
    echo "  Dataset:                 $(get_dataset_name "$DATASET_NAME")"
    echo "  Number of Vectors:       $NUM_VECTORS"
    
    # Benchmark Configuration  
    echo "  Connections:             $CONNECTIONS"
    echo "  Clients:                 $CLIENTS"
    echo "  Pipeline:                $PIPELINE"
    echo "  Threads:                 $THREADS"
    echo "  Queries:                 ${QUERIES:-10000}"
    echo "  Repetitions:             ${REPETITIONS:-1}"
    
    # Performance Monitoring
    echo "  Enable EMON:             $EMON_ENABLE"
    echo "  Enable Perf:             $PERF_ENABLE"
    echo "  Server NUMA Config:      ${NUMA_CONFIG:-'(none)'}"
    echo "  Client NUMA Config:      ${NUMA_CONFIG_CLIENT:-'(none)'}"
    
    # Cluster Configuration
    if [[ "${REDIS_CLUSTER:-0}" -eq 1 ]]; then
        echo "  Cluster Mode:            Enabled"
        echo "  Cluster Nodes:           ${CLUSTER_NODES:-6}"
        echo "  Cluster Replicas:        ${CLUSTER_REPLICAS:-0}"
    else
        echo "  Cluster Mode:            Disabled"
    fi
    
    echo "  Working Directory:       $WORKING_DIR"
    echo ""
}


