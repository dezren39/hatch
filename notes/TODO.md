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

## 1. Real store — is it the right way? (judgment: yes, via nix's `real` setting)
- [ ] Test: `allow-symlinked-store = true` + `real = /home/hatch/nix-persist`; drop LD_PRELOAD shim from nix invocations; verify `nix eval`, a real build, dispatcher resolution, `nix store gc`, recycle path via init.sh
- [ ] If verified: shim becomes legacy fallback; docs updated. If not: keep shim, record why (`file:line`)

## 2. developing-today/code — NixOS config review (READ-ONLY on their repo)
- [x] Clone `developing-today/code` (Drew typed "develioing-today" — find the real name) — research 2026-09-30: real repo is developing-today/code, cloned read-only to /tmp/dt-code
- [x] Read the config in full depth; list candidate settings/programs/features worth stealing (do NOT copy the whole structure) — research 2026-09-30: notes/architecture/nixos-config-review.md — top steals: nixConfig block → our nix.conf (ca-derivations, fetch-closure), nix-output-monitor + nh + linters, standalone home-manager, git-absorb/atuin/kondo/topgrade, timeout-guarded oneshot + tmpfiles patterns
- [ ] Incorporate the good bits; record each with why — notes/architecture/nixos-config-review.md (phase 2)

## 3. dezren39/nix + mcpx
- [x] Clone; map the flake: mcpx package/module, how to import it as a flake input — research 2026-09-30 (/tmp/dn-nix): `inputs.dezren39-nix.url="github:dezren39/nix"` → `packages.x86_64-linux.mcpx` (flake.nix:385,424; also apps at :494); NO nixosModules output — package only, no module to import
- [x] Understand the lootbin host's MCP config — write the parity target list — research 2026-09-30: "lootbin" appears NOWHERE in dezren39/nix, dezren39/hatch, or GH code search for dezren39; only MCP host is **lootbox** (Drew's Mac, launchd agent configuration.nix:718-755, servers in lootbox.config.json). mcpx = Go daemon (unix socket + HTTP, JSON config, ${VAR} secrets, auto-spawn) — full findings in notes/architecture/mcpx-opencode-plan.md
- [ ] Confirm with Drew: "lootbin" = lootbox? Parity = mcpx-with-similar-servers, or also port lootbox-the-app?
- [ ] Import mcpx into our flake from dezren39/nix; configure it here
- [ ] Write the feedback file; push to dezren39/nix (branch/PR)
- [ ] Anything broken → GitHub issue → fix → PR; chain PRs indefinitely ahead of main

## 4. opencode + mcpx daemon
- [ ] Install opencode; smoke-test free models (if interactive auth needed: record + move on, REMIND DREW)
- [ ] Install mcpx opencode plugin; verify opencode can use mcpx tools
- [ ] mcpx daemon as systemd service; launched from init (init.sh writes unit + `daemon-reload` + `enable --now` every boot — /etc is ephemeral)
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
