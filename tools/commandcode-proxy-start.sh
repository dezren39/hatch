#!/bin/bash
# Start wrapper for commandcode-proxy (~/tools/commandcode-proxy/commandcode-proxy.mjs).
# A systemd service inherits neither the sandbox egress proxy nor any
# session env, so the network env the `commandcode` CLI children need is
# pinned here. The proxy ALSO enforces this env for its spawned children
# itself, so this is belt-and-braces and documentation of the requirement
# in one place.
export HOME=/home/hatch
# Port 18748 — free in the fleet map (18742 clef, 18743 agy, 18744 codex,
# 18745 antigravity-ls, 18746 design-code, 18747 muse).
export COMMANDCODE_PROXY_PORT=${COMMANDCODE_PROXY_PORT:-18748}
# One CLI turn per chat completion: this is a chat bridge, not an agent
# session — multi-turn runs took ~208s for a trivial reply (2026-10-24).
export COMMANDCODE_PROXY_MAX_TURNS=1
export COMMANDCODE_PROXY_HOST=127.0.0.1
export PATH="/home/hatch/tools/command-code/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
# Unauthenticated egress proxy (the per-session credential URL rotates and
# must never be baked into service files) + sandbox CA bundle.
export HTTPS_PROXY=http://hatch-egress-proxy:3128
export HTTP_PROXY=http://hatch-egress-proxy:3128
export https_proxy=http://hatch-egress-proxy:3128
export http_proxy=http://hatch-egress-proxy:3128
export SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
# REQUIRED for the commandcode CLI (a Node app): without this its fetch()
# ignores the *_PROXY vars above and tries a direct connection, which
# fails ("Unable to connect to the API"). The proxy also sets this for
# its children itself.
export NODE_USE_ENV_PROXY=1
export ALL_PROXY=http://hatch-egress-proxy:3128
export all_proxy=http://hatch-egress-proxy:3128
export NO_PROXY=127.0.0.1,localhost
export no_proxy=127.0.0.1,localhost
exec /usr/bin/node /home/hatch/tools/commandcode-proxy/commandcode-proxy.mjs
