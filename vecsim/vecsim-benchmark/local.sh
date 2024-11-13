#----------------------------------- Check if Redis and RediSearch module exists if not prepare them ------------------------------------------------
if [ ! "$SKIP_SETUP" -eq 1 ]; then
    apt-get install -y numactl

    if [[ ! -d "$REDIS_PATH" ]]; then
        echo "Redis not found in $REDIS_PATH, downloading it ..."
        git clone https://github.com/redis/redis $REDIS_PATH
        cd $REDIS_PATH
        git checkout $REDIS_BRANCH
        make
        cd -
    fi

    if [[ ! -d "$BOOST_PATH" ]]; then
        echo "BOOST not found in $BOOST_PATH, downloading it ..."
	cd $HOME_PATH
        wget https://boostorg.jfrog.io/artifactory/main/release/1.82.0/source/boost_1_82_0.tar.gz
	tar -xvzf boost_1_82_0.tar.gz
	cd - 
    fi

    REDISEARCH_LIB=$REDIS_PATH/modules/redisearch/src/bin/linux-x64-release/search-community/redisearch.so

    if [[ ! -d "$REDISEARCH_LIB " ]]; then
        echo "Redisearch not found in $REDISEARCH_LIB, downloading it ..."
	cd $REDIS_PATH/modules/redisearch
	BOOST_DIR=$BOOST_PATH make	
        cd -
    fi



    #---------------------------------------------- Run Redis Instance with Redisearch module ----------------------------------------------------------

    echo "Killing existing redis server instances and remove rdb files..."
    killall -9 redis-server

    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        REDISCLUSTER_SCRIPT=$REDIS_PATH/utils/create-cluster/create-cluster-numa
        cp ./create-cluster-numa $REDISCLUSTER_SCRIPT
        cd $REDIS_PATH/utils/create-cluster
        $REDISCLUSTER_SCRIPT stop
        $REDISCLUSTER_SCRIPT clean
        cd -
    else
        rm -f ${REDIS_PATH}/*.rdb
    fi

    sleep 5

    if [ "$REDIS_CLUSTER" -eq 1 ]; then
        cd $REDIS_PATH/utils/create-cluster
        REDISCLUSTER_CONFIG=$REDIS_PATH/utils/create-cluster/config.sh
        echo "PORT=$((PORT-1))" > $REDISCLUSTER_CONFIG
        echo "NODES=$CLUSTER_NODES" >> $REDISCLUSTER_CONFIG
        echo "TIMEOUT=$CLUSTER_TIMEOUT" >> $REDISCLUSTER_CONFIG
        echo "REPLICAS=$CLUSTER_REPLICAS" >> $REDISCLUSTER_CONFIG
        echo "USE_NUMACTL=$USE_NUMACTL" >> $REDISCLUSTER_CONFIG
        echo "NUMA_NODES=$NUMA_NODES" >> $REDISCLUSTER_CONFIG
        echo "ADDITIONAL_OPTIONS='--save \"\" --loadmodule $REDISEARCH_LIB WORKERS 4 --protected-mode no --appendonly no'" >> $REDISCLUSTER_CONFIG
        $REDISCLUSTER_SCRIPT start
        echo "yes" | $REDISCLUSTER_SCRIPT create
        cd -
    else
	if [ "$USE_NUMACTL" -eq 1 ]; then
        	cmd="numactl -m ${NUMA_NODES} -N ${NUMA_NODES} $REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --logfile $REDIS_PATH/server.log --loadmodule $REDISEARCH_LIB --save \"\" --protected-mode no --appendonly no "
        	echo -e $cmd
        	$cmd &
	else
        	cmd="$REDIS_PATH/src/redis-server $REDIS_PATH/redis.conf --PORT ${PORT} --logfile $REDIS_PATH/server.log --loadmodule $REDISEARCH_LIB --save \"\" --protected-mode no --appendonly no"
        	echo -e $cmd
        	$cmd &
	fi
    fi
fi
