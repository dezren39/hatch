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
CF_TOKEN=""
if [ -f /home/hatch/tools/bws-env.sh ] && [ -n "${HTTPS_PROXY:-}" ]; then
  # shellcheck disable=SC1091
  source /home/hatch/tools/bws-env.sh >/dev/null 2>&1
  CF_TOKEN="$("/home/hatch/tools/bin/bws" secret list -o json 2>/dev/null | jq -r '.[] | select(.key=="cloudflare.api-token-ai-inference") | .value' | head -1)"
fi
if [ -n "$CF_TOKEN" ] && [ "$CF_TOKEN" != "null" ]; then
  TMP_ENV="$(mktemp "$SECRETS_DIR/.opencode-serve.env.XXXXXX")"
  {
    # The session proxy URL carries a per-session credential that rotates;
    # the same proxy also answers unauthenticated on its host:port from
    # inside the sandbox, which is the stable form a service can use.
    PROXY_HOSTPORT="$(printf '%s' "${HTTPS_PROXY:-}" | sed -E 's#^[a-zA-Z]+://##; s#^[^@/]*@##')"
    [ -n "$PROXY_HOSTPORT" ] && printf 'HTTPS_PROXY=http://%s\nhttps_proxy=http://%s\nHTTP_PROXY=http://%s\nhttp_proxy=http://%s\nALL_PROXY=http://%s\nall_proxy=http://%s\n' "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT" "$PROXY_HOSTPORT"
    [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && printf 'NODE_EXTRA_CA_CERTS=%s\nSSL_CERT_FILE=%s\nNODE_USE_ENV_PROXY=1\n' "$NODE_EXTRA_CA_CERTS" "${SSL_CERT_FILE:-$NODE_EXTRA_CA_CERTS}"
    printf 'CLOUDFLARE_API_TOKEN=%s\n' "$CF_TOKEN"
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
unset CF_TOKEN

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
