#!/bin/bash

source ips.sh
MODULE="/tmp/module.zip"

IP=$B_M1_E
IIP=$B_M1_I

scp -i ${PEM} $MODULE ${USER}@${IP}:/tmp/module.zip

ssh -i ${PEM} -t ${USER}@${IP} sudo \
    curl -L -k -u "performance@redislabs.com:performance" -X POST -F "module=@/tmp/module.zip" https://localhost:9443/v1/modules
