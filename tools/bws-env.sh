#!/bin/bash
# Bitwarden Secrets Manager env loader.
# Sources the machine-account access token from a 600-perm file and exports
# BWS_ACCESS_TOKEN (and BWS_SERVER_URL if set) for `bws` CLI calls.
#
# Usage: source ~/tools/bws-env.sh
#        bws secret list
#
# The token itself lives in ~/.config/bitwarden/access-token (600).
# Never echo it, never commit it, never put it in chat.

# The bws binary lives in ~/tools/bin, which is not on every shell's PATH
# (cron workers have missed it — Archer Slack review failed 2026-10-27).
# Make this loader self-sufficient.
export PATH="$HOME/tools/bin:$PATH"

_BWS_TOKEN_FILE="${HOME}/.config/bitwarden/access-token"

if [[ ! -f "$_BWS_TOKEN_FILE" ]]; then
  echo "bws-env: no token at $_BWS_TOKEN_FILE — run the receive flow first" >&2
  return 1 2>/dev/null || exit 1
fi

export BWS_ACCESS_TOKEN
BWS_ACCESS_TOKEN="$(cat "$_BWS_TOKEN_FILE")"

if [[ -z "$BWS_ACCESS_TOKEN" ]]; then
  echo "bws-env: token file is empty" >&2
  return 1 2>/dev/null || exit 1
fi

# Optional: EU vaults need the server URL override.
if [[ -f "${HOME}/.config/bitwarden/server-url" ]]; then
  export BWS_SERVER_URL
  BWS_SERVER_URL="$(cat "${HOME}/.config/bitwarden/server-url")"
fi

echo "bws-env: BWS_ACCESS_TOKEN loaded (${#BWS_ACCESS_TOKEN} chars)" >&2
