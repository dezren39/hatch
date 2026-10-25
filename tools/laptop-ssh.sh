#!/usr/bin/env bash
# laptop-ssh.sh — SSH to Drew's AMD Framework laptop (amd-6, 100.99.113.103)
# over Tailscale, through this VM's tailnet tunnel proxy (port 3130).
# The proxy credential lives only in the session env (HTTPS_PROXY) and is
# read at runtime — nothing secret is stored in this script.
# Usage: laptop-ssh.sh [ssh args...] 'remote command'
# Default remote user is Drew's daily account "user".
set -euo pipefail
: "${HTTPS_PROXY:?HTTPS_PROXY must be set (runtime proxy env)}"
exec python3 - "$@" <<'PYEOF'
import os, sys, urllib.parse, subprocess
u = urllib.parse.urlparse(os.environ["HTTPS_PROXY"])
user = urllib.parse.unquote(u.username or "")
pw = urllib.parse.unquote(u.password or "")
host = u.hostname
proxycmd = f"socat - PROXY:{host}:100.99.113.103:22,proxyport=3130,proxyauth={user}:{pw}"
args = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "IdentitiesOnly=yes", "-i", os.path.expanduser("~/.ssh/id_ed25519"),
        "-o", f"ProxyCommand={proxycmd}", "-o", "ConnectTimeout=25",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=" + os.path.expanduser("~/.ssh/cm-%r@%h:%p"),
        "-o", "ControlPersist=600",
        "user@100.99.113.103"] + sys.argv[1:]
os.execvp("ssh", args)
PYEOF
