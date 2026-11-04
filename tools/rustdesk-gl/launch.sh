#!/bin/bash
# rustdesk-gl/launch.sh — bring up the RustDesk GUI client in this sandbox.
#
# Why this exists: nix binaries here cannot use the host GL stack (the distro
# has no libEGL at all, and nix ld.so cannot dlopen distro libs), and the
# nixpkgs RustDesk wrapper expects the NixOS /run/opengl-driver layout.
# The fix is a mesa whose glibc is <= the app closures' glibc 2.40:
# mesa 24.0.7 (nixpkgs 0da3c44a, mesa + mesa.drivers outputs, GC-rooted under
# /nix/var/nix/gcroots/dispatcher/mesa-gl-24.0.7*). Mesa 26.x from the current
# pin FAILS: its libgallium requires GLIBC_ABI_GNU2_TLS (glibc >= 2.41).
#
# Idempotent. Safe to re-run after a sandbox recycle (all state it rebuilds
# lives on tmpfs: /run/opengl-driver, /tmp sockets, processes).
set -u
MESA_DRV=/nix/store/clkv22khc4fh7az6gxc2p3mzmn7zhrv8-mesa-24.0.7-drivers
DISP=:99
export DISPLAY=$DISP

# 1. /run/opengl-driver (NixOS layout the wrapper + libglvnd expect)
if [ ! -e /run/opengl-driver/lib/libEGL_mesa.so.0 ]; then
  mkdir -p /run/opengl-driver/share/glvnd
  ln -sfn "$MESA_DRV/lib" /run/opengl-driver/lib
  ln -sfn "$MESA_DRV/share/glvnd/egl_vendor.d" /run/opengl-driver/share/glvnd/egl_vendor.d
  echo "launch: /run/opengl-driver populated from $MESA_DRV"
fi

# 2. Xvfb
if [ ! -e "/tmp/.X11-unix/X${DISP#:}" ]; then
  nohup Xvfb "$DISP" -screen 0 1600x1000x24 > /tmp/xvfb-rustdesk.log 2>&1 &
  sleep 2
  echo "launch: Xvfb $DISP started"
fi

# 3. SSH forward to the laptop's RustDesk (:21118) if not already listening
if ! timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/21118' 2>/dev/null; then
  nohup "$HOME/tools/laptop-ssh.sh" -N -L 21118:127.0.0.1:21118 \
    -o ExitOnForwardFailure=yes > /tmp/ssh-fwd-rustdesk.log 2>&1 &
  sleep 5
  echo "launch: ssh forward 127.0.0.1:21118 -> laptop started"
fi

# 4. RustDesk client (software GL)
if ! pgrep -f 'rustdesk.*\.rustdesk-wrapped|bin/rustdesk' > /dev/null; then
  LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    nohup "$HOME/tools/bin/rustdesk" > /tmp/rustdesk.log 2>&1 &
  sleep 6
  echo "launch: rustdesk client started"
fi
echo "launch: ready (DISPLAY=$DISP)"
