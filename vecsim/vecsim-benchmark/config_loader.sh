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
    case "$dataset" in
        "laion-512-1M")    echo "laion-img-emb-512-1M-cosine" ;;
        "laion-512-10M")   echo "laion-img-emb-512-10M-cosine" ;;
        "laion-512-20M")   echo "laion-img-emb-512-20M-cosine" ;;
        "laion-512-40M")   echo "laion-img-emb-512-40M-cosine" ;;
        "laion-512-100M")  echo "laion-img-emb-512-100M-cosine" ;;
        "laion-512-200M")  echo "laion-img-emb-512-200M-cosine" ;;
        "laion-512-400M")  echo "laion-img-emb-512-400M-cosine" ;;
        "laion-768-1M")    echo "laion-img-emb-768-1M-cosine" ;;
        "dbpedia-1536-1M") echo "dbpedia-openai-1M-1536-angular-100neighbors" ;;
        "cohere-768-1M")   echo "cohere-768-1M" ;;
        *)                 echo "" ;;
    esac
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
    
    # Export critical variables
    export DATASET HOME_PATH REDIS_PATH LOGIN_ID SERVER_REMOTE TARGET PORT
    export VECTORDB_BENCHMARK_PATH REPETITIONS QUERIES M EF_CONSTRUCTION PARALLEL DATA_TYPE EF_SEARCH
    export CREATE_DYNAMICALLY SKIP_UPLOAD SKIP_SETUP REDIS_CLUSTER USE_NUMACTL_CLIENT NUMA_NODES_CLIENT
    
    # Validate required variables
    local required_vars=("HOME_PATH" "REDIS_PATH" "LOGIN_ID" "SERVER_REMOTE")
    if ! validate_required_vars "${required_vars[@]}"; then
        return 1
    fi
    
    # Set defaults for optional variables
    set_default_values
    
    # Determine target servers
    determine_target_servers
    
    log_info "Configuration validation completed successfully"
    return 0
}

# Function to set default values for optional variables
set_default_values() {
    VENV_DIR_NAME=${VENV_DIR_NAME:-"venv-redis-benchmark"}
    SKIP_SETUP=${SKIP_SETUP:-0}
    SKIP_UPLOAD=${SKIP_UPLOAD:-0}
    USE_NUMACTL=${USE_NUMACTL:-0}
    REDIS_CLUSTER=${REDIS_CLUSTER:-0}
    CLUSTER_MULTIPLE_SERVERS=${CLUSTER_MULTIPLE_SERVERS:-0}
    REDIS_ENTERPRISE=${REDIS_ENTERPRISE:-0}
}

# Function to determine target servers based on configuration
determine_target_servers() {
    if [[ ${SERVER_REMOTE} == true ]]; then
        if [ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]; then
            TARGET=$CLUSTER_MASTER
            log_info "Multiple server cluster mode - target: $TARGET"
        else
            TARGET=$SERVER_IP
            log_info "Single remote server mode - target: $TARGET"
        fi
    else
        TARGET="localhost"
        log_info "Local server mode - target: $TARGET"
    fi
}

# Function to get server list for setup
get_server_list() {
    local servers=("localhost")
    
    if [[ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]]; then
        servers+=("${CLUSTER_SERVERS[@]}")
    elif [[ "$SERVER_REMOTE" == "true" ]]; then
        servers+=("$TARGET")
    fi
    
    echo "${servers[@]}"
}

# Function to display configuration summary
display_config_summary() {
    log_info "=== Configuration Summary ==="
    
    # Redis Configuration
    log_info "Redis: ${REDIS_PATH} (${REDIS_BRANCH:-default}) on ${TARGET}:${PORT:-6379}"
    log_info "Vector Search: ${VECTOR_SEARCH:-redisearch}, NUMA: ${USE_NUMACTL}"
    
    # Cluster Configuration
    if [ "${REDIS_CLUSTER:-0}" -eq 1 ]; then
        log_info "Cluster: ${CLUSTER_NODES:-6} nodes, ${CLUSTER_REPLICAS:-0} replicas"
    fi
    
    # Benchmark Configuration
    if [[ -n "${DATASET:-}" ]]; then
        log_info "Dataset: ${DATASET} (${DATASET_NAME:-unknown})"
        log_info "Queries: ${QUERIES:-10000}, Repetitions: ${REPETITIONS:-1}"
    fi
    
    log_info "=== End Configuration Summary ==="
}
