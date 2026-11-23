#!/bin/bash
# ~/tools/init-ensure.sh — dumb bootstrap prelude (Phase A, 2026-10-25).
# Ensures sandbox init is done/running for this boot WITHOUT watching it.
# Warm path is a few stats (<0.5s) and never invokes init.sh.
# Exit contract: 0 = fine or already handled; 2 = a previous init failure
# is being reported (exactly once, via watermark); 1 = init failed to start.
set -u
LOG_DIR=/home/hatch/logs
LOG=$LOG_DIR/init.log
STATUS=$LOG_DIR/init-status
MARKER=$LOG_DIR/.init-boot-id
REPORTED=$LOG_DIR/.init-reported
ENSURE_LOCK=$LOG_DIR/.init-ensure.lock
TIMER_UNIT=/etc/systemd/system/init-ensure.timer
INIT=/home/hatch/tools/init.sh
mkdir -p "$LOG_DIR"

# --- Binary resolution by test execution (code#12498) ---
# ~/tools/fleet can be a Nix binary whose interpreter is absent in
# this sandbox: it passes -x but every exec fails ENOENT, so the
# broker/init blocks below resolve the fleet binary by test
# execution (shared helper in resolve-bin.sh), falling back to the
# recovery build. Resolved lazily, once, on first use, so the warm
# path stays a few stats.
[ -f /home/hatch/tools/resolve-bin.sh ] && . /home/hatch/tools/resolve-bin.sh
FLEET_BIN_OK=""
FLEET_BIN_RESOLVED=""
fleet_bin_ok() {
  if [ -z "$FLEET_BIN_RESOLVED" ]; then
    FLEET_BIN_RESOLVED=1
    if command -v resolve_test_exec >/dev/null 2>&1; then
      FLEET_BIN_OK=$(resolve_test_exec /home/hatch/tools/fleet \
        /home/hatch/.local/share/hatch-recovery/bin/fleet || true)
    fi
  fi
  [ -n "$FLEET_BIN_OK" ]
}

# --- Previous-failure surfacing: report a failed init exactly once ---
if [ -f "$STATUS" ]; then
  END_DT=$(grep '^end_datetime=' "$STATUS" 2>/dev/null | cut -d= -f2- || echo "")
  RESULT=$(grep '^result=' "$STATUS" 2>/dev/null | cut -d= -f2- || echo "")
  LAST_REPORTED=""
  [ -f "$REPORTED" ] && LAST_REPORTED=$(cat "$REPORTED" 2>/dev/null || echo "")
  if [ -n "$RESULT" ] && [ "$RESULT" != "SUCCESS" ] && [ -n "$END_DT" ] \
     && [ "$END_DT" != "$LAST_REPORTED" ]; then
    printf '%s\n' "$END_DT" > "$REPORTED"
    echo "init: previous init run FAILED ($END_DT): result=$RESULT (see $LOG)"
    exit 2
  fi
fi

# --- Tailnet proxy env for broker spawns (code#12426) ---
# In userspace-tailscale mode the bootstrap tailnet phase writes
# ~/.local/state/tailscale/fleet-proxy.env exporting HTTPS_PROXY at
# tailscaled's local CONNECT proxy (127.0.0.1:3130). The session
# proxy tunnels through whatever HTTPS_PROXY it is spawned with;
# spawning it with the ambient sandbox egress proxy leaves every
# CONNECT to a tailnet IP closed (the egress proxy cannot route
# them), which is how the queue/shell legs died on the felix seat
# (code#12426). So each broker spawn below runs in a subshell that
# sources the env file first when it exists, dropping the other
# ambient proxy vars so only the tailnet value survives. Absent
# file = kernel mode (bootstrap removes it there): spawns inherit
# the ambient env exactly as before. Subshell-scoped on purpose:
# the rest of this prelude — the secrets broker's BWS calls in
# particular — must keep the ambient egress route.
TAILNET_PROXY_ENV=/home/hatch/.local/state/tailscale/fleet-proxy.env
tailnet_proxy_env() {
  if [ -f "$TAILNET_PROXY_ENV" ]; then
    . "$TAILNET_PROXY_ENV" >/dev/null 2>&1 || true
    unset http_proxy https_proxy HTTP_PROXY all_proxy ALL_PROXY
  fi
}

# --- Session proxy (laptop-agent broker) autostart (2026-11-04, #5343) ---
# Every prelude keeps the sandbox session proxy running: it is the single
# entry point to the laptop (laptop-agent, secrets broker, queue broker).
# No-op when a broker is already running — the pgrep gate skips the spawn,
# and the broker itself probes its socket and exits quietly if a live one
# owns it. Best-effort: never prints, never changes the exit contract.
# Since step 3 (code#5431) the broker is `fleet proxy serve`; the Python
# broker remains the fallback when no fleet binary is installed, and the
# gate accepts either process as "running".
{
  BROKER_SOCK=/home/hatch/.cache/laptop-agent/broker.sock
  BROKER_LOG=/home/hatch/.cache/laptop-agent/broker.log
  if [ ! -S "$BROKER_SOCK" ] || { ! pgrep -f 'laptop-agent-broker\.py' >/dev/null 2>&1 && ! pgrep -f 'fleet proxy serve' >/dev/null 2>&1; }; then
    mkdir -p /home/hatch/.cache/laptop-agent
    exec 9>"/home/hatch/.cache/laptop-agent/.broker-ensure.lock"
    if flock -n 9; then
      if fleet_bin_ok; then
        # LAPTOP_AGENT_POOL=50: the proxy pool sized for the fleet's
        # work (code#5412 concurrency benchmark — the default of 12
        # cliffs at ~12 concurrent consumers). The compiled default
        # becomes 50 with the fleet-proxy pool fix; this env is the
        # explicit override at the broker's owning launch surface.
        # tailnet_proxy_env: spawn with the tailnet proxy env, never
        # the ambient egress proxy (code#12426, helper above).
        ( tailnet_proxy_env
          setsid nohup env LAPTOP_AGENT_POOL=50 "$FLEET_BIN_OK" proxy serve \
            >>"$BROKER_LOG" 2>&1 </dev/null & )
      else
        ( tailnet_proxy_env
          setsid nohup python3 /home/hatch/tools/laptop-agent-broker.py \
            >>"$BROKER_LOG" 2>&1 </dev/null & )
      fi
    fi
    exec 9>&-
  fi
} 2>/dev/null || true

# --- Location-aware fleet init (2026-11-11, code#6770 / task 14633) ---
# The sandbox carries a [host] manifest in ~/.config/fleet/fleet.toml
# (location "sandbox", init_mode "spawn", role proxy). This is the
# pinned call site from the #6770 deploy sequence: FLEET_LOCATION
# makes the caller's assumption explicit, belt-and-braces alongside
# the manifest. In spawn mode `fleet init` is the strict no-op proxy
# ensure when the broker above is already running, and spawns it
# when it is not. Best-effort: output silenced, never changes the
# exit contract.
{
  if fleet_bin_ok; then
    # Spawn mode runs the proxy role in this process, so the init
    # call gets the same tailnet proxy env treatment (code#12426).
    ( tailnet_proxy_env
      FLEET_LOCATION=sandbox "$FLEET_BIN_OK" init >/dev/null 2>&1 || true )
  fi
} 2>/dev/null || true

# --- Sandbox-local secrets broker (2026-11-15, code#10578) ---
# The sandbox dual-hosts the secrets broker with the laptop so
# sandbox secret reads survive a laptop broker/tunnel outage.
# Spawn-mode `fleet init` reports this role but does not manage
# it, so this prelude keeps it alive exactly like the session
# proxy above. Loopback only: SECRETS_BROKER_BIND pins the TCP
# leg to 127.0.0.1 (the broker's compiled default is the laptop's
# tailnet IP - never use it here) and the UDS is pinned to the
# fleet-config default path. The broker's API token is
# ~/.config/secrets-broker/token; its Bitwarden machine token
# resolves from ~/.config/bitwarden/access-token. Best-effort:
# never prints, never changes the exit contract.
{
  SB_SOCK=/home/hatch/.config/secrets-broker/broker.sock
  SB_LOG=/home/hatch/.cache/secrets-broker/broker.log
  SB_PID=$(pgrep -f 'fleet serve secrets-broker' 2>/dev/null | sort -n | head -1)
  if [ -n "$SB_PID" ] && [ -S "$SB_SOCK" ] \
    && ! curl -fsS -m 3 --unix-socket "$SB_SOCK" http://broker/health 2>/dev/null | grep -q '"serving":true'; then
    SB_AGE=$(ps -o etimes= -p "$SB_PID" 2>/dev/null | tr -d ' ')
    if [ "${SB_AGE:-0}" -ge 120 ]; then
      kill "$SB_PID" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SB_PID" 2>/dev/null || break; sleep 0.5; done
      rm -f "$SB_SOCK"
    fi
  fi
  if [ ! -S "$SB_SOCK" ] || ! pgrep -f 'fleet serve secrets-broker' >/dev/null 2>&1; then
    mkdir -p /home/hatch/.cache/secrets-broker /home/hatch/.config/secrets-broker
    exec 9>"/home/hatch/.cache/secrets-broker/.broker-ensure.lock"
    if flock -n 9; then
      if fleet_bin_ok && [ -s /home/hatch/.config/secrets-broker/token ]; then
        setsid nohup env PATH="/home/hatch/tools/bin:/home/hatch/tools:$PATH" \
          SECRETS_BROKER_BIND=127.0.0.1:4800 \
          SECRETS_BROKER_SOCKET="$SB_SOCK" \
          "$FLEET_BIN_OK" serve secrets-broker \
          >>"$SB_LOG" 2>&1 </dev/null &
      fi
    fi
    exec 9>&-
  fi
} 2>/dev/null || true

# --- fleet binary links (2026-11-04, code#5343) ---
# ~/tools/bin/fleet is the PATH entry point for the fleet multicall
# binary, and repo-queue is its argv0 alias. Recreate either link if it
# has gone missing or dangling; a present, resolvable link is left
# untouched. Best-effort: never prints, never changes the exit contract.
{
  for link in fleet repo-queue; do
    if [ ! -e "/home/hatch/tools/bin/$link" ] && fleet_bin_ok; then
      ln -sfn "$FLEET_BIN_OK" "/home/hatch/tools/bin/$link"
    fi
  done
} 2>/dev/null || true

# --- gh -> fleet gh shim (2026-11-14, Drew directive) ---
# /usr/local/bin is overlay state: a recycle rebuilds it with gh
# pointing at the nix profile again. Repoint it at the shim in
# ~/tools (which survives) whenever it does not already resolve
# there; the shim pins FLEET_GH_BIN to the real gh so fleet's own
# gh calls cannot recurse, and gh-orig keeps the pristine binary
# one name away. Best-effort: never prints, never changes the
# exit contract.
{
  SHIM=/home/hatch/tools/gh-shim.sh
  if [ -x "$SHIM" ] && [ -w /usr/local/bin ]; then
    if [ "$(readlink -f /usr/local/bin/gh 2>/dev/null || echo none)" != "$SHIM" ]; then
      ln -sfn "$SHIM" /usr/local/bin/gh
    fi
    if [ ! -e /usr/local/bin/gh-orig ] && [ -n "$(resolve_test_exec /home/hatch/.nix-profile/bin/gh 2>/dev/null || true)" ]; then
      ln -sfn /home/hatch/.nix-profile/bin/gh /usr/local/bin/gh-orig
    fi
  fi
} 2>/dev/null || true

# --- Warm check: marker matches this boot AND backstop timer installed ---
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || echo none)" = "$BOOT_ID" ] \
   && [ -f "$TIMER_UNIT" ]; then
  exit 0
fi

# --- Stale-init detector (report only; never kills, never spawns) ---
# Every init step is timeout-bounded, so an init still holding the lock
# past STALE_INIT_SECS is stuck on something outside the step model.
# Without this, ensure would exit 0 silently on every poll forever and
# no failure would ever surface (STATUS is only written at END).
STALE_INIT_SECS=5400
exec 7>"$LOG_DIR/.init.lock"
if ! flock -n 7; then
  INIT_PID=$(pgrep -f 'tools/init\.sh' 2>/dev/null | sort -n | head -1)
  if [ -n "${INIT_PID:-}" ]; then
    INIT_AGE=$(ps -o etimes= -p "$INIT_PID" 2>/dev/null | tr -d ' ')
    if [ -n "${INIT_AGE:-}" ] && [ "$INIT_AGE" -gt "$STALE_INIT_SECS" ] 2>/dev/null; then
      echo "init: WARNING init.sh (pid $INIT_PID) has held the init lock for ${INIT_AGE}s (> ${STALE_INIT_SECS}s) — it appears stuck; see $LOG"
      echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init-ensure: stale init detected pid=$INIT_PID age=${INIT_AGE}s" >> "$LOG"
    fi
  fi
fi
exec 7>&-

# --- Cold path: spawn init detached, exactly once, return immediately ---
if [ ! -x "$INIT" ]; then
  echo "init: FAILED TO START: $INIT missing or not executable"
  exit 1
fi
exec 8>"$ENSURE_LOCK"
if ! flock -n 8; then
  exit 0   # another ensure already spawned init; nothing more to do
fi
setsid nohup bash "$INIT" >>"$LOG" 2>&1 < /dev/null &
exit 0
