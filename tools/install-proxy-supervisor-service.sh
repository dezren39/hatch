#!/bin/bash
# Install + enable the proxy-supervisor units and run one reconcile.
# Idempotent; run by ~/tools/init.sh every boot because /etc is
# ephemeral.
#
# Boot order contract: the per-proxy installers (agy/muse/commandcode)
# run BEFORE this step and start their proxies on the canonical ports;
# the supervisor then ADOPTS those healthy instances (same artifact
# hash) instead of restarting them, and owns all later rolls. The
# relays to the laptop-hosted proxies (codex 18744, antigravity-ls
# 18745, design-code 18746) are started here.
set -u
install -m 0644 /home/hatch/tools/proxy-supervisor.service /etc/systemd/system/proxy-supervisor.service
install -m 0644 /home/hatch/tools/proxy-supervisor.timer /etc/systemd/system/proxy-supervisor.timer
systemctl daemon-reload
systemctl enable proxy-supervisor.timer >/dev/null 2>&1 || true
systemctl start proxy-supervisor.timer || true

SUP="/usr/bin/node /home/hatch/tools/proxy-supervisor/proxy-supervise.mjs --config /home/hatch/tools/proxy-supervisor/config.json"
HOME=/home/hatch $SUP || true

# Verify: the LOCAL proxies must be healthy on their canonical ports.
# The relays are reported but not fatal here — their /health is
# end-to-end to the laptop, which may legitimately be asleep; the
# 2-minute timer keeps retrying.
fail=0
for port in 18743 18747 18748; do
  if curl --noproxy '*' -s -m 3 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q '"status": "ok"\|\"status\":\"ok\"'; then
    echo "install-proxy-supervisor-service: local proxy on $port healthy"
  else
    echo "install-proxy-supervisor-service: WARNING local proxy on $port NOT healthy"
    fail=1
  fi
done
for port in 18744 18745 18746; do
  if curl --noproxy '*' -s -m 5 "http://127.0.0.1:$port/health" 2>/dev/null | grep -q '"status": "ok"\|\"status\":\"ok\"'; then
    echo "install-proxy-supervisor-service: relay on $port healthy (laptop backend up)"
  else
    echo "install-proxy-supervisor-service: relay on $port not answering end-to-end (laptop backend may be down)"
  fi
done
exit $fail
