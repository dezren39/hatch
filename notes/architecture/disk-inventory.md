# Disk inventory

Full `find` listings (type, mode, user, group, size, mtime, path) live in
`../disk-listings/`, generated 2026-09-30 ~05:10 CDT:

| File | Entries | What |
|---|---|---|
| `disk-listings/home-hatch-btrfs.txt.gz` | 565,131 | `/home/hatch` — the persistent 100 GB btrfs volume |
| `disk-listings/root-overlay.txt.gz` | 105,770 | `/` — the ephemeral overlay (OS layer), `-xdev` |
| `disk-listings/opt-hatch-squashfs.txt.gz` | 12,561 | `/opt/hatch` — read-only platform squashfs |

Listings are gzip-compressed (9.9 MB total) and **not tracked in git** —
they're regenerable in ~2 min. `zcat` to read.

Format per line: `<type> <mode> <user> <group> <bytes> <YYYY-MM-DD HH:MM> <path>`
(`f`=file, `d`=dir, `l`=symlink).

## Block devices

| Device | Size | Role | Visible to us |
|---|---|---|---|
| `vda` | 7.6G | Ephemeral OS disk (backs the overlay's lowerdir) | Partially — as `/` overlay |
| `vdb` | 7.5G | Container runtime backing store | ❌ not mounted in our namespace |
| `vdc` | 803M | Boot/config (`vdc1` 795M, `vdc2` 6.3M, `vdc3` 4K) | ❌ not mounted in our namespace |
| `vdd` | 100G | **Persistent home** → `/dev/mapper/rv` (dm-crypt) → btrfs → `/home/hatch` | ✅ |

`df`: `/home/hatch` 100G, 3.7G used, 96G avail (4%).

## `/home/hatch` — by directory (file count)

| Dir | Files | Notes |
|---|---|---|
| `nix-persist/` | 303,191 | Live nix store (1.4G) + var (13M) |
| `.nix-portable/` | 227,815 | Legacy, superseded — cleanup candidate (887M) |
| `tools/` | 16,305 | Toolchains, scripts, tarballs |
| `agents/` | 9,157 | Subagent session records (152M) |
| `.git/` | 6,712 | Our repo objects (1 squashed commit) |
| `workspace/` | 988 | Working state (42M) |
| `.cache/` | 786 | Chromium, nix, omnibin caches (106M) |
| `docs/` | 33 | Meta platform docs |
| `.config/` | 25 | gh auth, chromium |
| `memory/` | 17 | Daily logs, people, bank |
| `notes/` | 13+ | This documentation |
| `dreams/` | 12 | Alignment data |

Type totals: 401,709 files, 156,084 dirs, 7,338 symlinks.

## `/` overlay — by directory (file count)

| Dir | Files | Notes |
|---|---|---|
| `/usr/lib` | 51,596 | System libraries |
| `/usr/share` | 36,279 | Shared data, docs, locales |
| `/usr/include` | 7,263 | C headers |
| `/opt/hatch-image` | 4,515 | Base image payload |
| `/var/lib` | 3,411 | Var state (dpkg, etc.) |
| `/usr/bin` | 912 | System binaries (`jq` lives here) |
| `/opt/meta-chromium` | 456 | Headless Chromium |
| `/etc/ssl` | 251 | CA certificates |

This whole tree is **ephemeral** — wiped on recycle, rebuilt from the image.
Anything we need must be reinstalled by `~/tools/init.sh` or live in
`/home/hatch`.

## `/opt/hatch` — platform squashfs (12,561 files)

Read-only runtime tools provided by the platform. We don't modify it;
one-off backup at `~/opt-backup.tar.zst`.

## What's *not* listable

- `vdb` (7.5G container backing) and `vdc` (803M boot/config) aren't mounted
  in our namespace — no file listing possible from here.
- `/run/hatch/*` tmpfs mounts are runtime state, intentionally excluded.
- `/proc`, `/sys`, `/dev` are virtual — not real disks.

## Regenerating

```bash
find /home/hatch -xdev -printf "%y %m %u %g %s %TY-%Tm-%Td\ %TH:%TM %p\n" \
  2>/dev/null | sort -k8 > ~/notes/disk-listings/home-hatch-btrfs.txt
```

Takes ~1–2 min for `/home/hatch` (565K entries, 84 MB listing).
The 84 MB home listing is the largest file in `notes/` — consider
compressing or excluding from git if it becomes a burden.
