#!/bin/bash
# ~/tools/init.sh — boot/init restore for the agent sandbox.
# Restores ephemeral state (system users, /nix symlink, wrappers, ...)
# after the sandbox is recycled. Idempotent: safe to run any time; skips work
# when the marker matches the current boot AND all restores are in place.
set -u
LOG_DIR=/home/hatch/logs
LOG=$LOG_DIR/init.log
STATUS=$LOG_DIR/init-status
MARKER=$LOG_DIR/.init-boot-id
mkdir -p "$LOG_DIR"

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
BOOT_TIME=$(uptime -s 2>/dev/null || echo unknown)
START_DT=$(date '+%Y-%m-%d %H:%M:%S %Z')
START_EPOCH=$(date +%s)

# --- Previous boot info (before we overwrite STATUS) ---
PREV_BOOT_ID="none"
PREV_END="none"
if [ -f "$STATUS" ]; then
  PREV_BOOT_ID=$(grep '^boot_id=' "$STATUS" 2>/dev/null | cut -d= -f2 || echo "none")
  PREV_END=$(grep '^end_datetime=' "$STATUS" 2>/dev/null | cut -d= -f2- || echo "none")
fi

# --- System snapshot ---
KERNEL=$(uname -r 2>/dev/null || echo unknown)
OS_VER=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo unknown)
CPU_COUNT=$(nproc 2>/dev/null || echo unknown)
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2"M"}' || echo unknown)
DISK_HOME=$(df -h /home/hatch 2>/dev/null | awk 'NR==2{print $4" free of "$2}' || echo unknown)
NIX_SIZE=$(du -sh /home/hatch/nix-persist 2>/dev/null | cut -f1 || echo unknown)

# --- Network check (TCP latency, ICMP blocked) ---
NET_OK="no"
NET_LAT="null"
if timeout 10 curl -sI https://cache.nixos.org/ 2>/dev/null | head -1 | grep -q "200"; then
  NET_OK="yes"
  # 3 quick samples for latency
  NET_LAT=$(for i in 1 2 3; do
    curl -s -o /dev/null -w "%{time_total}\n" --max-time 10 https://cache.nixos.org/ 2>/dev/null || echo "0"
  done | awk '$1>0{sum+=$1;n++} END{if(n>0)printf "%.3f", sum/n; else print "null"}')
  [ "$NET_LAT" = "null" ] || NET_LAT="$NET_LAT"
fi

nix_works() {
  # Use the /usr/local/bin wrapper (sets LD_PRELOAD for the symlink shim),
  # not the raw binary path which trips nix's symlink guard.
  [ -x /usr/local/bin/nix ] \
    && /usr/local/bin/nix eval --impure --expr '1 + 1' 2>/dev/null | grep -q '^2$'
}

# --- Personal-repo symlink guard (~/hatch-personal, private) ---
# The canonical personal paths under $HOME are symlinks into ~/hatch-personal.
# If anything ever replaces a link with a real file/dir, edits would silently
# stop reaching the private repo — detect and repair loudly. Runs on every
# poll (cheap: a dozen stats), not just on boot.
PERSONAL_REPO=/home/hatch/hatch-personal
PERSONAL_LINKS="MEMORY.md USER.md SOUL.md IDENTITY.md AGENTS.md HEARTBEAT.md PROACTIVE_PREFERENCES.md memory dreams logs workspace/goals workspace/user"
# NOTE: ~/user is intentionally NOT managed here — it is Meta platform runtime
# state (voice-call lifecycle), and a platform process recreates it as a real
# dir (observed 2026-09-30). A backup copy lives in the personal repo.
check_personal_links() {
  local rel link target stamp
  for rel in $PERSONAL_LINKS; do
    link="/home/hatch/$rel"
    target="$PERSONAL_REPO/$rel"
    if [ -L "$link" ]; then
      if [ "$(readlink "$link")" != "$target" ]; then
        echo "[$START_DT] init: personal-link '$rel' pointed at $(readlink "$link") — re-pointing" >> "$LOG"
        ln -sfn "$target" "$link"
      fi
      continue
    fi
    if [ ! -e "$target" ]; then
      echo "[$START_DT] init: personal-link '$rel' BROKEN — repo target $target missing, cannot repair" >> "$LOG"
      continue
    fi
    if [ -e "$link" ]; then
      # Real file/dir where a symlink should be: keep the newer content, then re-link.
      stamp=$(date +%Y%m%d-%H%M%S)
      mkdir -p "$PERSONAL_REPO/.desync-backup"
      if [ -f "$link" ] && [ -f "$target" ] && [ "$link" -nt "$target" ]; then
        cp -p "$link" "$target"
        echo "[$START_DT] init: personal-link '$rel' was a real file NEWER than the repo copy — synced into repo first" >> "$LOG"
      fi
      mv "$link" "$PERSONAL_REPO/.desync-backup/$(printf '%s' "$rel" | tr '/' '_').$stamp"
      echo "[$START_DT] init: personal-link '$rel' was a real file/dir — moved aside to .desync-backup, re-linking" >> "$LOG"
    else
      echo "[$START_DT] init: personal-link '$rel' missing — re-creating" >> "$LOG"
    fi
    ln -s "$target" "$link"
  done
}
check_personal_links

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$BOOT_ID" ] && nix_works; then
  echo "[$START_DT] init: already initialized for boot $BOOT_ID, nothing to do" >> "$LOG"
  exit 0
fi

# --- Log boot context ---
{
  echo "[$START_DT] init: START boot_id=$BOOT_ID boot_time='$BOOT_TIME'"
  echo "[$START_DT] init: prev_boot_id=$PREV_BOOT_ID prev_end='$PREV_END'"
  echo "[$START_DT] init: sys kernel=$KERNEL os='$OS_VER' cpus=$CPU_COUNT mem=$MEM_TOTAL"
  echo "[$START_DT] init: sys disk_home='$DISK_HOME' nix_persist=$NIX_SIZE net_cache_nixos_org=$NET_OK"
} >> "$LOG"

FAILURES=0

run_step() { # name, then command + args
  local name="$1"; shift
  local step_start=$(date +%s)
  if "$@" >>"$LOG" 2>&1; then
    local step_dur=$(($(date +%s) - step_start))
    echo "[$START_DT] init: step '$name' OK (${step_dur}s)" >> "$LOG"
  else
    local code=$?
    local step_dur=$(($(date +%s) - step_start))
    echo "[$START_DT] init: step '$name' FAILED (exit $code, ${step_dur}s) — see output above" >> "$LOG"
    FAILURES=$((FAILURES+1))
  fi
}

run_step "nix-ensure" bash /home/hatch/tools/nix-ensure.sh
run_step "nix-wrapper" bash /home/hatch/tools/install-nix-wrapper.sh
run_step "nix-profile-sync" bash /home/hatch/tools/nix-profile-sync.sh
run_step "mcpx-service" bash /home/hatch/tools/install-mcpx-service.sh
run_step "bash-wrapper" bash /home/hatch/tools/install-bash-wrapper.sh
run_step "go-check" bash -c '[ -x /home/hatch/tools/go/bin/go ] && /home/hatch/tools/go/bin/go version'
run_step "rust-check" bash -c 'export CARGO_HOME=/home/hatch/tools/cargo RUSTUP_HOME=/home/hatch/tools/rustup; [ -x /home/hatch/tools/cargo/bin/cargo ] && /home/hatch/tools/cargo/bin/cargo --version'
# (future restore steps go here as run_step lines)

# --- Post-init health snapshot ---
NIX_VERSION=$(nix --version 2>/dev/null || echo "nix_broken")
STORE_PATHS=$(ls /nix/store 2>/dev/null | wc -l || echo 0)
PROFILE_PKGS=$(ls /nix/var/nix/profiles/default/bin 2>/dev/null | wc -l || echo 0)

QUOTA=$(/opt/hatch/bin/subscription-status status 2>/dev/null | tr '\n' '; ' || echo "quota query failed")

END_DT=$(date '+%Y-%m-%d %H:%M:%S %Z')
END_EPOCH=$(date +%s)
INIT_SECS=$((END_EPOCH - START_EPOCH))

if [ "$FAILURES" -eq 0 ]; then RESULT="SUCCESS"; else RESULT="FAILURES=$FAILURES"; fi
{
  echo "boot_datetime=$BOOT_TIME"
  echo "boot_id=$BOOT_ID"
  echo "start_datetime=$START_DT"
  echo "end_datetime=$END_DT"
  echo "init_seconds=$INIT_SECS"
  echo "result=$RESULT"
  echo "kernel=$KERNEL"
  echo "os=$OS_VER"
  echo "disk_home=$DISK_HOME"
  echo "nix_persist_size=$NIX_SIZE"
  echo "nix_version=$NIX_VERSION"
  echo "store_paths=$STORE_PATHS"
  echo "profile_bins=$PROFILE_PKGS"
  echo "net_cache=$NET_OK"
  echo "quota=$QUOTA"
} > "$STATUS"
echo "[$END_DT] init: END result=$RESULT init_secs=$INIT_SECS nix=$NIX_VERSION store_paths=$STORE_PATHS profile_bins=$PROFILE_PKGS quota=[$QUOTA]" >> "$LOG"

# --- Compact JSON telemetry (one line per boot, machine-parseable) ---
JSONL=$LOG_DIR/init.jsonl
# Escape quotes for JSON
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
{
  printf '{"ts":"%s","boot_id":"%s","boot_time":"%s","prev_boot_id":"%s","result":"%s","init_secs":%d,' \
    "$(json_esc "$END_DT")" "$(json_esc "$BOOT_ID")" "$(json_esc "$BOOT_TIME")" "$(json_esc "$PREV_BOOT_ID")" "$(json_esc "$RESULT")" "$INIT_SECS"
  printf '"kernel":"%s","os":"%s","cpus":"%s","mem":"%s","disk_home":"%s","nix_persist":"%s",' \
    "$(json_esc "$KERNEL")" "$(json_esc "$OS_VER")" "$(json_esc "$CPU_COUNT")" "$(json_esc "$MEM_TOTAL")" "$(json_esc "$DISK_HOME")" "$(json_esc "$NIX_SIZE")"
  printf '"net_ok":"%s","net_lat_s":%s,"nix_version":"%s","store_paths":%s,"profile_bins":%s}\n' \
    "$(json_esc "$NET_OK")" "$NET_LAT" "$(json_esc "$NIX_VERSION")" "$STORE_PATHS" "$PROFILE_PKGS"
} >> "$JSONL"

if [ "$FAILURES" -eq 0 ]; then
  echo "$BOOT_ID" > "$MARKER"   # only mark clean boots; failures retry next poll
  exit 0
else
  exit 1
fi
