# TODO — nix / mcpx / opencode program (Drew's directive 2026-09-30 ~06:25 CDT)

## How this file works (his rules — follow exactly)
- Read it at the START and END of every session. Every time you look at it, ask "what can I add?" — do that first.
- Check off done items with `[x]` + refs: commit hash / PR# / issue# / `file:line`, plus one short line: problem → solution.
- For each completed item: review ALL docs (TOOLS.md, notes/architecture/*, this file) and fix what you can.
- Push regularly. Work on branches / chained PRs ahead of main; merge only after review. NEVER force-push main. `git pull --rebase` before pushing to avoid conflicts.
- If push is denied anywhere: stay on the local branch, keep moving, add a `REMIND DREW` line.

## 0. B/C/D — DONE 2026-09-30 ~06:31 CDT, commit `b2af047` (origin/main) — phase 2 cleared
- [x] B: nixbld traverse grant + `build-users-group = nixbld` restored — `b2af047` — problem: nixbld users couldn't traverse /home/hatch (drwxrws---) so builds ran as root; solution: traverse-only (`--x`) ACLs via python3 ctypes on /home/hatch, nix-persist, ~/tools, taint-shim; probe derivation verified builder ran as nixbld1 (uid 999)
- [x] C: bootstrap merged into single user profile — `b2af047` — problem: two profiles (bootstrap nix 2.34.8 + default); solution: nix itself installed via flake into /nix/var/nix/profiles/per-user/root/profile (now nix 2.35.2), bootstrap deleted, wrapper repointed with self-heal (heal adds newest store nix with real bin/nix, never remove-before-add — `profile remove`+`add` quirk found and fixed)
- [x] D: omnibin as flake input with follows — `b2af047` — problem: dispatcher used github: URL + floating nixpkgs caused 46 source builds; solution: ~/tools/dispatcher/omnibin/flake.nix (omnibin input @459dcff6, nixpkgs follows theirs @4975466d32), dispatcher uses local flake; also fixed latent `nix store realise` → `nix build --no-link` bug
- [x] Pushed `b2af047` to origin/main (verified on remote)

## 1. Real store — DONE 2026-09-30 (refined: no `real` setting in 2.35.2; shim SLIMMED, not dropped)
- [x] `real` store-dir setting does NOT exist in nix 2.35.2 ("unknown setting 'real'") — phase-1 research claim corrected; no nix.conf change needed (allow-symlinked-store=true + build-users-group=nixbld already ensured by nix-ensure.sh:38-42, recycle path covered)
- [x] Slimmed taint-shim: full symlink-bit spoofing REMOVED, replaced with mode mask (0777→0755) on /nix; xattr/chown handling kept — tools/taint-shim/taint_shim.c (rebuilt .so; README.md updated)
- [x] Verified on 2.35.2 with slim shim: `nix eval` ✓; genuine local build as nixbld1 (uid 999) ✓; dispatcher resolution ✓; `nix store gc` (1250 paths, 1.1 GiB freed) ✓; `nix store add-file` ✓; `nix profile list` ✓; `nix flake metadata` + `flake update` ✓
- [x] Why the shim can't go entirely: (1) sandbox denies removexattr on user.hatch_tainted* even for root → EPERM registering .drv without xattr handling; (2) build sandbox checkNotWorldWritable (nix 2.35.2 derivation-builder.cc:356, called at :389 for build-user builds) rejects S_IWOTH ancestors → needs the mode mask
- [x] Pre-existing limitation (identical under old full shim — NOT a regression): fresh tarball-flake fetch fails "(or its ancestor) is a symlink" — kernel-level O_NOFOLLOW in openFileEnsureBeneathNoSymlinks, not bypassable via stat
- [x] Docs updated: TOOLS.md, MEMORY.md, tools/taint-shim/README.md, taint_shim.c header note

## 2. developing-today/code — NixOS config review (READ-ONLY on their repo)
- [x] Clone `developing-today/code` (Drew typed "develioing-today" — find the real name) — research 2026-09-30: real repo is developing-today/code, cloned read-only to /tmp/dt-code
- [x] Read the config in full depth; list candidate settings/programs/features worth stealing (do NOT copy the whole structure) — research 2026-09-30: notes/architecture/nixos-config-review.md — top steals: nixConfig block → our nix.conf (ca-derivations, fetch-closure), nix-output-monitor + nh + linters, standalone home-manager, git-absorb/atuin/kondo/topgrade, timeout-guarded oneshot + tmpfiles patterns
- [x] Incorporate the good bits — done 2026-09-30, via nix-ensure.sh → /etc/nix/nix.conf (applied, verified live with `nix show-config`):
  - `keep-outputs = true` / `keep-derivations = true` — why: protects dispatcher-resolved binaries and .drvs from `nix store gc` (we gc'd 1.1 GiB today; these keep the working set alive)
  - `fallback = true` — why: if a binary fetch fails, build from source instead of erroring (resilience for the dispatcher)
  - `http-connections = 50` — why: Drew uses 100; 50 is safer for our bandwidth while still parallelizing fetches
  - `allow-dirty = true` — why: our wrapper flake lives in a dirty git tree; dirty flakes otherwise refuse to evaluate
  - NOT taken (recorded why): `ca-derivations`/`fetch-closure` — experimental, changes derivation hashing; risk to dispatcher/omnibin flows, revisit later; `auto-optimise-store` — Drew deliberately keeps false, we keep default; `use-xdg-base-directories` — would move ~/.nix-profile etc., our tooling assumes current paths
- [ ] Tools from the review (nix-output-monitor, nh, nixfmt, statix, deadnix, nvd) — install via `nix profile` (pending; avoiding profile-lock contention with mcpx/opencode installs)

## 3. dezren39/nix + mcpx
- [x] Clone; map the flake: mcpx package/module, how to import it as a flake input — research 2026-09-30 (/tmp/dn-nix): `inputs.dezren39-nix.url="github:dezren39/nix"` → `packages.x86_64-linux.mcpx` (flake.nix:385,424; also apps at :494); NO nixosModules output — package only, no module to import
- [x] Understand the lootbin host's MCP config — write the parity target list — research 2026-09-30: "lootbin" appears NOWHERE in dezren39/nix, dezren39/hatch, or GH code search for dezren39; only MCP host is **lootbox** (Drew's Mac, launchd agent configuration.nix:718-755, servers in lootbox.config.json). mcpx = Go daemon (unix socket + HTTP, JSON config, ${VAR} secrets, auto-spawn) — full findings in notes/architecture/mcpx-opencode-plan.md
- [ ] Confirm with Drew: "lootbin" = lootbox? Parity = mcpx-with-similar-servers, or also port lootbox-the-app?
- [ ] Import mcpx into our flake from dezren39/nix; configure it here — IN PROGRESS 2026-09-30: delegate adding `dezren39-nix` input to ~/tools/dispatcher/omnibin/flake.nix (recursiveUpdate merge) + `nix profile install`; minimal config at ~/.config/mcpx/config.json (empty mcpServers, valid JSON) pending Drew's lootbin answer
- [ ] Write the feedback file; push to dezren39/nix (branch/PR)
- [ ] Anything broken → GitHub issue → fix → PR; chain PRs indefinitely ahead of main

## 4. opencode + mcpx daemon
- [ ] Install opencode; smoke-test free models (if interactive auth needed: record + move on, REMIND DREW) — IN PROGRESS 2026-09-30: delegate running `nix profile install nixpkgs#opencode`
- [ ] Install mcpx opencode plugin; verify opencode can use mcpx tools — IN PROGRESS 2026-09-30: delegate copying plugin from dezren39/nix to ~/.config/opencode/
- [x] mcpx systemd service file written: ~/tools/mcpx.service (canonical source) — runs as root with HOME=/home/hatch, /usr/local/bin/mcpx daemon, restart-on-failure
- [x] init.sh hook: ~/tools/install-mcpx-service.sh (copies unit to /etc, daemon-reload, enable --now; skips gracefully if mcpx not installed) — wired into init.sh via run_step "mcpx-service" after nix-profile-sync
- [ ] Verify: run hook → `systemctl is-active mcpx` must be active (blocked on mcpx install)
- [ ] Push the service file back to dezren39/nix; fix if broken

## 5. Docs & demo
- [x] notes/architecture/dispatcher-vs-omnibin-run.md — how our dispatcher differs from omnibin's `nix run` (file written 2026-09-30; UNPUSHED — B/C/D coordinator has uncommitted tree changes, will push after their tree is clean/committed)
- [ ] Demo script for Drew's check-in (4+ hrs): the exact commands to show it all working

## 6. Routine (standing)
- [x] 15-min check cron active (`nix-mcpx-15min-check`, 2026-09-30) — carries these rules; drives work, pushes, fixes docs
- [ ] Cron verified firing and updating this file
- Phase-1 status (2026-09-30 ~06:45): COMPLETE. Research done (NixOS review → nixos-config-review.md; mcpx/lootbox map → mcpx-opencode-plan.md). Drafts: mcpx systemd unit + init.sh hook + opencode plan (in mcpx-opencode-plan.md). Dispatcher doc written. B/C/D landed as b2af047 (observed via TOOLS.md + git log). All phase-1 files committed/pushed. Awaiting: parent's explicit phase-2 signal; Drew's lootbin-vs-lootbox answer.

## Awareness (not this program's work — keep an eye, don't own)
- WI annual report DEVELOPING.TODAY LLC due TODAY 2026-09-30 — filing retry cron 07:12 CDT; needs Drew if blocked
- Marketplace deal-hunt sweeps every 4h — silent unless a real deal appears
