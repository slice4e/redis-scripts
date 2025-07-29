#!/bin/bash

# Helper script to activate the Python virtual environment used by the Redis benchmark scripts
# Usage: source ./activate_venv.sh

# Load configuration
if [ -f "./config.file" ]; then
    source ./config.file
else
    echo "Warning: config.file not found, using default HOME_PATH"
    HOME_PATH=$HOME
fi

VENV_PATH="$HOME_PATH/venv-redis-benchmark"

if [ -d "$VENV_PATH" ]; then
    echo "Activating Python virtual environment at: $VENV_PATH"
    source "$VENV_PATH/bin/activate"
    echo "Virtual environment activated. Python path: $(which python)"
    echo "To deactivate, run: deactivate"
else
    echo "Virtual environment not found at: $VENV_PATH"
    echo "Please run the Redis setup script first to create the virtual environment."
    exit 1
fi
