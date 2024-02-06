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
cd "$VECTORDB_BENCHMARK_PATH" || exit
if [[ -x "$PYTHON_PATH" ]]; then
    "$PYTHON_PATH" -m pip install poetry
    # Generally this shouldn't be done this way, but there were some problems with poetry install on that repository.
    # TODO: Fix this
    "$PYTHON_PATH" -m pip install -r <("$PYTHON_PATH" -m poetry export -f requirements.txt)
else
    echo "Invalid PYTHON_PATH: $PYTHON_PATH"
    exit 1
fi

#----------------------------------- Check if Redis and RediSearch module exists if not prepare them ------------------------------------------------

if [[ ! -d "$REDIS_PATH" ]]; then
    echo "Redis not found in $REDIS_PATH, downloading it ..."
    git clone https://github.com/redis/redis $REDIS_PATH
    cd $REDIS_PATH
    git checkout $REDIS_BRANCH
    make
    cd -
fi

if [ "$REDIS_CLUSTER" -eq 1 ]; then
    REDISEARCH_LIB=$REDISEARCH_PATH/bin/linux-x64-release/coord-oss/module-oss.so
else
    REDISEARCH_LIB=$REDISEARCH_PATH/bin/linux-x64-release/search/redisearch.so
fi


if [[ ! -e $REDISEARCH_LIB ]]; then
    echo "Rediseach library not found in $REDISEARCH_LIB"

    if [[ ! -d "$REDISEARCH_PATH" ]]; then
        echo "Rediseach not found in $REDIS_PATH"
        git clone https://github.com/RediSearch/RediSearch $REDISEARCH_PATH
        cd $REDISEARCH_PATH
        git checkout $REDISEARCH_BRANCH
        git submodule update --init --recursive
    fi

    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        cd $REDISEARCH_PATH
        $REDISEARCH_PATH/sbin/setup bash -l
        make build COORD=oss MT=1
    else
        cd $REDISEARCH_PATH
        $REDISEARCH_PATH/sbin/setup bash -l
        make build
    fi
fi

#---------------------------------------------- Run Redis Instance with Redisearch module ----------------------------------------------------------

echo "Killing existing redis server instances and remove rdb files..."
killall -9 redis-server

if [ "$REDIS_CLUSTER" -eq 1 ]; then
    cd $REDIS_PATH/utils/create-cluster
    REDISCLUSTER_SCRIPT=$REDIS_PATH/utils/create-cluster/create-cluster
    $REDISCLUSTER_SCRIPT stop
    $REDISCLUSTER_SCRIPT clean
    cd -
else
    rm -f ${REDIS_PATH}/*.rdb
fi

sleep 10

if [ "$REDIS_CLUSTER" -eq 1 ]; then
    cd $REDIS_PATH/utils/create-cluster
    REDISCLUSTER_CONFIG=$REDIS_PATH/utils/create-cluster/config.sh
    echo "PORT=$((PORT-1))" > $REDISCLUSTER_CONFIG
    echo "NODES=$CLUSTER_NODES" >> $REDISCLUSTER_CONFIG
    echo "REPLICAS=$CLUSTER_REPLICAS" >> $REDISCLUSTER_CONFIG
    echo "ADDITIONAL_OPTIONS='--loadmodule $REDISEARCH_LIB'" >> $REDISCLUSTER_CONFIG
    $REDISCLUSTER_SCRIPT start
    $REDISCLUSTER_SCRIPT create
    cd -
else
    cmd="numactl -m ${SERVER_SOCKET} -N ${SERVER_SOCKET} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --logfile $REDIS_PATH/server.log --loadmodule $REDISEARCH_LIB --save \"\""
    echo -e $cmd
    $cmd &
fi


Redis_Ping=$(${REDIS_PATH}/src/redis-cli -h localhost -p ${PORT} ping )
echo "Waiting for redis server to be ready..."
while [[ $Redis_Ping != *"PONG"* ]]; do
    sleep 1
    Redis_Ping=$(${REDIS_PATH}/src/redis-cli -h localhost -p ${PORT} ping )
    echo -ne "."
done


#-------------------------------------------------------- Run Vector-db-benchmark ------------------------------------------------------------------

REDIS_CLUSTER=$REDIS_CLUSTER REDIS_PORT=$PORT $PYTHON_PATH $VECTORDB_BENCHMARK_PATH/run.py --engines redis-m-$M-ef-$EF_CONSTRUCTION --datasets ${DATASET_DICT[$DATASET_SIZE]} --host localhost