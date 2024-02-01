#!/bin/bash

#------------------------------------------------------ check if user is sudo or root ---------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	  echo "This script must be run as root."
	    exit 1
fi

#------------------------------------------------------ load config file ---------------------------------------------------------------
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
    # TODO: Add redis installation
    echo "Redis directory not found. Please be sure redis istalled to the path: $REDIS_PATH"
    exit 1
fi
if [[ ! -e $REDISEARCH_PATH/bin/linux-x64-release/search/redisearch.so ]]; then
    # TODO: Add redisearch building
    echo "redisearch.so library not found. Please be sure redisearch library is in path: $REDISEARCH_PATH/bin/linux-x64-release/search/redisearch.so"
    exit 1
fi

