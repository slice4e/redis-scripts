#!/bin/bash
#=======================================================================================================================
# Mixed Workload Sweep Wrapper
# Runs run-vector-db-benchmark.sh across multiple --update-fraction values,
# organizing results into a timestamped directory tree.
#
# Usage:
#   ./mixed_workload_script_wrapper.sh <config_file> [update_fractions...]
#
# Examples:
#   ./mixed_workload_script_wrapper.sh config.file                    # default sweep: 0.0 0.1 0.3 0.5 0.95
#   ./mixed_workload_script_wrapper.sh config.file 0.0 0.5 1.0       # custom sweep
#=======================================================================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Default update fractions
DEFAULT_FRACTIONS=(0.0 0.1 0.3 0.5 0.95)

#-----------------------------------------------------------------------------------------------------------------------
# Parse arguments
#-----------------------------------------------------------------------------------------------------------------------
CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    echo "Usage: $0 <config_file> [update_fractions...]"
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file '$CONFIG_FILE' not found."
    exit 1
fi

shift
if [[ $# -gt 0 ]]; then
    UPDATE_FRACTIONS=("$@")
else
    UPDATE_FRACTIONS=("${DEFAULT_FRACTIONS[@]}")
fi

#-----------------------------------------------------------------------------------------------------------------------
# Read key settings from config file
#-----------------------------------------------------------------------------------------------------------------------
DATASET=$(grep -E '^\s*DATASET=' "$CONFIG_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
EXPERIMENT_CONFIGURATION=$(grep -E '^\s*EXPERIMENT_CONFIGURATION=' "$CONFIG_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
VECTORDB_BENCHMARK_PATH=$(grep -E '^\s*VECTORDB_BENCHMARK_PATH=' "$CONFIG_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
# Expand $HOME_PATH if used in VECTORDB_BENCHMARK_PATH
HOME_PATH=$(grep -E '^\s*HOME_PATH=' "$CONFIG_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
HOME_PATH="${HOME_PATH:-$HOME}"
VECTORDB_BENCHMARK_PATH="${VECTORDB_BENCHMARK_PATH//\$HOME_PATH/$HOME_PATH}"
VECTORDB_BENCHMARK_PATH="${VECTORDB_BENCHMARK_PATH:-$HOME/vector-db-benchmark}"

if [[ -z "$DATASET" || -z "$EXPERIMENT_CONFIGURATION" ]]; then
    echo "Error: Could not read DATASET or EXPERIMENT_CONFIGURATION from config file."
    exit 1
fi

#-----------------------------------------------------------------------------------------------------------------------
# Create results directory structure
#-----------------------------------------------------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESULTS_DIR="$SCRIPT_DIR/mixed_workload_results_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

echo "========================================================================"
echo " Mixed Workload Sweep"
echo "========================================================================"
echo " Config file:     $CONFIG_FILE"
echo " Dataset:         $DATASET"
echo " Experiment:      $EXPERIMENT_CONFIGURATION"
echo " Update fractions: ${UPDATE_FRACTIONS[*]}"
echo " Results dir:     $RESULTS_DIR"
echo "========================================================================"

#-----------------------------------------------------------------------------------------------------------------------
# Create a working copy of the config file
#-----------------------------------------------------------------------------------------------------------------------
WORKING_CONFIG="$RESULTS_DIR/config.file.sweep"
cp "$CONFIG_FILE" "$WORKING_CONFIG"

#-----------------------------------------------------------------------------------------------------------------------
# Run sweep
#-----------------------------------------------------------------------------------------------------------------------
for fraction in "${UPDATE_FRACTIONS[@]}"; do
    echo ""
    echo "========================================================================"
    echo " Running update-fraction=$fraction"
    echo "========================================================================"

    # Update VECTORDB_BENCHMARK_PARAMS in the working config
    # Remove any existing --update-fraction from the params, then add the new one
    if grep -qE '^\s*VECTORDB_BENCHMARK_PARAMS=' "$WORKING_CONFIG"; then
        # Get current params, strip any existing --update-fraction
        CURRENT_PARAMS=$(grep -E '^\s*VECTORDB_BENCHMARK_PARAMS=' "$WORKING_CONFIG" | tail -1 | cut -d= -f2- | tr -d '"')
        CURRENT_PARAMS=$(echo "$CURRENT_PARAMS" | sed 's/--update-fraction[[:space:]]*[0-9.]*//g' | xargs)
        NEW_PARAMS="$CURRENT_PARAMS --update-fraction $fraction"
        sed -i "s|^\s*VECTORDB_BENCHMARK_PARAMS=.*|VECTORDB_BENCHMARK_PARAMS=\"${NEW_PARAMS}\"|" "$WORKING_CONFIG"
    else
        echo "VECTORDB_BENCHMARK_PARAMS=\"--update-fraction $fraction\"" >> "$WORKING_CONFIG"
    fi

    # Always do a full run (upload + search) since updates/inserts modify the data
    sed -i 's/^\s*SKIP_UPLOAD=.*/SKIP_UPLOAD=0/' "$WORKING_CONFIG"

    # Clear the vector-db-benchmark results directory before each run
    VDB_RESULTS="$VECTORDB_BENCHMARK_PATH/results"
    rm -rf "$VDB_RESULTS"
    mkdir -p "$VDB_RESULTS"

    # Run the benchmark
    echo "Config: $(grep VECTORDB_BENCHMARK_PARAMS "$WORKING_CONFIG")"
    echo "SKIP_UPLOAD: $(grep SKIP_UPLOAD "$WORKING_CONFIG")"

    "$SCRIPT_DIR/run-vector-db-benchmark.sh" "$WORKING_CONFIG" 2>&1 | tee "$RESULTS_DIR/run_update_${fraction}.log"

    # Organize results into the directory structure
    DEST_DIR="$RESULTS_DIR/$DATASET/$EXPERIMENT_CONFIGURATION/update_${fraction}/cluster_nodes_1"
    mkdir -p "$DEST_DIR"

    # Copy the entire results directory from vector-db-benchmark
    if [[ -d "$VDB_RESULTS" ]]; then
        cp -r "$VDB_RESULTS"/* "$DEST_DIR/" 2>/dev/null || true
    fi

    # Copy the log
    cp "$RESULTS_DIR/run_update_${fraction}.log" "$DEST_DIR/"

    echo "Results for update-fraction=$fraction saved to $DEST_DIR"
done

echo ""
echo "========================================================================"
echo " Sweep complete!"
echo " Results: $RESULTS_DIR"
echo "========================================================================"
