# Turso CLI install script — archive, breakdown, and the 2026-10-21 reinstall

## The archived file

- File: `turso-install-2026-10-21.sh` (in this directory, verbatim)
- Source: `https://get.tur.so/install.sh`
- Fetch result: HTTP 200, **final URL after redirects = the same URL**,
  8,091 bytes, sha256
  `87e74f65584735d0dd548016b73cfc4621ddae29ea2b6cf54a962e8cdaa61931`
- **User-Agent test:** default curl UA vs Chrome browser UA — byte-identical.
  UA does not matter.

Canonical command (what current Turso documentation gives): the install
page named in our task, `https://docs.turso.tech/cli/install`, returns
**404 as of 2026-10-21** (docs have moved); the command
`curl -sSfL https://get.tur.so/install.sh | bash` is the one Turso's
quickstart and the Cloudflare Workers Turso integration docs both publish.
Homebrew alternative on macOS/Linux: `brew install tursodatabase/tap/turso`.

## How the script works

POSIX `sh`, `set -e`, no version pinning and **no checksum verification
anywhere** (contrast with the Muse installer, which verifies sha256 twice).
Install directory is hard-coded: `$HOME/.turso`.

1. `probe_os` / `probe_arch` from `uname`: OS ∈ {Darwin, Linux};
   arch x86_64 stays `x86_64`, aarch64/arm64 → `arm64` (for the CLI target).
2. **Installs `sqld` (libsql-server) FIRST** — most people don't notice this
   script installs two binaries:
   `https://github.com/tursodatabase/libsql/releases/latest/download/libsql-server-<arch>-<os-target>.tar.xz`
   (Linux target: `x86_64-unknown-linux-gnu`), extracts only `sqld`
   (`tar --strip-components=1`) into `~/.turso`.
3. **Installs the CLI**: `https://github.com/tursodatabase/homebrew-tap/releases/latest/download/homebrew-tap_<OS>_<ARCH>.tar.gz`
   (here: `homebrew-tap_Linux_x86_64.tar.gz`), extracts only the `turso`
   binary into `~/.turso`. "latest" both times — re-running the installer
   silently jumps to whatever the newest release is.
4. `update_profile`: appends `export PATH="$PATH:$HOME/.turso"` (note: it
   *appends* `~/.turso` to PATH, and only if the profile doesn't already
   contain the string `.turso`). Profile detection is `$SHELL`-based
   (bash → `~/.bashrc`/`~/.bash_profile`, zsh → `~/.zshrc`,
   fish → `~/.config/fish/conf.d/turso.fish`).

## Provenance gap — why the old binary "just existed"

Before today, `~/tools/bin/turso` was **not an official install at all**. It
was a 256-byte auto-generated stub from our own dispatcher
(`~/tools/dispatcher.sh`, created Oct 20 when `turso` was first invoked),
which resolved through the omnibin index to a Nix store path
(`…-turso-cli-1.0.30/bin/turso`). Nothing in TOOLS.md recorded any of this —
that silence is the provenance gap Drew flagged. It worked, but nobody could
have said where it came from.

## Reinstall log — 2026-10-21 (what was actually done)

1. Old stub copied to `~/tmp/turso-bin-backup` (256 bytes, kept — not
   shredded) and removed from `~/tools/bin`. Note: /tmp is ephemeral; the
   stub is dispatcher-generated and reproducible (see Rollback), so this is
   a convenience copy, not the only copy of anything.
2. **First installer run FAILED** at the `sqld` extraction step:
   `tar: sqld: Cannot change ownership to uid 1001, gid 127: Operation not
   permitted` — the sandbox denies `chown` even for root (same quirk class
   as the Nix installer's, documented in TOOLS.md), and tar-as-root defaults
   to `--same-owner`. `set -e` stopped the script before the CLI step.
3. **Retry with `TAR_OPTIONS=--no-same-owner`** (passed to both the curl
   pipe's environment and the `bash` process): **success**, exit 0.
4. Results in `~/.turso/`:
   - `turso` — 37,470,500 bytes, build dated Oct 7 2025 → **v1.0.34**
     (up from the dispatcher's v1.0.30)
   - `sqld` — 45,368,728 bytes, build dated Feb 14 2025
   - The script could not detect a profile file in the exec environment
     (`$SHELL` unset), so it printed the PATH line for manual adding and
     **modified no shell profile**. Fine here: `~/tools/bin` is our PATH
     entry point.
5. `~/tools/bin/turso` is now a **symlink → `~/.turso/turso`**, so existing
   PATH, scripts, and config keep working against the official binary.

## Verification (post-reinstall)

- `turso --version` → `turso version v1.0.34`
- `turso auth whoami` → `dezren39` — the existing
  `~/.config/turso/settings.json` (mode 600) kept working unchanged; the new
  binary did NOT demand a different config location and no re-login was
  needed. (File mtime refreshed by the CLI's own run; size unchanged.)
- `turso db list` → both databases visible: `great-star-lord` and
  `muse-meta` (group `great-star-lord`, aws-us-east-1).

## Rollback

Delete the `~/tools/bin/turso` symlink and restore `~/tmp/turso-bin-backup`
in its place while /tmp survives; or simply invoke `turso` once with no stub
present — the dispatcher's command-not-found path regenerates the stub and
resolves the Nix v1.0.30 build again. The official v1.0.34 in `~/.turso`
can stay in place unused.

## Standing notes

- The installer always fetches **latest** and installs `sqld` whether you
  want it or not (~80 MB total in `~/.turso`). If a future reinstall matters,
  check `turso --version` before and after.
- If the official install is ever re-run here, it needs
  `TAR_OPTIONS=--no-same-owner` in this sandbox or it dies at the same tar
  step. That is an environment workaround, not a script change — the
  archived script above is byte-for-byte upstream.
