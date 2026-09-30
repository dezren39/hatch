#!/bin/bash
# ~/tools/nix-ensure.sh — make nix usable. Idempotent.
#
# Layout: /nix is a SYMLINK to /home/hatch/nix-persist (persistent btrfs).
# No copy, no per-exec mount — the symlink is a filesystem entry visible to
# every exec. Two profiles separate concerns:
#   /nix/var/nix/profiles/bootstrap — nix itself (pinned store path).
#     The /usr/local/bin/nix wrapper execs this directly, so ordinary
#     `nix profile install` in the user profile can never take nix away.
#   /nix/var/nix/profiles/per-user/root/profile (a.k.a. ~/.nix-profile) —
#     ordinary packages. Both live under /nix/var, i.e. on the persistent
#     volume, so they survive recycles.
#
# Constraints:
# - The sandbox denies chown() even for root -> shim elides redundant chowns.
# - The sandbox denies removexattr on taint xattrs -> shim hides them.
# - The shim also hides the /nix symlink from nix's store guard and build
#   sandbox (allow-symlinked-store only covers the store-open path).
# - Never auto-delete/quarantine the persistent dir on failure (fail loud).
set -u
BOOTSTRAP=/nix/var/nix/profiles/bootstrap
NIXBIN=$BOOTSTRAP/bin/nix
PERSIST=/home/hatch/nix-persist
TARBALL=/home/hatch/tools/nix-store.tar.gz

# Needed for every nix invocation: hides taint xattrs, elides redundant
# chowns, and hides the /nix symlink from nix's store/build-sandbox checks
# (the sandbox blocks removexattr/chown; allow-symlinked-store only covers
# the store-open path).
export LD_PRELOAD=/home/hatch/tools/taint-shim/taint_shim.so

# /etc/nix is on the overlay, so rewrite every boot.
mkdir -p /etc/nix
for line in \
  "experimental-features = nix-command flakes" \
  "extra-substituters = https://omnibin.cachix.org" \
  "extra-trusted-public-keys = omnibin.cachix.org-1:HWeLv8+LfqLqLDOoQJmvmW7m0ug1Fne/DYaxgdECHgw=" \
  "accept-flake-config = true" \
  "allow-symlinked-store = true" \
  "build-users-group ="; do
  key="${line%% = *}"
  grep -q "^[[:space:]]*${key}[[:space:]]*=" /etc/nix/nix.conf 2>/dev/null \
    || echo "$line" >> /etc/nix/nix.conf
done

nix_works() {
  [ -x "$NIXBIN" ] && "$NIXBIN" eval --impure --expr '1 + 1' 2>/dev/null | grep -q '^2$'
}

persist_healthy() {
  [ -d "$PERSIST/store" ] && [ -n "$(ls -A "$PERSIST/store" 2>/dev/null)" ] \
    && [ -f "$PERSIST/var/nix/db/db.sqlite" ]
}

ensure_link() {
  if [ -L /nix ]; then
    [ "$(readlink /nix)" = "$PERSIST" ] && return 0
    rm -f /nix
  elif [ -e /nix ]; then
    # A real /nix dir is overlay cruft; clear it for the symlink.
    rm -rf /nix
  fi
  ln -s "$PERSIST" /nix
}

ensure_bootstrap() {
  # The bootstrap profile holds nix itself, pinned to a store path. It is a
  # GC root, so its nix binary can't be garbage-collected; and ordinary
  # `nix profile install` touches only the user profile, so this never needs
  # the old "rescue nix from ~/.nix-profile" logic. If the bootstrap link is
  # broken, reinstall from any nix binary found in the persistent store.
  [ -x "$NIXBIN" ] && return 0
  local boot_nix
  boot_nix=$(find "$PERSIST/store" -maxdepth 3 -path "*/bin/nix" -type f 2>/dev/null | head -1)
  if [ -z "$boot_nix" ]; then
    echo "FATAL: no nix binary found in $PERSIST/store" >&2
    return 1
  fi
  echo "nix-ensure: bootstrap nix missing; reinstalling into $BOOTSTRAP via $boot_nix" >&2
  rm -f "$BOOTSTRAP"
  LD_PRELOAD=/home/hatch/tools/taint-shim/taint_shim.so \
    "$boot_nix" profile add --profile "$BOOTSTRAP" "$(dirname "$(dirname "$boot_nix")")" 2>&1 | tail -2
  [ -x "$NIXBIN" ]
}

populate_persist() {
  # Fill $PERSIST from the tarball, or fresh install as last resort.
  # Never extract over a non-empty tree (tar hardlinks aren't idempotent).
  # NOTE: no build-user setup — nix.conf sets `build-users-group =` (empty),
  # so builds run as the calling UID. Verified with a genuine local build
  # 2026-09-30; the old nixbld accounts are inert leftovers.
  if [ -n "$(ls -A "$PERSIST" 2>/dev/null)" ]; then
    local bad="$PERSIST.bad.$(date +%s)"
    echo "WARNING: $PERSIST non-empty but unhealthy; moving aside to $bad" >&2
    mv "$PERSIST" "$bad"
  fi
  mkdir -p "$PERSIST"
  if [ -s "$TARBALL" ]; then
    tar -xzpf "$TARBALL" -C "$PERSIST" --strip-components=1 2>/dev/null
    tar -xzpf "$TARBALL" -C "$PERSIST" --strip-components=1 2>/dev/null || true
  else
    rm -rf /nix; mkdir -p /nix
    bash /home/hatch/tools/nix-install.sh
    cp -a /nix/. "$PERSIST/" 2>/dev/null || true
    rm -rf /nix
  fi
}

persist_healthy || populate_persist
ensure_link
ensure_bootstrap
nix_works
