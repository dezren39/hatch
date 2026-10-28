#!/bin/bash
# Claude Code OAuth login, run under systemd so runtime restarts cannot kill it.
# The authorization code is fed in later via the FIFO:
#   printf '%s\n' '<code>' > /home/hatch/tmp/claude-login.fifo
set -u
export HTTPS_PROXY=http://hatch-egress-proxy:3128
export HTTP_PROXY=http://hatch-egress-proxy:3128
export https_proxy=http://hatch-egress-proxy:3128
export http_proxy=http://hatch-egress-proxy:3128
export SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
FIFO=/home/hatch/tmp/claude-login.fifo
mkdir -p /home/hatch/tmp
rm -f "$FIFO"
mkfifo "$FIFO"
# Hold the FIFO open read-write so the CLI never sees EOF between code pastes.
exec 3<>"$FIFO"
exec /home/hatch/tools/claude-code/package/claude auth login <&3
