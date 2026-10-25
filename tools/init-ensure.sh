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

# --- Warm check: marker matches this boot AND backstop timer installed ---
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || echo none)" = "$BOOT_ID" ] \
   && [ -f "$TIMER_UNIT" ]; then
  exit 0
fi

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
