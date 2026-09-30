# Sandbox Architecture

How the agent sandbox works: boot lifecycle, persistence, program access,
services, and everything we've learned operating it.

## Contents

- [boot-lifecycle.md](boot-lifecycle.md) — Boot vs recycle, the init system, cron scheduling, and the marker protocol
- [nix-persistence.md](nix-persistence.md) — How `/nix` survives recycles with zero copies (symlink + LD_PRELOAD shim)
- [nix-install-flakes.md](nix-install-flakes.md) — Installing Nix single-user with flakes enabled, the wrappers, self-healing
- [omnibin.md](omnibin.md) — What omnibin is, how we use it without FUSE, links (flake, blog, releases)
- [program-access.md](program-access.md) — How every program is on PATH in every exec (wrappers, profile sync, bash wrapper, `@version`)
- [systemd.md](systemd.md) — Running persistent services via systemd units and detached processes
- [telemetry.md](telemetry.md) — Boot logging: human-readable log, compact JSONL, and what we capture
- [capabilities.md](capabilities.md) — Kernel caps, what works / doesn't (FUSE, mknod, namespaces), sandbox quirks
- [system-profile.md](system-profile.md) — OS, hardware, VM/container indicators, read-only surfaces, mounts
- [home-dir-inventory.md](home-dir-inventory.md) — Every top-level dir/file in /home/hatch: what, how many, how big
- [disk-inventory.md](disk-inventory.md) — Disk layout + full find listings (in `../disk-listings/`)
- [infra-gaps.md](infra-gaps.md) — Known gaps: filed platform asks + our own automation backlog

## Quick Reference

| What | Where |
|---|---|
| Boot orchestrator | `~/tools/init.sh` |
| Boot log (human) | `~/logs/init.log` |
| Boot telemetry (JSON) | `~/logs/init.jsonl` |
| Boot status | `~/logs/init-status` |
| Nix ensure | `~/tools/nix-ensure.sh` |
| Taint shim source | `~/tools/taint-shim/taint_shim.c` |
| Git root | `/home/hatch` (this repo) |
