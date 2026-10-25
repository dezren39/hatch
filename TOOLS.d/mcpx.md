# TOOLS.d/mcpx.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

## mcpx daemon
- The daemon's HTTP health endpoint binds an EPHEMERAL port per boot (35817, 36999, 33983 observed) — discover it via `journalctl -u mcpx` ("listening on ... and http://127.0.0.1:PORT") or `ss -tlnp | grep mcpx-wrapped`, NOT from config.json's `port` key (41001 — not what it binds). Probing 41001 returns 000 even when the daemon is healthy. (Hit 2026-10-05.)
- `mcpx call` end-to-end syntax: `mcpx call <namespace>.<tool> '{"json":"args"}'` (arguments must be JSON, not key=value) — e.g. `mcpx call fff_nix.grep '{"pattern":"flake.nix"}'`.
