# Chromium / Real Browser + Playwright — Rules and Setup Status

## What actually exists here (verified 2026-10-21)
- **The real browser is a platform-managed Chromium**, driven through the Muse browser tools — it is *not* a binary in this sandbox. Checks on 2026-10-21 found: no `chromium` / `chromium-browser` / `google-chrome` on PATH, nothing in `/usr/bin`, no `~/.cache/ms-playwright`, and **no Python `playwright` module installed** (`ModuleNotFoundError`). So: browser work = the managed browser; Playwright = **not installed locally** as of this check. Any future Playwright setup must start from an install step and be re-verified — do not assume the Python/Node Playwright from other machines exists here.
- Browser windows: each browser task is a window with tabs; every window shares the default browser profile, so one sign-in serves every chat and scheduled job unless a window was opened in a named profile for another account. The user can watch and take over a live session; agent and user never drive it at the same time.


## Install targets — Drew's decision, 2026-10-21
- Chromium and Playwright **should be installed** on this machine as part of the toolchain set, so they are available if local browser automation is ever needed — but they are **optional, not a requirement**, and nothing depends on them (all current browser work goes through the platform-managed browser above).
- Expected mode if installed: **headless only**.
- Status: not installed, **not tested, and deliberately not investigated yet** (Drew, 2026-10-21: "we don't need to test that right now or put much thought into it"). When someone does install them, land browsers on persistent disk (`~/`) and add a dated verification entry to this doc.

## Download / Install (Playwright, if ever needed)
- UNSOURCED / NOT DONE: no Playwright install has been performed or recorded on this sandbox. A future install would need to land browsers on persistent disk (`~/`), not `/tmp` or the overlay, and would need its own verification entry here before use.

## Gather secrets
- **Never put a password in a browser assignment, chat, file, or memory.** Passwords reach the browser only through the Secure Vault / secure capture flow. A one-time code the user provides goes to the browser task as a protected reference (`verification_code`); the user approves sharing it on a card before the browser receives it.
- Browser profiles are separate from the user's devices and from connected accounts — a connector login does NOT sign the browser into that website.

## Rules: what the real browser can and can't do (sourced)
- CAN: navigate, sign in (via the workflows above), fill forms, click through multi-step flows, make purchases (with the product's own approval/checkout rules), solve CAPTCHAs and bot checks without asking the user while it works. A text fetch failing does NOT establish that the live browser is blocked or that a site requires login.
- CAN: the user may take over the live browser to get past a bot check/site block on a task they started in conversation; the task continues after they hand control back. Scheduled/proactive tasks never offer takeover.
- **CANNOT / blocked: Meta auth URLs.** From MEMORY (Drew's account-connection campaign notes, 2026-10-20): Muse OAuth-related flows note that "Muse's browser can't reach those DNS" for the Meta auth path, and Drew helps with those logins himself. Related, also from MEMORY: some financial institutions (additional Plaid institutions beyond Citi) are done in **Drew's own browser only — Muse's browser is policy-blocked** for them.
- CANNOT: the agent cannot change browser permissions (Settings > Connectors > Browser: visiting, form/POST submission, downloads, uploads, saved credentials — each Allow/Ask/Deny; uploads are Ask/Deny only).
- Purchases: one checkout per window; report an order complete only from verified merchant evidence; an unknown outcome must be reconciled before any retry.

## Test
- Liveness of the managed browser is tested by opening a browser task window — there is no local binary to `--version`. Local Playwright test (currently expected to FAIL until installed):
  ```bash
  python3 -c "import playwright"   # 2026-10-21 result: ModuleNotFoundError — Playwright not installed locally
  ```

## Known quirks & what has NOT worked
- Cloudflare-fronted sites 403 non-browser User-Agents (error 1010) for script fetches — that is a *fetch* limitation, not a browser limitation; the real browser with a real UA is the workaround, and a failed text fetch must never be reported as "the site blocks the browser".
- Anything about specific sites beyond the Meta-auth and Plaid cases above that is not in TOOLS.md/MEMORY/the browser doc is **UNSOURCED** — record it here with a date the first time it's actually observed, rather than generalising from one failure.
