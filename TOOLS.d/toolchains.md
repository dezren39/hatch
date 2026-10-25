# TOOLS.d/toolchains.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

## Toolchains (installed 2026-09-29, under ~/tools — persistent)
- Go: `~/tools/go/bin/go` (1.25.1). Add to PATH as needed.
- Go builds/tests: /tmp is a 512M tmpfs — linking a Go binary fails with
  "mapping output file failed: no space left on device". Run with
  `TMPDIR=/home/hatch/tmp` (btrfs, 95G free; mkdir it first). Hit 2026-09-30
  running mcpx's e2e tests, which `go build` the binary into a temp dir.
- Go `testing.TempDir` reads `GOTMPDIR`, NOT `TMPDIR`, and caches one parent
  dir per test (first call wins; later env changes are ignored). Redirecting
  TMPDIR inside a test to keep temp files under a fake $HOME silently does
  nothing — set GOTMPDIR before the first t.TempDir call. Hit 2026-09-30
  fixing mcpx's daemon test isolation (the config walk passes through the
  real $HOME when the temp tree sits under it).
- Rust: `CARGO_HOME=~/tools/cargo RUSTUP_HOME=~/tools/rustup`; cargo at `~/tools/cargo/bin/cargo`.
- `/bin/bash` is a wrapper (installed by `~/tools/install-bash-wrapper.sh`, run
  on boot via init.sh) that sets `BASH_ENV=~/tools/shell-env.sh` and
  execs `/bin/bash.real`. Every exec therefore gets `program@version` support
  with zero per-exec setup. `shell-env.sh` is startup-clean (4–5ms): PATH
  setup + `command_not_found_handle` only. The installer never overwrites
  `/bin/bash.real` when `/bin/bash` is already a wrapper; rollback is
  `cp /bin/bash.real /bin/bash`.
- `~/tools/dispatcher.sh` — single resolver for `program[@version]`, used by
  both `command_not_found_handle` and stubs in `~/tools/bin/` (on PATH).
  Pinned omnibin wrapper flake (`~/tools/dispatcher/omnibin/flake.nix`:
  omnibin as input with `nixpkgs.follows`); persistent GC roots
  (`/nix/var/nix/gcroots/dispatcher/`); disk cache (`~/tools/dispatcher/cache/`,
  ~16ms hits); loud failure (exit 127) on inexact version, never substitutes.
  Refresh the flake input only via `~/tools/omnibin-refresh.sh`.
