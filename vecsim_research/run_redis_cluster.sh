#!/bin/bash
echo "REDIS_DIR=${REDIS_DIR}"
echo "CLUSTER_PATH=${CLUSTER_PATH}"
echo "REDISEARCH_PATH=${REDISEARCH_PATH}"
echo "Nodes number=$1"
echo "Start with port=$2"

cluster_creation="$REDIS_DIR/src/redis-cli --cluster create"

for x in `seq 0 $(($1-1))`;
do
    port=$(($2+$x))
    mkdir $CLUSTER_PATH/$port
    cd $CLUSTER_PATH/$port
    cp $REDIS_DIR/redis.conf ./redis.conf
    echo "port $port
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
appendonly yes" >> ./redis.conf
    $REDIS_DIR/src/redis-server redis.conf --loadmodule $REDISEARCH_PATH > $port.log 2>&1 &
    cluster_creation="$cluster_creation 127.0.0.1:$port"
done
sleep 10
cluster_creation="$cluster_creation --cluster-replicas 1"
eval $cluster_creation
echo "Cluster created"
