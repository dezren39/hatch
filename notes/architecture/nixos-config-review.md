# developing-today/code — NixOS config review (2026-09-30)

Drew's everything-monorepo; the NixOS config is one slice. Reviewed read-only
(clone at /tmp/dt-code, nothing modified). This file: the portable good bits
worth stealing. His architecture (flake host-composition, NixOS modules, disko,
impermanence) stays behind — see "Not portable" at the end.

Repo shape in brief: `flake.nix` (427 lines, ~45 inputs, `nixConfig` block that
doubles as system nix.conf) → `nixos/hosts/default.nix` (2 Framework 13 hosts,
`nixos` Intel / `amd` AMD, composed from per-concern modules in `nixos/`) →
`home/` (home-manager tree, `home/common/default.nix` = 1133 lines of programs
+ packages). `machines/user/configuration.nix` is a clan template, not real config.

## nix.conf candidates — highest value, directly portable

His flake `nixConfig` IS the system nix.conf (`nixos/nix/settings/default.nix:3`
sets `nix.settings = inputs.self.nixConfig`). Steal the "define once, reuse"
pattern: keep our nix.conf settings in one place (nix-ensure.sh already does
this — extend it).

- `substituters`/`trusted-substituters`/`trusted-public-keys` (`flake.nix:342-378`):
  cache.nixos.org + cachix with pinned keys. Template for our cache setup; we
  already do omnibin's cachix — adopt the full key-pinned pattern.
- `experimental-features` (`flake.nix:317-334`): nix-command, flakes,
  **ca-derivations**, **fetch-closure**, recursive-nix, auto-allocate-uids,
  git-hashing. ca-derivations + fetch-closure are directly relevant to our
  real-store (`real` setting) exploration.
- `accept-flake-config = true` (`flake.nix:385`): lets flake-pinned caches
  (like omnibin's) self-configure.
- `keep-outputs` / `keep-derivations = true` (`flake.nix:383-384`): keep build
  outputs around — matches our heavy nix experimentation.
- `http-connections = 100`, `max-substitution-jobs = 64` (`flake.nix:380-381`):
  4× default fetch parallelism for bulk fetches.
- `fallback = true` (`flake.nix:388`): build from source if a substitute fails —
  reliability for flaky caches.
- `tarball-ttl = 259200` (`flake.nix:395`): 72h flake-input cache TTL, fewer
  redundant re-fetches.
- `use-xdg-base-directories = true` (`flake.nix:338`): XDG paths for nix state.
- `allow-dirty = true` (`flake.nix:399`): dirty git trees in flakes — matches
  our fast-iteration style.
- `log-lines = 128`, `show-trace`, `trace-verbose` (`flake.nix:389-397`):
  verbose build logs for debugging.
- Input hygiene (`flake.nix:102`, comment: "channel branch: fully cached on
  cache.nixos.org (master is not)"): pin `nixos-unstable` branch refs, not
  master — directly relevant to our `nixpkgs#` fetches.
- Cautionary: `auto-optimise-store = false` **deliberately** (`flake.nix:408-415`):
  on ext4 without `large_dir`, `/nix/store/.links` hits the htree limit (~8.7M
  entries) → ENOSPC despite free space. Our /home/hatch is btrfs so likely
  fine, but don't blindly enable auto-optimise — check dedup costs first.

## CLI tools worth installing (all in nixpkgs)

- **`nix-output-monitor`** (`nixos/environment/default.nix:197`) — `nom`: human
  nix build progress. Best QoL win; we run lots of builds.
- **`nh`** (same file, nix-tools block ~740) — `nh search`, generation cleanup,
  profile management. Fits our profile workflow.
- **`nix-tree`, `nix-du`, `nix-melt`, `nvd`** — store inspection; `nvd` diffs
  generations ("what changed") for our profile/snapshot workflow.
- **`nixfmt`, `statix`, `deadnix`** (`home/common/default.nix:935,1026`) —
  formatter + linters. We now write nix (dispatcher flake, scripts) — add to a
  pre-commit/treefmt.
- **`sops` + `age` + `ssh-to-age`** (`home/common/default.nix:1019`,
  `nixos/environment/default.nix:198`) — encrypt secrets in git. Pattern for
  repo-level secrets (complements the Secure Vault, doesn't replace it).
- **`atuin`** (`home/common/default.nix:727`) — shell history sync/search
  across sessions. Our execs are ephemeral shells — genuinely useful.
- **`any-nix-shell`** (`home/common/default.nix:725`) — `nix shell`/`nix develop`
  prompt integration, removes papercuts.
- **`git-absorb`** (`home/common/default.nix:825`) — folds staged changes into
  the right commit as fixups. Fits our commit-often hygiene.
- **`kondo`** (`home/common/default.nix:880`) — reclaims `target/`,
  `node_modules/`, etc. Our 100GB vdd will thank us.
- **`topgrade`** (`home/common/default.nix:1051`) — upgrades everything
  (nix profile, cargo, npm…) in one shot.
- **`tealdeer`** (`home/common/default.nix:416`) — tldr client.
- **`magic-wormhole`** (~772) — PAKE file transfer, no server. Moving files to
  Drew's laptop.
- **`fclones`** (`home/common/default.nix:806`) — duplicate finder, btrfs-aware
  reflink dedup — relevant to our btrfs home.
- **`trippy`** (`home/common/default.nix:1057`) — traceroute TUI with TCP mode
  (ICMP is blocked in our sandbox — same constraint as their env).
- **`tmuxPlugins.resurrect` + `continuum`** (`home/common/default.nix:1046-1047`) —
  tmux auto-save/restore across restarts. Complements our PID-file
  persistent-process pattern.
- **`direnv` with path whitelist** (`home/common/default.nix:245-259`) — steal
  the pattern: whitelist our agent workdirs so direnv never prompts.
- **`cachix` CLI** (`home/common/default.nix:757`) — manage binary caches.
- **`xcp`** (`home/common/default.nix:1083`) — cp with progress (large nix tarballs).
- **`hexyl`, `jless`, `jql`, `tidy-viewer`, `fselect`** — data inspection kit.
- **`pay-respects`** (`home/common/default.nix:1040`) — command correction.
- **`lemmeknow`** (`home/common/default.nix:887`) — identifies hashes/secrets in
  pasted text. Cheap security win.
- **`tmate`** (`home/common/default.nix:422`) — instant terminal sharing for
  pairing with Drew.

## Shell / program patterns

- **Standalone home-manager** (`nixos/environment/default.nix`, "App and package
  management" block): installed as a regular package — works on Ubuntu without
  NixOS. The big structural steal: declarative dotfiles/shell for our env.
- **`git config safe.directory = ["*"]`** (`nixos/programs/default.nix:8-12`):
  kills "dubious ownership" errors in agent-owned repos. We hit these.
- Aliases as config: `ls`→`exa`, `cat`→`bat`; git `ci`/`co`/`s`,
  `push.autoSetupRemote = true` (`home/common/default.nix:503-506,330-345`).
- **opencode setup**: their own opencode fork + `oh-my-pi` OMP harness
  (`nixos/environment/default.nix:202-204`), `developing-today/opencode-auto-continue`
  plugin, `.opencode/*.jsonc` with **notification sounds** — audio cues for
  agent events, relevant to Drew's voice-first preference.

## systemd patterns (portable — systemd works here)

- **Oneshot with boot-safety guards** (`nixos/abstract/tailscale-autoconnect/default.nix:60-110`):
  `after`/`wants` on `network-pre.target`, `Type=oneshot`, every network call
  wrapped in `timeout 10` "to avoid hanging the boot process". Copy this pattern
  for our init.sh-managed units (including the mcpx unit).
- **`systemd.tmpfiles.rules`** (`nixos/systemd/user/default.nix`) — portable via
  `/etc/tmpfiles.d/` on Ubuntu; cleaner than mkdir chains in init scripts.
- SSH posture values (`nixos/services/default.nix:43-49`): `PermitRootLogin no`,
  `PasswordAuthentication false` — portable values even though the module isn't.

## Explicitly NOT portable — don't chase

- The NixOS module/option system entirely: host-composition abstraction, disko,
  impermanence, `boot.loader`, `hardware-configuration`, `networking.*`/`firewall`,
  `services.*` modules, NixOS `systemd.services` syntax (patterns above are
  portable, the syntax isn't).
- `nix-ld` — fixes non-Nix binaries on NixOS; we run Ubuntu, no such problem.
- home-manager/sops-nix **as NixOS modules** — the standalone CLIs are the
  portable parts.
- clan-core, microvm.nix, fleet provisioning — single container, irrelevant.
- Desktop stack (hyprland etc.), ESP-IDF/SDR/FPGA/K8s package bulk —
  domain-specific to his hardware work.
- Wireless/sops secrets, Tailscale fleet config — his personal infra, not ours.

## Incorporation priority (for phase 2, TODO §2 item 3)

1. nixConfig block → our nix.conf (nix-ensure.sh), incl. ca-derivations/fetch-closure.
2. `nix-output-monitor` + `nh` + nix linters via `nix profile install`.
3. Standalone home-manager for dotfiles/shell.
4. `git-absorb`, `atuin`, `kondo`, `topgrade`, `tealdeer`.
5. `safe.directory=*`, alias set, direnv whitelist pattern.
6. timeout-guarded oneshot + tmpfiles patterns for our units.
