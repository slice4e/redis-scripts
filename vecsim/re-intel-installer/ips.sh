#!/bin/bash

USER=ubuntu
PEM=${PEM:-"~/redislabs/pems/perf-cto-us-east-2.pem"}

TOTAL_NODES=2

CLUSTER_NAME="${TOTAL_NODES}_nodes_laion400m"

#internal IP addresses
B_M1_I=1.2.3.4
B_M2_I=1.2.3.5

#external IP addresses
B_M1_E=1.2.3.4
B_M2_E=1.2.3.5
