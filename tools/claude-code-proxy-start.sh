#!/bin/bash
# Start wrapper for claude-code-proxy (~/tools/claude-code-proxy/claude-code-proxy.mjs).
# A systemd service inherits neither the sandbox egress proxy nor any
# session env, so the network env the `claude` CLI children need is
# pinned here. The proxy ALSO enforces this env for its spawned children
# itself (deletes ANTHROPIC_API_KEY, pins the proxy + CA), so this is
# belt-and-braces and documentation of the requirement in one place.
export HOME=/home/hatch
# Port 18749 — the next free port in the fleet map (18742 clef, 18743
# agy, 18744 codex, 18745 antigravity-ls, 18746 design-code, 18747 muse,
# 18748 commandcode).
export CLAUDE_CODE_PROXY_PORT=${CLAUDE_CODE_PROXY_PORT:-18749}
export CLAUDE_CODE_PROXY_HOST=127.0.0.1
# Unauthenticated egress proxy (the per-session credential URL rotates
# and must never be baked into service files) + sandbox CA bundle.
export HTTPS_PROXY=http://hatch-egress-proxy:3128
export HTTP_PROXY=http://hatch-egress-proxy:3128
export https_proxy=http://hatch-egress-proxy:3128
export http_proxy=http://hatch-egress-proxy:3128
export SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
export NODE_USE_ENV_PROXY=1
export NO_PROXY=127.0.0.1,localhost
export no_proxy=127.0.0.1,localhost
# ANTHROPIC_API_KEY takes priority over the CLI's claude.ai OAuth login
# and bills the pay-as-you-go API instead — it must be absent.
unset ANTHROPIC_API_KEY
exec /usr/bin/node /home/hatch/tools/claude-code-proxy/claude-code-proxy.mjs
