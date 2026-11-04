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
- **BLOCKED on video, not auth**: the host's Wayland ScreenCast/PipeWire
  pipeline never delivers frames — client shows "Connection error:
  Timeout" after the share is granted. See "Video leg" below.

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
1. `launch.sh` — /run/opengl-driver + Xvfb :99 (1600×1000) + SSH forward
   `127.0.0.1:21118 → laptop 127.0.0.1:21118` (via `~/tools/laptop-ssh.sh`,
   laptop = tailnet 100.99.113.103) + RustDesk client.
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

## Video leg — the remaining blocker (host-side Wayland capture)
- After auth, the laptop shows the xdg portal picker
  (class `hyprland-share-picker`, a real hyprctl client at [1080,720]
  720×480 on this desktop). It can be driven with ydotool via HYPRLAND
  geometry (fractions of the live window: Remember ≈ (0.03w, 0.84h),
  monitor row ≈ (0.50w, 0.32h), Share ≈ (0.935w, 0.93h); ydotool click
  code 0xC0, pointer feedback loop against `hyprctl cursorpos`, ~2.186×
  fast-move scaling). "Remember this choice" was clicked once, so the
  picker may not reappear. Helper used: `/tmp/rd-portal-click.py`
  (ephemeral; recreate from this description if needed).
- Even with the share granted: SelectSources returns response 0, codec
  negotiation completes (encoder AV1), then NO PipeWire frames ever flow;
  the client times out (~"Connection error: Timeout") and the host logs
  `Connection closed: Timeout`. The stall is after the portal handshake,
  in the ScreenCast Start / PipeWire negotiation on the laptop's Hyprland
  stack — same family as the dead KRdp (code#5415) and the host UI's own
  "Wayland support is experimental" flag. Not a credential or route issue.

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
