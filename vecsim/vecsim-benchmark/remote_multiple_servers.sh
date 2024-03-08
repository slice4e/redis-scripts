#----------------------------------- Check if Redis and RediSearch module exists if not prepare them ------------------------------------------------
if [ ! "$SKIP_SETUP" -eq 1 ]; then
    for server in "${CLUSTER_SERVERS[@]}";
    do
        SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${server}"
        $SSH_COMMAND apt-get install -y numactl
        if $SSH_COMMAND [ ! -d "$REDIS_PATH" ]; then
            echo "Redis not found in $REDIS_PATH, downloading it ..."
            $SSH_COMMAND "git clone https://github.com/redis/redis $REDIS_PATH"
            $SSH_COMMAND "cd $REDIS_PATH && git checkout $REDIS_BRANCH && make && cd -"
        fi

        REDISEARCH_LIB=$REDISEARCH_PATH/bin/linux-x64-release/coord-oss/module-oss.so

        if $SSH_COMMAND [ ! -e \"$REDISEARCH_LIB\" ]; then
            echo "Rediseach library not found in $REDISEARCH_LIB"

            if $SSH_COMMAND [ ! -d \"$REDISEARCH_PATH\" ]; then
                echo "Rediseach not found in $REDISEARCH_PATH"
                $SSH_COMMAND "git clone https://github.com/RediSearch/RediSearch $REDISEARCH_PATH"
                $SSH_COMMAND "cd $REDISEARCH_PATH && git checkout $REDISEARCH_BRANCH && git submodule update --init --recursive"
            fi

            $SSH_COMMAND "cd $REDISEARCH_PATH && $REDISEARCH_PATH/sbin/setup bash -l && make build COORD=oss MT=1"

        fi
    done

    #---------------------------------------------- Run Redis Instance with Redisearch module ----------------------------------------------------------

    for server in "${CLUSTER_SERVERS[@]}";
    do
        SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${server}" 
        echo "Killing existing redis server instances and remove rdb files..."
        $SSH_COMMAND "killall -9 redis-server"

        if [ "$REDIS_CLUSTER" -eq 1 ]; then
            REDISCLUSTER_SCRIPT=$REDIS_PATH/utils/create-cluster/create-cluster-numa
            scp -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} ./create-cluster-numa ${LOGIN_ID}@${server}:$REDISCLUSTER_SCRIPT
            $SSH_COMMAND "cd $REDIS_PATH/utils/create-cluster && $REDISCLUSTER_SCRIPT stop && $REDISCLUSTER_SCRIPT clean && cd -"
        else
            $SSH_COMMAND "rm -f ${REDIS_PATH}/*.rdb"
        fi
        sleep 2

        REDISCLUSTER_CONFIG=$REDIS_PATH/utils/create-cluster/config.sh
        $SSH_COMMAND "echo "PORT=$((PORT-1))" > $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "NODES=$CLUSTER_NODES" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "REPLICAS=$CLUSTER_REPLICAS" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "TIMEOUT=$CLUSTER_TIMEOUT" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "CLUSTER_HOST=$server" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "USE_NUMACTL=1" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo "SERVER_SOCKET=$SERVER_SOCKET" >> $REDISCLUSTER_CONFIG"
        $SSH_COMMAND "echo \"ADDITIONAL_OPTIONS='--save \"\" --loadmodule \"$REDISEARCH_LIB\" --protected-mode no --appendonly no'\" >> \"$REDISCLUSTER_CONFIG\""
        $SSH_COMMAND "cd $REDIS_PATH/utils/create-cluster && $REDISCLUSTER_SCRIPT start"
    done
    sleep 2
    SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${CLUSTER_MASTER}"
    ENDPORT=$((PORT+CLUSTER_NODES-1))
    STARTPORT=$PORT
    HOSTS=""
    while [ $((STARTPORT < ENDPORT)) != "0" ]; do
        for server in "${CLUSTER_SERVERS[@]}";
        do
            HOSTS="$HOSTS $server:$STARTPORT"
        done
        STARTPORT=$((STARTPORT+1))
    done
    $SSH_COMMAND "echo "yes" | $REDIS_PATH/src/redis-cli --cluster create $HOSTS --cluster-replicas $CLUSTER_REPLICAS"
fi
