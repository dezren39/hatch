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
# Bounded: the reconcile does health checks against laptop backends and
# A/B rolls — `|| true` guards failure, not hanging. The 2-minute timer
# retries, so a timed-out reconcile here is not fatal.
# shellcheck disable=SC2086 # $SUP is a command line; word splitting intended
HOME=/home/hatch timeout --signal=TERM --kill-after=15 300 $SUP || true

# Verify: health gate REMOVED 2026-10-25 (Drew, 20:52 follow-up). All
# sandbox provider relays are now disabled and the supervisor config
# manages zero proxies: muse-proxy (18747) and commandcode-proxy (18748)
# left the must-be-healthy list, the codex relay (18744) left this report
# (18743/18745/18746 already went earlier today). An absent proxy port is
# the intended state, not a failure — this installer now only installs
# the (disabled) units and runs a no-op reconcile. init.sh no longer
# calls it at all; it remains for a deliberate manual restore.
fail=0
echo "install-proxy-supervisor-service: no managed proxies (all relays disabled by Drew 2026-10-25) — nothing to health-gate"
exit $fail
