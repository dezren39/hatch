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
  # Load the Bitwarden token via the sibling bws-env.sh (same directory
  # as this script), falling back to ~/tools and ~/hatch/tools.
  _OP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for _OP_BWS_ENV in "${_OP_SCRIPT_DIR}/bws-env.sh" "${HOME}/tools/bws-env.sh" "${HOME}/hatch/tools/bws-env.sh"; do
    if [[ -f "$_OP_BWS_ENV" ]]; then
      # shellcheck disable=SC1090
      source "$_OP_BWS_ENV"
      break
    fi
  done
  if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    echo "op-env: step 'load BWS_ACCESS_TOKEN' failed: bws-env.sh not found or token empty (tried sibling directory, ~/tools, ~/hatch/tools)" >&2
    return 1 2>/dev/null || exit 1
  fi
fi

# Resolve the bws binary: ~/tools/bin/bws when present (sandbox layout),
# otherwise the bws on PATH (on the laptop that is the system bws).
# Never a single hardcoded path (code#6829 / code#7931): the hardcoded
# ~/tools/bin/bws does not exist on the laptop, and the old fetch line's
# 2>/dev/null swallowed its exit 127, surfacing only a downstream
# JSONDecodeError on empty input.
_OP_BWS_BIN=""
if [[ -x "${HOME}/tools/bin/bws" ]]; then
  _OP_BWS_BIN="${HOME}/tools/bin/bws"
elif command -v bws >/dev/null 2>&1; then
  _OP_BWS_BIN="$(command -v bws)"
else
  echo "op-env: step 'resolve bws binary' failed: no executable ~/tools/bin/bws and no bws on PATH" >&2
  return 1 2>/dev/null || exit 1
fi

_OP_FETCH_JSON="$("$_OP_BWS_BIN" secret get "$_OP_SECRET_ID" -o json)"
_OP_FETCH_RC=$?
if [[ $_OP_FETCH_RC -ne 0 || -z "$_OP_FETCH_JSON" ]]; then
  echo "op-env: step 'bws secret get' failed for account '$_OP_ACCOUNT' (exit $_OP_FETCH_RC, output ${#_OP_FETCH_JSON} chars, binary $_OP_BWS_BIN)" >&2
  return 1 2>/dev/null || exit 1
fi

export OP_SERVICE_ACCOUNT_TOKEN
OP_SERVICE_ACCOUNT_TOKEN="$(printf '%s' "$_OP_FETCH_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["value"] if isinstance(d,dict) else d[0]["value"], end="")')"
_OP_PARSE_RC=$?
if [[ $_OP_PARSE_RC -ne 0 ]]; then
  echo "op-env: step 'parse bws secret get JSON' failed for account '$_OP_ACCOUNT' (python exit $_OP_PARSE_RC)" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then
  echo "op-env: step 'extract token value' failed: fetched secret for account '$_OP_ACCOUNT' has an empty value" >&2
  return 1 2>/dev/null || exit 1
fi

echo "op-env: OP_SERVICE_ACCOUNT_TOKEN loaded for account '$_OP_ACCOUNT' (${#OP_SERVICE_ACCOUNT_TOKEN} chars)" >&2
