#!/bin/bash
# Install + enable + (re)start the muse-proxy systemd unit. Idempotent;
# run by ~/tools/init.sh every boot because /etc is ephemeral.
# No runtime env file is prepared (unlike opencode-serve): the proxy needs
# no secrets — auth is the muse CLI's own OAuth login at
# ~/.config/muse/auth.json (persistent), and the network env is pinned in
# ~/tools/muse-proxy-start.sh.
set -u
SRC=/home/hatch/tools/muse-proxy.service
DST=/etc/systemd/system/muse-proxy.service

install -m 0644 "$SRC" "$DST"
chmod +x /home/hatch/tools/muse-proxy-start.sh
systemctl daemon-reload
systemctl enable muse-proxy.service >/dev/null 2>&1 || true

# A stray non-systemd muse-proxy can already hold port 18747 before this
# unit starts (observed 2026-10-24 recycle: orphan node PID 4024, PPID 1,
# started during a concurrent init; the unit then crash-looped EADDRINUSE
# while the orphan kept /health answering 200, so a port-only health check
# passed against the wrong process). If the unit is not the process
# listening on 18747, stop the unit, kill the orphan, and let the unit own
# the port. Guarded by is-active: when the unit itself is healthy we never
# touch its process.
if ! systemctl is-active --quiet muse-proxy.service; then
  holder=$(ss -ltnp 2>/dev/null | grep '127.0.0.1:18747' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
  if [ -n "${holder:-}" ]; then
    echo "install-muse-proxy-service: port 18747 held by non-systemd PID $holder — stopping unit and killing orphan"
    systemctl stop muse-proxy.service || true
    kill "$holder" || true
    sleep 1
  fi
fi

if systemctl is-active --quiet muse-proxy.service; then
  systemctl restart muse-proxy.service || true
else
  systemctl start muse-proxy.service || true
fi

# --- verify the end state (mirror install-mcpx-service.sh) ---
# A start/restart returning 0 proves nothing if the unit is
# crash-looping. Poll for real health — active AND the bridge port
# accepting TCP — before exiting.
muse_proxy_healthy() {
  systemctl is-active --quiet muse-proxy.service || return 1
  timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/18747' 2>/dev/null || return 1
  # The port must be owned by the unit itself, not an orphan (see above).
  local main_pid holder
  main_pid=$(systemctl show muse-proxy.service -p MainPID --value 2>/dev/null || echo 0)
  holder=$(ss -ltnp 2>/dev/null | grep '127.0.0.1:18747' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
  [ -n "$holder" ] && [ "$holder" = "$main_pid" ]
}
deadline=$(( $(date +%s) + 30 ))
until muse_proxy_healthy; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "install-muse-proxy-service: muse-proxy NOT healthy after 30s:"
    systemctl status muse-proxy.service --no-pager 2>&1 | head -15
    exit 1
  fi
  sleep 2
done
echo "install-muse-proxy-service: muse-proxy active, port 18747 accepting"
