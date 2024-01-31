import urllib3
import os
import requests
import json
from requests.auth import HTTPBasicAuth

urllib3.disable_warnings()


SOURCE_MODULE = os.environ.get("SOURCE_MODULE", "/tmp/module.zip")
if not SOURCE_MODULE:
    print("SOURCE_MODULE variable not set")
    exit(1)

SOURCE_FQDN = os.environ.get("SOURCE_FQDN", "localhost")
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


def get_modules(fqdn, user, password):
    return requests.get(
        url="https://" + fqdn + ":9443/v1/modules",
        auth=HTTPBasicAuth(user, password),
        headers={
            "Content-Type": "application/json",
        },
        verify=False,
    )


def upload_module(fqdn, user, password, path):
    with open(path,'rb') as fp:
        file_data = fp.read()
    return requests.post(
        url="https://" + fqdn + ":9443/v1/modules",
        auth=HTTPBasicAuth(user, password),
        headers={
            "Content-Type": "application/zip",
        },
        data=file_data,
        verify=False,
    )


def main():
    w_resp = upload_module(SOURCE_FQDN, SOURCE_USER, SOURCE_PASSWORD,SOURCE_MODULE).content
    d = json.loads(w_resp)
    print(d)


if __name__ == "__main__":
    main()
