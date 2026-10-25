#!/bin/bash
# Install + enable + (re)start the board-agent systemd unit, and prepare
# its runtime env file. Idempotent; run by ~/tools/init.sh every boot
# because /etc is ephemeral.
set -u
SRC=/home/hatch/tools/board-agent.service
DST=/etc/systemd/system/board-agent.service
SECRETS_DIR=/home/hatch/tools/secrets.d
ENV_FILE="$SECRETS_DIR/board-agent.env"
TOKEN_FILE=/home/hatch/tmp/board/token.txt

# --- prepare runtime env (Turso token from the persistent token file) ---
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -s "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
  TMP_ENV="$(mktemp "$SECRETS_DIR/.board-agent.env.XXXXXX")"
  {
    printf 'BOARD_MACHINE=muse\n'
    printf 'BOARD_STORE=http\n'
    printf 'BOARD_DIR=/home/hatch/workspace/general-board\n'
    printf 'TURSO_TOKEN=%s\n' "$TOKEN"
    # The sandbox egress proxy answers unauthenticated on this host:port
    # from inside the sandbox; the per-session proxy credential rotates,
    # so a service must use this stable form (see install-opencode-service.sh).
    printf 'HTTPS_PROXY=http://hatch-egress-proxy:3128\n'
    printf 'https_proxy=http://hatch-egress-proxy:3128\n'
    printf 'HTTP_PROXY=http://hatch-egress-proxy:3128\n'
    printf 'http_proxy=http://hatch-egress-proxy:3128\n'
    printf 'SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem\n'
  } > "$TMP_ENV"
  chmod 600 "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
  unset TOKEN
else
  echo "install-board-agent-service: WARNING token file $TOKEN_FILE missing/empty; keeping any existing $ENV_FILE" >&2
fi

# --- install + start the unit ---
install -m 0644 "$SRC" "$DST"
systemctl daemon-reload
systemctl enable board-agent.service >/dev/null 2>&1 || true
if systemctl is-active --quiet board-agent.service; then
  systemctl restart board-agent.service || true
else
  systemctl start board-agent.service || true
fi
