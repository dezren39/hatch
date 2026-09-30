# Sandbox Architecture

How the agent sandbox works: boot lifecycle, persistence, program access, and services.

## Contents

- [boot-lifecycle.md](boot-lifecycle.md) — Boot vs recycle, the init system, cron scheduling, and the marker protocol
- [nix-persistence.md](nix-persistence.md) — How `/nix` survives recycles with zero copies (symlink + LD_PRELOAD shim)
- [program-access.md](program-access.md) — How every program is on PATH in every exec (wrappers, profile sync, bash wrapper, `@version`)
- [systemd.md](systemd.md) — Running persistent services via systemd units and detached processes
- [telemetry.md](telemetry.md) — Boot logging: human-readable log, compact JSONL, and what we capture

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
