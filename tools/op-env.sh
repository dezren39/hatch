#!/bin/bash
# 1Password service-account env loader.
#
# Usage: source ~/tools/op-env.sh           -> museRW account (DEFAULT)
#        source ~/tools/op-env.sh muse      -> original muse account
#        source ~/tools/op-env.sh museRW    -> museRW account (explicit)
#
# Drew's rule (2026-10-24): both tokens stay saved in Bitwarden Secrets
# Manager; museRW (Dev read/write + Walla read-only) is the default.
# The original muse token (Dev + Walla, read-verified) stays as the
# non-default fallback — laptop entries reference its exact Bitwarden
# key name, so that key must not be renamed.
#
# The token is fetched from Bitwarden at source time and exported as
# OP_SERVICE_ACCOUNT_TOKEN. It is never stored on disk outside
# Bitwarden, never echoed, never committed.

_OP_ACCOUNT="${1:-museRW}"

case "$_OP_ACCOUNT" in
  museRW)
    # key: op museRW service account auth token 1password
    _OP_SECRET_ID="5d3d53c9-153c-46f7-a1b0-b4ed00585272"
    ;;
  muse)
    # key: op muse service account auth token 1password
    _OP_SECRET_ID="3855e961-00f8-410d-b0d8-b4eb00e9c0eb"
    ;;
  *)
    echo "op-env: unknown account '$_OP_ACCOUNT' (use museRW or muse)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/bws-env.sh" 2>/dev/null
fi

export OP_SERVICE_ACCOUNT_TOKEN
OP_SERVICE_ACCOUNT_TOKEN="$("${HOME}/tools/bin/bws" secret get "$_OP_SECRET_ID" -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["value"] if isinstance(d,dict) else d[0]["value"], end="")')"

if [[ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then
  echo "op-env: failed to fetch token for account '$_OP_ACCOUNT' from Bitwarden" >&2
  return 1 2>/dev/null || exit 1
fi

echo "op-env: OP_SERVICE_ACCOUNT_TOKEN loaded for account '$_OP_ACCOUNT' (${#OP_SERVICE_ACCOUNT_TOKEN} chars)" >&2
