# System profile

Snapshot 2026-09-30 ~05:10 CDT. See [capabilities.md](capabilities.md) for
what the kernel lets us do, [disk-inventory.md](disk-inventory.md) for the
full file listings.

## OS / kernel / hardware

| | |
|---|---|
| OS | Ubuntu 24.04.5 LTS (Noble Numbat) |
| Kernel | 7.0.0-39-generic `#1 SMP PREEMPT_DYNAMIC` (built Sep 24 2026) |
| Hostname | `htch-runtime` |
| CPU | 2× AMD EPYC 9D25 126-Core (vCPUs) |
| RAM | 7.7 GiB (5.4 used / 2.4 available at snapshot) |
| Init | systemd (PID 1, fully functional) |
| User | root (uid 0) inside the container |

## VM vs container: what the evidence says

**It's a container** (systemd-nspawn), running on a virtualized host:

| Indicator | Value | Meaning |
|---|---|---|
| `systemd-detect-virt` | `systemd-nspawn` | Container, not a VM |
| `/.dockerenv` | absent | Not Docker |
| CPU flag `hypervisor` | present | The *host* is virtualized (KVM-ish: `vmmcall`, `npt`, `vnmi` flags) |
| `/proc/1/cgroup` | `0::/..` | cgroup v2, minimal hierarchy |
| No `/dev/kvm` | — | Can't nest VMs |
| Disks as virtio (`vd*`) | vda/vdb/vdc/vdd | Typical cloud VM block devices |

So: a VM somewhere runs containers; we live in one of the containers.

## Read-only surfaces

| Path | Type | Notes |
|---|---|---|
| `/opt/hatch` | squashfs (`/dev/mapper/opt_hatch`) | Platform runtime tools — read-only by design |
| `/etc/hosts`, `/etc/resolv.conf` | squashfs (same device) | Bind-mounted from the platform image |
| `/etc/hatch/credentials` | tmpfs, ro | Credential injection point |
| `/run/hatch/*` | tmpfs, ro | `auth`, `cell-anchors`, `egress-tls`, `noded`, `privsep`, `runtime-cell`, `telemetry` |
| `/sys`, `/sys/*` | sysfs/tmpfs, ro | Kernel interfaces |
| `/home/hatch/assets` | squashfs | Platform assets inside home |
| `~/.pki/nssdb` | tmpfs, ro | NSS certificate DB |

`/opt/hatch` contents: 12,561 files, 1.6 MB listing — the full listing is in
`../disk-listings/opt-hatch-squashfs.txt`. One-off backup at
`~/opt-backup.tar.zst` (1.0 GB, 2026-09-29).

## Mount topology (abridged)

```
 /                        overlay (ephemeral — wiped on recycle)
 ├── /opt/hatch           squashfs, ro  (platform tools)
 ├── /home/hatch          btrfs /dev/mapper/rv, rw  (PERSISTENT)
 │   └── assets           squashfs, ro
 ├── /tmp                 tmpfs (shared across execs, lost on reboot)
 ├── /dev                 tmpfs (no /dev/fuse, no /dev/kvm; /dev/net/tun exists)
 └── /run/hatch/*         tmpfs, ro  (runtime state)
```

Note: `/home/hatch` appears three times in `/proc/mounts` (overlay, then
btrfs twice) — the last mount wins, so the effective fs is btrfs on
`/dev/mapper/rv` (dm-crypt → the 100 GB `vdd`). Mount options:
`rw,nosuid,nodev,noatime,compress-force=zstd:3,ssd,discard=async,space_cache=v2`.

## Boot / recycle

- **Boot** = kernel start (new `/proc/sys/kernel/random/boot_id`, uptime reset).
- **Recycle** = sandbox torn down, overlay wiped. In practice they've always
  coincided here — 6 unique boot IDs logged, each with a wiped overlay.
- Current boot_id (2026-09-30 05:10): `bc741be0-1c72-4358-9acb-9447b8d91a2b`,
  uptime 1:28 — a recycle happened between the 04:45 and 05:10 snapshots,
  and everything persistent came back intact.
- `init.sh` has no explicit "overlay was wiped" check; it blindly restores.

## Network

- Outbound HTTPS works (cache.nixos.org reachable; latency logged per boot).
- ICMP blocked (100% loss) — health checks must be TCP/HTTPS.
- DNS via `/etc/resolv.conf` (platform-provided, read-only).
