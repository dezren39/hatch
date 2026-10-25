#!/bin/bash
# Receive + store a Bitwarden Secrets Manager access token.
# Reads the token from stdin (NOT from argv — keeps it out of process lists
# and shell history), writes it to ~/.config/bitwarden/access-token with
# 600 permissions, then verifies it with `bws secret list`.
#
# Usage: echo "$TOKEN" | ~/tools/bws-receive-token.sh
#    or: ~/tools/bws-receive-token.sh < /path/to/token-file
#
# The token is never printed.

set -euo pipefail

TOKEN_FILE="${HOME}/.config/bitwarden/access-token"
mkdir -p "$(dirname "$TOKEN_FILE")"
chmod 700 "$(dirname "$TOKEN_FILE")"

TOKEN="$(cat)"
# Strip whitespace/newlines (paste artifacts)
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

if [[ -z "$TOKEN" ]]; then
  echo "bws-receive-token: empty token on stdin, aborting" >&2
  exit 1
fi

printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
unset TOKEN

echo "bws-receive-token: stored to $TOKEN_FILE (600)" >&2

# Verify the token works
# shellcheck disable=SC1091
source "${HOME}/tools/bws-env.sh"
if bws secret list >/dev/null 2>&1; then
  echo "bws-receive-token: verified — token authenticates, can list secrets" >&2
else
  echo "bws-receive-token: WARNING — stored, but 'bws secret list' failed." >&2
  echo "  Check the token value and BWS_SERVER_URL if on an EU vault." >&2
  exit 2
fi
