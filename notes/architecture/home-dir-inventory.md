# Home directory inventory (`/home/hatch`)

What shipped with / was created in the agent home dir, as of 2026-09-30.
Counts/sizes measured with `find | wc -l` and `du -sh`. This is the
**persistent** volume (100 GB btrfs) — the only thing that survives recycles.

## Root files (tracked in git unless noted)

| File | Size | What |
|---|---|---|
| `.gitignore` | 1.2K | Keeps MEMORY.md, USER.md, agents/, docs/, etc. out of git |
| `AGENTS.md` | 886B | My operating manual (untracked — in TODO for review) |
| `HEARTBEAT.md` | 113B | Heartbeat check template (untracked, empty = no-op) |
| `IDENTITY.md` | 682B | Who I am: Archer, anime-butler vibe (untracked) |
| `MEMORY.md` | 11K | Curated long-term memory (untracked — sensitive) |
| `PROACTIVE_PREFERENCES.md` | 496B | Proactive notification prefs (untracked — will fill) |
| `README.md` | 2.4K | Home dir index |
| `SOUL.md` | 795B | Persona (untracked) |
| `TODO.md` | 1.4K | Git-review checklist for the sensitive files |
| `TOOLS.md` | 7K | Local tool notes (I wrote it; no personal info) |
| `USER.md` | 337B | Who Drewry is (untracked — has his name) |
| `opt-backup.tar.zst` | 1.0G | One-off backup of the /opt/hatch squashfs (2026-09-29) |
| `runtime.lock` | 0 | Runtime lock file (empty) |

## Directories

| Dir | Entries | Size | What |
|---|---|---|---|
| `agents/` | 9,157 | 152M | **2,250 subagent session dirs** — each has `sessions.json` (UUIDs, timestamps, token counts) + `.jsonl` transcript. No main-chat sessions here. Untracked (too sensitive). |
| `assets/` | 1,056 | 99M | Platform-provided assets (read-only squashfs mount also here) |
| `captest/` | 3 | ~0 | Capability test scratch |
| `config/` | 7 | 28K | `home.yaml`, `skills.yaml`, `workspace-state.json`, filesystem watch hashes |
| `data/` | 1 | 0 | Empty placeholder |
| `docs/` | 33 | 204K | **Meta platform docs** (27 files) — Meta maintains; we track to observe changes |
| `dreams/` | 12 | 36K | Alignment synthesis + repair threads (nightly background) |
| `go/` | 5 | ~0 | Go workspace (toolchain in `tools/go`) |
| `hooks/` | 8 | 4K | Event-hook definitions, scripts, state, logs |
| `logs/` | 5 | 64K | `init.log` + `init.jsonl` boot telemetry |
| `memory/` | 17 | 356K | `MEMORY.md` overflow: daily logs, `people/`, `bank/`, shopping profile |
| `nix-persist/` | 303,191 | 1.5G | **The persistent nix store** — `store/` (1.4G) + `var/` (13M). `/nix` symlinks here |
| `notes/` | 13+ | 1.7M | This documentation + per-disk find listings |
| `subscriptions/` | 7 | 12K | `activity_feed`, `device_syncs`, `spaces_actions` |
| `taint-test/` | 5 | 12K | Taint-shim test scratch |
| `tools/` | 16,305 | 1.3G | All our tooling (see below) |
| `user/` | 2 | 4K | User-provided files |
| `workspace/` | 988 | 42M | Working state (see below) |
| `.cache/` | 786 | 106M | chromium-headless, nix, omnibin, thumbnails, go-build |
| `.config/` | 25 | 60K | `gh/` auth (`hosts.yml`), chromium, etc. |
| `.git/` | — | — | Git repo (branch `main`, 1 squashed commit, remote `dezren39/hatch`) |
| `.local/` | 7 | 12K | Local user data |
| `.nix-defexpr/` | — | — | Legacy nix defexpr (unused, flakes only) |
| `.nix-portable/` | 227,815 | 887M | **Legacy**: nix-portable install, superseded by real nix. Candidate for deletion |
| `.nix-profile` | symlink | — | → `/nix/var/nix/profiles/per-user/root/profile` |
| `.pki/` | — | — | NSS db (read-only tmpfs mount) |
| `.rustup/` | 0 | 0 | Empty placeholder (real toolchain in `tools/rustup`) |
| `.ssh/` | — | — | Ed25519 keypair (persistent) |

## `tools/` breakdown (1.3G)

| Item | Size | What |
|---|---|---|
| `rustup/` | 577M | Rust toolchain (`CARGO_HOME=~/tools/cargo`) |
| `nix-store.tar.gz` | 335M | Compressed nix store backup (restores after recycle) |
| `go/` | 236M | Go 1.25.1 |
| `nix-portable/` | 65M | Legacy nix-portable copy |
| `nix-store.tar.gz.prev` | 40M | Previous store backup |
| `cargo/` | 21M | Cargo home |
| `taint-shim/` | 40K | **LD_PRELOAD shim** (C source + README): hides taint xattrs, elides nix's redundant chown, hides the `/nix` symlink from nix's store guard |
| `init.sh` | 8K | **Boot orchestrator** — run by `sandbox-boot-init` cron every 5 min |
| `nix-installer.sh` | 8K | Upstream nix installer (cached) |
| `omnibin-not-found.sh` | 4K | `command_not_found_handle` → `@version` support in every exec |
| `nix-ensure.sh` | — | Idempotent nix health check + repair (~0.2s healthy) |
| `nix-install.sh` | — | Full fresh nix install |
| `nix-snapshot.sh` | — | Re-tar live store → backup |
| `nix-restore.sh` | — | Legacy shim → nix-ensure |
| `nix-profile-sync.sh` | — | Symlink profile bins → /usr/local/bin |
| `install-bash-wrapper.sh` | — | Installs the `/bin/bash` wrapper (BASH_ENV) |
| `install-nix-wrapper.sh` | — | Installs the `/usr/local/bin/nix` wrapper |

## `workspace/` breakdown (42M)

| Dir | Entries | Size | What |
|---|---|---|---|
| `agents/` | 89 | 1.4M | Agent workspace files |
| `avatars/` | 65 | 16M | **62 avatar images** (tracked in git) |
| `cron.d/` | 15 | 16K | Cron job definitions (4 files; each embeds full prompt text) |
| `feature-request/` | 5 | 8K | Feature requests filed |
| `feed/` | 54 | 1.6M | Feed posts and state (22 files) |
| `goals/` | 38 | 40K | Goal workspaces (10 files) |
| `memory/` | 18 | 52K | Workspace memory (13 files) |
| `objectives/` | 3 | 4K | `INFERRED_GOAL_LEADS.md` (background-inferred) |
| `onboarding_tour/` | 5 | 2.9M | Onboarding tour assets |
| `proactivity/` | 137 | 2.3M | Proactive notification prep (106 files) |
| `scheduler/` | 1 | 0 | Empty |
| `self_improvement/` | 306 | 788K | Background self-improvement (166 files) |
| `spaces/` | 1 | 0 | Empty |
| `system/` | 2 | 88K | System prompt copy |
| `user/` | 7 | 544K | User media library |

## Dotfile notes

- **No `~/.bashrc`** — deleted at Drewry's request. The `/bin/bash` wrapper
  sets `BASH_ENV=~/tools/omnibin-not-found.sh` and execs `/bin/bash.real`.
- `.gitconfig` exists (1 entry, 337B).
- `.postgres-ready` (6B) — marker from a postgres experiment.

## Cleanup candidates

- `.nix-portable/` (887M) — superseded by real nix; safe to delete after
  confirming nothing references it.
- `tools/nix-portable/` (65M) — same.
- `tools/nix-store.tar.gz.prev` (40M) — superseded backup.
