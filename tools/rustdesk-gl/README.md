# RustDesk in the sandbox — render fix + laptop route (2026-11-04)

## Status
- **Client RENDERS.** Root cause found and fixed (below). Screenshots:
  `shot-main.png` (client UI), `shot-preauth.png` (password dialog from the
  laptop's server).
- **Connection reaches the laptop** (direct-IP via SSH forward) and gets a
  password prompt from the real server.
- **Credential RECONCILED (2026-11-04, per Drew's ruling)**: the laptop's
  permanent password was reset to the Bitwarden `rustdesk.amd-6-password`
  value and is now ACCEPTED (session advances past auth; see "Password
  reset" below for why the CLI could not do it and what was written).
- **VIDEO WORKS (2026-11-04, code#5509 closed)**: a fresh client session
  streams the laptop desktop and stays up (proof session: host cm panel
  "Connected 00:06:47" and counting, vs a ~170s death ceiling all
  morning; screenshots in `~/workspace/rd-work/proof-desktop-frames*.png`).
  Two stacked root causes — a wedged portal daemon and the route riding
  the shared SSH mux — see "Video leg" below before re-diagnosing.

## Why GL was broken (the precise wall)
The morning hypothesis ("X servers lost GLX") was wrong — the X servers were
fine all along (a distro-libGL probe against the same Xvfb showed GLX with
240 fbconfigs). The defect was client-side, in EVERY nix binary:

1. The sandbox's distro GL stack is unusable by nix binaries: there is **no
   libEGL anywhere in the distro** (no `libEGL.so.1`, no glvnd vendor JSONs),
   and nix `ld.so` cannot dlopen distro libs by soname anyway.
2. The nix closures (RustDesk, glxinfo) ship libglvnd + `mesa-libgbm` only —
   **no mesa GL/EGL vendor** — so glvnd found zero vendors → zero fbconfigs →
   Flutter's "No available configurations for the given pixel format".
3. Adding a vendor by hand hit an ABI wall: the dispatcher-pinned nixpkgs
   mesa (26.2.3) builds `libgallium` against glibc ≥ 2.41
   (`GLIBC_ABI_GNU2_TLS`), but every app closure here carries **glibc 2.40**.
   Mixing libcs in-process is impossible — that mesa can never load here.

## The fix
The RustDesk nix wrapper already prepends `/run/opengl-driver/lib`, and nix
libglvnd's compiled-in vendor search starts at
`/run/opengl-driver/share/glvnd/egl_vendor.d`. Populate that NixOS layout
with a mesa whose glibc ≤ 2.40:

- **mesa 24.0.7** from nixpkgs `0da3c44a9460a26d2025ec3ed2ec60a895eb1114`
  (the omnibin flake.lock "nixpkgs-24_05" node; glibc 2.39):
  - out: `/nix/store/jxqbfi5lgyjdcn2js5pp8i8vxp48770k-mesa-24.0.7`
  - drivers: `/nix/store/clkv22khc4fh7az6gxc2p3mzmn7zhrv8-mesa-24.0.7-drivers`
  - Both GC-rooted: `/nix/var/nix/gcroots/dispatcher/mesa-gl-24.0.7{,-drivers}`
- `/run/opengl-driver/lib` → drivers/lib; `/run/opengl-driver/share/glvnd/egl_vendor.d`
  → drivers' dir (its `50_mesa.json` points at the store path absolutely).
  No GLX vendor JSON needed: glvnd's libGLX fallback search includes
  `/run/opengl-driver/lib` and finds `libGLX_mesa.so.0` by soname.
- Result: `glxinfo -B` → direct rendering Yes, **llvmpipe**, OpenGL 4.5;
  RustDesk renders with plain `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`.

`/run` and `/tmp` are tmpfs — a sandbox recycle wipes the layout, Xvfb, the
forward, and the processes (this happened mid-task). `launch.sh` rebuilds
everything idempotently; the store paths + GC roots survive.

## Route to the laptop desktop
1. `launch.sh` — /run/opengl-driver + Xvfb :99 (1600×1000) + DEDICATED
   SSH forward `127.0.0.1:21118 → laptop 127.0.0.1:21118` (via
   `forward.sh` — its own ssh process, NOT the shared laptop-ssh
   ControlMaster; laptop = tailnet 100.99.113.103) + RustDesk client.
2. Connect: `DISPLAY=:99 rustdesk --connect 127.0.0.1:21118` (the GUI Connect
   button ignores synthetic clicks; the CLI forwards to the running instance).
   Laptop device ID is 101234269; direct-IP avoids the rendezvous network.
3. `auth.sh` — Bitwarden-fed clipboard paste into the password dialog
   (see its header for the focus/geometry lessons and the credential state).

## Password reset (2026-11-04) — why the CLI is a dead end, what worked
- `rustdesk --set-password` on the laptop's Nix build (1.5.0, also 1.4.3)
  NEVER writes: every regime (no display / session env cloned from the
  service / service stopped / software-GL / `env -i`) dies with SIGABRT in
  libsciter-gtk's exit handlers (flexi_logger TLS panic under the hood).
  Config mtime never moved. Running it against the live service (IPC) also
  had no effect — the next login still rejected the value. Do not retry it.
- What the drifted config actually held: the `password` field (214 chars,
  prefix "00") was the new-format storage DOUBLE-WRAPPED — a legacy "00"
  secretbox layer around a complete "01…" storage string (decrypts with
  key = machine-id bytes; inner = 118 bytes, prefix "01"). Valid storage
  of the wrong (drifted) password, in a form no setter produced on purpose.
- RustDesk 1.5.0 storage format (from the vendored source,
  `libs/hbb_common/src/config/permanent_password.rs` — read it before
  touching this again): keep `salt` from RustDesk.toml stable;
  `h1 = SHA256(password || salt)`; hashed = `"00" + base64(h1)`;
  field = `"01" + base64(0x01 || nonce24 || secretbox(hashed))` with
  key = machine-uid bytes zero-padded to 32. The reset computed exactly
  that on the laptop (libsodium via ctypes, vault value piped on stdin,
  never in argv/files/logs), self-verified by decrypting the field back to
  the same h1, spliced the single `password` line with the service
  stopped, and restarted it. Backups: `RustDesk.toml.bak-20261104` and
  `RustDesk.toml.bak-prewrite` beside the config.
- Proof of acceptance: fresh client connect → paste → session advanced to
  the host's "select the screen to be shared" step; host server log shows
  the portal handshake completing (`response: 0`, session handle issued).

## Video leg — RESOLVED 2026-11-04 (code#5509): two stacked root causes

The morning's diagnosis ("ScreenCast Start / PipeWire negotiation stalls,
zero frames") was the visible end of TWO independent defects:

1. **xdg-desktop-portal-hyprland was wedged.** Its main thread spun at
   100% CPU in userspace (utime+stime delta 299 ticks / 3s) and the
   daemon was D-Bus-deaf: RustDesk's ScreenCast **Start** never got a
   Response signal (`wl-stage:start:no-response`), session **Close**
   timed out in the frontend ("Failed to close session implementation:
   Timeout was reached"), and even `busctl get-property … ScreenCast
   version` timed out. CreateSession/SelectSources sometimes squeaked
   through early on, which made it look like a PipeWire problem — no
   PipeWire node is ever created when Start is never answered. It had
   arrived wedged (the day's first CreateSession already NoReply'd at
   07:37) after the frontend portal had been restarted at 06:57 against
   the backend started 06:00. **Fix: `systemctl --user restart
   xdg-desktop-portal-hyprland`** (later the frontend + rustdesk service
   were restarted too, to clear a morning of poisoned session state).
   Post-restart, Start completes in <1s and the GStreamer pipeline
   confirms PLAYING. If it recurs: symptom-test is the busctl property
   get + thread state R; the restart is the remedy. No flake defect was
   found — xdph 1.4.1-git + Hyprland 0.56 stream fine when not wedged.
2. **The route rode the shared SSH ControlMaster.** The old launch.sh
   forward (`laptop-ssh.sh -N -L`) is owned by the single mux process
   that also carries every other fleet session (25-min cargo-test output
   streams, 1700s sleep-pollers, build watches). Under contention the
   mux stalls and the forwarded stream freezes in both directions:
   server logs `Connection closed: Timeout` at ~100–170s, client shows
   "Connection error: Timeout", auto-reconnects — and every reconnect
   mints a NEW portal session and a NEW share picker (the churn also
   kept the frontend busy burying dead sessions, feeding intermittent
   CreateSession NoReply). **Fix: dedicated ssh for the forward**
   (`forward.sh`: ControlMaster=no / ControlPath=none; launch.sh now
   cancels any mux-owned 21118 forwarding and starts the dedicated one).
   Proof session then ran 6m47s+ with an active PipeWire link
   (`rustdesk` node ← `capture_1 [active]`), continuous frame diffs,
   and a working input round-trip.

Picker mechanics (still needed per fresh connection — RustDesk's
restore-token flow does not survive its own reconnect churn): the
picker (class `hyprland-share-picker`, [1080,720] 720×480) is driven
by `share-grant.py` (in this dir; run it ON the laptop, needs
HYPRLAND_INSTANCE_SIGNATURE): Remember (0.03w, 0.84h) → monitor row
(0.50w, 0.32h) → Share (0.935w, 0.93h) via ydotool + cursorpos
feedback. Use the no-dismiss variant in this dir — dismissing a
"stale" picker kills the fresh one.

Noise not to chase: RustDesk 1.5.0's `--server` processes panic on
exit (`cannot access a Thread Local Storage value during or after
destruction`, 22× in one day) — it fires during teardown, after the
fate of the connection is already decided; the service respawns a
fresh `--server`. Also cosmetic: client is 1.4.5 vs server 1.5.0;
the pairing streams fine.

## Notes
- The sandbox client's own RustDesk ID is unchanged (config in
  `~/.config/rustdesk` survived the recycle).
- The laptop's `rustdesk.service` has been restarted several times during
  diagnosis and for the password reset; final state verified active and
  listening on :21118 with the reconciled credential in place.
- xclip 0.13 lives at `/nix/store/s5dlvs8ripp19rc31n55hrrcg7ngfb8c-xclip-0.13/bin/xclip`
  (fetched via omnibin; `~/tools/bin/xclip` has no stub).
- xdotool focus: no WM in Xvfb → use `xdotool windowfocus --sync <id>`,
  never `windowactivate`. Remote window title: `127.0.0.1:21118 - Remote Desktop - RustDesk`.
