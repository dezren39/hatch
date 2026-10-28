#!/bin/bash
# Install + enable + (re)start the opencode-serve systemd unit, and prepare
# its runtime env file. Idempotent; run by ~/tools/init.sh every boot
# because /etc is ephemeral. This script runs in a context that HAS the
# sandbox egress proxy env, which the service itself never inherits.
set -u
SRC=/home/hatch/tools/opencode.service
DST=/etc/systemd/system/opencode-serve.service
SECRETS_DIR=/home/hatch/tools/secrets.d
ENV_FILE="$SECRETS_DIR/opencode-serve.env"

# --- prepare runtime env (proxy + Cloudflare token from Bitwarden) ---
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# --- OpenCode v2 server password (stable across boots) ---
# v2 serve requires auth: without OPENCODE_SERVER_PASSWORD it generates a
# random one on every start and prints it to the journal, which breaks
# scripted consumers. Persist one locally (600, this dir is 700); the same
# value is filed in Bitwarden as `opencode.server-password`
# (filed 2026-10-24, v1->v2 migration).
SERVER_PW_FILE="$SECRETS_DIR/opencode-server-password"
if [ ! -s "$SERVER_PW_FILE" ]; then
  head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32 > "$SERVER_PW_FILE"
  echo >> "$SERVER_PW_FILE"
fi
chmod 600 "$SERVER_PW_FILE"
SERVER_PW="$(tr -d '\n' < "$SERVER_PW_FILE")"
CF_TOKEN=""
if [ -f /home/hatch/tools/bws-env.sh ] && [ -n "${HTTPS_PROXY:-}" ]; then
  # shellcheck disable=SC1091
  source /home/hatch/tools/bws-env.sh >/dev/null 2>&1
  # Bounded: a stalled egress proxy / Bitwarden call must not hang this
  # installer before the unit is even written — on timeout CF_TOKEN is
  # empty and we fall through to the keep-existing-env path below.
  CF_TOKEN="$(timeout 30 "/home/hatch/tools/bin/bws" secret list -o json 2>/dev/null | jq -r '.[] | select(.key=="cloudflare.api-token-ai-inference") | .value' | head -1)"
fi
if [ -n "$CF_TOKEN" ] && [ "$CF_TOKEN" != "null" ]; then
  TMP_ENV="$(mktemp "$SECRETS_DIR/.opencode-serve.env.XXXXXX")"
  {
    # The session proxy URL carries a per-session credential that rotates;
    # the same proxy also answers unauthenticated on its host:port from
    # inside the sandbox, which is the stable form a service can use.
    PROXY_HOSTPORT="$(printf '%s' "${HTTPS_PROXY:-}" | sed -E 's#^[a-zA-Z]+://##; s#^[^@/]*@##')"
    [ -n "$PROXY_HOSTPORT" ] && printf 'HTTPS_PROXY=http://%s\nhttps_proxy=http://%s\nHTTP_PROXY=http://%s\nhttp_proxy=http://%s\nALL_PROXY=http://%s\nall_proxy=http://%s\n' "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT"
    # Loopback must NEVER go through the egress proxy: local bridge
    # providers (muse-proxy on 18747, codex-proxy on 18744) live on
    # 127.0.0.1, and with NODE_USE_ENV_PROXY=1 + no NO_PROXY the server's
    # fetch routes those requests into the egress proxy, which blackholes
    # them — the provider call hangs silently (hit 2026-10-21 wiring the
    # muse provider; the session log shows the stream starting, no request
    # ever reaches the bridge).
    printf 'NO_PROXY=localhost,127.0.0.1,::1\nno_proxy=localhost,127.0.0.1,::1\n'
    [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && printf 'NODE_EXTRA_CA_CERTS=%s\nSSL_CERT_FILE=%s\nNODE_USE_ENV_PROXY=1\n' "$NODE_EXTRA_CA_CERTS" "${SSL_CERT_FILE:-$NODE_EXTRA_CA_CERTS}"
    printf 'CLOUDFLARE_API_TOKEN=%s\n' "$CF_TOKEN"
    printf 'CLOUDFLARE_ACCOUNT_ID=234b866b99ce2b142d7963d8d139cbfa\nCLOUDFLARE_GATEWAY_ID=opencode-gateway\n'
    [ -n "$SERVER_PW" ] && printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$SERVER_PW"
    # Feature flags (Drew, 2026-10-20: enable the interesting ones).
    # Web search backends + experimental features that make sense on a
    # headless server. FILEWATCHER stays disabled here: this box's home
    # tree is a giant git worktree and whole-dir watching stalls sessions
    # (see TOOLS.md). EXPERIMENTAL_NATIVE_LLM deliberately held off while
    # the Codex transport is being diagnosed.
    printf '%s\n' \
      'OPENCODE_EXPERIMENTAL=1' \
      'OPENCODE_EXPERIMENTAL_ICON_DISCOVERY=1' \
      'OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=1' \
      'OPENCODE_ENABLE_EXA=1' \
      'OPENCODE_ENABLE_PARALLEL=1' \
      'OPENCODE_ENABLE_EXPERIMENTAL_MODELS=1' \
      'OPENCODE_EXPERIMENTAL_PARALLEL=1' \
      'OPENCODE_EXPERIMENTAL_PLAN_MODE=1' \
      'OPENCODE_EXPERIMENTAL_SCOUT=1' \
      'OPENCODE_EXPERIMENTAL_WORKSPACES=1' \
      'OPENCODE_EXPERIMENTAL_LSP_TOOL=1' \
      'OPENCODE_EXPERIMENTAL_OXFMT=1' \
      'OPENCODE_EXPERIMENTAL_EXA=1' \
      'OPENCODE_EXPERIMENTAL_EVENT_SYSTEM=1' \
      'OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER=1'
  } > "$TMP_ENV"
  chmod 600 "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
else
  echo "install-opencode-service: WARNING could not refresh env from Bitwarden; keeping any existing $ENV_FILE" >&2
fi
unset CF_TOKEN SERVER_PW

# --- install + start the unit ---
install -m 0644 "$SRC" "$DST"
chmod +x /home/hatch/tools/opencode-serve-start.sh
systemctl daemon-reload
systemctl enable opencode-serve.service >/dev/null 2>&1 || true
if systemctl is-active --quiet opencode-serve.service; then
  systemctl restart opencode-serve.service || true
else
  systemctl start opencode-serve.service || true
fi

# --- verify the end state (mirror install-mcpx-service.sh) ---
# A start/restart returning 0 proves nothing: the unit can be
# crash-looping (e.g. /usr/local/bin/opencode missing after a recycle,
# observed 2026-10-24) while this script still claimed success. Poll
# for real health — active AND the API answering 200 — before exiting.
opencode_healthy() {
  systemctl is-active --quiet opencode-serve.service || return 1
  local pw code
  pw="$(tr -d '\n' < "$SERVER_PW_FILE" 2>/dev/null)"
  [ -n "$pw" ] || return 1
  # --noproxy: loopback must never go through the egress proxy.
  code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -u "opencode:$pw" http://127.0.0.1:4096/openapi.json 2>/dev/null)"
  [ "$code" = "200" ]
}
deadline=$(( $(date +%s) + 30 ))
until opencode_healthy; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "install-opencode-service: opencode-serve NOT healthy after 30s:"
    systemctl status opencode-serve.service --no-pager 2>&1 | head -15
    exit 1
  fi
  sleep 2
done
echo "install-opencode-service: opencode-serve active, API 200"
