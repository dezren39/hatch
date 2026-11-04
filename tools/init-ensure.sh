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
{
  BROKER_SOCK=/home/hatch/.cache/laptop-agent/broker.sock
  BROKER_LOG=/home/hatch/.cache/laptop-agent/broker.log
  if [ ! -S "$BROKER_SOCK" ] || ! pgrep -f 'laptop-agent-broker\.py' >/dev/null 2>&1; then
    mkdir -p /home/hatch/.cache/laptop-agent
    exec 9>"/home/hatch/.cache/laptop-agent/.broker-ensure.lock"
    if flock -n 9; then
      setsid nohup python3 /home/hatch/tools/laptop-agent-broker.py \
        >>"$BROKER_LOG" 2>&1 </dev/null &
    fi
    exec 9>&-
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
