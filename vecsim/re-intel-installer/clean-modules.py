import urllib3
import os
import requests
import json
from requests.auth import HTTPBasicAuth

urllib3.disable_warnings()

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


def delete_module(fqdn, user, password, uid):
    return requests.delete(
        url="https://" + fqdn + ":9443/v1/modules/" + uid,
        auth=HTTPBasicAuth(user, password),
        headers={
            "Content-Type": "application/json",
        },
        verify=False,
    )


def clean_modules():
    print("Initial modules list:")
    w_resp = get_modules(SOURCE_FQDN, SOURCE_USER, SOURCE_PASSWORD).content
    d = json.loads(w_resp)
    print(d)
    for module in d:
        print(module["display_name"],module)

    d = json.loads(w_resp)
    for module in d:
        print("Deleting " + module["display_name"])
        delete_module(SOURCE_FQDN, SOURCE_USER, SOURCE_PASSWORD, module["uid"])

    print("Final modules list:")
    w_resp = get_modules(SOURCE_FQDN, SOURCE_USER, SOURCE_PASSWORD).content
    d = json.loads(w_resp)
    print(d)


def main():
    clean_modules()


if __name__ == "__main__":
    main()
