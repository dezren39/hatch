# TOOLS.d/secrets.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

## Bitwarden Secrets Manager CLI (bws 2.1.0, set up 2026-10-07)
- Binary: `~/tools/bin/bws` (on PATH). Installed from
  `github.com/bitwarden/sdk-sm` release `bws-v2.1.0`
  (`bws-x86_64-unknown-linux-gnu-2.1.0.zip`).
- Token lives in `~/.config/bitwarden/access-token` (600, dir 700).
  Optional EU vault override in `~/.config/bitwarden/server-url`.
- `source ~/tools/bws-env.sh` → exports `BWS_ACCESS_TOKEN` (never prints it).
- `echo "$TOKEN" | ~/tools/bws-receive-token.sh` → stores token from stdin
  (keeps it out of argv/process list/history), chmod 600, then verifies with
  `bws secret list`.
- Token format: `0.<org>.<env>.<client_id>:<client_secret>` — shown ONCE at
  creation in the web vault (Secrets Manager → machine account → access tokens).
- `bws secret create` has NO stdin/file input: `create KEY - PROJECT` stores the
  literal string `"-"`. Pass values via `"$(cat file)"` — the literal command
  text (kept in the exec harness's environ) then contains only the path, never
  the value; it appears only transiently in the bws child's argv. Full pattern
  and verification live in `~/tools/bws-backup-secrets.sh`.
- bws gotchas (hit 2026-10-07): `secret get <id> -o json` returns an object
  for one id but the shape has varied — normalize with
  `jq 'if type=="array" then .[0].value else .value end'`; `jq -r` appends a
  trailing newline, so use `jq -j` when hashing values for comparison;
  values starting with `-` (e.g. `-----BEGIN OPENSSH PRIVATE KEY-----`) are
  parsed as flags — put options first, then `--`, then positionals
  (`bws secret create --note ... -o none -- KEY VALUE PROJECT`), otherwise
  clap errors AND echoes the value in the error message.
- 2026-10-07: backed up all on-disk secrets into project "developing today"
  (`d370cd10-…`): `nix-cache.upload-secret`, `nix-cache.signing-key`,
  `cachix.cachix-dhall`, `github-cli.hosts-yml`, `ssh.id-ed25519` — each
  round-trip sha256-verified. The Cloudflare Worker secret UPLOAD_SECRET
  (nix-cache worker) holds the same value as `nix-cache.upload-secret`.
  The bws access token itself is deliberately NOT stored there.
- 2026-10-07 ~03:30 CDT: Drew supplied the account-wide API token + R2 S3
  creds. Stored in Bitwarden: `cloudflare.api-token-account-wide` (NEVER put
  in Worker secrets/env — mint scoped tokens from it), `cloudflare.r2-access-key-id`,
  `cloudflare.r2-secret-access-key`, `cloudflare.r2-endpoint`. NOTE 2026-10-07:
  those pasted R2 creds are BROAD admin (token "weathered-breeze-ead0" carries
  ~every permission group — "came from the global key"); kept in Bitwarden as
  Drew's admin copy (renoted, NOT used by the worker). The worker uses a
  DEDICATED bucket-scoped pair minted 2026-10-07: `cloudflare.r2-worker-api-token`
  (raw token value), `cloudflare.r2-worker-access-key-id`,
  `cloudflare.r2-worker-secret-access-key` (Object Read+Write on nix-cache-nars
  only; S3 Access Key ID = token id, Secret Access Key = SHA-256(token value)).
  Created via POST /accounts/{id}/tokens with resource
  `com.cloudflare.edge.r2.bucket.<acct>_default_nix-cache-nars` and permission
  groups Workers R2 Storage Bucket Item Read
  (6a018a9f2fc74eb6b293b0c548f38b39) + Write
  (2efd5506f9c8494dacb1fa10a3e7d5b6). Worker secrets
  `R2_ACCOUNT_ID`/`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY` set on the
  nix-cache worker from those values. `UPLOAD_SECRET` ROTATED (old worker
  value was unrecoverable — the local file had diverged); new value consistent
  across Worker secret, `~/.config/nix-cache/upload-secret`, Bitwarden.
  Presign flow verified end-to-end: presign 200 → signed R2 URL → PUT 200
  (one 13-byte probe object left in the bucket; DELETE via hand-rolled SigV4
  kept failing — use a real S3 client for cleanup if it matters).
- Day-to-day token `cloudflare.api-token-day-to-day` (minted 2026-10-07, id
  26b92e8c…): Workers Scripts/KV/R2/D1/Queues read+write + Workers Tail read,
  scoped to account 234b866b… only. Use for routine wrangler/API work.
  - **2026-10-23 (Drew: "update your key … using your root key"):** added two
    permission groups via the account-wide token — `Analytics Read`
    (zone-scoped to security.cab d9632853…) and `Workers Containers Read`
    (account scope). Verified live: containers list now 200 (was 403), and
    zone analytics returns real data via the **GraphQL** API. NOTE: the
    legacy REST `/zones/{id}/analytics/dashboard` refuses ALL account-owned
    tokens (error 1016) — analytics for account tokens = GraphQL
    (httpRequests1dGroups etc.) only. security.cab traffic seen at verify
    time: 1,989 requests 2026-10-22, 61 on 2026-10-23 (partial day).
  - **2026-10-23 later (agent-inbox build, same Drew directive):** the day
    token additionally gained three groups, all **zone-scoped to security.cab
    only**: Email Routing Rules Write, DNS Write, Zone Settings Write —
    needed to stand up Email Routing on the agents.security.cab subdomain.
    Still NOT present: zone Workers Routes write (a webhook-gateway test
    route failed with "No access to the specified resource").
- Inference token `cloudflare.api-token-ai-inference` (minted 2026-10-07, id
  7746f234…): AI Gateway Read+Run + Workers AI Read+Write, account-scoped.
  Live-tested OK (gateway list + embedding inference). For inference use.
- `~/tools/cloudflare/wrangler-secret.py` — reads `{"token","name","value"}`
  JSON from stdin, sets `CLOUDFLARE_API_TOKEN` transiently, pipes the value to
  `wrangler secret put` (cwd `~/git/nix-cache`). Sends the value with NO
  trailing newline: wrangler stores stdin bytes verbatim, and a stray `\n`
  breaks `timingSafeEqual` checks and SigV4 signatures (hit 2026-10-07).
- Cloudflare edge error **1010** blocks requests with non-browser User-Agents:
  python-urllib's default UA gets 403 on workers.dev even for no-auth routes.
  Use a browser UA header for worker/API test requests (hit 2026-10-07 —
  this masqueraded as a "wrong upload secret" for an hour).

## 1Password CLI (op) — two service accounts (set up 2026-10-24)
- Binary: `~/tools/bin/op` → `~/tools/1password-cli/op`.
- TWO service-account tokens, BOTH kept in Bitwarden Secrets Manager (project "developing today"); Drew's rule 2026-10-24: **museRW is the default**.
  - **museRW** (default): Bitwarden key `op museRW service account auth token 1password` (id 5d3d53c9-…), Integration ID C47JI5RKSBA6HK772VOVHX4QTE, service-account email eq7f2cj4…@1passwordserviceaccounts.com. Permissions per Drew: Dev read/write + Walla read-only. 852 chars, sha256 prefix cf80ff5b7e6a5ea2. Origin: 1Password Dev vault item "Service Account Auth Token: museRW" (hy7f4ugc53jo2svowxsw3cgryy) — pull/copy THAT item in/out of Dev for exact transfers; a view-once share-link transcription of this token (2026-10-24) came back corrupt and had to be shredded — never trust visual transcription for 852-char tokens.
  - **muse** (fallback, do NOT rename its Bitwarden key — laptop entries reference it exactly): key `op muse service account auth token 1password` (id 3855e961-…), Integration ID UFWDYBUZRJFBPCGRZSOC6JXTNI, email ppcaz3p4…@. Its own item lives in the Walla vault ("Service Account Auth Token: muse").
- `source ~/tools/op-env.sh` → exports OP_SERVICE_ACCOUNT_TOKEN for museRW (default); `source ~/tools/op-env.sh muse` → the original account. Fetches from Bitwarden at source time; never prints the value.
- Verified 2026-10-24 with museRW: `op whoami` OK, `op vault list` = Dev + Walla, item list/get in BOTH vaults OK (reads ~2s).
- **Sandbox writes WORK — the "hang" was stdin (root-caused 2026-10-24):** `op item create` with NO field assignments blocks forever reading a template from stdin (no TTY needed to reproduce; timeouts at 25–170s, item never appears — earlier notes called this a transport hang; it is not). FIX: always pass field assignments or `--template <file>`, and add `< /dev/null`. With that, creates complete in ~2.5s from the sandbox with museRW. Verified end-to-end 2026-10-24: probe item created in Dev, read back, deleted; then the 11-item catch-up batch (dnb.my-account-password, cline.api-key, turso.general-db-token, cloudflare.webhook-gateway.github-secret, cloudflare.webhook-gateway.admin-token, cloudflare.agent-inbox-admin-token, turso.muse-meta-agent-inbox-token, rustdesk.amd-6-password, krdp.amd-6-password, commandcode.api-key, globalping.api-token) filed into Dev as LOGIN items (value in a CONCEALED password field, built via a 600 `--template` JSON so values never hit argv) and each verified with `op item get`; a sha spot-check (cline.api-key) matched Bitwarden byte-for-byte (`op item get --fields` output appends a trailing newline — trim before hashing). A laptop-side create probe also hung the same way (same stdin cause); no laptop write path is needed.
- **REDACTED readback trap (hit 2026-10-26):** `op item get --fields password` on this build can return a redaction notice (text ending "…to reveal ]") instead of the value — hash checks then mismatch on a CORRECT item. Fix: add `--reveal`. Verify structure first with `--format json` (field lengths only), then read with `--reveal` and strip `\r\n` before hashing.
- **DUPLICATE password-field trap (root-caused 2026-10-26):** the 11 catch-up LOGIN items built from the 600 template (incl. `rustdesk.amd-6-password`, `krdp.amd-6-password`) each carry TWO fields with id `password`: the standard one is EMPTY (len 0) and the real value sits in a second CONCEALED field. Any first-match read (`op item get --fields password`, naive jq) returns the empty string and auth fails with a misleading "wrong password". Verified 2026-10-26: the non-empty fields hash-match the Bitwarden originals exactly (len 24, sha12 846919846475 / e8f91317e3db). Rule: for these items select the non-empty CONCEALED field — or simpler, read the Bitwarden original via bws.

## 1Password via Muse's service accounts (discovered 2026-10-25)
- bws holds `op muse service account auth token 1password` (read-only) and `op museRW service account auth token 1password` (read/write). Fetch the token value from bws, export as OP_SERVICE_ACCOUNT_TOKEN, then the `op` dispatcher CLI works — no interactive account exists or is needed. Visible vaults: Dev, Walla. The Dev vault mirrors most bws secret names (e.g. user@amd = laptop sudo login).
- Gotchas: op:// references break on titles containing `@` (use the item ID instead); `op item create` with field assignments needs stdin from /dev/null or it tries to read a JSON template from the pipe; first op call in a fresh sandbox can take ~20s-3min (dispatcher realise + proxy).

## Meta (Muse) API keys — name mapping (renamed 2026-10-27, Drew's order)
The old bws names pointed the WRONG WAY and caused a real misroute; use this mapping, never the old names:
- **Muse Code plan key** (the ONLY key the OpenCode `meta` provider may use): bws `meta.muse-code-plan.api-key`, value pattern LLM_1026...XQGI, sha256 prefix 61a2ae5f. (Old name: `meta.api-key`.)
- **Muse API / Default Project key** (PAYG project key; NOT for provider routing): bws `meta.muse-api-default-project.api-key`, pattern LLM_4614...wSws, sha256 prefix 6b1ea8ee. (Old name: `meta.api-key-funded` — it is NOT the plan key despite the old name.) 1Password Dev item renamed to match.
- Identify keys by Drew's console table (product/project), never by the old secret names.
