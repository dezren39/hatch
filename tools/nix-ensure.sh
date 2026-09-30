#!/bin/bash
# ~/tools/nix-ensure.sh — make nix usable. Idempotent.
#
# Layout: /nix is a SYMLINK to /home/hatch/nix-persist (persistent btrfs).
# No copy, no per-exec mount — the symlink is a filesystem entry visible to
# every exec. One profile holds everything:
#   /nix/var/nix/profiles/per-user/root/profile (a.k.a. ~/.nix-profile) —
#     nix itself (installed as nixpkgs#nix) plus ordinary packages.
# It lives under /nix/var, i.e. on the persistent volume, so it survives
# recycles. If the profile ever loses its nix binary, ensure_profile_nix
# reinstalls it from any nix binary found in the persistent store.
#
# Constraints:
# - The sandbox denies chown() even for root -> shim elides redundant chowns.
# - The sandbox denies removexattr on taint xattrs -> shim hides them.
# - The shim also hides the /nix symlink from nix's store guard and build
#   sandbox (allow-symlinked-store only covers the store-open path).
# - Never auto-delete/quarantine the persistent dir on failure (fail loud).
set -u
PROFILE=/nix/var/nix/profiles/per-user/root/profile
PROFILE_NIX=$PROFILE/bin/nix
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
  "build-users-group = nixbld" \
  "keep-outputs = true" \
  "keep-derivations = true" \
  "fallback = true" \
  "http-connections = 50" \
  "allow-dirty = true"; do
  key="${line%% = *}"
  grep -q "^[[:space:]]*${key}[[:space:]]*=" /etc/nix/nix.conf 2>/dev/null \
    || echo "$line" >> /etc/nix/nix.conf
done

# /etc/passwd and /etc/group live on the overlay, so the nixbld build users
# (created by the original nix installer as gid 993 / uids 999-1008) vanish
# on every recycle — but nix.conf above sets `build-users-group = nixbld`,
# so any nix build fails with "the group 'nixbld' does not exist" until they
# come back. Recreate them idempotently (first found 2026-09-30: the
# 11:12-12:02 recycle wiped them and every nix build broke).
ensure_nixbld_users() {
  if ! getent group nixbld >/dev/null; then
    groupadd -g 993 nixbld
  fi
  for i in $(seq 1 10); do
    getent passwd "nixbld$i" >/dev/null || \
      useradd -u $((998 + i)) -g nixbld -M -s /usr/sbin/nologin \
        -d /var/empty "nixbld$i"
    # nix refuses "the build users group 'nixbld' has no members" unless the
    # users are listed as supplementary members too (primary group isn't enough)
    usermod -aG nixbld "nixbld$i"
  done
}
ensure_nixbld_users

nix_works() {
  [ -x "$PROFILE_NIX" ] && "$PROFILE_NIX" eval --impure --expr '1 + 1' 2>/dev/null | grep -q '^2$'
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

ensure_profile_nix() {
  # nix itself lives in the user profile (installed as nixpkgs#nix). If the
  # profile's nix binary is missing/not executable, reinstall it from the
  # store. The profile itself is a GC root for its elements, so a store
  # nix is almost always present.
  #
  # Verified 2026-09-30 quirks of `nix profile add <store-path>`:
  # - If the store path's bin/nix is a SYMLINK to another store path, the
  #   add links every nix-* binary EXCEPT bin/nix (silent). Must add a path
  #   whose bin/nix is a real file.
  # - nix 2.34.8 adding its OWN store path silently skips bin/nix (2.35.2
  #   does not have this quirk).
  # - `profile remove X` followed by `profile add X` (same path) updates the
  #   manifest but does NOT relink bin/nix (silent). So we NEVER remove
  #   before adding — we add first, then best-effort remove old broken paths.
  # - Two different nix versions in one profile collide on bin/nix (hard
  #   error), so the add only works when the old element's bin/nix is
  #   actually missing from the generation (the broken case).
  # Net: repair = add newest nix with a real bin/nix (no prior remove).
  # The version may change on repair; a working newer nix beats a broken one.
  [ -x "$PROFILE_NIX" ] && return 0
  local shim=/home/hatch/tools/taint-shim/taint_shim.so
  local boot_nix target_nix nix_paths p
  echo "nix-ensure: profile nix missing; repairing $PROFILE" >&2
  # Newest nix whose bin/nix is a real file (not a symlink): both the
  # bootstrapper and the install target. 2.35.2 self-add works; 2.34.8's
  # self-add quirk is avoided by preferring the newest.
  target_nix=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -L "$p" ] && [ -x "$p" ]; then
      target_nix="/nix/store/$(basename "$(dirname "$(dirname "$p")")")"
      boot_nix="$p"
      break
    fi
  done < <(find "$PERSIST/store" -maxdepth 3 -path "*/bin/nix" -type f 2>/dev/null \
    | sort -t- -k3 -V -r)
  if [ -z "$target_nix" ]; then
    echo "FATAL: no usable nix in $PERSIST/store" >&2
    return 1
  fi
  LD_PRELOAD=$shim "$boot_nix" profile add --profile "$PROFILE" "$target_nix" 2>&1 | tail -2
  # NOTE: we deliberately do NOT remove old/duplicate nix elements here.
  # `profile remove` (by path or name) after an add can delete bin/nix from
  # the new generation when elements share store paths (verified 2026-09-30).
  # A duplicate nix element is harmless; a broken profile is not.
  [ -x "$PROFILE_NIX" ]
}

populate_persist() {
  # Fill $PERSIST from the tarball, or fresh install as last resort.
  # Never extract over a non-empty tree (tar hardlinks aren't idempotent).
  # NOTE: builds run as nixbld users — nix.conf sets
  # `build-users-group = nixbld`; the nixbld group has traverse-only ACLs
  # (g:nixbld:--x) on /home/hatch, /home/hatch/nix-persist,
  # /home/hatch/tools, /home/hatch/tools/taint-shim, plus read on
  # taint_shim.so, because /home/hatch is otherwise 2770 root:nogroup.
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
ensure_profile_nix
nix_works
