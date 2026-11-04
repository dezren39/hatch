#!/usr/bin/env bash
# laptop-ssh.sh — SSH to Drew's AMD Framework laptop (amd, 100.99.113.103)
# over Tailscale, through this VM's tailnet tunnel proxy (port 3130).
#
# Security posture (fixed 2026-10-26, cf. code issue #948):
# - The proxy credential is read from the HTTPS_PROXY env at runtime by
#   ~/tools/laptop-proxy-connect.py and sent only inside the CONNECT
#   request — it never appears in any process argv (the old socat
#   ProxyCommand embedded proxyauth= in the argv of ssh AND socat).
# - Host key verification is ON: the laptop's ed25519 host key is pinned
#   in ~/.ssh/known_hosts_laptop (captured from the host itself over the
#   established channel). No more StrictHostKeyChecking=no.
# - No heredoc: stdin passes straight through to ssh (the old python
#   heredoc ate piped stdin, breaking sudo -S and password feeds).
#
# Usage: laptop-ssh.sh [ssh args...] 'remote command'
# Default remote user is Drew's daily account "user".
# Previous version: ~/tools/laptop-ssh.sh.bak-2026-10-26
set -euo pipefail
: "${HTTPS_PROXY:?HTTPS_PROXY must be set (runtime proxy env)}"
exec ssh \
  -o "ProxyCommand=python3 $HOME/tools/laptop-proxy-connect.py" \
  -o "StrictHostKeyChecking=yes" \
  -o "UserKnownHostsFile=$HOME/.ssh/known_hosts_laptop" \
  -o "IdentitiesOnly=yes" -i "$HOME/.ssh/id_ed25519" \
  -o "ConnectTimeout=60" \
  -o "ConnectionAttempts=3" \
  -o "ServerAliveInterval=15" \
  -o "ServerAliveCountMax=8" \
  -o "ControlMaster=auto" \
  -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p" \
  -o "ControlPersist=3600" \
  "user@100.99.113.103" "$@"
