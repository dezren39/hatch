# TOOLS.d/sandbox.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

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

## init.sh recycle-straddle race (observed 2026-10-05)
- init.sh decides "already initialized" from the per-boot marker file AT SCRIPT START. A recycle mid-run is not re-checked: the 14:11:51 CDT recycle fell inside this routine's 14:11:43–14:12:39 init.sh run, which still reported "already-initialized" against the OLD boot's (now-wiped) marker — the first full init on the new boot happened 9 min later at this run's 14:21:06 execution.
- Harmless here: the sandbox-boot-init cron also keys on the per-boot marker, so the first init.sh execution after the recycle always does a full init; the straddling run just reports stale good news. Exposure window = one schedule interval. When triaging "already-initialized" lines in events.log against init.log START lines, check which boot_id each belongs to — a mismatch within ~10 min means a straddle, not a missed init.

## init.sh interrupted mid-run on a fresh recycle (hit 2026-10-16)
- The sandbox recycled ~7s into a scheduled run (boot 12:20:42 UTC, run started 12:20:34, init.sh launched 12:20:49): the exec dispatch died with "the service restarted while it was running" and init.sh left NO init.log trace (no START/END lines) — the interrupted invocation did nothing at all.
- Detect: `/proc/sys/kernel/random/boot_id` differs from init-status's `boot_id`, and init.log's last line predates the boot. Fix: just re-run init.sh — it's idempotent; the fresh-boot full init ran clean (exit 0, 82s, END result=SUCCESS, 10572 store paths, mcpx unit restored+started). Nothing else needs repair.
