# Muse CLI — Setup Cycle (status: discrepancy to resolve)

## Observed state (verified 2026-10-21, this sandbox)
- `which muse` / `command -v muse` → **not on PATH**.
- `timeout 6 muse --help` → `timeout: failed to run command 'muse': No such file or directory`.
- No `muse` binary in `/usr/local/bin`, `~/tools/bin/`, and `/opt/muse` is the platform's skills/assets directory, not a CLI install. (`/opt/hatch/bin/muse-mail` exists but is a mail tool, not the Muse CLI.)
- Drew's direction when commissioning this doc: "muse cli (I fixed that, try it again)". The re-check above was run *after* that note and still found no binary in this sandbox — so either the fix landed somewhere not on this exec's PATH, applies to a different machine/surface, or hasn't propagated here yet. **This is an open discrepancy, not a conclusion that the CLI doesn't exist.** Next step when picked up: ask where the fixed binary lives (exact path) and re-run the Test section against that path.

## Download / Install
- UNSOURCED: no install path, download source, or version for a Muse CLI is recorded in TOOLS.md or MEMORY. Do not invent one. (What IS documented: Bitwarden holds items named `muse.sdk-token` and `meta.api-key` — names only — which suggests an SDK/API route exists in Drew's fleet, but no CLI wiring for it is recorded here.)

## Gather secrets
- If/when the CLI is located, the candidate credential names in Bitwarden Secrets Manager are `muse.sdk-token` and `meta.api-key` (names only, never values). **Caution from TOOLS.md (Meta Model API):** a Meta API credential was wired into the opencode `meta` provider and authenticated fine (GET /v1/models 200) but inference returned **402 Payment Required** — the Meta Model API is separate pay-as-you-go billing and a Muse subscription does not fund it. Verify which billing a located CLI actually draws on before running up usage.

## Configure
- UNSOURCED / NOT DONE on this sandbox — no config file location is recorded.

## Test (run against the real binary path once known)
```bash
<path-to-muse> --help      # record the actual help output + version here, dated
<path-to-muse> --version   # if supported
```

## Known quirks & what has NOT worked
- The only recorded "what has not worked" is this doc's own finding: as of 2026-10-21 the CLI is not discoverable in the sandbox despite the fix note. Everything else about the Muse CLI in this environment is currently UNSOURCED and must be filled in from a live check, not from assumption.
- Related, for orientation only: in this chat the agent itself runs on Muse Wonder (paid Muse plans run Wonder; free runs Spark — see plans doc, separate file). The Muse CLI, the Muse agent product, and the Meta Model API are three different surfaces that share branding; keep their credentials and billing separate in every future note.
