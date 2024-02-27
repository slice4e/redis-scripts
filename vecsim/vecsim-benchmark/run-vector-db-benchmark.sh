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

#------------------------------- check if vector-db-benchmark directory exists if not pull it from github -------------------------------------------

if [[ ! -d $VECTORDB_BENCHMARK_PATH ]]; then
    echo "Couldn't find Vector DB Benchmark in $VECTORDB_BENCHMARK_PATH, cloning it now ..."
    git clone -b update.redisearch https://github.com/redis-performance/vector-db-benchmark "$VECTORDB_BENCHMARK_PATH"
else
    cd "$VECTORDB_BENCHMARK_PATH" || exit
    git pull origin update.redisearch
    cd -
fi

#------------------------------- install python requirements for vector-db-benchmark ----------------------------------------------------------------

# Installing python packages with root is not the best way to do it TODO: Figure out how to change it
if [[ -x "$PYTHON_PATH" ]]; then
    "$PYTHON_PATH" -m pip install poetry
    "$PYTHON_PATH" -m pip install -r requirements-vdb.txt
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
        {\"name\": \"redis-m-${M}-ef-${EF_CONSTRUCTION}-parallel-${PARALLEL}\",
        \"engine\": \"redis\",
        \"connection_params\": {},
        \"collection_params\": {
            \"hnsw_config\": { \"M\": ${M}, \"EF_CONSTRUCTION\": ${EF_CONSTRUCTION} }
        },
        \"search_params\": [
            { \"parallel\": ${PARALLEL}, \"search_params\": { \"ef\": ${EF_SEARCH} } }
        ],
        \"upload_params\": { \"parallel\": 100, \"batch_size\": 100 }
    }]" 
 
    echo $OUT > $VECTORDB_BENCHMARK_PATH/experiments/configurations/redis-intel.json

    #-------------------------------------------------------- Run Vector-db-benchmark ------------------------------------------------------------------

    REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $PYTHON_PATH $VECTORDB_BENCHMARK_PATH/run.py --engines redis-m-$M-ef-$EF_CONSTRUCTION-parallel-$PARALLEL --datasets ${DATASET_DICT[$DATASET_SIZE]} --host ${TARGET} --no-skip-if-exists $ADDITIONAL_FLAGS
else
    REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $PYTHON_PATH $VECTORDB_BENCHMARK_PATH/run.py --engines redis-m-$M-ef-$EF_CONSTRUCTION --datasets ${DATASET_DICT[$DATASET_SIZE]} --host ${TARGET} --no-skip-if-exists $ADDITIONAL_FLAGS
fi
