# ~/tools/shell-env.sh — sourced via BASH_ENV by every non-interactive bash.
#
# STARTUP-CLEAN BY DESIGN: this file must never do network I/O, run nix,
# or refresh anything. It only:
#   1. puts the persistent dispatcher stubs dir on PATH (no duplicates,
#      appended so system binaries keep precedence), and
#   2. defines command_not_found_handle, which execs the dispatcher.
# All resolution/download/caching lives in ~/tools/dispatcher.sh.
# (Replaces the old omnibin-not-found.sh, which ran nix on every miss
# inline; the dispatcher now owns that path with caching + GC roots.)

# 1. stubs dir on PATH (append; no duplicates)
case ":${PATH}:" in
  *":$HOME/tools/bin:"*) ;;
  *) export PATH="$PATH:$HOME/tools/bin" ;;
esac

# 2. unknown command -> dispatcher (handles name[@version], then execs)
command_not_found_handle() {
  exec /home/hatch/tools/dispatcher.sh "$@"
}

# 3. on-demand repair sentinel — cheap stats only, NO nix invocation here.
# If /nix, the profile nix, or the nix wrapper look broken, run nix-repair.sh
# synchronously so the current shell session is healed. Guarded by
# NIX_REPAIR_GUARD so repair children (BASH_ENV is unset there) never
# re-trigger. Failures are non-fatal to the shell.
if [ -z "${NIX_REPAIR_GUARD:-}" ]; then
  if [ ! -L /nix ] \
     || [ ! -x /nix/var/nix/profiles/per-user/root/profile/bin/nix ] \
     || [ ! -x /usr/local/bin/nix ]; then
    NIX_REPAIR_GUARD=1 /bin/bash.real /home/hatch/tools/nix-repair.sh || true
  fi
fi
