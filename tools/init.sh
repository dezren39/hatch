#!/bin/bash
# ~/tools/init.sh — boot/init restore for the agent sandbox.
# Restores ephemeral state (system users, /nix symlink, wrappers, ...)
# after the sandbox is recycled. Idempotent: safe to run any time; skips work
# when the marker matches the current boot AND all restores are in place.
# Hardened 2026-10-25 (Drew: "fix init to not crash"): every step runs
# under a per-step timeout, critical service restores run before all
# heavy/telemetry work, and no single command may block the sequence —
# see run_step and the deferred-telemetry block below.
set -u
LOG_DIR=/home/hatch/logs
LOG=$LOG_DIR/init.log
STATUS=$LOG_DIR/init-status
MARKER=$LOG_DIR/.init-boot-id
mkdir -p "$LOG_DIR"

# --- Concurrency backstop: only one init at a time (Phase A, 2026-10-25) ---
exec 9>"$LOG_DIR/.init.lock"
if ! flock -n 9; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: another init already running, exiting" >> "$LOG"
  exit 0
fi

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

# --- System snapshot (cheap fields only) ---
# The expensive telemetry — nix-persist size (du over the ~58G tree) and
# the cache.nixos.org latency probe — is measured AFTER the restore
# steps (see "Deferred telemetry" below). An unbounded du here stalled
# the 2026-10-25 16:07 boot for ~40 min before any step ran, leaving
# every proxy port dark; even bounded, telemetry has no business ahead
# of the critical restores. Defaults are set now so the STATUS/JSONL
# keys always exist with truthful values.
KERNEL=$(uname -r 2>/dev/null || echo unknown)
OS_VER=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo unknown)
CPU_COUNT=$(nproc 2>/dev/null || echo unknown)
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2"M"}' || echo unknown)
DISK_HOME=$(df -h /home/hatch 2>/dev/null | awk 'NR==2{print $4" free of "$2}' || echo unknown)
NIX_SIZE="unknown"
NET_OK="no"
NET_LAT="null"

nix_works() {
  # Use the /usr/local/bin wrapper (sets LD_PRELOAD for the symlink shim),
  # not the raw binary path which trips nix's symlink guard.
  # Bounded: a wedged store lock must not stall the fast-path check.
  [ -x /usr/local/bin/nix ] \
    && timeout 30 /usr/local/bin/nix eval --impure --expr '1 + 1' 2>/dev/null | grep -q '^2$'
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
      if [ ! -e "$target" ]; then
        echo "[$START_DT] init: personal-link '$rel' DANGLING — target $target missing from repo" >> "$LOG"
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

# Workspace symlink layer (27 relocated trees + supabase private subsets +
# archer-slack state dir): repaired by tools/restore-workspace-links.sh,
# which is quiet when every link is correct and never clobbers a real
# path. Runs before the warm-boot exit, like the guard above; failures
# are logged, never fatal to init.
/home/hatch/tools/restore-workspace-links.sh >> "$LOG" 2>&1 || echo "[$START_DT] init: restore-workspace-links reported a problem (see above)" >> "$LOG"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$BOOT_ID" ] && nix_works; then
  echo "[$START_DT] init: already initialized for boot $BOOT_ID, nothing to do" >> "$LOG"
  exit 0
fi

# --- Log boot context ---
{
  echo "[$START_DT] init: START boot_id=$BOOT_ID boot_time='$BOOT_TIME'"
  echo "[$START_DT] init: prev_boot_id=$PREV_BOOT_ID prev_end='$PREV_END'"
  echo "[$START_DT] init: sys kernel=$KERNEL os='$OS_VER' cpus=$CPU_COUNT mem=$MEM_TOTAL"
  echo "[$START_DT] init: sys disk_home='$DISK_HOME' nix_persist=deferred net_cache_nixos_org=deferred"
} >> "$LOG"

FAILURES=0

# run_step name budget-seconds command...
# Every step runs under `timeout`: a hung step is killed at its budget,
# logged as FAILED, and the sequence CONTINUES to the END marker. Before
# this, a single wedged step held init (and its flock) forever and no
# later restore ran — the failure shape behind the dark proxy ports on
# 2026-10-25. Budgets are ceilings, not targets: healthy steps take
# seconds; the large ones cover cold-cache network/store work under
# load. A timeout counts as a failure, so result= stays truthful and
# the boot marker is not written (the next poll retries).
run_step() {
  local name="$1" budget="$2"; shift 2
  local step_start=$(date +%s)
  timeout --signal=TERM --kill-after=15 "$budget" "$@" >>"$LOG" 2>&1
  local code=$?
  local step_dur=$(($(date +%s) - step_start))
  local now=$(date '+%Y-%m-%d %H:%M:%S %Z')
  if [ "$code" -eq 0 ]; then
    echo "[$now] init: step '$name' OK (${step_dur}s)" >> "$LOG"
  elif [ "$code" -eq 124 ]; then
    echo "[$now] init: step '$name' FAILED (timeout after ${budget}s budget, ran ${step_dur}s) — see output above" >> "$LOG"
    FAILURES=$((FAILURES+1))
  else
    echo "[$now] init: step '$name' FAILED (exit $code, ${step_dur}s) — see output above" >> "$LOG"
    FAILURES=$((FAILURES+1))
  fi
}

# Critical path first: nix plumbing, then every service installer
# (units + opencode-serve + mcpx + proxies + supervisor), then shell
# plumbing. Heavy non-essentials are deferred below the services.
run_step "nix-ensure" 600 bash /home/hatch/tools/nix-ensure.sh
run_step "nix-wrapper" 120 bash /home/hatch/tools/install-nix-wrapper.sh
run_step "nix-profile-sync" 120 bash /home/hatch/tools/nix-profile-sync.sh
# DISABLED by Drew 2026-10-25: mcpx + opencode-serve autostart off on the
# sandbox (units left installed; manual start still works). Do not re-enable.
# run_step "mcpx-service" 180 bash /home/hatch/tools/install-mcpx-service.sh
# run_step "opencode-service" 300 bash /home/hatch/tools/install-opencode-service.sh
# DISABLED by Drew 2026-10-28: board-agent autostart off on the sandbox
# (General Board unused — no real posts since bring-up 2026-10-23; cleanup
# decision pending). Unit left installed; manual start still works.
# run_step "board-agent-service" 180 bash /home/hatch/tools/install-board-agent-service.sh
# DISABLED by Drew 2026-10-25 (20:52 follow-up): muse-proxy autostart off
# (also removed from proxy-supervisor config). Do not re-enable.
# run_step "muse-proxy-service" 180 bash /home/hatch/tools/install-muse-proxy-service.sh
# DISABLED by Drew 2026-10-25: agy-proxy autostart off (also removed from
# proxy-supervisor config). Do not re-enable.
# run_step "agy-proxy-service" 180 bash /home/hatch/tools/install-agy-proxy-service.sh
# DISABLED by Drew 2026-10-25 (20:52 follow-up): commandcode-proxy +
# claude-code-proxy autostart off (also removed from proxy-supervisor
# config). Do not re-enable.
# run_step "commandcode-proxy-service" 180 bash /home/hatch/tools/install-commandcode-proxy-service.sh
# run_step "claude-code-proxy-service" 180 bash /home/hatch/tools/install-claude-code-proxy-service.sh
# DISABLED by Drew 2026-10-25 (20:52 follow-up): proxy-supervisor off —
# its config now manages zero relays (muse/commandcode/codex all removed),
# so the timer and its installer no longer run. Do not re-enable.
# run_step "proxy-supervisor-service" 420 bash /home/hatch/tools/install-proxy-supervisor-service.sh
run_step "bash-wrapper" 120 bash /home/hatch/tools/install-bash-wrapper.sh
# Deferred heavy work: mcpx-servers performs unpinned network installs
# (npm/go/gh/Chrome downloads; 119s under load on 2026-10-25) and used
# to sit ahead of every service restore. mcpx-service above skips
# quietly if the daemon binary is absent, and services-verify (last)
# re-runs its installer, so a cold mcpx still converges within the run.
# DISABLED by Drew 2026-10-25: mcpx-servers gated with the mcpx service
# above (no daemon to serve them while mcpx autostart is off). Do not re-enable.
# run_step "mcpx-servers" 900 bash /home/hatch/tools/install-mcpx-servers.sh
run_step "go-check" 60 bash -c '[ -x /home/hatch/tools/go/bin/go ] && /home/hatch/tools/go/bin/go version'
run_step "rust-check" 60 bash -c 'export CARGO_HOME=/home/hatch/tools/cargo RUSTUP_HOME=/home/hatch/tools/rustup; [ -x /home/hatch/tools/cargo/bin/cargo ] && /home/hatch/tools/cargo/bin/cargo --version'
# (future restore steps go here as run_step lines)
run_step "services-verify" 900 bash /home/hatch/tools/verify-services.sh

# --- Deferred telemetry (measured only after every restore step) ---
# Every command bounded; the values land in STATUS/JSONL under the
# same keys as always (nix_persist_size, net_cache, quota, ...). See
# the snapshot comment near the top for why this no longer runs first.
NIX_SIZE=$(timeout 60 du -sh /home/hatch/nix-persist 2>/dev/null | cut -f1)
[ -n "$NIX_SIZE" ] || NIX_SIZE=unknown
if timeout 10 curl -sI https://cache.nixos.org/ 2>/dev/null | head -1 | grep -q "200"; then
  NET_OK="yes"
  # 3 quick samples for latency
  NET_LAT=$(for i in 1 2 3; do
    curl -s -o /dev/null -w "%{time_total}\n" --max-time 10 https://cache.nixos.org/ 2>/dev/null || echo "0"
  done | awk '$1>0{sum+=$1;n++} END{if(n>0)printf "%.3f", sum/n; else print "null"}')
fi

# --- Post-init health snapshot ---
NIX_VERSION=$(timeout 15 nix --version 2>/dev/null || echo "nix_broken")
STORE_PATHS=$(timeout 30 ls /nix/store 2>/dev/null | wc -l || echo 0)
PROFILE_PKGS=$(timeout 30 ls /nix/var/nix/profiles/default/bin 2>/dev/null | wc -l || echo 0)

QUOTA=$(timeout 30 /opt/hatch/bin/subscription-status status 2>/dev/null | tr '\n' '; ' || echo "quota query failed")

END_DT=$(date '+%Y-%m-%d %H:%M:%S %Z')
END_EPOCH=$(date +%s)
INIT_SECS=$((END_EPOCH - START_EPOCH))

# --- Airthings monitor: reinstall systemd units if missing ---
# /etc/systemd/system does not survive sandbox recycles; the units live in
# the persistent repo and install.sh is idempotent.
ATM_DIR=/home/hatch/hatch-personal/scripts/airthings-monitor
if [ -x "$ATM_DIR/install.sh" ]; then
  if ! systemctl is-active --quiet airthings-monitor.timer 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring airthings-monitor timer" >> "$LOG"
    timeout 120 "$ATM_DIR/install.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

# --- Fleet units: reinstall systemd units if missing ---
# Same pattern as Airthings above; the units live in the persistent repo.
FU_DIR=/home/hatch/hatch-personal/scripts/fleet-units
if [ -x "$FU_DIR/install.sh" ]; then
  if ! systemctl is-active --quiet init-ensure.timer 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring fleet units" >> "$LOG"
    timeout 120 "$FU_DIR/install.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

# --- Fleet-feed collector: reinstall systemd units if missing ---
# Same pattern as above; the units + installer live in the pm-feed clone
# (developing-today/code#903).
FFC_DIR=/home/hatch/git/pm-feed/pm-stack/aggregator
if [ -x "$FFC_DIR/scripts/install-collector-units.sh" ]; then
  if ! systemctl is-active --quiet fleet-feed-collector.timer 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring fleet-feed collector timer" >> "$LOG"
    timeout 120 "$FFC_DIR/scripts/install-collector-units.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

# --- Resource sampler: reinstall systemd unit if missing ---
# Same pattern as above; the unit + installer live in hatch-personal
# (scripts/resource-sampler). 1s load/mem/top-process log to
# ~/logs/resource so the minutes before any crash stay on disk.
RS_DIR=/home/hatch/hatch-personal/scripts/resource-sampler
if [ -x "$RS_DIR/install-sampler-units.sh" ]; then
  if ! systemctl is-active --quiet resource-sampler.service 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring resource sampler" >> "$LOG"
    timeout 120 "$RS_DIR/install-sampler-units.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

# --- Hatch-personal autocommit: reinstall systemd units if missing ---
# Same pattern as above; the units + installer live in hatch-personal
# (scripts/hatch-autocommit). Every-minute commit+push of everything
# uncommitted in hatch-personal, so a repeat of the 2026-10-25 deletion
# incident can never lose more than ~1 minute of uncommitted work.
AC_DIR=/home/hatch/hatch-personal/scripts/hatch-autocommit
if [ -x "$AC_DIR/install-autocommit-units.sh" ]; then
  if ! systemctl is-active --quiet hatch-autocommit.timer 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring hatch-autocommit timer" >> "$LOG"
    timeout 120 "$AC_DIR/install-autocommit-units.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

# --- Sandbox state backup: reinstall systemd units if missing ---
# Same pattern as above; the units + installer live in hatch-personal
# (scripts/sandbox-state-backup). Daily restic backup of ~/.config to
# R2 (diff-only chunks); config is never committed to git (Drew,
# 2026-10-28).
SB_DIR=/home/hatch/hatch-personal/scripts/sandbox-state-backup
if [ -x "$SB_DIR/install-backup-units.sh" ]; then
  if ! systemctl is-active --quiet sandbox-state-backup.timer 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring sandbox-state-backup timer" >> "$LOG"
    timeout 120 "$SB_DIR/install-backup-units.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

# --- Sandbox home backup: reinstall systemd units if missing ---
# Same pattern as above; units + installer live in hatch-personal
# (scripts/sandbox-home-backup). Daily restic backup of ALL of
# /home/hatch to R2 (diff-only chunks) — Drew's directive 2026-10-31
# after the config-only backup's gap cost 8,261 ~/agents originals.
SH_DIR=/home/hatch/hatch-personal/scripts/sandbox-home-backup
if [ -x "$SH_DIR/install-backup-units.sh" ]; then
  if ! systemctl is-active --quiet sandbox-home-backup.timer 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] init: restoring sandbox-home-backup timer" >> "$LOG"
    timeout 120 "$SH_DIR/install-backup-units.sh" >>"$LOG" 2>&1 || FAILURES=$((FAILURES+1))
  fi
fi

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
echo "[$END_DT] init: END result=$RESULT init_secs=$INIT_SECS nix=$NIX_VERSION store_paths=$STORE_PATHS profile_bins=$PROFILE_PKGS nix_persist=$NIX_SIZE net_cache=$NET_OK net_lat_s=$NET_LAT quota=[$QUOTA]" >> "$LOG"

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
