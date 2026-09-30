# Program Access

How every program is available in every exec with zero per-exec setup.

## The Challenge

Each exec is a fresh, non-interactive, non-login bash (`/bin/bash` by absolute path):
- No `~/.bashrc`, no `~/.profile` — nothing is sourced
- No environment carries over between execs
- Default PATH includes `/usr/local/bin` but nothing else custom

## Layer 1: `/usr/local/bin/nix` Wrapper

`/usr/local/bin/nix` is a wrapper script (on the default PATH) that sets `LD_PRELOAD=~/tools/taint-shim/taint_shim.so` and execs the real nix binary. Created by `~/tools/install-nix-wrapper.sh`, recreated on boot via `init.sh`.

Result: `nix` works in any exec with no setup.

## Layer 2: Profile Sync

`~/tools/nix-profile-sync.sh` symlinks everything in `~/.nix-profile/bin/` into `/usr/local/bin/`.

- Runs on boot via `init.sh`
- Auto-triggered by the nix wrapper after `nix profile install/remove/upgrade/rollback`
- Skips `nix*` (the wrapper covers those), never clobbers real files

Result: `nix profile install nixpkgs#cowsay` → `cowsay` is immediately on PATH.

## Layer 3: `/bin/bash` Wrapper

`/bin/bash` is replaced with a wrapper script that sets `BASH_ENV=~/tools/omnibin-not-found.sh` and execs `/bin/bash.real` (the original binary).

- `BASH_ENV` is inherited across exec and auto-sourced by non-interactive bash
- Defines `command_not_found_handle` in every exec automatically
- Installed by `~/tools/install-bash-wrapper.sh`, recreated on boot via `init.sh`
- Transparent for all other commands

## Layer 4: `command_not_found_handle` (`@version`)

`~/tools/omnibin-not-found.sh` defines a `command_not_found_handle` that resolves `program@version`:

1. **Nix profile** (fast path) — checks if already installed via `nix profile`
2. **Omnibin index** — queries `nix run github:fzakaria/omnibin#omnibin -- which --all` for the specific version
3. **Nixpkgs fallback** — `nix run nixpkgs#program`

Verified: `jq@1.7.1`, `cowsay@3.8.4` (profile), `cowsay@3.8.3` (omnibin index), `tree@2.1.0` → falls back to 2.3.2 (nixpkgs current).

Note: omnibin's index pin is stale (e.g., max cowsay is 3.8.3, not 3.8.4). The fallback handles this.

## Summary

| What you type | How it resolves |
|---|---|
| `nix ...` | `/usr/local/bin/nix` wrapper → LD_PRELOAD → real binary |
| `cowsay` | `/usr/local/bin/cowsay` → symlink → nix profile |
| `jq@1.7.1` | `command_not_found_handle` → omnibin/nixpkgs → runs |
| `gh` | `/usr/local/bin/gh` → symlink → nix profile (gh 2.101.0) |
