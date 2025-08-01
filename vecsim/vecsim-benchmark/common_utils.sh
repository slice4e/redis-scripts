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
        echo ""
        echo "Available configuration files in current directory:"
        ls -1 *.file 2>/dev/null || echo "  No *.file found"
        echo ""
        echo "You can create a configuration file using the template:"
        echo "  cp config.file.template config.file"
        echo "  # Edit config.file with your settings"
        echo ""
        echo "Or specify a different config file:"
        echo "  $0 <config_file>"
        echo "  Example: $0 ./my-config.file"
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
        # Local background execution
        eval "$cmd" &
        local pid=$!
        log_info "Background process started locally with PID: $pid"
    else
        # Remote background execution
        local ssh_opts="-o PreferredAuthentications=publickey -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
        local ssh_cmd="ssh $ssh_opts -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${target_server}"
        
        nohup $ssh_cmd "$cmd" > /dev/null 2>&1 &
        local pid=$!
        log_info "Background process started on remote server with local PID: $pid"
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
    
    # For localhost, check if we actually need to install anything first
    if [[ "$target_server" == "localhost" ]]; then
        # Check if all required tools are already available
        local missing_deps=()
        
        if ! command_exists "numactl" "$target_server"; then
            missing_deps+=("numactl")
        fi
        
        if ! execute_command_quiet "python3 -m venv --help" "$target_server"; then
            missing_deps+=("python3-venv")
        fi
        
        if ! execute_command_quiet "pkg-config --exists openssl" "$target_server"; then
            missing_deps+=("libssl-dev pkg-config")
        fi
        
        # If nothing is missing, skip dependency installation
        if [[ ${#missing_deps[@]} -eq 0 ]]; then
            log_info "All required dependencies are already available on localhost, skipping installation"
            return 0
        fi
        
        # If something is missing, warn user and provide instructions
        log_warn "Missing dependencies on localhost: ${missing_deps[*]}"
        log_warn "Please install them manually with:"
        log_warn "sudo apt-get update && sudo apt-get install -y numactl python3-venv libssl-dev pkg-config"
        log_warn "Or ensure your user has sudo privileges"
        return 1
    fi
    
    # Update package lists first
    log_info "Updating package lists on $target_server..."
    if ! execute_command "sudo apt-get update" "$target_server"; then
        log_error "Failed to update package lists on $target_server"
        log_error "Ensure the user has passwordless sudo access"
        return 1
    fi
    
    # Install required packages
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
    
    log_info "Installing required packages on $target_server..."
    local package_list=$(IFS=' '; echo "${packages[*]}")
    if ! execute_command "sudo apt-get install -y --no-install-recommends $package_list" "$target_server"; then
        log_error "Failed to install required packages on $target_server"
        return 1
    fi
    
    log_info "All dependencies installed successfully on $target_server"
}

#=======================================================================================================================
# Python Environment Functions
#=======================================================================================================================

# Function to setup Python virtual environment
setup_python_venv() {
    local target_server="$1"
    local venv_path="$2"
    
    log_info "Setting up Python virtual environment on $target_server at $venv_path..."

    # Check if virtual environment exists and is valid
    if execute_command_quiet "[ ! -d \"$venv_path\" ] || [ ! -x \"$venv_path/bin/python\" ]" "$target_server"; then
        log_info "Virtual environment missing or invalid, creating new one at $venv_path..."
        # Remove any incomplete or corrupted venv directory
        execute_command "rm -rf \"$venv_path\"" "$target_server"
        # Create new virtual environment with --upgrade-deps
        if ! execute_command "python3 -m venv --upgrade-deps \"$venv_path\"" "$target_server"; then
            log_error "Failed to create virtual environment"
            return 1
        fi
    else
        log_info "Virtual environment already exists at $venv_path"
    fi
    
    # Verify pip is available and upgrade it
    if ! execute_command_quiet "\"$venv_path/bin/python\" -m pip --version" "$target_server"; then
        log_info "Virtual environment pip is not working, recreating..."
        execute_command "rm -rf \"$venv_path\"" "$target_server"
        execute_command "python3 -m venv --upgrade-deps \"$venv_path\"" "$target_server"
    fi
    
    # Upgrade pip in the virtual environment
    execute_command "\"$venv_path/bin/python\" -m pip install --upgrade pip" "$target_server"
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
