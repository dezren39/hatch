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
# The fleet's OpenCode is the developing-today/opencode FORK, v2 line,
# installed into the nix profile from the fork flake at the rev pinned by
# ~/git/devtoday-code/flake.lock (inputs.opencode) — the same source the
# laptop's home-manager config uses (inputs.opencode.packages.*.opencode).
# /usr/local/bin/opencode is kept pointing at the profile by
# ~/tools/nix-profile-sync.sh. Current build: 2.0.30+954ff7c
# (/nix/store/byz0f7r81m5psbch280929bxjwqf44qh-opencode-2.0.30+954ff7c),
# installed 2026-10-25 DIRECTLY from the fork flake — the external purity
# shim flake is retired (rev 954ff7c9 builds clean with no override).
# NOTE: no --pure — the fork's v2 serve rejects the flag (v1-only concept);
# the deployed config's plugin list is emptied instead, which is what keeps
# dead v1 plugins from stalling location activation under v2.

# Wait for the opencode binary to exist before exec'ing it: after a
# sandbox recycle this unit can start before nix-profile-sync has
# restored /usr/local/bin/opencode, and exec'ing a missing binary just
# crash-loops the unit (observed 2026-10-24). Poll for up to 60s.
waited=0
while [ ! -x /usr/local/bin/opencode ] && [ "$waited" -lt 60 ]; do
  if [ "$waited" -eq 0 ]; then
    echo "opencode-serve-start: waiting for /usr/local/bin/opencode to appear" >&2
  fi
  sleep 2
  waited=$((waited + 2))
done
exec /usr/local/bin/opencode serve --port 4096 --hostname 127.0.0.1
