import urllib3
import os
import requests
import json
from requests.auth import HTTPBasicAuth

urllib3.disable_warnings()

NODES = int(os.environ.get("NODES", "5"))
SHARD_COUNT = int(os.environ.get("SHARD_COUNT", "200"))
MEMORY_SIZE = int(1024 * 1024 * 1024 * SHARD_COUNT * 25)
MODULE_VERSION = os.environ.get("MODULE_VERSION", "2.10.4")
WORKER_THREADS = int(os.environ.get("WORKER_THREADS", "5"))

SHARDING_ENABLED = False


CLUSTER_ENABLED = bool(os.environ.get("CLUSTER_ENABLED", "1"))
if SHARD_COUNT > 1:
    SHARDING_ENABLED = True


SOURCE_PORT = int(os.environ.get("SOURCE_PORT", "12000"))
SOURCE_FQDN = os.environ.get("SOURCE_FQDN", "localhost")

#SOURCE_FQDN = os.environ.get("SOURCE_FQDN", "localhost")
if not SOURCE_FQDN:
    print("SOURCE_FQDN variable not set")
    exit(1)

SOURCE_USER = os.environ.get("SOURCE_USER", "performance@redislabs.com")
if not SOURCE_USER:
    print("SOURCE_USER variable not set")
    exit(1)

SOURCE_PASSWORD = os.environ.get("SOURCE_PASSWORD", "performance")
if not SOURCE_USER:
    print("SOURCE_PASSWORD variable not set")
    exit(1)


def create_db(data, fqdn, user, password):
    return requests.post(
        url="https://" + fqdn + ":9443/v1/bdbs",
        auth=HTTPBasicAuth(user, password),
        headers={
            "Content-Type": "application/json",
        },
        data=json.dumps(data),
        verify=False,
    )


def get_modules(fqdn, user, password):
    return requests.get(
        url="https://" + fqdn + ":9443/v1/modules",
        auth=HTTPBasicAuth(user, password),
        headers={
            "Content-Type": "application/json",
        },
        verify=False,
    )


def create_sourcedb():
    req = {
        "name": "NODES-{}-SHARDS-{}-WORKERS-{}".format(
            NODES, SHARD_COUNT, WORKER_THREADS
        ),
        "port": SOURCE_PORT,
        "type": "redis",
        "replication": False,
        "memory_size": MEMORY_SIZE,
        "sharding": SHARDING_ENABLED,
        "shards_count": SHARD_COUNT,
        "oss_cluster": CLUSTER_ENABLED,
        "sched_policy": "mnp",
        "conns": 32,
        "proxy_policy": "all-master-shards",
        "shard_key_regex": [{"regex": ".*\\{(?<tag>.*)\\}.*"}, {"regex": "(?<tag>.*)"}],
        "module_list": [
            {
                "module_args": "PARTITIONS AUTO WORKERS {} MIN_OPERATION_WORKERS {}".format(
                    WORKER_THREADS, WORKER_THREADS
                ),
                "semantic_version": MODULE_VERSION,
                "module_name": "search",
            }
        ],
    }
    w_resp = create_db(req, SOURCE_FQDN, SOURCE_USER, SOURCE_PASSWORD).content

    print(w_resp)

    source_endpoint = str.format(
        "redis-{}.internal.{}:{}", SOURCE_PORT, SOURCE_FQDN, SOURCE_PORT
    )
    return source_endpoint


def main():
    print("Initial modules list:")
    w_resp = get_modules(SOURCE_FQDN, SOURCE_USER, SOURCE_PASSWORD).content
    d = json.loads(w_resp)
    for module in d:
        print(module["display_name"])
        print(module)

    source_endpoint = create_sourcedb()
    print("Source endpoint: " + source_endpoint)


if __name__ == "__main__":
    main()
