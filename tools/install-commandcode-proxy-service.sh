#!/bin/bash
# Install + enable + (re)start the commandcode-proxy systemd unit. Idempotent;
# run by ~/tools/init.sh every boot because /etc is ephemeral.
# No runtime env file is prepared: the proxy needs no secrets — auth is
# the commandcode CLI's own login at ~/.commandcode/auth.json
# (persistent), and the network env is pinned in
# ~/tools/commandcode-proxy-start.sh.
set -u
SRC=/home/hatch/tools/commandcode-proxy.service
DST=/etc/systemd/system/commandcode-proxy.service

install -m 0644 "$SRC" "$DST"
chmod +x /home/hatch/tools/commandcode-proxy-start.sh
systemctl daemon-reload
systemctl enable commandcode-proxy.service >/dev/null 2>&1 || true
if systemctl is-active --quiet commandcode-proxy.service; then
  systemctl restart commandcode-proxy.service || true
else
  systemctl start commandcode-proxy.service || true
fi

# --- verify the end state (mirror install-agy-proxy-service.sh) ---
# A start/restart returning 0 proves nothing if the unit is
# crash-looping. Poll for real health — active AND the bridge's /health
# endpoint answering — before exiting.
commandcode_proxy_healthy() {
  systemctl is-active --quiet commandcode-proxy.service || return 1
  curl --noproxy '*' -s -m 3 http://127.0.0.1:18748/health 2>/dev/null | grep -q '"status": "ok"'
}
deadline=$(( $(date +%s) + 30 ))
until commandcode_proxy_healthy; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "install-commandcode-proxy-service: commandcode-proxy NOT healthy after 30s:"
    systemctl status commandcode-proxy.service --no-pager 2>&1 | head -15
    exit 1
  fi
  sleep 2
done
echo "install-commandcode-proxy-service: commandcode-proxy active, /health ok on port 18748"
