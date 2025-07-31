#!/bin/bash

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [benchmark] [INFO] $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [benchmark] [WARN] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [benchmark] [ERROR] $*" >&2
}

# Constants
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VENV_DIR_NAME="venv-redis-benchmark"

#------------------------------------------------------ load config and variables file ---------------------------------------------------------------

# Function to load configuration files
load_configuration() {
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
        exit 1
    fi
    
    # Source the config file
    source "$config_file"
    
    # Check for variables file
    if [[ ! -e "./variables.file" ]]; then
        log_error "Variables file does not exist."
        exit 1
    fi
    
    source "./variables.file"
    log_info "Configuration loaded successfully"
    
    DATASET_NAME=${DATASET_DICT["$DATASET"]}
}

# Load configuration
load_configuration "${1:-}"
SOURCE_SCRIPT=$(dirname $(dirname "$SCRIPT_DIR"))/shared-scripts/set_ssh.sh

if [ "$REDIS_ENTERPRISE" -eq 1 ]; then
    for server in "${RE_SERVERS[@]}"; do
        SERVER_IP=$server
        source $SOURCE_SCRIPT
    done
    source "./re_setup.sh"
else
    if [ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]; then
        CLUSTER_MASTER=$SERVER_IP
        for server in "${CLUSTER_SERVERS[@]}"; do
            SERVER_IP=$server
            source $SOURCE_SCRIPT
        done
    else
        source $SOURCE_SCRIPT
    fi

    if [[ ${SERVER_REMOTE} == true ]]; then
        if [ "$CLUSTER_MULTIPLE_SERVERS" -eq 1 ]; then
            TARGET=$CLUSTER_MASTER
        else
            TARGET=$SERVER_IP
        fi
    else
        TARGET="localhost"
    fi
    
    # Use unified Redis setup script
    source "./redis_setup.sh"
fi



# Function to setup vector-db-benchmark repository
setup_vectordb_benchmark() {
    log_info "Setting up vector-db-benchmark repository..."
    
    if [[ ! -d "$VECTORDB_BENCHMARK_PATH" ]]; then
        log_info "Cloning vector-db-benchmark from GitHub..."
        if ! git clone https://github.com/redis-performance/vector-db-benchmark "$VECTORDB_BENCHMARK_PATH"; then
            log_error "Failed to clone vector-db-benchmark repository"
            return 1
        fi
        
        # Switch to the specified branch
        cd "$VECTORDB_BENCHMARK_PATH" || exit
        log_info "Switching to branch: $VECTORDB_BENCHMARK_BRANCH"
        if ! git checkout "$VECTORDB_BENCHMARK_BRANCH"; then
            log_error "Failed to switch to branch: $VECTORDB_BENCHMARK_BRANCH"
            return 1
        fi
        cd -
    else
        log_info "Updating existing vector-db-benchmark repository..."
        cd "$VECTORDB_BENCHMARK_PATH" || exit
        git fetch origin
        log_info "Switching to branch: $VECTORDB_BENCHMARK_BRANCH"
        git checkout "$VECTORDB_BENCHMARK_BRANCH"
        git pull origin "$VECTORDB_BENCHMARK_BRANCH"
        cd -
    fi
}

# Function to wait for Redis to be ready
wait_for_redis() {
    local max_attempts=${1:-60}
    local attempt=0
    
    log_info "Waiting for Redis server to be ready on $TARGET:$PORT..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        if redis_ping=$(${REDIS_PATH}/src/redis-cli -h ${TARGET} -p ${PORT} ping 2>/dev/null) && [[ $redis_ping == *"PONG"* ]]; then
            log_info "Redis server is ready!"
            return 0
        fi
        
        sleep 1
        ((attempt++))
        echo -ne "."
    done
    
    log_error "Redis server did not become ready after $max_attempts seconds"
    return 1
}

# Function to setup and activate Python virtual environment (for local benchmark client)
setup_python_environment() {
    # In local mode, Python environment is already set up by redis_setup.sh
    if [[ "$SERVER_REMOTE" != "true" ]]; then
        log_info "Python environment already set up by redis_setup.sh for local mode"
        return 0
    fi
    
    local venv_path="$HOME_PATH/$VENV_DIR_NAME"
    
    log_info "Setting up Python virtual environment locally for benchmark client..."
    
    # Create virtual environment if it doesn't exist locally
    if [[ ! -d "$venv_path" ]]; then
        log_info "Creating Python virtual environment at $venv_path..."
        if ! python3 -m venv "$venv_path"; then
            log_error "Failed to create virtual environment"
            return 1
        fi
    fi
    
    # Activate the virtual environment
    log_info "Activating virtual environment..."
    source "$venv_path/bin/activate"
    
    # Verify activation worked
    if [[ "$VIRTUAL_ENV" != "$venv_path" ]]; then
        log_error "Failed to activate virtual environment"
        return 1
    fi
    
    log_info "Virtual environment activated: $VIRTUAL_ENV"
    
    # Install/upgrade packages in the activated environment
    log_info "Installing Python packages in virtual environment..."
    
    if ! python -m pip install --upgrade pip; then
        log_error "Failed to upgrade pip"
        return 1
    fi
    
    if ! python -m pip install poetry; then
        log_error "Failed to install poetry"
        return 1
    fi
    
    if ! python -m pip install -r "$SCRIPT_DIR/requirements-vdb.txt"; then
        log_error "Failed to install requirements"
        return 1
    fi
    
    log_info "Python environment setup completed successfully"
}

# Setup Redis, vector-db-benchmark, and Python environment
source "./redis_setup.sh"
main  # Call the main function from redis_setup.sh to set up and start Redis on remote servers
setup_vectordb_benchmark
setup_python_environment  # Set up Python environment locally for benchmark client
wait_for_redis

Redis_Ping=$(${REDIS_PATH}/src/redis-cli -h ${TARGET} -p ${PORT} ping 2>/dev/null || echo "failed")
echo "Waiting for redis server to be ready..."
while [[ $Redis_Ping != *"PONG"* ]]; do
    sleep 1
    Redis_Ping=$(${REDIS_PATH}/src/redis-cli -h ${TARGET} -p ${PORT} ping 2>/dev/null || echo "failed")
    echo -ne "."
done

if [ "$CREATE_DYNAMICALLY" -eq 1 ]; then
    #---------------------------------------------- Dynamically Generate a vector db benchmark configuation file -----------------------------------------------

    # Check if EF_SEARCH has "," in it, if so, we will create multiple search params
    if [[ "$EF_SEARCH" == *,* ]]; then
        SEARCH_PARAMS_JSON="["
        IFS=',' read -ra EF_LIST <<< "$EF_SEARCH"
        for idx in "${!EF_LIST[@]}"; do
            ef_val="${EF_LIST[$idx]}"
            SEARCH_PARAMS_JSON+="
                { \"parallel\": ${PARALLEL}, \"search_params\": { \"ef\": ${ef_val}, \"data_type\": \"${DATA_TYPE}\" } }"
            # Add comma if not the last element
            if [[ $idx -lt $((${#EF_LIST[@]}-1)) ]]; then
                SEARCH_PARAMS_JSON+=","
            fi
        done
        SEARCH_PARAMS_JSON+="
            ]"
    else
        SEARCH_PARAMS_JSON="[
                { \"parallel\": ${PARALLEL}, \"search_params\": { \"ef\": ${EF_SEARCH}, \"data_type\": \"${DATA_TYPE}\" } }
            ]"
    fi

    if [[ "$VECTOR_SEARCH" == "vectorsets" ]]; then
        COLLECTION_PARAMS="{}"
        UPLOAD_PARAMS="{ \"parallel\": 128, \"data_type\": \"${DATA_TYPE}\", \"hnsw_config\": { \"M\": ${M}, \"EF_CONSTRUCTION\": ${EF_CONSTRUCTION} } }"
        ENGINE_NAME="vectorsets"
    else
        COLLECTION_PARAMS="{
            \"data_type\": \"${DATA_TYPE}\",
            \"hnsw_config\": { \"M\": ${M}, \"EF_CONSTRUCTION\": ${EF_CONSTRUCTION} }
        }"
        UPLOAD_PARAMS="{ \"parallel\": 128, \"data_type\": \"${DATA_TYPE}\" }"
        ENGINE_NAME="redis"
    fi

    OUT="[
        {\"name\": \"redis-m-${M}-ef-${EF_CONSTRUCTION}-parallel-${PARALLEL}-${DATA_TYPE}\",
        \"engine\": \"${ENGINE_NAME}\",
        \"connection_params\": {},
        \"collection_params\": $COLLECTION_PARAMS,
        \"search_params\": $SEARCH_PARAMS_JSON,
        \"upload_params\": $UPLOAD_PARAMS
    }]" 
    echo "$OUT" > "$VECTORDB_BENCHMARK_PATH/experiments/configurations/redis-intel.json"

    #-------------------------------------------------------- Run Vector-db-benchmark ------------------------------------------------------------------
    ENGINE_APPEND="-parallel-$PARALLEL-${DATA_TYPE}"
else
    ENGINE_APPEND=""
fi

# NUMA PREFIX
if [ "$USE_NUMACTL_CLIENT" -eq 1 ]; then
    NUMACTL_PREFIX="numactl -N $NUMA_NODES_CLIENT -m $NUMA_NODES_CLIENT"
else
    NUMACTL_PREFIX=""
fi


# STAGE DOWNLOAD
# Construct dataset path based on dataset type
if [[ "$DATASET" == laion-512-* ]]; then
    DATASET_PATH=$VECTORDB_BENCHMARK_PATH/datasets/laion-img-emb-512/$DATASET_NAME.hdf5
    DATASET_URL="http://benchmarks.redislabs.s3.amazonaws.com/vecsim/laion400m/$DATASET_NAME.hdf5"
elif [[ "$DATASET" == laion-768-* ]]; then
    DATASET_PATH=$VECTORDB_BENCHMARK_PATH/datasets/laion-img-emb-768/$DATASET_NAME.hdf5
    DATASET_URL="http://benchmarks.redislabs.s3.amazonaws.com/vecsim/laion400m/$DATASET_NAME.hdf5"
elif [[ "$DATASET" == dbpedia-* ]]; then
    DATASET_PATH=$VECTORDB_BENCHMARK_PATH/datasets/dbpedia/$DATASET_NAME.hdf5
    DATASET_URL="http://benchmarks.redislabs.s3.amazonaws.com/vecsim/dbpedia/$DATASET_NAME.hdf5"
elif [[ "$DATASET" == cohere-* ]]; then
    DATASET_PATH=$VECTORDB_BENCHMARK_PATH/datasets/cohere/$DATASET_NAME.hdf5
    DATASET_URL="http://benchmarks.redislabs.s3.amazonaws.com/vecsim/cohere/$DATASET_NAME.hdf5"
else
    log_error "Unknown dataset type: $DATASET"
    exit 1
fi

# Ensure the parent directory exists
mkdir -p "$(dirname "$DATASET_PATH")"

if [[ ! -e $DATASET_PATH ]]; then
    log_info "Downloading dataset from $DATASET_URL..."
    wget -q -O $DATASET_PATH $DATASET_URL
fi

# STAGE UPLOAD
if [ "$SKIP_UPLOAD" -eq 0 ] || [ "$SKIP_SETUP" -eq 0 ]; then
    REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $NUMACTL_PREFIX python3 $VECTORDB_BENCHMARK_PATH/run.py --engines redis-m-$M-ef-$EF_CONSTRUCTION$ENGINE_APPEND --datasets $DATASET_NAME --host ${TARGET} --no-skip-if-exists --skip-search
fi

# STAGE RUN
if [[ ${RUN_EMON} == true ]]; then
    echo "Starting emon... (First, try to stop if emon is running)"
    # Extract a short identifier from dataset name for EMON filename
    DATASET_ID=$(echo "$DATASET" | sed 's/.*-\([^-]*\)$/\1/')  # Extract last part after final dash
    if [[ ${SERVER_REMOTE} == false ]]; then
        ${EMON_FOLDER}/emon -stop || true
        (${EMON_FOLDER}/emon -collect-edp -f redis-${DATASET_ID}-m-${M}-ef-${EF_CONSTRUCTION}-emon.dat) &
    fi
    if [[ ${SERVER_REMOTE} == true ]]; then
        $SSH_COMMAND "${EMON_FOLDER}/emon -stop || true"
        cmd="${EMON_FOLDER}/emon -collect-edp -f ${HOME_PATH}/redis-${DATASET_ID}-m-${M}-ef-${EF_CONSTRUCTION}-emon.dat"
        nohup $SSH_COMMAND "$cmd &" &
    fi
fi

REPETITIONS=$REPETITIONS REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $NUMACTL_PREFIX python3 $VECTORDB_BENCHMARK_PATH/run.py --engines redis-m-$M-ef-$EF_CONSTRUCTION$ENGINE_APPEND --datasets $DATASET_NAME --host ${TARGET} --no-skip-if-exists --queries $QUERIES --skip-upload

if [[ ${RUN_EMON} == true ]]; then
    echo "Stopping emon..."
    if [[ ${SERVER_REMOTE} == false ]]; then
        ${EMON_FOLDER}/emon -stop || true
        source ../../shared-scripts/emon_process.sh
    fi
    if [[ ${SERVER_REMOTE} == true ]]; then
        $SSH_COMMAND "${EMON_FOLDER}/emon -stop || true"
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ../../shared-scripts/emon_process.sh $LOGIN_ID@${TARGET}:${HOME_PATH}/emon_process.sh
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${EMON_CONFIG_FILE} $LOGIN_ID@${TARGET}:${HOME_PATH}/pyedp_config.txt
        $SSH_COMMAND "cd ${HOME_PATH} && EMON_CONFIG_FILE=$HOME_PATH/pyedp_config.txt RUN_EMON=true EMON_HOME=$EMON_HOME bash ${HOME_PATH}/emon_process.sh"
    fi
fi
