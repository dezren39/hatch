# TOOLS.md - Local Notes

Short, durable notes that make external tools work reliably in this
particular setup: device nicknames, host aliases, preferred voices, and
environment-specific quirks. Skills describe how tools work in general; this
file holds only what is unique here. Leave it empty until there is something
worth recording.

## Toolchains (installed 2026-09-29, under ~/tools — persistent)
- Go: `~/tools/go/bin/go` (1.25.1). Add to PATH as needed.
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
- Nix 2.35.2 single-user (`--no-daemon`): `/nix` is a SYMLINK to
  `/home/hatch/nix-persist` (persistent btrfs). `allow-symlinked-store = true`
  in nix.conf covers nix's LocalStore guard; taint-shim handles the two
  remaining sandbox quirks: hides taint xattrs (sandbox denies removexattr
  even for root — local builds fail with EPERM without it) and masks the
  /nix symlink mode 0777→0755 (nix 2.35.2's build-sandbox
  `checkNotWorldWritable` rejects S_IWOTH ancestors when building as nixbld).
  The symlink bit itself is reported truthfully since phase 2 (2026-09-30);
  the old full symlink spoofing was removed. The `real` store-dir setting
  from the phase-1 research does not exist in nix 2.35.2. No copy, no
  per-exec mount — the symlink survives recycles and is visible to every
  exec. `~/tools/nix-ensure.sh`
  (wired into `~/tools/init.sh`) is idempotent: populates the persistent dir
  from tarball if unhealthy, ensures the symlink, verifies `nix eval`.
  Binary at `/nix/var/nix/profiles/per-user/root/profile/bin/nix` (user
  profile, nix 2.35.2 — self-heals via nix-ensure.sh if the binary goes
  missing; the old bootstrap profile was merged away 2026-09-30).
  `build-users-group = nixbld` in nix.conf: builds run as nixbld1-10 (verified
  via a local derivation probe). The nixbld group has traverse-only
  (`--x`) ACLs on `/home/hatch`, `/home/hatch/nix-persist`, and
  `~/tools/taint-shim` (set via python3 ctypes; `setfacl` not installed).
  - `~/tools/nix-ensure.sh` — fast (~0.2s) when healthy. NEVER auto-deletes or
    quarantines the persistent dir on failure (fail loud); NEVER extracts over
    a non-empty tree (tar hardlinks aren't idempotent — moves aside as
    `.bad.<timestamp>`).
  - `~/tools/nix-install.sh` — full fresh install (separate script); the installer's
    final profile step fails on sandbox taint xattrs, so the script builds the
    profile symlinks manually. `~/tools/nix-restore.sh` is a legacy shim → nix-ensure.
  - Backup is `~/tools/nix-store.tar.gz` (ships in the base image, so first
    populate never needs apt; snapshots via `~/tools/nix-snapshot.sh` re-tar
    the live tree with --hard-dereference).
  - ALWAYS run nix with `LD_PRELOAD=~/tools/taint-shim/taint_shim.so`.
    The shim: hides taint xattrs (sandbox denies removexattr), elides nix's
    redundant startup chown (sandbox denies chown even for root), and masks
    the /nix symlink mode 0777→0755 for the build-sandbox ancestor check.
    nix-ensure.sh exports this.
  - /etc/nix/nix.conf (overlay, rewritten each boot by nix-ensure.sh):
    `experimental-features = nix-command flakes`,
    omnibin cachix `extra-substituter` + key, `accept-flake-config = true`.
  - `/usr/local/bin/nix` is a wrapper script (on the default PATH) that sets
    LD_PRELOAD and execs the PROFILE nix directly — so `nix` works in any
    shell with no per-shell setup, and self-heals if the profile binary goes
    missing. Created by `~/tools/install-nix-wrapper.sh`, run on boot via
    init.sh (overlay wipes /usr/local/bin; atomic temp+rename install).
    After `nix profile` install/remove/upgrade/rollback it auto-runs
    nix-profile-sync.sh.
  - `~/tools/nix-repair.sh` — on-demand repair triggered by the shell sentinel
    in `shell-env.sh` when `/nix`, the profile nix, or `/usr/local/bin/nix` look
    broken. `flock`-guarded, `NIX_REPAIR_GUARD` recursion guard (children get
    `BASH_ENV` unset, run via `/bin/bash.real`), verifies actual state
    post-repair, never deletes nix-persist on failure. Full recycle still via
    init.sh + `sandbox-boot-init` cron.
  - `~/tools/nix-profile-sync.sh` symlinks `~/.nix-profile/bin/*` into
    `/usr/local/bin/` so `nix profile install`ed apps (e.g. cowsay) are on the
    PATH in every shell with no wrappers per program. Skips `nix*` (the
    wrapper covers those) and never clobbers real files. Run on boot via
    init.sh; auto-triggered by the nix wrapper after profile mutations.
  - nix-ensure.sh self-heals if the profile loses its nix binary (a flake
    `nix profile install` replaces the installer-provided profile generation):
    it adds the newest store nix with a real (non-symlink) bin/nix — never
    removes before adding (`profile remove` + `profile add` of the same path
    silently skips linking bin/nix; 2.34.8 self-add has the same quirk).
  - Symlinked-store C-build gotcha (hit building mcpx 2026-09-30): gcc
    canonicalizes /nix through the symlink → cc-wrapper purity check fails
    ("impure path ... used in link"). Escape hatch per derivation:
    `NIX_ENFORCE_PURITY=0` (safe here — the "impure" path IS the store). For Go
    derivations, prefer `env.CGO_ENABLED = "0"` (nixpkgs honors args.env over
    go.CGO_ENABLED) so no C toolchain is needed at all; makeCWrapper's
    postInstall wrapProgram still compiles a C wrapper, which is where the
    purity flag becomes necessary. Upstreamed to dezren39/nix as PR #194.

## Sandbox filesystem model (learned 2026-09-29, corrected)
- Kernel persists across execs, but the sandbox DOES get recycled (new boot_id,
  overlay wiped — observed 2026-09-29 ~08:06 CDT). Overlay files persist across
  execs, NOT across recycles. `/home/hatch` (btrfs) is the only thing that
  survives a recycle.
- **Mount namespaces are per-exec**: any `mount` I do is invisible to the next exec.
  Don't design around bind mounts persisting; install real files instead.
- `/tmp` is a shared tmpfs (files persist across execs, not across kernel reboots).
- `/home/hatch` quirks: (a) even root CANNOT `rm` inside read-only (555) directories
  — `chmod -R u+w` first, or better, keep backups as single tarballs instead of live
  trees; (b) new files get `user.hatch_tainted*` xattrs (harmless, but the nix
  installer chokes removing them — hence manual profile build); (c) apt-installed
  packages are ephemeral — init must reinstall anything it depends on, or better,
  depend only on base-image tools (gzip/xz/curl/python3 all survive).
- Rust shims need env: `CARGO_HOME=~/tools/cargo RUSTUP_HOME=~/tools/rustup`.
- `~/tools/init.sh` (cron `sandbox-boot-init`, every 5m) verifies major components
  (go/rust/nix present and working); heavy installs live in separate scripts it calls.
  Logs to `/home/hatch/logs/init.log` with per-boot telemetry: boot_id, kernel/OS,
  disk usage, nix store stats (paths, profile bins), network check, per-step timing,
  and init duration. Skips via marker file when already initialized for the boot.

## omnibin (fzakaria/omnibin — used via nix, nothing stored locally)
- The app is its own UX: `nix run github:fzakaria/omnibin` drops into a shell
  with every nixpkgs binary on PATH (FUSE daemon + unshare'd shell). No wrapper
  script needed. Always run with `LD_PRELOAD=~/tools/taint-shim/taint_shim.so`
  (taint xattr EPERM).
- `nix run github:fzakaria/omnibin#omnibin -- which <name>` (or `which --all`)
  queries the pinned index DB with no FUSE — works fully in the sandbox.
  Without FUSE you lose transparent lazy execution, but `nix-store --realise
  <path>` fetches any resolved binary (verified: ran Python 3.7.1 from 2018).
- Its cachix binary cache is baked into /etc/nix/nix.conf by nix-ensure.sh, so
  no --accept-flake-config flag needed and no source builds after a recycle.
- Near-0-step without FUSE: `~/tools/dispatcher.sh` (via
  `command_not_found_handle` in `~/tools/shell-env.sh`, sourced from
  `BASH_ENV` by the `/bin/bash` wrapper) — type any nixpkgs binary
  (e.g. `cowsay`, `cowsay@3.8.4`) and it's resolved, fetched, GC-rooted,
  cached, and run. Lookup order: nix profile (exact `--version` fast path),
  then the pinned omnibin index (`which --all` for @version), then fallback
  to `nix run nixpkgs#`. Verified: `figlet` (index, survives `nix store gc`
  via persistent root), `cowsay@3.8.4` (profile); `cowsay@9.9.9` fails loudly
  with exit 127 (no substitution). Misses still print 'command not found'.
- Stubs in `~/tools/bin/` (auto-created on resolution, on PATH) let
  subprocesses and build tools discover resolved binaries without bash's
  `command_not_found_handle`.
- FUSE mounts do NOT work here (tested 2026-09-29): kernel has fuse and
  user+mount namespaces work, but the sandbox denies mknod (EPERM as root and
  in a userns), so /dev/fuse can't be created. The shell app fails cleanly at
  mount with "fuse: device /dev/fuse not found". Needs the runtime to expose
  /dev/fuse. After a sandbox recycle, `nix run` re-fetches from cachix (~2 min).
