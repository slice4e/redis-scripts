#!/bin/bash

source ips.sh

IP=$B_M1_E
IIP=$B_M1_I

scp -i ${PEM} license ${USER}@${IP}:/tmp/license.txt
ssh -i ${PEM} -t ${USER}@${IP} sudo \
    /opt/redislabs/bin/rladmin cluster create name $CLUSTER_NAME \
    username performance@redislabs.com password performance license_file /tmp/license.txt

ssh -i ${PEM} -t ${USER}@${IP} sudo \
    /opt/redislabs/bin/rladmin tune cluster default_shards_placement sparse

# join cluster
for ((c = 2; c <= $TOTAL_NODES; c++)); do
    varname=B_M${c}_E
    IP=${!varname}
    ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} sudo \
        /opt/redislabs/bin/rladmin cluster join nodes ${IIP} \
        username performance@redislabs.com password performance
done
