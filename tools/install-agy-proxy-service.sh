#!/bin/bash
# Install + enable + (re)start the agy-proxy systemd unit. Idempotent;
# run by ~/tools/init.sh every boot because /etc is ephemeral.
# No runtime env file is prepared: the proxy needs no secrets — auth is
# the agy CLI's own Google OAuth login at ~/.gemini/oauth_creds.json
# (persistent), and the network env is pinned in
# ~/tools/agy-proxy-start.sh.
set -u
SRC=/home/hatch/tools/agy-proxy.service
DST=/etc/systemd/system/agy-proxy.service

install -m 0644 "$SRC" "$DST"
chmod +x /home/hatch/tools/agy-proxy-start.sh
systemctl daemon-reload
systemctl enable agy-proxy.service >/dev/null 2>&1 || true
if systemctl is-active --quiet agy-proxy.service; then
  systemctl restart agy-proxy.service || true
else
  systemctl start agy-proxy.service || true
fi

# --- verify the end state (mirror install-muse-proxy-service.sh) ---
# A start/restart returning 0 proves nothing if the unit is
# crash-looping. Poll for real health — active AND the bridge's /health
# endpoint answering — before exiting.
agy_proxy_healthy() {
  systemctl is-active --quiet agy-proxy.service || return 1
  curl -s -m 3 http://127.0.0.1:18743/health 2>/dev/null | grep -q '"status": "ok"'
}
deadline=$(( $(date +%s) + 30 ))
until agy_proxy_healthy; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "install-agy-proxy-service: agy-proxy NOT healthy after 30s:"
    systemctl status agy-proxy.service --no-pager 2>&1 | head -15
    exit 1
  fi
  sleep 2
done
echo "install-agy-proxy-service: agy-proxy active, /health ok on port 18743"
