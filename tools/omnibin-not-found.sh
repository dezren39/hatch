# omnibin command-not-found handler — near-0-step access to every nixpkgs binary.
#
# True 0-step (just type `python3@3.6.2`) needs the FUSE mount, which needs
# /dev/fuse from the sandbox runtime. Until then, this is the closest thing:
# source it from ~/.bashrc and any unknown command is looked up in the
# omnibin index, fetched from cache.nixos.org on first use, and executed.
#
#   $ jq --version            # not installed -> resolved, fetched, run
#   jq-1.8.1
#   $ python3@3.7.1 --version # versioned form works too
#   Python 3.7.1
#
# Requires: single-user nix at /nix, ~/tools/taint-shim/taint_shim.so.
# Install: append `source ~/tools/omnibin-not-found.sh` to ~/.bashrc.

command_not_found_handle() {
  local cmd="$1"; shift
  local NIX=/nix/var/nix/profiles/default/bin/nix
  local REALISE=/nix/var/nix/profiles/default/bin/nix-store
  local SHIM=/home/hatch/tools/taint-shim/taint_shim.so
  if [ ! -x "$NIX" ] || [ ! -x "$REALISE" ]; then
    printf 'bash: %s: command not found\n' "$cmd" >&2
    return 127
  fi

  local base="$cmd" ver=""
  if [[ "$cmd" == *@* ]]; then
    base="${cmd%%@*}"; ver="${cmd#*@}"
  fi

  # 1. Profile binary (fast path): nix profile install puts it on PATH via
  #    nix-profile-sync, but the @version form bypasses PATH. Check directly.
  local prof_bin="$HOME/.nix-profile/bin/$base"
  if [ -x "$prof_bin" ] && [ "$prof_bin" -ef "/usr/local/bin/$base" 2>/dev/null -o ! -e "/usr/local/bin/$base" ]; then
    if [ -z "$ver" ]; then
      exec "$prof_bin" "$@"
    else
      local got_ver
      got_ver=$("$prof_bin" --version 2>/dev/null | head -1 || true)
      case "$got_ver" in
        *"$ver"*) exec "$prof_bin" "$@" ;;
      esac
      # Version mismatch: fall through to omnibin/nixpkgs.
    fi
  fi

  local entry=""
  if [ -n "$ver" ]; then
    # Versioned form: name@version -> find the matching row of `which --all`.
    entry=$(LD_PRELOAD="$SHIM" "$NIX" run github:fzakaria/omnibin#omnibin \
      -- which --all "$base" 2>/dev/null | grep -F "$base@$ver"$'\t' | tail -1)
    entry="${entry##*$'\t'}"   # last field: /nix/store/<base>/bin/<exe>
  else
    entry=$(LD_PRELOAD="$SHIM" "$NIX" run github:fzakaria/omnibin#omnibin \
      -- which "$cmd" 2>/dev/null | head -1)
  fi

  # 2. Fallback: version not in omnibin index (stale pin) -> nixpkgs via nix run.
  if [ -z "$entry" ]; then
    LD_PRELOAD="$SHIM" "$NIX" run "nixpkgs#$base" -- "$@" 2>/dev/null && return $?
    printf 'bash: %s: command not found\n' "$cmd" >&2
    return 127
  fi

  local exe="${entry##*/}"          # <exe>
  local storepath="${entry%/bin/$exe}"  # /nix/store/<base>
  if [ ! -x "$storepath/bin/$exe" ]; then
    LD_PRELOAD="$SHIM" "$REALISE" --realise "$storepath" >/dev/null 2>&1 || {
      printf 'bash: %s: command not found\n' "$cmd" >&2
      return 127
    }
  fi
  "$storepath/bin/$exe" "$@"
}
