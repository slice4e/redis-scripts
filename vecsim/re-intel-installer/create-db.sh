#!/bin/bash

source ips.sh
USER=ubuntu

IP=$B_M1_E
IIP=$B_M1_I

scp -i ${PEM} create-db.py ${USER}@${IP}:/tmp/create-db.py
ssh -i ${PEM} -t ${USER}@${IP} sudo \
    python3 /tmp/create-db.py
