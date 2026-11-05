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

# Idle auto-exit (Drew ruling 2026-11-04, code#5775): the client renders via
# llvmpipe software GL and burns 26-45% of a core while merely displayed, so
# a forgotten client is real waste. A watcher (step 5) exits the client after
# RUSTDESK_IDLE_EXIT_MINUTES with NO live session. "Live session" signal: an
# ESTABLISHED TCP connection to 127.0.0.1:21118 (the dedicated forward to the
# laptop's RustDesk server, step 3) — the only thing that connects there is
# this client's session traffic. The watcher re-checks immediately before
# terminating, so an active session is never killed.
RUSTDESK_IDLE_EXIT_MINUTES="${RUSTDESK_IDLE_EXIT_MINUTES:-15}"
RUSTDESK_IDLE_POLL_SEC="${RUSTDESK_IDLE_POLL_SEC:-60}"
RUSTDESK_CLIENT_PATTERN="${RUSTDESK_CLIENT_PATTERN:-rustdesk.*\.rustdesk-wrapped|bin/rustdesk}"

session_active() {
  ss -tn state established 2>/dev/null | grep -qE '127\.0\.0\.1:21118[[:space:]]'
}

idle_watch() {
  local idle_sec=0 misses=0 pids pid
  echo "idle-watch: watching (exit client after ${RUSTDESK_IDLE_EXIT_MINUTES}m without a session)"
  while :; do
    pids=$(pgrep -f "$RUSTDESK_CLIENT_PATTERN" || true)
    if [ -z "$pids" ]; then
      # client not up (yet) or already gone; give up after a short grace
      misses=$((misses + 1))
      [ "$misses" -ge 3 ] && { echo "idle-watch: no client process; exiting"; exit 0; }
    else
      misses=0
      if session_active; then
        idle_sec=0
      else
        idle_sec=$((idle_sec + RUSTDESK_IDLE_POLL_SEC))
      fi
      if [ "$idle_sec" -ge $((RUSTDESK_IDLE_EXIT_MINUTES * 60)) ]; then
        if session_active; then
          idle_sec=0   # a session appeared at the last moment; never kill it
        else
          echo "idle-watch: no session for ${RUSTDESK_IDLE_EXIT_MINUTES}m; exiting rustdesk client (pids: $(echo $pids | tr '\n' ' '))"
          for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
          sleep 5
          for pid in $pids; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true; done
          exit 0
        fi
      fi
    fi
    sleep "$RUSTDESK_IDLE_POLL_SEC"
  done
}
if [ "${1:-}" = "--idle-watch" ]; then idle_watch; exit 0; fi

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

# 3. SSH forward to the laptop's RustDesk (:21118) — a DEDICATED ssh process
#    via forward.sh, never the shared laptop-ssh ControlMaster (mux stalls
#    froze the stream both ways -> server/client "Timeout" churn; see
#    forward.sh and README "Video leg"). If the port is held by anything
#    else (typically the mux master from an older launch), cancel that mux
#    forwarding and take the port over.
fwd_holder() {
  ss -tlnp 2>/dev/null | grep -w '127.0.0.1:21118' | grep -oP 'pid=\K[0-9]+' | head -1
}
HOLDER=$(fwd_holder)
if [ -n "$HOLDER" ] && ! tr '\0' ' ' < "/proc/$HOLDER/cmdline" 2>/dev/null | grep -q 'ControlPath=none'; then
  ssh -S "$HOME/.ssh/cm-user@100.99.113.103:22" -O cancel \
    -L 21118:127.0.0.1:21118 user@100.99.113.103 2>/dev/null || true
  sleep 1
  HOLDER=$(fwd_holder)
fi
if [ -z "$HOLDER" ]; then
  nohup "$HOME/tools/rustdesk-gl/forward.sh" > /tmp/ssh-fwd-rustdesk.log 2>&1 &
  sleep 5
  echo "launch: dedicated ssh forward 127.0.0.1:21118 -> laptop started"
fi

# 4. RustDesk client (software GL)
if ! pgrep -f 'rustdesk.*\.rustdesk-wrapped|bin/rustdesk' > /dev/null; then
  LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    nohup "$HOME/tools/bin/rustdesk" > /tmp/rustdesk.log 2>&1 &
  sleep 6
  echo "launch: rustdesk client started"
fi

# 5. Idle auto-exit watcher (single instance, pidfile-guarded)
WATCH_PID_FILE=/tmp/rustdesk-idle-watch.pid
if [ -f "$WATCH_PID_FILE" ] && kill -0 "$(cat "$WATCH_PID_FILE")" 2>/dev/null; then
  echo "launch: idle watcher already running (pid $(cat "$WATCH_PID_FILE"))"
else
  nohup bash "$0" --idle-watch >> /tmp/rustdesk-idle-watch.log 2>&1 &
  echo $! > "$WATCH_PID_FILE"
  echo "launch: idle watcher started (client exits after ${RUSTDESK_IDLE_EXIT_MINUTES}m without a session)"
fi
echo "launch: ready (DISPLAY=$DISP)"
