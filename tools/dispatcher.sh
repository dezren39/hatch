#!/bin/bash
# ~/tools/dispatcher.sh — single resolver for `program[@version]` requests.
#
# Called by:
#   - command_not_found_handle (via BASH_ENV) for interactive `foo` / `foo@1.2`
#   - executable stubs in ~/tools/bin/ for subprocess/build-tool discovery
#
# What it does:
#   1. Resolves name[@version] via the pinned omnibin index (never the
#      floating flake).
#   2. Downloads the closure (nix-store --realise).
#   3. Registers a persistent GC root so the binary survives `nix store gc`.
#   4. Caches the resolution on disk (cache hit = no nix invocation).
#   5. Creates/refreshes a stub in ~/tools/bin/<name> for subprocess use.
#   6. execs the binary, preserving args and exit status.
#
# Rules:
#   - An explicit name@version that has NO exact match in the index is a
#     LOUD failure (exit 127). We never silently substitute another version.
#   - The omnibin pin is refreshed ONLY by ~/tools/omnibin-refresh.sh,
#     never on a cache miss.
set -u

DISPATCHER_DIR=/home/hatch/tools/dispatcher
CACHE_DIR=$DISPATCHER_DIR/cache
GCROOT_DIR=/nix/var/nix/gcroots/dispatcher
STUB_DIR=/home/hatch/tools/bin
PIN_FILE=$DISPATCHER_DIR/omnibin-pin
NIXBIN=/nix/var/nix/profiles/bootstrap/bin/nix
SHIM=/home/hatch/tools/taint-shim/taint_shim.so

# nix with the shim, bypassing the /usr/local/bin wrapper (overlay-ephemeral).
xnix() { LD_PRELOAD="$SHIM" "$NIXBIN" "$@"; }

die() { printf 'dispatcher: %s\n' "$1" >&2; exit "${2:-127}"; }

# --- management commands (not a program lookup) ---
case "${1:-}" in
  --gc-list)
    for r in "$GCROOT_DIR"/*; do [ -e "$r" ] || continue
      printf '%s -> %s\n' "$(basename "$r")" "$(readlink "$r")"; done
    exit 0 ;;
  --gc-remove)
    [ -n "${2:-}" ] || die "usage: dispatcher.sh --gc-remove <name[@version]>" 2
    rm -f "$GCROOT_DIR/$2" "$CACHE_DIR/$2" "$STUB_DIR/${2%%@*}"
    echo "removed $2"; exit 0 ;;
  --refresh-index)
    exec /home/hatch/tools/omnibin-refresh.sh ;;
esac

[ -n "${1:-}" ] || die "usage: dispatcher.sh <program[@version]> [args...]" 2
[ -f "$PIN_FILE" ] || die "omnibin pin missing: $PIN_FILE" 2
PIN=$(cat "$PIN_FILE")
OMNIBIN="github:fzakaria/omnibin/$PIN#omnibin"

cmd="$1"; shift
base="$cmd"; ver=""
if [[ "$cmd" == *@* ]]; then base="${cmd%%@*}"; ver="${cmd#*@}"; fi
[ -n "$base" ] || die "empty program name" 2
cache_key="$cmd"   # "name" or "name@version"

# --- 1. cache hit? ---
if [ -f "$CACHE_DIR/$cache_key" ]; then
  binpath=$(cat "$CACHE_DIR/$cache_key")
  if [ -x "$binpath" ]; then
    exec "$binpath" "$@"
  fi
  # stale cache entry (binary GC'd or store path gone) — fall through
fi

# --- 2. resolve via pinned omnibin index (profile first for exact versions) ---
[ -x "$NIXBIN" ] || die "bootstrap nix not executable: $NIXBIN" 2
entry=""
if [ -n "$ver" ]; then
  # 2a. User profile fast path: an installed binary whose --version contains
  # the requested version is an exact match (not a substitution).
  prof_bin="$HOME/.nix-profile/bin/$base"
  if [ -x "$prof_bin" ]; then
    got_ver=$("$prof_bin" --version 2>/dev/null | head -1 || true)
    case "$got_ver" in
      *"$ver"*) entry="$prof_bin" ;;
    esac
  fi
  # 2b. Pinned omnibin index: exact version only.
  if [ -z "$entry" ]; then
    # Exact version only. grep for "base@version<TAB>" — anchored, no fuzzy.
    entry=$(xnix run "$OMNIBIN" -- which --all "$base" 2>/dev/null \
      | grep -F "$base@$ver"$'\t' | tail -1)
    entry="${entry##*$'\t'}"
  fi
  [ -n "$entry" ] || die "no exact match for '$cmd' in the user profile or the pinned omnibin index (refusing to substitute another version)" 127
else
  entry=$(xnix run "$OMNIBIN" -- which "$base" 2>/dev/null | head -1)
  [ -n "$entry" ] || {
    # Fallback: nixpkgs attribute (covers packages the index missed).
    if xnix run "nixpkgs#$base" -- true 2>/dev/null; then
      # Resolve the actual store path nix would run.
      entry=$(xnix build "nixpkgs#$base" --no-link --print-out-paths 2>/dev/null | head -1)
      [ -n "$entry" ] && entry="$entry/bin/$base"
    fi
  }
  [ -n "$entry" ] || die "bash: $cmd: command not found" 127
fi

exe="${entry##*/}"
storepath="${entry%/bin/$exe}"
[ -n "$storepath" ] && [ "$storepath" != "$entry" ] \
  || die "could not parse resolution result: $entry" 2

# Profile binaries are already installed (the profile itself is a GC root);
# skip download and root registration for them.
from_profile=0
case "$storepath" in
  /nix/store/*) ;;
  *) from_profile=1 ;;
esac

# --- 3. download the closure (store paths only) ---
if [ "$from_profile" = 0 ] && [ ! -x "$entry" ]; then
  xnix store realise "$storepath" >/dev/null 2>&1 \
    || die "failed to realise $storepath" 2
fi
[ -x "$entry" ] || die "resolved binary not executable: $entry" 2

# --- 4. persistent GC root (store paths only; survives `nix store gc`) ---
if [ "$from_profile" = 0 ]; then
  mkdir -p "$GCROOT_DIR"
  ln -sfn "$storepath" "$GCROOT_DIR/$cache_key"
fi

# --- 5. cache the resolution ---
mkdir -p "$CACHE_DIR"
printf '%s' "$entry" > "$CACHE_DIR/$cache_key"

# --- 6. stub for subprocess/build-tool discovery (unversioned name only) ---
mkdir -p "$STUB_DIR"
stub="$STUB_DIR/$base"
if [ ! -e "$stub" ]; then
  cat > "$stub" <<EOF
#!/bin/bash
# Auto-generated stub by dispatcher.sh — do not edit.
# Resolves '$base' via the dispatcher (cached) so subprocesses and build
# tools can discover it without bash's command_not_found_handle.
exec /home/hatch/tools/dispatcher.sh "$base" "\$@"
EOF
  chmod +x "$stub"
fi

# --- 7. run it, preserving args and exit status ---
exec "$entry" "$@"
