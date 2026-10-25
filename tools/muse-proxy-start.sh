#!/bin/bash
# Start wrapper for muse-proxy (~/tools/muse-proxy/muse-proxy.mjs).
# A systemd service inherits neither the sandbox egress proxy nor any
# session env, so the network env the `muse` CLI children need is pinned
# here. The proxy ALSO enforces this env for its spawned children itself
# (deletes META_API_KEY, pins the proxy + CA), so this is belt-and-braces
# and documentation of the requirement in one place.
export HOME=/home/hatch
# Port 18747 — NOT the proxy's built-in default 18746: that port is claimed
# by design-code-proxy in Drew's home-manager config (developing-today/code,
# home/common/default.nix). 18747 is this sandbox deployment's port.
export MUSE_PROXY_PORT=${MUSE_PROXY_PORT:-18747}
# Unauthenticated egress proxy (the per-session credential URL rotates and
# must never be baked into service files) + sandbox CA bundle. Verified
# 2026-10-21: headless `muse exec` reaches Meta only with these set.
export HTTPS_PROXY=http://hatch-egress-proxy:3128
export HTTP_PROXY=http://hatch-egress-proxy:3128
export https_proxy=http://hatch-egress-proxy:3128
export http_proxy=http://hatch-egress-proxy:3128
export SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
# META_API_KEY takes priority over the CLI's OAuth account login and bills
# a separate pay-as-you-go wallet (402 until funded) — it must be absent.
unset META_API_KEY
exec /usr/bin/node /home/hatch/tools/muse-proxy/muse-proxy.mjs
