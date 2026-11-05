#!/bin/bash
# rustdesk-gl/forward.sh — DEDICATED (non-multiplexed) SSH forward for the
# RustDesk client route: sandbox 127.0.0.1:21118 -> laptop 127.0.0.1:21118.
#
# Why dedicated (root cause, 2026-11-04, code#5509): the old route ran the
# -L forward through the SHARED laptop-ssh ControlMaster, whose single mux
# process also carries every other fleet session (25-min cargo test output,
# 1700s sleep-pollers, build watches). When the mux stalls, the forwarded
# RustDesk stream freezes in BOTH directions: the server logs
# "Connection closed: Timeout" after ~100-170s, the client shows
# "Connection error: Timeout", auto-reconnects, and each reconnect mints a
# new portal session + share picker on the laptop. A private ssh process
# (ControlMaster=no, ControlPath=none) removes the contention entirely;
# sessions then run indefinitely (proof: 6m47s+ and counting, 2026-11-04).
#
# Same proxy/hostkey posture as ~/tools/laptop-ssh.sh; only multiplexing
# differs. Requires HTTPS_PROXY in the environment (runtime proxy env).
set -euo pipefail
: "${HTTPS_PROXY:?HTTPS_PROXY must be set (runtime proxy env)}"
exec ssh -o ControlMaster=no -o ControlPath=none \
  -o "ProxyCommand=python3 $HOME/tools/laptop-proxy-connect.py" \
  -o "StrictHostKeyChecking=yes" \
  -o "UserKnownHostsFile=$HOME/.ssh/known_hosts_laptop" \
  -o "IdentitiesOnly=yes" -i "$HOME/.ssh/id_ed25519" \
  -o "ConnectTimeout=60" \
  -o "ServerAliveInterval=15" \
  -o "ServerAliveCountMax=8" \
  -o "ExitOnForwardFailure=yes" \
  -N -L 21118:127.0.0.1:21118 \
  user@100.99.113.103
