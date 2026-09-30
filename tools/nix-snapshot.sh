#!/bin/bash
# ~/tools/nix-snapshot.sh — snapshot the live /nix (overlay) into the
# persistent tarball that nix-ensure.sh restores after a sandbox recycle.
# Why a tarball and not a symlink to /home/hatch: even root cannot delete
# inside read-only (555) dirs on the btrfs home volume (verified 2026-09-29),
# so a persistent live store could never be garbage-collected or upgraded.
# A tarball sidesteps that: single file, replaced atomically.
# Safe to re-run any time; keeps one backup of the previous snapshot.
set -u
TARBALL=/home/hatch/tools/nix-store.tar.gz
[ -d /nix/store ] || { echo "no live /nix/store; nothing to snapshot"; exit 1; }
echo "live /nix: $(du -sh /nix | cut -f1)"
if [ -f "$TARBALL" ]; then
  cp -f "$TARBALL" "$TARBALL.prev"
  echo "previous snapshot kept at $TARBALL.prev"
fi
# /nix is normally a symlink to persistent storage; -h dereferences it so the
# tarball always holds real files (format: nix/...), keeping the restore path
# in nix-ensure.sh unchanged. --hard-dereference stores hardlinked files
# (nix/store/.links) as separate copies: bigger archive, but extraction can't
# hit tar's out-of-order hardlink failures (seen 2026-09-29).
tar -czphf --hard-dereference "$TARBALL.new" -C / nix && tar -tzf "$TARBALL.new" >/dev/null \
  && mv -f "$TARBALL.new" "$TARBALL" \
  && echo "snapshot ok: $(du -h "$TARBALL" | cut -f1) (was: ${TARBALL}.prev)"
