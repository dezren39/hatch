#!/bin/bash
# ~/tools/verify-services.sh — verify the sandbox's systemd services are
# actually UP, not just installed, and repair any that are down by
# re-running their installers. Wired into ~/tools/init.sh as its final
# step so a boot only reports SUCCESS when every service is healthy;
# also safe to run standalone at any time.
#
# Why this exists: the per-service installers historically ended with
# `systemctl start ... || true` and never checked the end state, so
# init logged steps OK while services were down (observed 2026-10-24:
# opencode-serve absent for 15 min after a recycle while init claimed
# SUCCESS). This script trusts only live health checks.
set -u

FAILURES=0

tcp_ok() { # host port — true if a TCP connect succeeds
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

check_mcpx() {
  systemctl is-active --quiet mcpx.service || return 1
  timeout 10 /usr/local/bin/mcpx status >/dev/null 2>&1
}

check_opencode_serve() {
  systemctl is-active --quiet opencode-serve.service || return 1
  local pw code
  pw="$(tr -d '\n' < /home/hatch/tools/secrets.d/opencode-server-password 2>/dev/null)"
  [ -n "$pw" ] || return 1
  # --noproxy: loopback must never go through the egress proxy.
  code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -u "opencode:$pw" http://127.0.0.1:4096/openapi.json 2>/dev/null)"
  [ "$code" = "200" ]
}

check_muse_proxy() {
  systemctl is-active --quiet muse-proxy.service || return 1
  tcp_ok 127.0.0.1 18747
}

check_board_agent() {
  systemctl is-active --quiet board-agent.service
}

wait_healthy() { # check-fn timeout-seconds
  local fn="$1" deadline=$(( $(date +%s) + $2 ))
  until "$fn"; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 2
  done
}

verify() { # display-name check-fn installer
  local name="$1" fn="$2" installer="$3"
  if "$fn"; then
    echo "$name: HEALTHY"
    return 0
  fi
  echo "$name: DOWN -> repairing"
  # opencode-serve crash-loops when its binary symlink is missing after
  # a recycle; restore the profile links before reinstalling the unit.
  if [ "$name" = "opencode-serve" ] && [ ! -x /usr/local/bin/opencode ]; then
    bash /home/hatch/tools/nix-profile-sync.sh >/dev/null 2>&1 || true
  fi
  bash "$installer" || true
  if wait_healthy "$fn" 20; then
    echo "$name: HEALTHY"
    return 0
  fi
  echo "$name: FAILED"
  FAILURES=$((FAILURES + 1))
}

# DISABLED by Drew 2026-10-25: mcpx + opencode-serve intentionally not
# autostarted on the sandbox — do not "repair" them back to life here.
# verify mcpx check_mcpx /home/hatch/tools/install-mcpx-service.sh
# verify opencode-serve check_opencode_serve /home/hatch/tools/install-opencode-service.sh
# DISABLED by Drew 2026-10-25 (20:52 follow-up): muse-proxy intentionally
# not autostarted on the sandbox — do not "repair" it back to life here.
# verify muse-proxy check_muse_proxy /home/hatch/tools/install-muse-proxy-service.sh
# DISABLED by Drew 2026-10-28: board-agent intentionally not autostarted
# on the sandbox — do not "repair" it back to life here.
# verify board-agent check_board_agent /home/hatch/tools/install-board-agent-service.sh

[ "$FAILURES" -eq 0 ]
