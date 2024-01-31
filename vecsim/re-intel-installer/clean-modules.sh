#!/bin/bash

source ips.sh

IP=$B_M1_E
IIP=$B_M1_I

scp -i ${PEM} clean-modules.py ${USER}@${IP}:/tmp/clean-modules.py
ssh -i ${PEM} -t ${USER}@${IP} sudo \
    python3 /tmp/clean-modules.py
