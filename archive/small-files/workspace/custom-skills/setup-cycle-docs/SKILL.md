# setup-cycle-docs

Status: tentative, first draft 2026-10-21.

## Purpose

Write/maintain one doc per tool following the same setup cycle, so any tool can be rebuilt from scratch on a fresh sandbox by a lesser agent following the doc literally. Canonical examples: `dezren39/hatch` → `library/toolchains/*.md`.

## The cycle (every doc, same order)

1. **Download** — exact source (release URL pattern, flake, npm prefix) and version observed, with the date verified.
2. **Install** — persistent location under `~/` (`~/tools/...`); ephemeral locations (`/usr/local/bin`, apt) only via an `init.sh`-restored wrapper/install script. Note disk/build quirks (e.g. Go needs `TMPDIR` off the 512M `/tmp` tmpfs).
3. **Gather secrets** — by Bitwarden/Secure Vault item **name only**, never a value. State the exact fetch path (e.g. `source ~/tools/bws-env.sh`) and file permissions (600, dir 700).
4. **Configure** — config file paths, the env vars a systemd service needs bridged in (services inherit none of the session env), and proxy rules: never bake the rotating per-session proxy credential into files; services use the unauthenticated in-sandbox proxy form.
5. **Test** — the exact command and expected output that prove the tool works (version string + one real operation).
6. **Known quirks & what has NOT worked** — dated failures and their workarounds. This section is the point of the doc; do not skip it when "nothing went wrong" — check memory/TOOLS.md first.

## Rules

- Verify versions live (`<tool> --version`) at write time; stamp the doc with the verification date.
- A doc that was not tested end-to-end says so in its header (Draft / not yet clean-room verified), like the Turso plan v0.1.
- Public-safe by default: if a step genuinely needs sensitive context, the doc says "details in private repo" and stops.
