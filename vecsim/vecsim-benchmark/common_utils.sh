#!/bin/bash

#=======================================================================================================================
# Common Utilities Script
# Shared functions for logging, SSH operations, and environment validation
#=======================================================================================================================

# Logging functions with improved formatting
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME:-script}] [INFO] $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME:-script}] [WARN] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME:-script}] [ERROR] $*" >&2
}

log_debug() {
    [[ "${DEBUG:-0}" == "1" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME:-script}] [DEBUG] $*" >&2
}

log_step() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────────────────┐"
    echo "│ $1"
    echo "└──────────────────────────────────────────────────────────────────────────────┘"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME:-script}] [✓] $*"
}

#=======================================================================================================================
# Configuration and Environment Functions
#=======================================================================================================================

# Function to validate required environment variables
validate_required_vars() {
    local required_vars=("$@")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        log_error "Please check your config.file"
        return 1
    fi
    
    return 0
}

# Function to load configuration file
load_config_file() {
    local config_file="${1:-./config.file}"
    
    log_info "Loading configuration from: $config_file"
    
    # Check if the config file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "The config file '$config_file' does not exist."
        return 1
    fi
    
    # Source the config file
    source "$config_file"
    log_info "Configuration loaded successfully"
    return 0
}

#=======================================================================================================================
# SSH and Remote Command Execution Functions
#=======================================================================================================================

# Function to execute commands either locally or remotely
# Args: $1 = command, $2 = target_server
execute_command() {
    local cmd="$1"
    local target_server="$2"
    
    log_info "Executing on $target_server: $cmd"
    
    if [[ "$target_server" == "localhost" ]]; then
        # Local execution
        if ! eval "$cmd"; then
            log_error "Command failed locally: $cmd"
            return 1
        fi
    else
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${target_server}"
        
        if ! $ssh_cmd "$cmd"; then
            log_error "Command failed on remote server $target_server: $cmd"
            return 1
        fi
    fi
}

# Function to execute commands quietly (no error logging for expected failures)
# Args: $1 = command, $2 = target_server
execute_command_quiet() {
    local cmd="$1"
    local target_server="$2"
    
    if [[ "$target_server" == "localhost" ]]; then
        eval "$cmd" >/dev/null 2>&1
    else
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${target_server}"
        $ssh_cmd "$cmd" >/dev/null 2>&1
    fi
}

# Function to execute commands in background (for server startup)
# Args: $1 = command, $2 = target_server
execute_command_background() {
    local cmd="$1"
    local target_server="$2"
    
    log_info "Starting background process on $target_server: $cmd"
    
    if [[ "$target_server" == "localhost" ]]; then
        # Local background execution with complete detachment
        # Use setsid to create a new session and nohup to detach from terminal
        nohup setsid bash -c "$cmd" >/dev/null 2>&1 &
        local pid=$!
        disown $pid 2>/dev/null || true
        log_info "Background process started locally with PID: $pid (completely detached)"
    else
        # Remote background execution
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${target_server}"
        
        nohup $ssh_cmd "$cmd" > /dev/null 2>&1 &
        local pid=$!
        disown $pid
        log_info "Background process started on remote server with local PID: $pid (detached from shell)"
    fi
}

# Function to copy files to remote server
copy_file_to_server() {
    local local_file="$1"
    local remote_path="$2"
    local target_server="$3"
    
    if [[ "$SERVER_REMOTE" == "true" ]]; then
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} "$local_file" $LOGIN_ID@${target_server}:"$remote_path"
    else
        cp "$local_file" "$remote_path"
    fi
}

#=======================================================================================================================
# System Dependencies and Environment Setup Functions
#=======================================================================================================================

# Function to check if a command exists
command_exists() {
    local cmd="$1"
    local target_server="$2"
    execute_command_quiet "command -v $cmd" "$target_server"
}

# Function to check if a package exists (for Debian/Ubuntu systems)
package_exists() {
    local pkg="$1"
    local target_server="$2"
    execute_command_quiet "dpkg -l | grep -q $pkg" "$target_server"
}

# Function to install system dependencies
install_dependencies() {
    local target_server="$1"
    
    log_info "Installing dependencies on $target_server..."
    
    # Define the complete list of required packages
    local packages=(
        "numactl"
        "python3-venv"
        "libssl-dev"
        "pkg-config"
        "ca-certificates"
        "wget"
        "dpkg-dev"
        "gcc"
        "g++"
        "libc6-dev"
        "make"
        "git"
        "cmake"
        "python3"
        "python3-pip"
        "python3-dev"
        "unzip"
        "rsync"
        "clang"
        "automake"
        "autoconf"
        "libtool"
    )
    
    # For localhost, check if we actually need to install anything first
    if [[ "$target_server" == "localhost" ]]; then
        # Check all required packages
        local missing_deps=()
        
        for pkg in "${packages[@]}"; do
            if ! package_exists "$pkg" "$target_server"; then
                missing_deps+=("$pkg")
            fi
        done
        
        # If nothing is missing, skip dependency installation
        if [[ ${#missing_deps[@]} -eq 0 ]]; then
            log_info "All required dependencies are already available on localhost, skipping installation"
            return 0
        fi
        
        log_info "Missing dependencies on localhost: ${missing_deps[*]}"
        
        # Try to install if we're root or have passwordless sudo
        if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
            log_info "Installing missing packages..."
            sudo apt-get update && sudo apt-get install -y --no-install-recommends "${missing_deps[@]}"
            if [[ $? -eq 0 ]]; then
                log_success "Dependencies installed successfully"
                return 0
            else
                log_error "Failed to install dependencies"
                return 1
            fi
        else
            # No root or passwordless sudo, provide manual instructions
            log_warn "Cannot automatically install packages (not root and no passwordless sudo)"
            log_warn "Please install them manually with:"
            log_warn "sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}"
            return 1
        fi
    fi
    
    # Update package lists first
    log_info "Updating package lists on $target_server..."
    if ! execute_command "sudo apt-get update" "$target_server"; then
        log_error "Failed to update package lists on $target_server"
        log_error "Ensure the user has passwordless sudo access"
        return 1
    fi
    
    # Install required packages
    log_info "Installing required packages on $target_server..."
    local package_list=$(IFS=' '; echo "${packages[*]}")
    if ! execute_command "sudo apt-get install -y --no-install-recommends $package_list" "$target_server"; then
        log_error "Failed to install required packages on $target_server"
        return 1
    fi
    
    log_info "All dependencies installed successfully on $target_server"
}

#=======================================================================================================================
# Utility Functions
#=======================================================================================================================

# Function to wait for a service to be ready
wait_for_service() {
    local service_name="$1"
    local check_command="$2"
    local max_attempts="${3:-60}"
    local attempt=0
    
    log_info "Waiting for $service_name to be ready..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        if eval "$check_command" >/dev/null 2>&1; then
            log_info "$service_name is ready!"
            return 0
        fi
        
        sleep 1
        ((attempt++))
        echo -ne "."
    done
    
    log_error "$service_name did not become ready after $max_attempts seconds"
    return 1
}



# Function to create directory structure
ensure_directory() {
    local dir_path="$1"
    local target_server="$2"
    
    if ! execute_command "mkdir -p \"$dir_path\"" "$target_server"; then
        log_error "Failed to create directory $dir_path on $target_server"
        return 1
    fi
    return 0
}

#=======================================================================================================================
# MLC (Memory Latency Checker) Functions
#=======================================================================================================================

# Function to download and setup MLC
setup_mlc() {
    local target_server="$1"
    local mlc_path="$2"
    
    log_info "Setting up MLC on $target_server at $mlc_path..."
    
    # Check if MLC already exists
    if execute_command_quiet "[ -f \"$mlc_path/mlc\" ]" "$target_server"; then
        log_info "MLC already exists at $mlc_path/mlc"
        return 0
    fi
    
    # Create MLC directory
    ensure_directory "$mlc_path" "$target_server" || return 1
    
    # Download MLC
    log_info "Downloading MLC from Intel..."
    local mlc_url="https://downloadmirror.intel.com/834254/mlc_v3.11b.tgz"
    local temp_file="/tmp/mlc_v3.11b.tgz"
    
    if ! execute_command "wget -O $temp_file $mlc_url" "$target_server"; then
        log_error "Failed to download MLC"
        return 1
    fi
    
    # Extract MLC
    log_info "Extracting MLC..."
    if ! execute_command "cd $mlc_path && tar -xzf $temp_file --strip-components=1" "$target_server"; then
        log_error "Failed to extract MLC"
        return 1
    fi
    
    # Cleanup temporary file
    execute_command "rm -f $temp_file" "$target_server"
    
    # Verify MLC executable exists
    if ! execute_command_quiet "[ -f \"$mlc_path/mlc\" ]" "$target_server"; then
        log_error "MLC executable not found after extraction"
        return 1
    fi
    
    # Make MLC executable
    execute_command "chmod +x $mlc_path/mlc" "$target_server"
    
    log_info "MLC successfully set up on $target_server"
    return 0
}

# Function to run MLC and save output
run_mlc() {
    local target_server="$1"
    local mlc_path="$2"
    local output_dir="$3"
    
    log_info "Running MLC on $target_server..."
    
    # Verify MLC exists
    if ! execute_command_quiet "[ -f \"$mlc_path/mlc\" ]" "$target_server"; then
        log_error "MLC executable not found at $mlc_path/mlc"
        return 1
    fi
    
    # Create output directory
    ensure_directory "$output_dir" "$target_server" || return 1
    
    # Generate timestamp for output files
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local output_file="$output_dir/mlc_output_${timestamp}.txt"
    
    log_info "Running MLC and saving output to $output_file..."
    
    # Run MLC with default parameters and save output
    local mlc_cmd="cd $mlc_path && ./mlc > $output_file 2>&1"
    
    if execute_command "$mlc_cmd" "$target_server"; then
        log_success "MLC completed successfully. Output saved to $output_file"
        return 0
    else
        log_error "MLC execution failed"
        return 1
    fi
}

# Function to setup and run MLC if enabled
execute_mlc_if_enabled() {
    local target_server="$1"
    
    # Check if MLC is enabled
    if [[ "${MLC:-0}" != "1" ]]; then
        log_info "MLC is disabled (MLC=0), skipping MLC execution"
        return 0
    fi
    
    # Validate MLC_PATH is set
    if [[ -z "${MLC_PATH:-}" ]]; then
        log_error "MLC is enabled but MLC_PATH is not set"
        return 1
    fi
    
    log_step "Executing MLC (Memory Latency Checker) on $target_server"
    
    # Setup MLC
    if ! setup_mlc "$target_server" "$MLC_PATH"; then
        log_error "Failed to setup MLC on $target_server"
        return 1
    fi
    
    # Run MLC and save output to the same directory
    if ! run_mlc "$target_server" "$MLC_PATH" "$MLC_PATH"; then
        log_error "Failed to run MLC on $target_server"
        return 1
    fi
    
    log_success "MLC execution completed successfully on $target_server"
    return 0
}
