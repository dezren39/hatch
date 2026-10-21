# Submodule registry

Registered 2026-10-21. Core repos are recorded as **gitlinks under `repos/`** in this repo (`dezren39/hatch`) — a registry, not checked-out working trees. No content was cloned to register them; each gitlink is just the HEAD SHA of the repo's default branch at registration time, verified with `gh repo view` / `gh api` before recording.

## Registered

| path | repo | pinned at (2026-10-21) | usual working location |
|---|---|---|---|
| `repos/nix` | `dezren39/nix` | `83de89d` | `~/git/nix` |
| `repos/code` | `developing-today/code` | `5897cdc` | `~/git/devtoday-code` |
| `repos/opencode` | `developing-today/opencode` | `241d4ef` | `~/git/devtoday-opencode` |
| `repos/openchamber` | `developing-today/openchamber` | `4d4aa0d` | `~/git/devtoday-openchamber` |
| `repos/zettel-dezren39` | `dezren39/zettel` | `82683ed` | — |
| `repos/zettel-developing-today` | `developing-today/zettel` | `a004698` | — |
| `repos/dezren39` | `dezren39/dezren39` | `9b9489a` | — |

## Not registered

- **`developing-today/developing-today`** (org profile repo): the repo exists (created 2023-04-16) but is **empty — no commits** — so there is no HEAD SHA to pin. Register it the same way after its first commit lands. The other seven candidates all existed and were pinnable.

## The pattern

1. **Submodules are the registry.** A gitlink + `.gitmodules` entry here says "this repo is part of the program, at this known-good commit." That is all it says. Disk and time are not spent cloning content that already lives in its own working clone.
2. **Materialize on demand:** `scripts/link-submodules.sh <name> …` (repo root) shallow-clones that one submodule in place under `repos/` and symlinks it to its usual working location if a mapping exists in the script's table (`nix`, `code`, `opencode`, `openchamber` above; the zettel/profile repos have no standard working location and are left in place). If the working location already exists as a real clone, the script leaves it alone.
3. **What earns a submodule:** work that stays open longer than a single PR — core repos and long-lived efforts (e.g. hardcore reboot/restore tooling) get committed as submodules and then ignored day-to-day. Short work (one PR) does not get registered; just clone it where you need it and delete it after.
4. **Updating a pin** is a deliberate act: materialize, move to the new HEAD, commit the gitlink change here with a message saying why. Pins drifting silently is the failure mode this pattern exists to prevent.

The private repo (`dezren39/hatch-personal`) follows the same pattern for private-only repos (e.g. the CANTO repo and the private, blank `dezren39` zettel) — those gitlinks live there, never here.
