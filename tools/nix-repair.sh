#!/bin/bash
# ~/tools/nix-repair.sh — on-demand repair for partial nix breakage.
#
# Triggered by the shell-env.sh sentinel when it detects:
#   - /nix missing or not a symlink to /home/hatch/nix-persist
#   - bootstrap nix not executable
#   - /usr/local/bin/nix wrapper missing
#
# (Full recycle is handled by init.sh + the sandbox-boot-init cron;
# this covers partial breakage while the shell wrapper is still alive.)
#
# Safety properties:
#   - flock(1) exclusive lock: concurrent repairs serialize; a second
#     caller sees the lock held and exits 0 (repair already in progress).
#   - Recursion guard: sets NIX_REPAIR_GUARD for all children, and runs
#     nix-ensure.sh via /bin/bash.real with BASH_ENV unset, so nested
#     shells never re-trigger the sentinel.
#   - Verifies ACTUAL state after repair (not just "script ran ok").
#   - Never deletes /home/hatch/nix-persist on failure (nix-ensure.sh
#     upholds this); failures are loud and retryable.
set -u

LOCK=/home/hatch/.nix-repair.lock
ENSURE=/home/hatch/tools/nix-ensure.sh
SHIM=/home/hatch/tools/taint-shim/taint_shim.so
BOOTSTRAP_NIX=/nix/var/nix/profiles/bootstrap/bin/nix
EXPECTED_NIX_TARGET=/home/hatch/nix-persist

# Recursion guard for this process and all children.
export NIX_REPAIR_GUARD=1
# Children must not source the sentinel again.
export BASH_ENV=

log() { printf 'nix-repair: %s\n' "$*" >&2; }

# Non-blocking exclusive lock. If another repair holds it, we're done.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another repair in progress; skipping"
  exit 0
fi

log "starting (triggered by shell sentinel)"
if [ ! -x /bin/bash.real ]; then
  log "FATAL: /bin/bash.real missing — cannot run repair safely"
  exit 1
fi

# Run the repair via the real bash (no wrapper, no BASH_ENV).
/bin/bash.real "$ENSURE" >&2
ensure_rc=$?
if [ $ensure_rc -ne 0 ]; then
  log "nix-ensure.sh failed (rc=$ensure_rc); persistent data left intact, retryable"
  exit $ensure_rc
fi

# Restore wrappers (nix-ensure.sh doesn't cover these; they're overlay-ephemeral).
/bin/bash.real /home/hatch/tools/install-nix-wrapper.sh >&2 || log "nix wrapper reinstall failed"
/bin/bash.real /home/hatch/tools/install-bash-wrapper.sh >&2 || log "bash wrapper reinstall failed"

# --- verify ACTUAL state (not just exit code) ---
fail=0
tgt=$(readlink /nix 2>/dev/null || true)
if [ "$tgt" != "$EXPECTED_NIX_TARGET" ]; then
  log "VERIFY FAIL: /nix -> '$tgt' (expected $EXPECTED_NIX_TARGET)"; fail=1
fi
if ! LD_PRELOAD="$SHIM" "$BOOTSTRAP_NIX" --version >/dev/null 2>&1; then
  log "VERIFY FAIL: bootstrap nix does not run"; fail=1
fi
if [ ! -x /usr/local/bin/nix ]; then
  log "VERIFY FAIL: /usr/local/bin/nix missing"; fail=1
fi
if ! grep -q 'BASH_ENV=/home/hatch/tools/shell-env.sh' /bin/bash 2>/dev/null; then
  log "VERIFY FAIL: /bin/bash wrapper missing or stale"; fail=1
fi

if [ $fail -ne 0 ]; then
  log "verification failed; state may need manual attention"
  exit 1
fi
log "repair complete and verified"
exit 0
