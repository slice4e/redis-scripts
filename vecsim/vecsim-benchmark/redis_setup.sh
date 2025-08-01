#!/bin/bash

#=======================================================================================================================
# Simplified Redis Setup Script
# Main entry point for Redis environment setup
#=======================================================================================================================

# Script identification for logging
SCRIPT_NAME="redis_setup"

# Get script directory and source utilities
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/config_loader.sh"
source "$SCRIPT_DIR/redis_utils.sh"

#=======================================================================================================================
# Main execution logic
#=======================================================================================================================
main() {
    log_info "Starting Redis setup process..."
    
    # Load and validate configuration
    if ! load_benchmark_configuration "${1:-}"; then
        exit 1
    fi
    
    # Display configuration summary
    display_config_summary
    
    if [ "$SKIP_SETUP" -eq 1 ]; then
        log_info "Skipping setup (SKIP_SETUP=1)"
        return 0
    fi

    # Get server list and setup Redis environment
    local servers=($(get_server_list))
    setup_redis_environment "${servers[@]}"
    
    log_info "=== Redis setup completed successfully ==="
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
