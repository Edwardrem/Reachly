"""Writes the client side of the demo fleet into the state folder, from the keys up.sh generated there.

  ssh_config            for OpenSSH: ssh -F ssh_config web-01 (jumps through the bastion)
  known_hosts           the four servers' host keys, so ssh checks them instead of trusting on first use
  reachly-demo.reachly  for Reachly: File > Import... adds the four hosts, the jump host, the key, the
                        host keys and the AI permission modes the recorded demo started with

Usage: python3 write_configs.py STATE_DIR BASTION_PORT
"""
import base64
import datetime as dt
import hashlib
import json
import os
import sys

HOSTS = ["bastion", "web-01", "db-01", "build-box"]

# Fixed ids, so importing the file again updates these records instead of adding copies.
PRODUCTION = "9E7BF34E-06FD-4E91-A76E-6813232EC247"
LAB = "DC04B630-5D3C-4514-829E-A426EBB1068B"
IDENTITY = "B4B4AE43-0FA8-4BE0-80FA-B09DAA19223A"
HOST_IDS = {
    "bastion": "9FEFE705-4DE5-44A9-B29A-C9D43D89BBCE",
    "web-01": "21B5FDA0-661A-4CD7-A36A-C007DF572291",
    "db-01": "5424EF02-6D99-4EB0-B9F6-00D4D8C64709",
    "build-box": "C57EB4BC-3AB1-4D66-98CC-682DDE6077EF",
}


def public_key(path):
    """The "type base64" part of an OpenSSH public key file, and its SHA256 fingerprint as ssh-keygen -l prints it."""
    key_type, blob = open(path).read().split()[:2]
    digest = hashlib.sha256(base64.b64decode(blob)).digest()
    return f"{key_type} {blob}", key_type, "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def quoted(path):
    return '"' + path.replace('"', '\\"') + '"'


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    state = os.path.abspath(sys.argv[1])
    port = int(sys.argv[2])
    key = os.path.join(state, "id_ed25519")
    known = os.path.join(state, "known_hosts")
    host_keys = {h: public_key(os.path.join(state, "keys", h, "host_key.pub")) for h in HOSTS}

    # OpenSSH: the bastion is the only published port; the others are reached through it by name.
    with open(os.path.join(state, "ssh_config"), "w") as f:
        f.write(f"# Written by demo/fleet/up.sh for the Reachly demo fleet. Use it with: ssh -F {quoted(os.path.join(state, 'ssh_config'))} web-01\n")
        f.write(f"Host bastion\n  HostName 127.0.0.1\n  Port {port}\n  User jump\n")
        f.write("Host web-01 db-01 build-box\n  User deploy\n  ProxyJump bastion\n")
        f.write(f"Host {' '.join(HOSTS)}\n  IdentityFile {quoted(key)}\n  IdentitiesOnly yes\n"
                f"  UserKnownHostsFile {quoted(known)}\n  StrictHostKeyChecking yes\n  LogLevel ERROR\n")
    with open(known, "w") as f:
        for h in HOSTS:
            name = f"[127.0.0.1]:{port}" if h == "bastion" else h
            f.write(f"{name} {host_keys[h][0]}\n")

    # Reachly: the same fleet as the recorded demo, as a plain (unencrypted, secret-free) .reachly file.
    client_key, client_type, client_fingerprint = public_key(key + ".pub")
    host = dict(authMethod="privateKey", autoReconnect=True, identityID=IDENTITY, inheritsGroupJumpHost=True,
                inheritsGroupProxy=True, port=22, shellIntegration="automatic", username="deploy",
                agentPermission="read-only", agentAllowlist=[], notes="", tags=[])
    document = {
        "format": "reachly",
        "schemaVersion": 1,
        "exportedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "appVersion": "demo-fleet",
        "groups": [
            {"id": PRODUCTION, "name": "Production", "sortOrder": 0, "colorLabel": "#FF5F57"},
            {"id": LAB, "name": "Lab", "sortOrder": 1, "colorLabel": "#5E9CFF", "themeID": "builtin:gruvbox-dark"},
        ],
        "hosts": [
            dict(host, id=HOST_IDS["bastion"], name="bastion", hostname="127.0.0.1", port=port, username="jump",
                 colorLabel="#FF9F0A", tags=["jump"], sortOrder=0),
            dict(host, id=HOST_IDS["web-01"], name="web-01", hostname="web-01", groupID=PRODUCTION,
                 jumpHostID=HOST_IDS["bastion"], tags=["web"], notes="Shop front end. nginx in front of the orders API.",
                 sortOrder=0),
            dict(host, id=HOST_IDS["db-01"], name="db-01", hostname="db-01", groupID=PRODUCTION,
                 jumpHostID=HOST_IDS["bastion"], tags=["db"], sortOrder=1),
            dict(host, id=HOST_IDS["build-box"], name="build-box", hostname="build-box", groupID=LAB,
                 jumpHostID=HOST_IDS["bastion"], colorLabel="#34C759", tags=["ci"], themeID="builtin:nord", sortOrder=0),
        ],
        "identities": [
            {"id": IDENTITY, "name": "Reachly demo key", "username": "deploy", "credentialKind": "keyFile",
             "privateKeyPath": key, "publicKey": client_key, "keyType": client_type, "fingerprint": client_fingerprint},
        ],
        "knownHosts": [
            {"host": "127.0.0.1" if h == "bastion" else h, "port": port if h == "bastion" else 22,
             "keyType": host_keys[h][1], "publicKey": host_keys[h][0], "fingerprintSHA256": host_keys[h][2]}
            for h in HOSTS
        ],
    }
    with open(os.path.join(state, "reachly-demo.reachly"), "w") as f:
        json.dump(document, f, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
