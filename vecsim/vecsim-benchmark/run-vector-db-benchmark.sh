#!/bin/bash
#------------------------------------------------------ check if user is sudo or root ---------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	  echo "This script must be run as root."
	    exit 1
fi

#------------------------------------------------------ load config and variables file ---------------------------------------------------------------
# Read the config file
if [ "$1" != "" ]; then
	config_file=$1
else
	config_file="./config.file"
fi

# Check if the file exists
if [ ! -f "$config_file" ]; then
  echo "Error: The config file '$config_file' does not exist. Please use the config file template to create one."
  exit 1
fi

source $config_file

if [[ ! -e "./variables.file" ]]; then
    # TODO: Add redisearch building
    echo "Variables file does not exist."
    exit 1
fi

source "./variables.file"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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
            source "./remote_multiple_servers.sh"
        else
            TARGET=$SERVER_IP
            source "./remote.sh"
        fi
    else
        TARGET="localhost"
        source "./local.sh"
    fi
fi



# #------------------------------- check if vector-db-benchmark directory exists if not pull it from github -------------------------------------------

if [[ ! -d $VECTORDB_BENCHMARK_PATH ]]; then
    echo "Couldn't find Vector DB Benchmark in $VECTORDB_BENCHMARK_PATH, cloning it now ..."
    git clone -b update.redisearch https://github.com/redis-performance/vector-db-benchmark "$VECTORDB_BENCHMARK_PATH"
    cd "$VECTORDB_BENCHMARK_PATH"
    git checkout db1896d602f30198cca217fec5052a21712617b7
    cd -
else
    cd "$VECTORDB_BENCHMARK_PATH" || exit
    git pull origin update.redisearch
    git checkout db1896d602f30198cca217fec5052a21712617b7
    cd -
fi

#------------------------------- install python requirements for vector-db-benchmark ----------------------------------------------------------------

# Installing python packages with root is not the best way to do it TODO: Figure out how to change it
if [[ -x "$PYTHON_PATH" ]]; then
    "$PYTHON_PATH" -m pip install poetry
    "$PYTHON_PATH" -m pip install -r $SCRIPT_DIR/requirements-vdb.txt
else
    echo "Invalid PYTHON_PATH: $PYTHON_PATH"
    exit 1
fi

Redis_Ping=$(${REDIS_PATH}/src/redis-cli -h ${TARGET} -p ${PORT} ping )
echo "Waiting for redis server to be ready..."
while [[ $Redis_Ping != *"PONG"* ]]; do
    sleep 1
    Redis_Ping=$(${REDIS_PATH}/src/redis-cli -h ${TARGET} -p ${PORT} ping )
    echo -ne "."
done

if [ "$CREATE_DYNAMICALLY" -eq 1 ]; then
    #---------------------------------------------- Dynamically Generate a vector db benchmark configuation file -----------------------------------------------

    OUT="[
        {\"name\": \"redis-svs-DEGREE-${EF_CONSTRUCTION}-parallel-${PARALLEL}\",
        \"engine\": \"redis\",
        \"connection_params\": {},
        \"collection_params\": {
            \"algorithm\": \"svs\",
            \"svs_config\": { \"NUM_THREADS\": 1, \"GRAPH_DEGREE\": ${EF_CONSTRUCTION}, \"WINDOW_SIZE\": 200 }
        },
        \"search_params\": [
            { \"parallel\": ${PARALLEL}, \"algorithm\": \"svs\" }
        ],
        \"upload_params\": { \"parallel\": 16 }
    }]" 
 
    echo $OUT > $VECTORDB_BENCHMARK_PATH/experiments/configurations/redis-intel.json

    #-------------------------------------------------------- Run Vector-db-benchmark ------------------------------------------------------------------
    ENGINE_APPEND="-parallel-$PARALLEL"
else
    ENGINE_APPEND=""
fi

# STAGE DOWNLOAD
DATASET_PATH=$VECTORDB_BENCHMARK_PATH/datasets/laion-img-emb-512/laion-img-emb-512-$DATASET_SIZE-cosine.hdf5
if [[ ! -e $DATASET_PATH ]]; then
    wget -O $DATASET_PATH http://benchmarks.redislabs.s3.amazonaws.com/vecsim/laion400m/laion-img-emb-512-$DATASET_SIZE-cosine.hdf5
fi

# STAGE UPLOAD
if [ "$SKIP_UPLOAD" -eq 0 ] || [ "$SKIP_SETUP" -eq 0 ]; then
    REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $PYTHON_PATH $VECTORDB_BENCHMARK_PATH/run.py --engines redis-svs-DEGREE-$EF_CONSTRUCTION$ENGINE_APPEND --datasets ${DATASET_DICT[$DATASET_SIZE]} --host ${TARGET} --no-skip-if-exists --skip-search
fi

# STAGE RUN
if [[ ${RUN_EMON} == true ]]; then
    echo "Starting emon... (First, try to stop if emon is running)"
    if [[ ${SERVER_REMOTE} == false ]]; then
        ${EMON_FOLDER}/emon -stop
        (${EMON_FOLDER}/emon -collect-edp -f redis-${DATASET_SIZE}-m-${M}-ef-${EF_CONSTRUCTION}-emon.dat) &
    fi
    if [[ ${SERVER_REMOTE} == true ]]; then
        $SSH_COMMAND "${EMON_FOLDER}/emon -stop"
        cmd="${EMON_FOLDER}/emon -collect-edp -f ${HOME_PATH}/redis-${DATASET_SIZE}-m-${M}-ef-${EF_CONSTRUCTION}-emon.dat"
        nohup $SSH_COMMAND "$cmd &" &
    fi
fi

REPETITIONS=1 REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $PYTHON_PATH $VECTORDB_BENCHMARK_PATH/run.py --engines redis-svs-DEGREE-$EF_CONSTRUCTION$ENGINE_APPEND --datasets ${DATASET_DICT[$DATASET_SIZE]} --host ${TARGET} --no-skip-if-exists --skip-upload

if [[ ${RUN_EMON} == true ]]; then
    echo "Stopping emon..."
    if [[ ${SERVER_REMOTE} == false ]]; then
        ${EMON_FOLDER}/emon -stop
        source ../../shared-scripts/emon_process.sh
    fi
    if [[ ${SERVER_REMOTE} == true ]]; then
        $SSH_COMMAND "${EMON_FOLDER}/emon -stop"
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ../../shared-scripts/emon_process.sh ${LOGIN_ID}@${TARGET}:${HOME_PATH}/emon_process.sh
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ${EMON_CONFIG_FILE} ${LOGIN_ID}@${TARGET}:${HOME_PATH}/pyedp_config.txt
        $SSH_COMMAND "cd ${HOME_PATH} && EMON_CONFIG_FILE=$HOME_PATH/pyedp_config.txt RUN_EMON=true EMON_HOME=$EMON_HOME bash ${HOME_PATH}/emon_process.sh"
    fi
fi
