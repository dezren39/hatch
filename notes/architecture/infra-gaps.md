# Infrastructure gaps & improvement backlog

Known gaps in the sandbox/agent infrastructure as of 2026-09-30.
Items marked **[filed]** have dev notes sent to the Muse team (confirmed
delivered 2026-09-30, no personal details attached).

## Platform gaps (need the runtime team)

1. **[filed] No `/dev/fuse`.** Kernel has FUSE, user+mount namespaces work,
   but `mknod` is denied (EPERM as root and in a userns), so `/dev/fuse`
   can't be created. Blocks: omnibin shell app, any FUSE filesystem.
   Ask: expose `/dev/fuse` to the sandbox.

2. **[filed] `/nix` doesn't survive recycles natively.** Worked around with
   the symlink (`/nix` → `/home/hatch/nix-persist`) + LD_PRELOAD taint-shim,
   plus tarball snapshots. Ask (any one): persist `/nix` across recycles,
   allow a designated boot script, or persist links to files outside the
   ephemeral overlay.

3. **No explicit "overlay was wiped" signal.** `init.sh` blindly restores on
   every boot; it can't distinguish "fresh recycle" from "already set up".
   The 5-minute cron's "already initialized" fast path works via a marker
   file, but there's no first-class boot-vs-recycle API. A recycle always
   coincides with a new boot_id here (6 observed), but that's inference.

4. **`removexattr` denied on taint xattrs.** New files get
   `user.hatch_tainted*`; the sandbox denies removing them even as root.
   Breaks stock installers (nix profile step). We work around per-case.

5. **No `/dev/kvm`.** Nested virtualization unavailable; can't run VMs.

6. **ICMP blocked.** Minor, but every network check must be TCP/HTTPS.

## Our own automation gaps (fixable by us)

7. **Boot telemetry has no alerting.** `init.sh` logs per-boot stats to
   `~/logs/init.log` + `init.jsonl`, but nothing watches for anomalies
   (e.g. nix unhealthy for N boots, disk filling). A watchdog cron could
   diff the last JSONL line against thresholds.

8. **`nix-snapshot.sh` isn't scheduled.** Snapshots are manual. A weekly
   cron (or post-`nix profile install` hook) would keep the restore tarball
   fresh. Currently the tarball can drift behind the live store.

9. **`opt-backup.tar.zst` (1 GB) is a one-off.** Taken 2026-09-29 of the
   `/opt/hatch` squashfs. No refresh schedule; if the platform updates the
   squashfs we won't have a matching backup. (Low priority — it's read-only
   and provided by the platform.)

10. **No health check on the `gh` auth token.** Device-flow OAuth tokens can
    expire/be revoked; `gh` calls would start failing silently in background
    jobs. `init.sh` could run `gh auth status` and flag it.

11. **Avatar backup is manual.** Drewry wants liked avatar animations backed
    up so an accidental source-image edit can't lose good renders. No
    automated versioning of `workspace/avatars/` yet.

12. **No off-sandbox backup of `/home/hatch`.** The btrfs volume persists
    across recycles, but there's no copy anywhere else. The git repo
    (`dezren39/hatch`) now covers tracked files; untracked data (memory,
    agents/, workspace state) has no second home.

13. **Cron job sprawl.** 38 cron jobs (6 user, 32 system). The 24 hourly
    feed-pulse jobs dominate. No central inventory doc beyond `cron list`.

## Deliberately not fixed

- **FUSE via userspace workarounds** — not worth it; `nix-store --realise`
  covers the need.
- **`~/.bashrc`** — deleted at Drewry's request; the `/bin/bash` wrapper +
  `BASH_ENV` replaces it. Never recreate.
- **Auto-quarantine of nix-persist on health-check failure** — explicitly
  forbidden; fail loud instead.
