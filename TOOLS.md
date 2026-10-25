# TOOLS.md - Local Notes

Short, durable notes that make external tools work reliably in this
particular setup: device nicknames, host aliases, preferred voices, and
environment-specific quirks. Skills describe how tools work in general; this
file holds only what is unique here.

SPLIT 2026-10-25 (token review #2): the detail moved verbatim to `~/TOOLS.d/`
topic files — this index keeps only the always-needed facts and pointers.
Read the topic file before doing that kind of work; do not guess from the
one-liners.

## Always-needed facts
- Persistent storage: ONLY `/home/hatch` survives a sandbox recycle; `/tmp`
  is a 512M tmpfs; mount namespaces are per-exec. Detail: TOOLS.d/sandbox.md
- Go: `~/tools/go/bin/go`; builds need `TMPDIR=/home/hatch/tmp` (and
  `GOTMPDIR` for tests). Rust: `CARGO_HOME=~/tools/cargo RUSTUP_HOME=~/tools/rustup`.
  Detail: TOOLS.d/toolchains.md
- Nix: ALWAYS `LD_PRELOAD=~/tools/taint-shim/taint_shim.so`; /nix is a symlink
  to ~/nix-persist; `nix` on PATH is a self-healing wrapper; NEVER bare
  `nix profile add .` and never a symlink as `--profile`. Detail: TOOLS.d/nix.md
- omnibin: `nix run github:fzakaria/omnibin` (with the taint-shim preload);
  `which` queries need no FUSE. Detail: TOOLS.d/nix.md
- Secrets: Bitwarden Secrets Manager via `~/tools/bws-env.sh` (bws at
  ~/tools/bin/bws); 1Password via `source ~/tools/op-env.sh`. Values are
  referenced by name only, never written to files. Detail: TOOLS.d/secrets.md
- Tool output in this environment has been FABRICATED before — verify
  consequential facts with a second independent call. The read tool can also
  serve stale snapshots of frequently-appended files. Detail: TOOLS.d/agent-quirks.md
- Laptop SSH: use ~/tools/laptop-ssh.sh (connection multiplexing; stock
  MaxStartups drops burst pre-auth setups — root-caused 2026-10-25).
  Detail: TOOLS.d/laptop.md

## Topic files (~/TOOLS.d/)
- toolchains.md — Go/Rust gotchas, bash wrapper, program@version dispatcher
- nix.md — the symlinked-store setup, nix-ensure/repair, profile rules, omnibin
- sandbox.md — filesystem/recycle model, init.sh races
- git.md — credential helper, repo layout (which tree is whose)
- agent-quirks.md — read-tool staleness, output fabrication, exec stdin vs heredoc
- mcpx.md — mcpx daemon notes
- secrets.md — Bitwarden Secrets Manager + 1Password service accounts
- opencode.md — OpenCode server on this sandbox + the v2 migration state
- laptop.md — laptop SSH drops (MaxStartups) and the multiplexing fix
- memory-cli.md — the mem CLI: append/search memory + topics without reading them
