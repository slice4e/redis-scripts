#----------------------------------- Check if Redis and RediSearch module exists if not prepare them ------------------------------------------------
if [ ! "$SKIP_SETUP" -eq 1 ]; then
    $SSH_COMMAND apt-get install -y numactl
    if $SSH_COMMAND [ ! -d "$REDIS_PATH" ]; then
        echo "Redis not found in $REDIS_PATH, downloading it ..."
        $SSH_COMMAND "git clone https://github.com/redis/redis $REDIS_PATH"
        $SSH_COMMAND "cd $REDIS_PATH && git checkout $REDIS_BRANCH && make && cd -"
    fi
    #install redis locally as well, since we are using redis-cli
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


    if $SSH_COMMAND [ ! -e \"$REDISEARCH_LIB\" ]; then
        echo "Rediseach library not found in $REDISEARCH_LIB"

        if $SSH_COMMAND [ ! -d \"$REDISEARCH_PATH\" ]; then
            echo "Rediseach not found in $REDISEARCH_PATH"
            $SSH_COMMAND "git clone https://github.com/RediSearch/RediSearch $REDISEARCH_PATH"
            $SSH_COMMAND "cd $REDISEARCH_PATH && git checkout $REDISEARCH_BRANCH && git submodule update --init --recursive"
        fi

        if [ "$REDIS_CLUSTER" -eq 1 ]; then
            $SSH_COMMAND "cd $REDISEARCH_PATH && $REDISEARCH_PATH/sbin/setup bash -l && make build COORD=oss MT=1"
        else
            $SSH_COMMAND "cd $REDISEARCH_PATH && $REDISEARCH_PATH/sbin/setup bash -l && make build"
        fi
    fi

    #---------------------------------------------- Run Redis Instance with Redisearch module ----------------------------------------------------------

    echo "Killing existing redis server instances and remove rdb files..."
    $SSH_COMMAND "killall -9 redis-server"

    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        REDISCLUSTER_SCRIPT=$REDIS_PATH/utils/create-cluster/create-cluster-numa
        scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ./create-cluster-numa ${LOGIN_ID}@${TARGET}:$REDISCLUSTER_SCRIPT
        $SSH_COMMAND "cd $REDIS_PATH/utils/create-cluster && $REDISCLUSTER_SCRIPT stop && $REDISCLUSTER_SCRIPT clean && cd -"
    else
        $SSH_COMMAND "rm -f ${REDIS_PATH}/*.rdb"
    fi

    sleep 5

    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        
        REDISCLUSTER_CONFIG=$REDIS_PATH/utils/create-cluster/config.sh
        $SSH_COMMAND "echo "PORT=$((PORT-1))" > $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "NODES=$CLUSTER_NODES" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "REPLICAS=$CLUSTER_REPLICAS" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "TIMEOUT=$CLUSTER_TIMEOUT" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "CLUSTER_HOST=$TARGET" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "USE_NUMACTL=$USE_NUMACTL" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "NUMA_NODES=$NUMA_NODES" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo \"ADDITIONAL_OPTIONS='--save \"\" --loadmodule \"$REDISEARCH_LIB\" --protected-mode no --appendonly no'\" >> \"$REDISCLUSTER_CONFIG\""
        $SSH_COMMAND "cd $REDIS_PATH/utils/create-cluster && $REDISCLUSTER_SCRIPT start && echo "yes" | $REDISCLUSTER_SCRIPT create && cd -"
        sleep 5
    else
	if [ "$USE_NUMACTL" -eq 1 ]; then
        	cmd="numactl -m ${NUMA_NODES} -N ${NUMA_NODES} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --bind $TARGET --protected-mode no --logfile $REDIS_PATH/server.log --loadmodule $REDISEARCH_LIB --save \"\" --appendonly no"
        	echo -e $cmd
        	nohup $SSH_COMMAND "$cmd &" &
	else
        	cmd="$REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --bind $TARGET --protected-mode no --logfile $REDIS_PATH/server.log --loadmodule $REDISEARCH_LIB --save \"\" --appendonly no"
        	echo -e $cmd
        	nohup $SSH_COMMAND "$cmd &" &

	fi
    fi
fi
