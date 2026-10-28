# Engineering Research Ledger → Postgres import — task 1018 (2026-10-25)

Source: "Engineering Research Ledger", Drive spreadsheet
1PWLW4Rv7P1VIHKo9NGNMDNoK8lFdrV1QR18dXRHgCNE, Drive modified
2026-10-21T17:04:34.861Z. The Ledger was NOT renamed/archived — that
rename stays held; this import is the verification it was waiting for.

## What was built
- Migration `~/workspace/supabase/muse-dev/migrations/0011_engineering.sql`:
  new schema `engineering` with `sources`, `sheet_rows` (JSON cells,
  ainventory pattern), and `records` (typed extract), RLS on, grants
  in the 0005 shape. Applied live.
- PostgREST exposed schemas updated to add `engineering`
  (verified readback: public,graphql_public,agent,ci,ideas,ainventory,engineering).
- Importer: `~/workspace/supabase/engineering-import/import_engineering.py`
  (idempotent upserts, per-run import_batch); source CSVs in
  `sheets/`, tab summary in `SOURCE_SUMMARY.json`, run log in
  `import_run_2026-10-25.log`.

## Verification (import batch d7071a02-bfb8-41ad-ab41-f78166249375)
Two independent reads agree (importer log via PostgREST + direct SQL
via Management API):
- `engineering.sheet_rows`: 410 rows — every tab, header rows included,
  per-tab counts identical to the Sheets export (Overview 32, Topics 174,
  Research 25, Stories 7, Reports 4, Follow-ups 4, Feedback 3, Sources 33,
  Changes 21, Reviews 5, Prompts 15, Archive 16, Audit 18, Watches 2,
  Watch Facts 47, Requests 4).
- `engineering.records`: 331 typed rows across the 13 tabs whose first
  column is a stable ID (header->value fields map, title/status lifted).
  Overview/Archive/Audit have no stable-ID structure and are preserved
  in sheet_rows only.
- Spot check: Topics records begin T001 "MCP", T002 "Rust", T003 "Roc".

Deadline context: content is now in Postgres ahead of the 2026-11-05
Gemini/ChatGPT cleanup.
