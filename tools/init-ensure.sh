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
  if [ ! -S "$BROKER_SOCK" ] || { ! pgrep -f 'laptop-agent-broker\.py' >/dev/null 2>&1 && ! pgrep -f '^/home/hatch/tools/fleet proxy serve' >/dev/null 2>&1; }; then
    mkdir -p /home/hatch/.cache/laptop-agent
    exec 9>"/home/hatch/.cache/laptop-agent/.broker-ensure.lock"
    if flock -n 9; then
      if [ -x /home/hatch/tools/fleet ]; then
        # LAPTOP_AGENT_POOL=50: the proxy pool sized for the fleet's
        # work (code#5412 concurrency benchmark — the default of 12
        # cliffs at ~12 concurrent consumers). The compiled default
        # becomes 50 with the fleet-proxy pool fix; this env is the
        # explicit override at the broker's owning launch surface.
        # 2026-11-22: source the tailnet fleet-proxy.env first — the
        # broker tunnels to the laptop through tailscaled's CONNECT
        # proxy (127.0.0.1:3130); without HTTPS_PROXY set it fails
        # every tunnel with "proxy closed during CONNECT" and the
        # queue/shell doctor legs stay down.
        setsid nohup bash -c 'set -a; [ -f /home/hatch/.local/state/tailscale/fleet-proxy.env ] && . /home/hatch/.local/state/tailscale/fleet-proxy.env; set +a; LAPTOP_AGENT_POOL=50 exec /home/hatch/tools/fleet proxy serve' \
          >>"$BROKER_LOG" 2>&1 </dev/null &
      else
        setsid nohup python3 /home/hatch/tools/laptop-agent-broker.py \
          >>"$BROKER_LOG" 2>&1 </dev/null &
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
  if [ -x /home/hatch/tools/fleet ]; then
    FLEET_LOCATION=sandbox /home/hatch/tools/fleet init >/dev/null 2>&1 || true
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
  SB_PID=$(pgrep -f '^/home/hatch/tools/fleet serve secrets-broker' 2>/dev/null | sort -n | head -1)
  if [ -n "$SB_PID" ] && [ -S "$SB_SOCK" ] \
    && ! curl -fsS -m 3 --unix-socket "$SB_SOCK" http://broker/health 2>/dev/null | grep -q '"serving":true'; then
    SB_AGE=$(ps -o etimes= -p "$SB_PID" 2>/dev/null | tr -d ' ')
    if [ "${SB_AGE:-0}" -ge 120 ]; then
      kill "$SB_PID" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SB_PID" 2>/dev/null || break; sleep 0.5; done
      rm -f "$SB_SOCK"
    fi
  fi
  if [ ! -S "$SB_SOCK" ] || ! pgrep -f '^/home/hatch/tools/fleet serve secrets-broker' >/dev/null 2>&1; then
    mkdir -p /home/hatch/.cache/secrets-broker /home/hatch/.config/secrets-broker
    exec 9>"/home/hatch/.cache/secrets-broker/.broker-ensure.lock"
    if flock -n 9; then
      if [ -x /home/hatch/tools/fleet ] && [ -s /home/hatch/.config/secrets-broker/token ]; then
        # FLEET_OP_VAULT (2026-11-24, Requirement 5): names the
        # 1Password vault for fleet-secrets' OpSource; kept in sync
        # with ~/.config/fleet/op-backend.env. The current broker
        # build ignores it server-side (its refresh is Bitwarden-
        # only); it is set here so a broker build with an op backend
        # picks it up with no further seat change, in the same style
        # as the Bitwarden wiring above.
        setsid nohup env PATH="/home/hatch/tools/bin:/home/hatch/tools:$PATH" \
          SECRETS_BROKER_BIND=127.0.0.1:4800 \
          SECRETS_BROKER_SOCKET="$SB_SOCK" \
          FLEET_OP_VAULT=Dev \
          /home/hatch/tools/fleet serve secrets-broker \
          >>"$SB_LOG" 2>&1 </dev/null &
      fi
    fi
    exec 9>&-
  fi
} 2>/dev/null || true

# --- Client routes ensure (2026-11-22, Drew directive) ---
# Keeps the secrets client route (fleet.toml [secrets-broker]
# transport: local "socket" vs laptop "tcp") and the gh route
# marker the gh shim reads pointed at whichever route is actually
# alive, falling back to the laptop / in-process routes while a
# primary is unhealthy. The logic lives in
# ~/tools/fleet-routes-ensure.sh, shared with the 15-minute keeper
# (~/tools/felix-ensure.sh) so init and the keeper never fight over
# the broker or the routes. Detached and throttled to one launch a
# minute: the prelude never blocks on a probe. Best-effort: prints
# nothing here (change tokens land in the routes log), never
# changes the exit contract.
{
  ROUTES_SCRIPT=/home/hatch/tools/fleet-routes-ensure.sh
  ROUTES_STAMP=/home/hatch/.local/state/fleet/.routes-ensure.last
  if [ -x "$ROUTES_SCRIPT" ]; then
    mkdir -p /home/hatch/.local/state/fleet
    ROUTES_NOW=$(date +%s 2>/dev/null || echo 0)
    ROUTES_LAST=0
    [ -f "$ROUTES_STAMP" ] && ROUTES_LAST=$(cat "$ROUTES_STAMP" 2>/dev/null || echo 0)
    case "$ROUTES_LAST" in *[!0-9]*|"") ROUTES_LAST=0 ;; esac
    if [ $((ROUTES_NOW - ROUTES_LAST)) -ge 60 ]; then
      echo "$ROUTES_NOW" > "$ROUTES_STAMP"
      setsid nohup "$ROUTES_SCRIPT" >>/home/hatch/logs/fleet-routes-ensure.log 2>&1 </dev/null &
    fi
  fi
} 2>/dev/null || true

# --- Session proxy broker env ensure (2026-11-22) ---
# The spawn block above only sets the broker's env at spawn time,
# and any fleet client can auto-spawn the broker first from an
# agent shell — inheriting the sandbox egress proxy, which breaks
# every tunnel to the laptop while the broker looks alive (the
# 2026-11-22 queue/shell flap). fleet-proxy-ensure.sh is the one
# implementation of the check (broker alive + HTTPS_PROXY equal to
# the tailnet phase's fleet-proxy.env), shared with the 15-minute
# keeper (~/tools/felix-ensure.sh). Detached and throttled to one
# launch a minute, exactly like the routes ensure above: the
# prelude never blocks on it. Best-effort: prints nothing here
# (change tokens land in the proxy log), never changes the exit
# contract.
{
  PROXY_SCRIPT=/home/hatch/tools/fleet-proxy-ensure.sh
  PROXY_STAMP=/home/hatch/.local/state/fleet/.proxy-ensure.last
  if [ -x "$PROXY_SCRIPT" ]; then
    mkdir -p /home/hatch/.local/state/fleet
    PROXY_NOW=$(date +%s 2>/dev/null || echo 0)
    PROXY_LAST=0
    [ -f "$PROXY_STAMP" ] && PROXY_LAST=$(cat "$PROXY_STAMP" 2>/dev/null || echo 0)
    case "$PROXY_LAST" in *[!0-9]*|"") PROXY_LAST=0 ;; esac
    if [ $((PROXY_NOW - PROXY_LAST)) -ge 60 ]; then
      echo "$PROXY_NOW" > "$PROXY_STAMP"
      setsid nohup "$PROXY_SCRIPT" >>/home/hatch/logs/fleet-proxy-ensure.log 2>&1 </dev/null &
    fi
  fi
} 2>/dev/null || true

# --- fleet binary links (2026-11-04, code#5343) ---
# ~/tools/bin/fleet is the PATH entry point for the fleet multicall
# binary, and repo-queue is its argv0 alias. Recreate either link if it
# has gone missing or dangling; a present, resolvable link is left
# untouched. Best-effort: never prints, never changes the exit contract.
{
  for link in fleet repo-queue; do
    if [ ! -e "/home/hatch/tools/bin/$link" ] && [ -x /home/hatch/tools/fleet ]; then
      ln -sfn /home/hatch/tools/fleet "/home/hatch/tools/bin/$link"
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
  # ~/tools/bin/gh is the durable-volume twin of the /usr/local/bin
  # link; recreate it if missing/dangling (2026-11-24).
  if [ -x "$SHIM" ] && [ "$(readlink -f /home/hatch/tools/bin/gh 2>/dev/null || echo none)" != "$SHIM" ]; then
    ln -sfn "$SHIM" /home/hatch/tools/bin/gh
  fi
  if [ -x "$SHIM" ] && [ -w /usr/local/bin ]; then
    if [ "$(readlink -f /usr/local/bin/gh 2>/dev/null || echo none)" != "$SHIM" ]; then
      ln -sfn "$SHIM" /usr/local/bin/gh
    fi
    # gh-orig: nix-profile gh preferred; while nix is out that path
    # dangles, so fall back to the packaged /usr/bin/gh (2026-11-24).
    if [ ! -e /usr/local/bin/gh-orig ]; then
      if [ -x /home/hatch/.nix-profile/bin/gh ]; then
        ln -sfn /home/hatch/.nix-profile/bin/gh /usr/local/bin/gh-orig
      elif [ -x /usr/bin/gh ]; then
        ln -sfn /usr/bin/gh /usr/local/bin/gh-orig
      fi
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
