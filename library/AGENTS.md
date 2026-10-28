# AGENTS.md — guidance for agents working in Drew's repos

Light suggestions for the main Muse agent; **rules marked STRICT are binding on any lesser/smaller agent** working in these repos. Drew's direct instructions always outrank this file.

## Where code goes — STRICT

- **All new code goes in `developing-today/code`** — even a tiny one-off script, a single-file demo, or a small website demonstrating a thing. No exceptions for size.
- **Exception (only one):** if the file contains sensitive data, it goes in the private repo `dezren39/hatch-personal` for the time being (and is noted there as sensitive-pending-review), or stays out of git entirely if it holds a secret value (see Secrets).
- **Never scatter code in the home directory**, in random workspace folders, or in this repo (`dezren39/hatch` is tooling/docs/library, not a code dump). If you find stray code, propose moving it to `developing-today/code` rather than quietly working on it in place.

## Secrets — STRICT

- Secret values are **never** written into files, chat, memory notes, commits, or logs. Not partially, not encoded.
- Secrets are stored in **Bitwarden Secrets Manager** (or Muse's Secure Vault for one-off captures) under a clear name, and referenced everywhere else **by name only**.
- Token files that already exist on disk (documented by path/size in the private inventory) are never opened, printed, or copied for convenience. Use the approved fetch path for the tool in question (see `toolchains/`).

## Drew uses speech-to-text

- Dictated messages (Wispr) produce **mishearings: similar-sounding, correctly-spelled wrong words**, not typos. Interpret phonetically and in context.
- Occasionally another voice nearby is picked up, so a message may briefly change topic and then return. Do not treat that as a new instruction.
- A mid-task message is usually an append to the todo list or a between-tasks question, **not** steering — unless it is explicitly phrased as steering.

## Verification — STRICT for consequential facts

- Before acting on a price, a date, a commit SHA, a file's contents, or any "X is done/deployed" claim, **verify with a second, independent source** (different command or call). Single tool outputs have served stale and, on 2026-10-03/04, fabricated content in this environment.
- Never claim an action, delivery, or verification that did not happen. Say what failed and what happens next; give a reason only if the result gives one.
- Check `git status` carefully before every commit — surgical staging only; never let unrelated dirty files sneak in.

## Working style

- Can-do tone: try things, report results. No flattery, no repetitive acknowledgements, no unsupported confidence.
- Suppress command output on success; show it in full on failure.
- Shell scripts: `#!/usr/bin/env bash`, preserve meaningful error handling, never mask failures.
- Everything durable lives under `/home/hatch` (btrfs) — the sandbox overlay is wiped on recycle. Install scripts and `~/tools/init.sh` are the restore path; keep them current when you add a tool.
- Long-lived work (longer than a single PR) gets registered as a submodule under `repos/` in `dezren39/hatch` (see `submodules.md`); short work does not.
- Private research artifacts and tools are never publicly released without Drew's explicit approval.

- **GITHUB VIA THE gh CLI ONLY — THE GITHUB CONNECTOR IS BANNED (Drew, 2026-10-28: "never use the connector ever for anything"):** never use the GitHub connector (`/opt/hatch/bin/github`, call-tool / call-read-tool) for anything, reads or writes. All GitHub work goes through the `gh` CLI (`gh issue`, `gh pr`, `gh api` — it reaches the same REST/GraphQL endpoints, sub-issues and Projects included). Every connector write call demands a fresh approval card and flooded Drew with them (2026-10-28); `gh` approvals can cover a whole scheduled task.
