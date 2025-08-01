#!/bin/bash

##############################################################################
# Redis Vector Database Custom Configuration Generator
##############################################################################
# 
# This script generates custom benchmark configurations for Redis vector
# database benchmarks with specified HNSW parameters.
#
# Usage:
#   ./create_custom_config.sh [options]
#
# Options:
#   -h, --help                    Show this help message
#   -o, --output FILE            Output configuration file (default: redis-custom.json)
#   -m, --m VALUE                HNSW M parameter (default: 32)
#   -e, --ef-construction VALUE  EF_CONSTRUCTION parameter (default: 256)
#   -s, --ef-search VALUES       EF_SEARCH values, comma-separated (default: 128)
#   -p, --parallel VALUE         Number of parallel clients (default: 8)
#   -t, --data-type TYPE         Data type: FLOAT16|FLOAT32 (default: FLOAT16)
#   -v, --vector-search TYPE     Vector search type: redisearch|vectorsets (default: redisearch)
#
# Examples:
#   ./create_custom_config.sh -m 64 -e 512 -s "90,100,110" -p 16
#   ./create_custom_config.sh --output my-config.json --ef-search "64,128,256"
#
##############################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration values
DEFAULT_M=32
DEFAULT_EF_CONSTRUCTION=256
DEFAULT_EF_SEARCH="128"
DEFAULT_PARALLEL=8
DEFAULT_DATA_TYPE="FLOAT16"
DEFAULT_VECTOR_SEARCH="redisearch"
DEFAULT_OUTPUT="redis-custom.json"

# Configuration variables
M="$DEFAULT_M"
EF_CONSTRUCTION="$DEFAULT_EF_CONSTRUCTION"
EF_SEARCH="$DEFAULT_EF_SEARCH"
PARALLEL="$DEFAULT_PARALLEL"
DATA_TYPE="$DEFAULT_DATA_TYPE"
VECTOR_SEARCH="$DEFAULT_VECTOR_SEARCH"
OUTPUT_FILE="$DEFAULT_OUTPUT"

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Function to show usage information
show_usage() {
    cat << EOF
Redis Vector Database Custom Configuration Generator

Usage: $0 [options]

Options:
  -h, --help                    Show this help message
  -o, --output FILE            Output configuration file (default: $DEFAULT_OUTPUT)
  -m, --m VALUE                HNSW M parameter (default: $DEFAULT_M)
  -e, --ef-construction VALUE  EF_CONSTRUCTION parameter (default: $DEFAULT_EF_CONSTRUCTION)
  -s, --ef-search VALUES       EF_SEARCH values, comma-separated (default: $DEFAULT_EF_SEARCH)
  -p, --parallel VALUE         Number of parallel clients (default: $DEFAULT_PARALLEL)
  -t, --data-type TYPE         Data type: FLOAT16|FLOAT32 (default: $DEFAULT_DATA_TYPE)
  -v, --vector-search TYPE     Vector search type: redisearch|vectorsets (default: $DEFAULT_VECTOR_SEARCH)

Examples:
  $0 -m 64 -e 512 -s "90,100,110" -p 16
  $0 --output my-config.json --ef-search "64,128,256"
  $0 --vector-search vectorsets --data-type FLOAT32

Generated configuration will be compatible with vector-db-benchmark framework.
EOF
}

# Function to validate parameters
validate_parameters() {
    # Validate M parameter
    if ! [[ "$M" =~ ^[0-9]+$ ]] || [ "$M" -lt 1 ] || [ "$M" -gt 512 ]; then
        log_error "M parameter must be a positive integer between 1 and 512"
        return 1
    fi
    
    # Validate EF_CONSTRUCTION parameter
    if ! [[ "$EF_CONSTRUCTION" =~ ^[0-9]+$ ]] || [ "$EF_CONSTRUCTION" -lt 1 ] || [ "$EF_CONSTRUCTION" -gt 2048 ]; then
        log_error "EF_CONSTRUCTION parameter must be a positive integer between 1 and 2048"
        return 1
    fi
    
    # Validate PARALLEL parameter
    if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [ "$PARALLEL" -lt 1 ] || [ "$PARALLEL" -gt 1024 ]; then
        log_error "PARALLEL parameter must be a positive integer between 1 and 1024"
        return 1
    fi
    
    # Validate DATA_TYPE parameter
    if [[ "$DATA_TYPE" != "FLOAT16" && "$DATA_TYPE" != "FLOAT32" ]]; then
        log_error "DATA_TYPE must be either FLOAT16 or FLOAT32"
        return 1
    fi
    
    # Validate VECTOR_SEARCH parameter
    if [[ "$VECTOR_SEARCH" != "redisearch" && "$VECTOR_SEARCH" != "vectorsets" ]]; then
        log_error "VECTOR_SEARCH must be either 'redisearch' or 'vectorsets'"
        return 1
    fi
    
    # Validate EF_SEARCH values
    IFS=',' read -ra EF_LIST <<< "$EF_SEARCH"
    for ef_val in "${EF_LIST[@]}"; do
        ef_val=$(echo "$ef_val" | xargs) # trim whitespace
        if ! [[ "$ef_val" =~ ^[0-9]+$ ]] || [ "$ef_val" -lt 1 ] || [ "$ef_val" -gt 2048 ]; then
            log_error "EF_SEARCH values must be positive integers between 1 and 2048: '$ef_val'"
            return 1
        fi
    done
    
    return 0
}

# Function to generate search parameters JSON
generate_search_params() {
    local ef_search="$1"
    local parallel="$2"
    local data_type="$3"
    
    local search_params_json="["
    
    # Handle multiple EF values separated by commas
    IFS=',' read -ra EF_LIST <<< "$ef_search"
    for idx in "${!EF_LIST[@]}"; do
        ef_val=$(echo "${EF_LIST[$idx]}" | xargs) # trim whitespace
        search_params_json+="{\"parallel\":${parallel},\"search_params\":{\"ef\":${ef_val},\"data_type\":\"${data_type}\"}}"
        [[ $idx -lt $((${#EF_LIST[@]}-1)) ]] && search_params_json+=","
    done
    
    search_params_json+="]"
    echo "$search_params_json"
}

# Function to generate benchmark configuration
generate_benchmark_config() {
    local vector_search="$1" 
    local m="$2" 
    local ef_construction="$3" 
    local parallel="$4" 
    local data_type="$5" 
    local ef_search="$6" 
    local output_file="$7"
    
    local search_params_json
    search_params_json=$(generate_search_params "$ef_search" "$parallel" "$data_type")
    
    # Configure based on vector search type
    local collection_params upload_params engine_name
    if [[ "$vector_search" == "vectorsets" ]]; then
        collection_params="{}"
        upload_params="{\"parallel\":128,\"data_type\":\"${data_type}\",\"hnsw_config\":{\"M\":${m},\"EF_CONSTRUCTION\":${ef_construction}}}"
        engine_name="vectorsets"
    else
        collection_params="{\"data_type\":\"${data_type}\",\"hnsw_config\":{\"M\":${m},\"EF_CONSTRUCTION\":${ef_construction}}}"
        upload_params="{\"parallel\":128,\"data_type\":\"${data_type}\"}"
        engine_name="redis"
    fi
    
    local config_json="[{\"name\":\"redis-m-${m}-ef-${ef_construction}-parallel-${parallel}-${data_type}\",\"engine\":\"${engine_name}\",\"connection_params\":{},\"collection_params\":$collection_params,\"search_params\":$search_params_json,\"upload_params\":$upload_params}]"
    
    # Create output directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"
    
    # Write configuration to file
    echo "$config_json" | python3 -m json.tool > "$output_file" 2>/dev/null || echo "$config_json" > "$output_file"
    
    log_success "Generated benchmark configuration: $output_file"
}

# Function to display configuration summary
show_configuration_summary() {
    log_info "Configuration Summary:"
    log_info "  Vector Search Type: $VECTOR_SEARCH"
    log_info "  HNSW M Parameter: $M"
    log_info "  EF_CONSTRUCTION: $EF_CONSTRUCTION"
    log_info "  EF_SEARCH Values: $EF_SEARCH"
    log_info "  Parallel Clients: $PARALLEL"
    log_info "  Data Type: $DATA_TYPE"
    log_info "  Output File: $OUTPUT_FILE"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -m|--m)
            M="$2"
            shift 2
            ;;
        -e|--ef-construction)
            EF_CONSTRUCTION="$2"
            shift 2
            ;;
        -s|--ef-search)
            EF_SEARCH="$2"
            shift 2
            ;;
        -p|--parallel)
            PARALLEL="$2"
            shift 2
            ;;
        -t|--data-type)
            DATA_TYPE="$2"
            shift 2
            ;;
        -v|--vector-search)
            VECTOR_SEARCH="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Main execution
main() {
    log_info "Redis Vector Database Custom Configuration Generator"
    
    # Validate all parameters
    if ! validate_parameters; then
        log_error "Parameter validation failed"
        exit 1
    fi
    
    # Show configuration summary
    show_configuration_summary
    
    # Generate the configuration
    generate_benchmark_config "$VECTOR_SEARCH" "$M" "$EF_CONSTRUCTION" "$PARALLEL" "$DATA_TYPE" "$EF_SEARCH" "$OUTPUT_FILE"
    
    log_info "Custom configuration generation completed successfully"
    log_info "You can now use this configuration file with vector-db-benchmark"
}

# Execute main function
main "$@"
