#!/bin/bash
set -e

source ips.sh
BDB=1

IP=$B_M1_E
IIP=$B_M1_I

ssh -o "StrictHostKeyChecking no" -i ${PEM} ${USER}@${IP} sudo /opt/redislabs/bin/rladmin tune db db:$BDB schedpolicy mnp
ssh -o "StrictHostKeyChecking no" -i ${PEM} ${USER}@${IP} sudo /opt/redislabs/bin/rladmin tune db db:$BDB conns 32

for ((c = 1; c <= $TOTAL_NODES; c++)); do
    varname=B_M${c}_E
    IP=${!varname}
    echo "Setting up proxy in node $c. EIP=$IP"
    ssh -o "StrictHostKeyChecking no" -i ${PEM} ${USER}@${IP} sudo \
        /opt/redislabs/bin/dmc_ctl restart &

done

wait
