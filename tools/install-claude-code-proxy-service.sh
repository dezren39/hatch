#!/bin/bash
# Install + enable + (re)start the claude-code-proxy systemd unit.
# Idempotent; run by ~/tools/init.sh every boot because /etc is
# ephemeral.
# No runtime env file is prepared: the proxy needs no secrets — auth is
# the Claude Code CLI's own claude.ai login under ~/.claude
# (persistent), and the network env is pinned in
# ~/tools/claude-code-proxy-start.sh.
set -u
SRC=/home/hatch/tools/claude-code-proxy.service
DST=/etc/systemd/system/claude-code-proxy.service

install -m 0644 "$SRC" "$DST"
chmod +x /home/hatch/tools/claude-code-proxy-start.sh
systemctl daemon-reload
systemctl enable claude-code-proxy.service >/dev/null 2>&1 || true
if systemctl is-active --quiet claude-code-proxy.service; then
  systemctl restart claude-code-proxy.service || true
else
  systemctl start claude-code-proxy.service || true
fi

# --- verify the end state (mirror install-commandcode-proxy-service.sh) ---
# A start/restart returning 0 proves nothing if the unit is
# crash-looping. Poll for real health — active AND the bridge's /health
# endpoint answering — before exiting.
claude_code_proxy_healthy() {
  systemctl is-active --quiet claude-code-proxy.service || return 1
  curl --noproxy '*' -s -m 3 http://127.0.0.1:18749/health 2>/dev/null | grep -q '"status": "ok"'
}
deadline=$(( $(date +%s) + 30 ))
until claude_code_proxy_healthy; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "install-claude-code-proxy-service: claude-code-proxy NOT healthy after 30s:"
    systemctl status claude-code-proxy.service --no-pager 2>&1 | head -15
    exit 1
  fi
  sleep 2
done
echo "install-claude-code-proxy-service: claude-code-proxy active, /health ok on port 18749"
