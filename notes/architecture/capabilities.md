# Capabilities: what works and what doesn't

Measured 2026-09-30 on this sandbox (systemd-nspawn container, kernel
7.0.0-39-generic, running as root). Re-test after any platform change.

## Linux capabilities (from /proc/self/status)

`CapEff: 000001fffff7ffff` — we hold **37 of 38** capabilities:

**Have:** CHOWN, DAC_OVERRIDE, DAC_READ_SEARCH, FOWNER, FSETID, KILL, SETGID,
SETUID, SETPCAP, LINUX_IMMUTABLE, NET_BIND_SERVICE, NET_ADMIN, NET_RAW,
IPC_LOCK, IPC_OWNER, SYS_MODULE, SYS_RAWIO, SYS_CHROOT, SYS_PTRACE,
SYS_ADMIN, SYS_BOOT, SYS_NICE, SYS_RESOURCE, SYS_TIME, SYS_TTY_CONFIG,
MKNOD, LEASE, AUDIT_WRITE, AUDIT_CONTROL, SETFCAP, MAC_OVERRIDE, MAC_ADMIN,
SYSLOG, WAKE_ALARM, BLOCK_SUSPEND, AUDIT_READ

**Missing:** only `SYS_PACCT` (process accounting — irrelevant).

**The catch:** capabilities are necessary but not sufficient. A seccomp
filter and/or device cgroup sits above them and denies specific syscalls
regardless of caps. So "have CAP_MKNOD" ≠ "can mknod".

## Tested: works ✅

| Test | Result |
|---|---|
| `unshare -U` (user namespace) | ✅ exit 0 |
| `unshare -m` (mount namespace) | ✅ exit 0 |
| systemd as PID 1, `systemctl` | ✅ fully functional |
| Bind mounts *within one exec* | ✅ (but see below) |
| `nix` builds / store realise | ✅ |
| Outbound HTTPS (cache.nixos.org etc.) | ✅ (~TCP+TLS latency logged per boot) |
| ICMP ping (8.8.8.8) | ❌ 100% loss — blocked; use TCP checks |
| Detached processes surviving exec exit | ✅ (`nohup`/`disown` + PID file + `kill -0`) |
| Writing to `/home/hatch` | ✅ persistent btrfs |
| chmod/chown as root | ✅ (except inside 555 dirs — see below) |

## Tested: doesn't work ❌

| Test | Result | Blocker |
|---|---|---|
| `mknod /tmp/testnull c 1 3` | ❌ `EPERM` | seccomp/device cgroup, despite CAP_MKNOD |
| `/dev/fuse` creation | ❌ `mknod` EPERM | same — FUSE impossible (kernel *has* fuse) |
| Mounts persisting across execs | ❌ invisible to next exec | mount namespaces are per-exec |
| Deleting inside 555 dirs (even as root) | ❌ `EPERM` | btrfs/overlay dir write-bit rule (see below) |
| `removexattr` on `user.hatch_tainted*` | ❌ `EPERM` | sandbox taint xattrs — breaks nix installer profile step |
| Reading vda/vdb/vdc block devices | ❌ not exposed | only vdd (via /dev/mapper/rv) is mounted in our ns |
| `/dev/kvm` | ❌ absent | no nested virtualization device |
| Docker daemon | ❌ n/a | no dockerd; nspawn container |

## Quirks that bit us (rules)

1. **Deletion depends on the *directory's* write bit, not file mode.**
   A read-only (444) file inside a writable directory deletes fine even as
   root — but *manual* `rm` of anything inside a read-only (555) directory
   fails for anyone, even root. Nix store dirs are 555.
   **Exception:** `nix store gc` works fine (tested 2026-09-30, freed ~1 GB:
   1.4G → 394M). Nix chmods store paths writable before deleting them —
   the 555 block only affects manual deletion, not nix's own GC.

2. **New files get `user.hatch_tainted*` xattrs** (harmless, but the nix
   installer chokes removing them — hence the manual profile build in
   `nix-install.sh`). The taint-shim also hides these from nix.

3. **`/tmp` is a shared tmpfs** — persists across execs, lost on kernel reboot.

4. **Mount namespaces are per-exec** — any `mount` I do is invisible to the
   next exec. Don't design around bind mounts persisting; install real files.

5. **apt-installed packages are ephemeral** — init must reinstall anything it
   depends on, or better, depend only on base-image tools
   (gzip/xz/curl/python3 all survive recycles).

6. **ICMP is blocked** — network checks must use TCP/HTTPS
   (we time cache.nixos.org instead of pinging 8.8.8.8).

## What this means for design

- Persistence must live under `/home/hatch` (the btrfs volume). Everything
  else is rebuilt by `~/tools/init.sh` on boot.
- No FUSE → no omnibin shell app, no FUSE-based tricks. Use
  `nix-store --realise` instead.
- No mknod → no device nodes, no loop mounts.
- Namespaces work → `unshare` tricks are fine *within* one exec.
- systemd works → prefer real services over detached processes where the
  unit file can be rewritten on boot (it's ephemeral).
