#!/bin/bash
source ips.sh

# exit immediately on error
set -e

for ((c = 1; c <= $TOTAL_NODES; c++)); do
    varname=B_M${c}_E
    IP=${!varname}
    echo "Installing in node $c. EIP=$IP"
    ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} echo $IP
    scp -i ${PEM} ./license ${USER}@${IP}:/tmp/license.txt
    scp -i ${PEM} ./install.sh ${USER}@${IP}:/tmp/i.sh
    scp -i ${PEM} ./get-re-7.2.sh ${USER}@${IP}:/tmp/get-re-7.2.sh
    # scp -i ${PEM} $RE ${USER}@${IP}:/tmp/re.tar
    ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} chmod 755 /tmp/get-re-7.2.sh
    ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} sudo /tmp/get-re-7.2.sh
    ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} chmod 755 /tmp/i.sh
    ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} sudo /tmp/i.sh &
    # ssh -o "StrictHostKeyChecking no" -i ${PEM} -t ${USER}@${IP} sudo /opt/redislabs/sbin/prepare_flash.sh
done

echo "waiting for all installs to have finished"
wait
