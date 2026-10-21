# Muse (Muse Code) install script — archive + breakdown

Archived 2026-10-21, per Drew's standing rule: when we run a curl-install, we
archive the script itself plus a breakdown README the same day. The CLI was
already installed on this box; this script was **fetched and read, NOT
executed**.

## The archived file

- File: `muse-install-2026-10-21.sh` (in this directory, verbatim)
- Source: `https://dev.meta.ai/install.sh`
- Fetch result: HTTP 200, **final URL after redirects = the same URL** (no
  redirects), 9,314 bytes, sha256
  `5196d820127a241211c96cf38f0b2e30cff8506a82e9da9508cd5f826632a0ca`
- **User-Agent test:** fetched twice — default curl UA and a Chrome browser
  UA — byte-identical (same size, empty diff). UA does not matter for this
  endpoint; no UA-based switching, no redirect to an HTML install page.

## How it works — it's a two-stage installer

**Stage 1 is this script.** It does NOT download the Muse binary and does
NOT switch on OS/arch. It:

1. Sets `install_dir` = `$MUSE_INSTALL_DIR`, defaulting to `~/.local/bin`.
2. Downloads exactly one thing: a **launcher script** from
   `https://api.meta.ai/muse-launcher.sh` (override: `$MUSE_LAUNCHER_URL`),
   with HTTPS enforced (`--proto '=https'`, `--tlsv1.2`, max 3 redirects).
3. Syntax-checks the download (`bash -n`), and verifies it against the
   `x-content-sha256` response header **when the server advertises one**
   (older serving code sends none — then it's unverified).
4. Installs atomically: mktemp inside the install dir → `chmod 0755` → `mv`
   into place as `~/.local/bin/muse` (skips the replace if identical).
5. Executes the launcher once with `MUSE_LAUNCHER_INSTALL=1`, cleans up
   `.muse-updater` / `.muse-install-lock` leftovers, and appends a PATH line
   to your shell profiles (bash/zsh/fish aware, incl. ZDOTDIR resolution;
   opt out with `MUSE_NO_MODIFY_PATH`).

**Stage 2 is the launcher** (fetched read-only on 2026-10-21 for this
breakdown; 32,737 bytes; its response carried
`x-content-sha256: c6db294799a190ca380da274beb3b9c0e160e0da9681a3d364ce8b0e5fa3a4bc`).
This is where the real work lives:

- **Platform switch:** `uname -s`/`uname -m` → `aarch64_macos`, `x86_macos`,
  `aarch64_linux`, `x86_linux`; anything else is a hard "unsupported
  platform" error.
- **Manifest flow:** channel manifest (`$MUSE_CHANNEL`, default
  `muse-stable`) → release manifest URL → per-platform artifact entry →
  download of the real binary (`muse-bin-<version>-<build>`, ~385 MB here),
  verified against the channel manifest's hashes (the Oct 2026 install here
  was SHA-verified this way).
- Also owns: credential storage (default `~/.config/muse/auth.json`,
  override `$MUSE_AUTH_PATH`), the login flow, and **hourly self-update
  checks** (`$MUSE_UPDATE_INTERVAL_SECONDS`, default 3600).

## Match against this machine

Our installed `~/.local/bin/muse` is a 32,737-byte bash script — i.e. it IS
the stage-2 launcher, exactly as this installer would leave it. The PATH
problem found 2026-10-21 (`~/.local/bin` not on the exec PATH) is a local
shell-env fact, not an installer failure; fixed by symlinking
`~/tools/bin/muse` → `~/.local/bin/muse`.

## Reinstall / redo

```bash
curl -sSL https://dev.meta.ai/install.sh | bash   # idempotent; stage 1 only refetches the launcher
muse --version                                     # expect the current stable build
```

Env knobs worth knowing: `MUSE_INSTALL_DIR`, `MUSE_LAUNCHER_URL`,
`MUSE_CHANNEL`, `MUSE_NO_MODIFY_PATH`, `MUSE_AUTH_PATH`.
