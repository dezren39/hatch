#!/bin/bash
# ~/tools/nix-install.sh — full fresh Nix install from scratch.
# Installs to /nix (overlay dir; files persist across execs), then saves
# a compressed tarball backup to ~/tools/nix-store.tar.zst (persistent).
# NOTE: the installer's final "install into default profile" step can fail
# in this sandbox (taint xattrs); the profile links are built manually then.
set -u
# NOTE: builds run as nixbld users — nix.conf sets `build-users-group = nixbld`
# (the nixbld group needs traverse ACLs on /home/hatch; see nix-ensure.sh).
[ -s "$HOME/tools/nix-installer.sh" ] || curl -sSL https://nixos.org/nix/install -o "$HOME/tools/nix-installer.sh"
rm -rf /nix
sh "$HOME/tools/nix-installer.sh" --no-daemon --no-channel-add || true
NIXPKG=$(ls -d /nix/store/*-nix-2.* 2>/dev/null | head -1)
if [ -z "$NIXPKG" ] || [ ! -x "$NIXPKG/bin/nix" ]; then
  echo "nix-install.sh: installer did not produce a nix package in /nix/store" >&2
  exit 1
fi
# nix itself goes straight into the user profile (single-profile layout).
if [ ! -x /nix/var/nix/profiles/per-user/root/profile/bin/nix ]; then
  mkdir -p /nix/var/nix/profiles/per-user/root
  "$NIXPKG/bin/nix" profile add --profile /nix/var/nix/profiles/per-user/root/profile "$NIXPKG"
fi
if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  mkdir -p /nix/var/nix/profiles/per-user/root
  rm -f /nix/var/nix/profiles/default
  ln -s "$NIXPKG" /nix/var/nix/profiles/per-user/root/profile-1-link
  ln -s profile-1-link /nix/var/nix/profiles/per-user/root/profile
  ln -s /nix/var/nix/profiles/per-user/root/profile /nix/var/nix/profiles/default
fi
export PATH=/nix/var/nix/profiles/default/bin:$PATH
nix --version
# persistent backup as a single gzipped tarball (gzip ships in the base image,
# so restores never depend on apt after a recycle; a live tree can't be used
# because even root can't rm inside read-only dirs on the btrfs home volume)
rm -f "$HOME/tools/nix-store.tar.gz"
tar -cz --numeric-owner -f "$HOME/tools/nix-store.tar.gz" -C / nix
echo "backup saved: $HOME/tools/nix-store.tar.gz"
