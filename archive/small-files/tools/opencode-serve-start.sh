#!/bin/bash
# Start wrapper for the opencode server.
# Runtime env (egress proxy + CLOUDFLARE_API_TOKEN fetched from Bitwarden)
# is prepared by ~/tools/install-opencode-service.sh at every boot into
# ~/tools/secrets.d/opencode-serve.env (dir 700, file 600) because a
# systemd service inherits neither the sandbox egress proxy nor a
# Bitwarden session. If the env file is missing, the server still starts;
# Cloudflare providers and outbound calls will fail until a reinstall.
export HOME=/home/hatch
ENV_FILE="$HOME/tools/secrets.d/opencode-serve.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "opencode-serve-start: WARNING $ENV_FILE missing; starting without prepared env" >&2
fi
# --pure: the ~/.config/opencode plugins (mcpx bridge, subtask2) stall the
# message loop on this box (verified 2026-10-20: full config + --pure
# answers in ~4s; without it the loop never starts). Revisit when the
# opencode<->mcpx plugin bridge is diagnosed.
exec /usr/local/bin/opencode serve --pure --port 4096 --hostname 127.0.0.1
