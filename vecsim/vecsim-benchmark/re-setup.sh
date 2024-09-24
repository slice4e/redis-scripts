if [ ! "$SKIP_SETUP" -eq 1 ]; then
    # Download RE on each node
    for server in "${RE_SERVERS[@]}";
        SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${server}"
        $SSH_COMMAND wget $RE_URL $REDIS_PATH
        $SSH_COMMAND $REDIS_PATH/install.sh -y
    done

    # Download RediSearch on master node and create cluster
    SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${CLUSTER_MASTER}"
    $SSH_COMMAND wget $REDISEARCH_URL $HOME_PATH/redisearch.zip
    $SSH_COMMAND /opt/redislabs/bin/rladmin cluster create name intel-demo addr "$CLUSTER_MASTER" username $RE_USERNAME password $RE_PASSWORD license_file $LICENSE_PATH
    $SSH_COMMAND curl -L -k -u "$RE_USERNAME:$RE_PASSWORD" -X POST -F "module=@$HOME_PATH/redisearch.zip" https://localhost:9443/v1/modules

    # Join all the other nodes to RE cluster
    for server in "${RE_SERVERS[@]}";
        SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${server}"
        $SSH_COMMAND /opt/redislabs/bin/rladmin cluster join nodes $CLUSTER_MASTER username $RE_USERNAME password $RE_PASSWORD addr $server
    done

    # Setup database
    SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} -q ${LOGIN_ID}@${CLUSTER_MASTER}"
    scp ./create-db-2.10.4.py $LOGIN_ID@$CLUSTER_MASTER:$HOME_PATH/create-db-2.10.4.py
    $SSH_COMMAND SHARD_COUNT=$SHARD_COUNT WORKER_THREADS=$WORKER_THREADS python3 $HOME_PATH/create-db-2.10.4.py
fi