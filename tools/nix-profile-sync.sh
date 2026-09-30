#!/bin/bash
# ~/tools/nix-profile-sync.sh — expose nix profile binaries on the default PATH.
# Symlinks ~/.nix-profile/bin/* into /usr/local/bin/ (on the default PATH for
# every shell, interactive or not). No per-program wrappers needed.
# - Skips the nix suite itself (nix*): the /usr/local/bin/nix wrapper (with
#   LD_PRELOAD) is the entry point; `nix build` etc. cover the old nix-* tools.
# - Never clobbers real files (protects the nix wrapper and manual installs);
#   only manages symlinks it created.
# Idempotent. Run on boot via init.sh and automatically after `nix profile`
# mutations (hooked in the /usr/local/bin/nix wrapper).
set -u
PROFILE_BIN="$HOME/.nix-profile/bin"
TARGET_DIR="/usr/local/bin"
mkdir -p "$TARGET_DIR"
[ -d "$PROFILE_BIN" ] || exit 0
for src in "$PROFILE_BIN"/*; do
  [ -e "$src" ] || continue
  name=$(basename "$src")
  case "$name" in
    nix*) continue ;;  # nix suite: use the LD_PRELOAD wrapper instead
  esac
  dest="$TARGET_DIR/$name"
  [ -e "$dest" ] && [ ! -L "$dest" ] && continue        # real file: leave alone
  if [ -L "$dest" ] && [ "$(readlink "$dest")" != "$src" ]; then
    continue                                            # foreign symlink: leave alone
  fi
  ln -sf "$src" "$dest"
done
