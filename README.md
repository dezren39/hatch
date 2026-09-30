# Hatch Home

This is the agent's persistent home directory (`/home/hatch`). It survives sandbox recycles; everything outside it is ephemeral.

## Layout

```
~/
├── README.md           # This file
├── .gitignore          # Tracks scripts/docs, ignores binaries/caches/private
├── *.md                # Agent identity: AGENTS, SOUL, IDENTITY, USER, MEMORY, TOOLS, etc.
├── tools/              # Scripts and toolchains (the important stuff)
│   ├── init.sh                 # Boot orchestrator (cron every 5m)
│   ├── nix-ensure.sh           # Nix setup (symlink, config, verify)
│   ├── install-nix-wrapper.sh  # /usr/local/bin/nix wrapper
│   ├── install-bash-wrapper.sh # /bin/bash wrapper (auto @version)
│   ├── nix-profile-sync.sh     # Profile bins → /usr/local/bin
│   ├── omnibin-not-found.sh    # command_not_found_handle (@version)
│   ├── nix-snapshot.sh         # Backup the nix store to tarball
│   ├── taint-shim/             # LD_PRELOAD shim source (C)
│   ├── go/                     # Go toolchain (ignored)
│   └── cargo/ rustup/          # Rust toolchain (ignored)
├── docs/
│   ├── sandbox/        # Architecture docs (tracked) — see notes/architecture/README.md
│   └── ...             # Platform reference docs (ignored, managed by platform)
├── nix-persist/        # The nix store (ignored, 1.4G of binaries)
├── user/               # User private files (ignored)
├── logs/               # Boot logs and telemetry (ignored)
├── workspace/          # Work product, goals (ignored)
└── memory/ dreams/     # Agent memory (ignored)
```

## Key Concepts

- **Boot vs recycle**: See [notes/architecture/boot-lifecycle.md](notes/architecture/boot-lifecycle.md)
- **Nix persistence**: `/nix` is a symlink to `nix-persist/` — see [notes/architecture/nix-persistence.md](notes/architecture/nix-persistence.md)
- **Program access**: Wrappers make everything available — see [notes/architecture/program-access.md](notes/architecture/program-access.md)
- **Services**: systemd works — see [notes/architecture/systemd.md](notes/architecture/systemd.md)

## Git

This directory is a git repo. Scripts, docs, and config are tracked. Binaries, caches, logs, and private files are ignored. Review `git status` carefully before committing — don't let anything sneak in.
