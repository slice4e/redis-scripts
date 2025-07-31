if [ ! "$SKIP_SETUP" -eq 1 ]; then
    set -x
    RE_INSTALLER_PATH=$HOME_PATH/RE_installer
    # Download RE on each node
    for server in "${RE_SERVERS[@]}";
    do
        SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${server}"
        if $SSH_COMMAND [ ! -d "$RE_INSTALLER_PATH" ]; then
            $SSH_COMMAND wget $RE_URL -O $HOME_PATH/redis.tar
            $SSH_COMMAND "mkdir $RE_INSTALLER_PATH && tar -xvf $HOME_PATH/redis.tar -C $RE_INSTALLER_PATH"
        fi
        $SSH_COMMAND "cd $RE_INSTALLER_PATH && ./install.sh -y"
    done

    # Download RediSearch on master node and create cluster
    SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${CLUSTER_MASTER}"
    REDISEARCH_ENTERPRISE_PATH=$HOME_PATH/redisearch.zip
    if $SSH_COMMAND [ ! -e "$REDISEARCH_ENTERPRISE_PATH" ]; then
        $SSH_COMMAND wget $REDISEARCH_URL -O $HOME_PATH/redisearch.zip
    fi
    $SSH_COMMAND /opt/redislabs/bin/rladmin cluster create name intel-demo addr "$CLUSTER_MASTER" username $RE_USERNAME password $RE_PASSWORD license_file $LICENSE_PATH
    $SSH_COMMAND curl -L -k -u "$RE_USERNAME:$RE_PASSWORD" -X POST -F "module=@$HOME_PATH/redisearch.zip" https://localhost:9443/v1/modules

    # Join all the other nodes to RE cluster
    for server in "${RE_SERVERS[@]}";
    do
        if [[ "$server" == "$cluster_master" ]]; then
            echo "Skipping cluster master"
        else
            SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${server}"
            $SSH_COMMAND /opt/redislabs/bin/rladmin cluster join nodes $CLUSTER_MASTER username $RE_USERNAME password $RE_PASSWORD addr $server
        fi
    done

    # Setup database
    NUMBER_OF_NODES=${#RE_SERVERS[@]}
    SSH_COMMAND="ssh -t -o PreferredAuthentications=publickey -i ${SSH_KEY_PATH}/${SSH_KEY_NAME} $LOGIN_ID@${CLUSTER_MASTER}"
    scp ./create-db-2.10.4.py $LOGIN_ID@$CLUSTER_MASTER:$HOME_PATH/create-db-2.10.4.py
    $SSH_COMMAND NODES=$NUMBER_OF_NODES SHARD_COUNT=$SHARD_COUNT WORKER_THREADS=$WORKER_THREADS $PYTHON_PATH $HOME_PATH/create-db-2.10.4.py
fi