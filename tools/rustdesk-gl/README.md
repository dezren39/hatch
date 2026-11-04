# RustDesk in the sandbox — render fix + laptop route (2026-11-04)

## Status
- **Client RENDERS.** Root cause found and fixed (below). Screenshots:
  `shot-main.png` (client UI), `shot-preauth.png` (password dialog from the
  laptop's server).
- **Connection reaches the laptop** (direct-IP via SSH forward) and gets a
  password prompt from the real server.
- **BLOCKED on credential**: Bitwarden `rustdesk.amd-6-password` is rejected
  by the laptop's RustDesk service — verified 4× (2 typed, 2 pasted
  byte-exact, once after restarting the laptop service; dot count = 24 =
  secret length each time). The vault value ≠ the laptop's configured
  permanent password. Reconcile one side, then `auth.sh` finishes in seconds.

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

## Notes
- The sandbox client's own RustDesk ID is unchanged (config in
  `~/.config/rustdesk` survived the recycle).
- The laptop's `rustdesk.service` was restarted once during diagnosis
  (activation experiment for its 05:49 config write); it is active and
  listening on :21118.
- xclip 0.13 lives at `/nix/store/s5dlvs8ripp19rc31n55hrrcg7ngfb8c-xclip-0.13/bin/xclip`
  (fetched via omnibin; `~/tools/bin/xclip` has no stub).
- xdotool focus: no WM in Xvfb → use `xdotool windowfocus --sync <id>`,
  never `windowactivate`. Remote window title: `127.0.0.1:21118 - Remote Desktop - RustDesk`.
