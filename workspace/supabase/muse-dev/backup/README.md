# muse-dev backups — content-addressed, streaming, DIY

Supabase Free has **no backups**. This script is the backup system (Drew, 2026-10-21).

## Design
- Two transports (`config.json` → `transport`):
  - **`pgdump`** — `pg_dump` via the Supabase session pooler (IPv4, 5432),
    full fidelity. For machines with normal outbound TCP (Drew's laptop).
  - **`api`** — schema + data export over the Supabase Management API (HTTPS),
    streamed as JSONL records (migrations bundle, generated DDL, per-table row
    batches, sequence values). This is what the sandbox runs: its egress is an
    HTTP proxy that will not tunnel TCP 5432 (verified 2026-10-21).
- Either way the stream passes through `zstd`, is SHA-256 hashed **while
  streaming**, and is uploaded to Cloudflare R2 bucket **`supabase-backups`**
  as an S3 multipart upload. Dump data never touches local disk (one ≤8 MiB
  part is buffered in memory at a time).
- Final object key embeds the content hash:
  `pg/muse-dev/<yyyy>/<mm>/<sha256>.sql.zst`
  If an object with that hash already exists, the upload is aborted — identical
  snapshots dedupe to one copy.
- `pg/muse-dev/manifest.json` lists every stored backup (hash, key, bytes,
  timestamp). `--list` prints it.
- Storage credentials are **bucket-scoped** (R2 token minted 2026-10-21, Object
  Read+Write on this bucket only) and live in Bitwarden Secrets Manager as
  `cloudflare.r2-backups-*`; the DB password is `supabase.db-password`.

## Run it
```sh
# needs: python3, pg_dump (postgresql client), zstd (or set "compressor":"gzip"),
# and either bws (with BWS_ACCESS_TOKEN exported) or env vars set:
#   SUPABASE_DB_PASSWORD, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
python3 supabase_backup.py            # back up now
python3 supabase_backup.py --if-due   # only if older than interval_hours (12)
python3 supabase_backup.py --list     # show manifest
```
Config: `config.json` next to the script (endpoint, bucket, prefix, cadence,
compressor, retention note). `BACKUP_INTERVAL_HOURS` env overrides cadence.
Runs from Muse's sandbox (scheduled, ~2×/day) and can run identically from
Drew's laptop — the `--if-due` mode makes double-scheduling harmless.

## Restore
```sh
# pgdump transport — download the object named in the manifest, verify
# sha256sum equals its filename, then:
zstd -d <sha256>.pgdump.sql.zst | psql "<target connection string>"

# api transport — produce SQL files, then apply them in order:
python3 restore_api.py <sha256>.api.jsonl.zst /tmp/restore
psql "<target>" -f /tmp/restore/schema.sql -f /tmp/restore/data.sql
```
Verified 2026-10-21: export of 13 tables / 4,362 rows restored to exactly
4,362 INSERT statements + migrations as schema.

## Known refinements (not yet done)
- `api` exports can differ byte-for-byte between runs even when data is
  unchanged (record-ordering jitter in generated DDL / row batches), so
  dedupe hits are best-effort for that transport. Fix = deterministic
  ORDER BY everywhere; do it if backup count grows faster than expected.
- Manifest updates are read-modify-write; don't run two backups at once.

## Notes / limits
- Full copies only for now; revisit (incremental/WAL) when full sets get big —
  at 13 MB DB this is a rounding error in R2's free 10 GB.
- A Cloudflare Worker variant (scheduled trigger doing the same pull) is the
  fallback if laptop/sandbox runs prove unreliable; not built yet.
- Free-plan DBs also pause after 1 week idle; the morning readout's daily
  query is the keep-alive, and these backups are a second touch.
