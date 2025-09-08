#!/bin/bash

# Test MLC functionality
# This script tests the MLC functions without running the full benchmark

set -e  # Exit on any error

# Source the required utilities
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common_utils.sh"

# Test configuration
export MLC=1
export MLC_PATH="$HOME/test_mlc"
export SCRIPT_NAME="mlc_test"

# Test functions
echo "Testing MLC functionality..."

# Test setup_mlc function
echo "1. Testing MLC setup..."
if setup_mlc "localhost" "$MLC_PATH"; then
    echo "   ✓ MLC setup successful"
else
    echo "   ✗ MLC setup failed"
    exit 1
fi

# Test if MLC executable exists
if [ -f "$MLC_PATH/mlc" ]; then
    echo "   ✓ MLC executable found at $MLC_PATH/mlc"
else
    echo "   ✗ MLC executable not found"
    exit 1
fi

# Test run_mlc function
echo "2. Testing MLC execution..."
if run_mlc "localhost" "$MLC_PATH" "$MLC_PATH"; then
    echo "   ✓ MLC execution successful"
else
    echo "   ✗ MLC execution failed"
    exit 1
fi

# Check if output file was created
output_files=$(ls "$MLC_PATH"/mlc_output_*.txt 2>/dev/null | wc -l)
if [ "$output_files" -gt 0 ]; then
    echo "   ✓ MLC output file(s) created"
    echo "   Output files:"
    ls -la "$MLC_PATH"/mlc_output_*.txt | sed 's/^/     /'
else
    echo "   ✗ No MLC output files found"
    exit 1
fi

# Test execute_mlc_if_enabled function
echo "3. Testing MLC wrapper function..."
if execute_mlc_if_enabled "localhost"; then
    echo "   ✓ MLC wrapper function successful"
else
    echo "   ✗ MLC wrapper function failed"
    exit 1
fi

echo ""
echo "All MLC tests passed successfully!"
echo "You can now use MLC=1 in your config.file to enable memory latency checking."

# Optional cleanup
read -p "Remove test MLC installation? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$MLC_PATH"
    echo "Test MLC installation removed."
fi
