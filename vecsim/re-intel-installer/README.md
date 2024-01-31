# Scripts for preparing redis enterprise for vector-db benchmarking
Needs license file in re-intel-installer directory
## Steps to install:
### Edit ips.sh file with IPs
### Install redis enteprise on all nodes
./install-RE.sh

### Setup cluster (node 1 will create and 2nd to last will join)
./setup-cluster.sh

###  Get Latest RediSearch
./get-search.sh

###  Delete all modules from cluster
./clean-modules.sh

###  Upload the latest search module to the cluster
./upload-search.sh

###  Change parameters in create-db.py 
###  Run create-db.py


## Scripts explained
### install-RE.sh script:

Takes ip's from ips.sh file, and for each node from 1 to $TOTAL_NODES it copies license, install.sh, get-re-7.2.sh scripts into the machines from ips.sh file. Then it runs chmod 755 on all of these scripts and executes them.

### get-re-7.2.sh script:

It downloads the tar file from redis s3 bucket that contains redis-enterprise with redislabs

### Install.sh script:

Untars tar file from previous script, moves /etc/resolv.conf into /etc/resolv.conf.orig and replaces it with /etc/systemd/resolved.conf with added "DNSStubListener=no". Then it restarts systemd-resolved service and runs install script of redis-enterprise

### Setup-cluster.sh script:
Takes ip's from ips.sh file, first node creates cluster with username: performance@redislabs.com with password performance, and all the other nodes from ips.sh file joins the cluster

### Get-search.sh script:
It downloads the zip file from redis s3 bucket with redisearch for appropriate OS

### Clean-modules.sh script:
Copies clean-modules.py file into every node from ips.sh

### Clean-modules.py script:
Uses redis enterprise API to get all modules loaded into the cluster and then remove them

### Upload-search.sh script:
Uploads the downloaded redisearch module via API to redis enterprise cluster

### Create-db.sh script:
Copies create-db.py script to main node and run it

### Create-db.py script:
Creates database with various settings from env variables such as:

- NODES
- SHARD_COUNT 
- MODULE_VERSION 
- WORKER_THREADS 
- CLUSTER_ENABLED

All happens through redis enterprise API