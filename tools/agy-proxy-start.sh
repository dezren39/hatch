#!/bin/bash
# Start wrapper for agy-proxy (~/tools/agy-proxy/agy-proxy.mjs, copied
# verbatim from developing-today/code bin/agy-proxy.mjs).
# A systemd service inherits neither the sandbox egress proxy nor any
# session env, so the network env the spawned `agy` CLI children need is
# pinned here (same treatment as muse-proxy-start.sh: the per-session
# credential URL rotates and must never be baked into service files —
# the UNAUTHENTICATED egress proxy is the stable endpoint).
export HOME=/home/hatch
# Port 18743 is the fleet's agy-proxy port (developing-today/code,
# home/common/default.nix: agyProxyPort = 18743) and the port the
# sandbox's deployed OpenCode provider `antigravity-agy` points at.
export AGY_PROXY_PORT=${AGY_PROXY_PORT:-18743}
export AGY_PROXY_HOST=127.0.0.1
# agy resolution for the proxy's findAgyBinary(): the nix-profile build
# lands at /usr/local/bin/agy (nix-profile-sync); keep the fleet's own
# candidate dirs on PATH too.
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.gemini/bin:$PATH"
export HTTPS_PROXY=http://hatch-egress-proxy:3128
export HTTP_PROXY=http://hatch-egress-proxy:3128
export https_proxy=http://hatch-egress-proxy:3128
export http_proxy=http://hatch-egress-proxy:3128
export SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
exec /usr/bin/node /home/hatch/tools/agy-proxy/agy-proxy.mjs
