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
  on boot via init.sh) that sets `BASH_ENV=~/tools/omnibin-not-found.sh` and
  execs `/bin/bash.real` (the original binary). Every exec therefore gets the
  omnibin `command_not_found_handle` automatically — `program@version` (e.g.
  `cowsay@3.8.4`) works with zero per-exec setup. The wrapper is transparent
  for all other commands.
- Nix 2.35.2 single-user (`--no-daemon`): `/nix` is a SYMLINK to
  `/home/hatch/nix-persist` (persistent btrfs). nix normally refuses a symlinked
  /nix, but taint-shim hides the symlink bit via lstat interposition so the
  guard passes. No copy, no per-exec mount — the symlink survives recycles
  and is visible to every exec. `~/tools/nix-ensure.sh` (wired into
  `~/tools/init.sh`) is idempotent: populates the persistent dir from tarball
  if unhealthy, ensures the symlink, verifies `nix eval`.
  Binary at `/nix/var/nix/profiles/default/bin/nix`; build users nixbld1-10 exist.
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
    redundant startup chown (sandbox denies chown even for root), and hides
    the /nix symlink from nix's store guard via lstat/stat interposition.
    nix-ensure.sh exports this.
  - /etc/nix/nix.conf (overlay, rewritten each boot by nix-ensure.sh):
    `experimental-features = nix-command flakes`,
    omnibin cachix `extra-substituter` + key, `accept-flake-config = true`.
  - `/usr/local/bin/nix` is a wrapper script (on the default PATH) that sets
    LD_PRELOAD and execs the real binary — so `nix` works in any shell with
    no per-shell setup. Created by `~/tools/install-nix-wrapper.sh`, run on
    boot via init.sh (overlay wipes /usr/local/bin). After `nix profile`
    install/remove/upgrade/rollback it auto-runs nix-profile-sync.sh.
  - `~/tools/nix-profile-sync.sh` symlinks `~/.nix-profile/bin/*` into
    `/usr/local/bin/` so `nix profile install`ed apps (e.g. cowsay) are on the
    PATH in every shell with no wrappers per program. Skips `nix*` (the
    wrapper covers those) and never clobbers real files. Run on boot via
    init.sh; auto-triggered by the nix wrapper after profile mutations.
  - nix-ensure.sh self-heals if the profile loses its nix binary (a flake
    `nix profile install` replaces the installer-provided profile generation):
    it bootstraps from any nix in the store and reinstalls nixpkgs#nix.

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
- Near-0-step without FUSE: ~/tools/omnibin-not-found.sh defines
  command_not_found_handle (sourced from ~/.bashrc) — type any nixpkgs binary
  (e.g. `cowsay`, `cowsay@3.8.4`) and it's resolved, fetched, and run.
  Lookup order: nix profile (fast path for `nix profile install`ed packages),
  then the omnibin index (`which --all` for @version), then fallback to
  `nix run nixpkgs#`. Verified: `jq`, `python3@3.7.1`, `cowsay@3.8.4`
  (profile), `cowsay@3.8.3` (omnibin index); misses still print
  'command not found' with exit 127.
- FUSE mounts do NOT work here (tested 2026-09-29): kernel has fuse and
  user+mount namespaces work, but the sandbox denies mknod (EPERM as root and
  in a userns), so /dev/fuse can't be created. The shell app fails cleanly at
  mount with "fuse: device /dev/fuse not found". Needs the runtime to expose
  /dev/fuse. After a sandbox recycle, `nix run` re-fetches from cachix (~2 min).
