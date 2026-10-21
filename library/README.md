# Library

Drew's working library: the documents that describe how this whole setup is built, what it costs, what hardware it runs on, and how Drew and Muse work together. Assembled 2026-10-21. Anything non-sensitive about the designs, plans, and ongoing work belongs here (public) or in the private counterpart at `dezren39/hatch-personal` → `library/` (sensitive material, full inventory, and the Turso plan until its ~Dec 2026 review).

## Sections

- **[AGENTS.md](AGENTS.md)** — guidance for any agent working in these repos: where code goes (`developing-today/code`, always), secret rules, speech-to-text quirks, verification rules.
- **[how-we-work.md](how-we-work.md)** — how Drew and Muse work together: roles, communication rules, what has worked, and what hasn't (with dates).
- **[toolchains/](toolchains/index.md)** — one doc per tool, each following the same cycle: Download → Install → Gather secrets → Configure → Test → Known quirks. Covers Nix (and the weird symlinked-store setup), git/gh, Bitwarden `bws`, Cloudflare (`cf` first, Wrangler configured as fallback), 1Password `op`, Bun, uv, Go, Rust, Tailscale, Chromium/Playwright and the real-browser rules, and the Muse CLI.
- **[plans/ai-plans.md](plans/ai-plans.md)** — every AI plan Drew holds: plan chosen, cost/month, quota, % used, reset dates and early resets, expirations, estimated API-equivalent value, estimated standard AA tasks per plan, and for each model: relative release dates, context window, in/out/cache pricing, scheduled deprecations, and short-term/beta OpenCode models.
- **[plans/hardware.md](plans/hardware.md)** — the full hardware register: servers, NICs, switches, RAM, drives, the basement Threadripper fleet, relative prices, and the cluster plan they feed.
- **[inventory-summary.md](inventory-summary.md)** — redacted public summary of the 2026-10-21 full-disk inventory: headline numbers, size totals per sensitivity class, biggest skipped items, method. The full inventory, symlink restore map, and classification table live in the private repo.
- **[submodules.md](submodules.md)** — the submodule registry pattern: core repos are registered as gitlinks under `repos/` in this repo and materialized on demand by `scripts/link-submodules.sh`.

Private counterpart (`dezren39/hatch-personal` → `library/`): `plans/turso-plan-v0.1.md` (versioned; private until review ~Dec 2026), `inventory/` (full inventory, symlink map, classification, unredacted summary), and the GitHub repo census (lands there first).

## Related repos and future links

Not everything lives here. This list is the map of repos that are — or may become — related, so nothing has to be rediscovered later.

### Core repos (registered as submodules under `repos/`, see submodules.md)

- `dezren39/nix` — the Nix program / flake work.
- `developing-today/code` — **the** code repo. All new code lands here (see AGENTS.md).
- `developing-today/opencode` — OpenCode fork/work.
- `developing-today/openchamber` — OpenChamber fork/work.
- `developing-today/nix-cache` — Nix binary cache on Cloudflare (Worker + R2 + KV + D1).

### Zettel (notes) repos

- `dezren39/zettel` — public, → zettel.drewrypope.com.
- `developing-today/zettel` — public, → zettel.developing-today.com.
- A private `dezren39` zettel also exists and is literally blank (GitHub's free-org public/private Pages rules are why the split looks like this). There is no private developing-today zettel.

### Profile repos

- `dezren39/dezren39` — personal GitHub profile repo.
- `developing-today/developing-today` — org profile repo.

### Planned / tentative (not yet created)

- `developing-today/forks` — planned home for forks (OpenCode, OpenChamber, …) so forks stop living in the main org/personal namespaces.
- `developing-today-archive` (tentative name) — planned home for clean clones with no changes of our own, so upstream mirrors are distinguishable from forks and original work.
- A public "chunk drawer" repo and a private "chunk drawer" repo (tentative) — for small files that are useless on their own (job start/stop metrics and other low-signal records) but worth keeping, with a note in each explaining exactly where it came from and where it goes back.
- **Zulip archive (open consideration, not built):** an open-source Zulip instance as an archive for all messages Drew receives, and possibly as a basic agent-communications platform. Mentioned here so the idea isn't lost; no decision made.
- **Google Drive "Muse Backups" folder** — dedicated Drive folder for Muse backups that don't belong in git at all (e.g. tarballs of session logs / `~/agents/`, ~1 GB and growing).
