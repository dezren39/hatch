-- backfill_event_log.sql — Phase 1 backfill for the append-only event
-- log (issue developing-today/code#1248). Loads existing ainventory facts
-- into measurement_events / price_events as HISTORICAL events:
--   * source_kind = 'workbook-import' (the import is the carrier, not
--     the origin — the underlying sources are AA / models.dev data that
--     transited the Drive workbook),
--   * source_date = the source's own date where the data carries one
--     (AA snapshot dates in benchmark_results.raw; the snapshot-YYYY-MM-DD
--     suffix in Rankings test_run_keys) — never backdated or falsified,
--   * ingested_at = when the workbook import actually landed the row
--     (sources.imported_at of its batch),
--   * ingest_batches rows reuse the original workbook import_batch uuids
--     so the provenance chain to sources/sheet_rows stays walkable.
-- ONE-SHOT: refuses to run if workbook-import events already exist.
--
-- Sets:
--   A. benchmark_results (645 rows, all 10 batches) -> measurement_events
--   B. v_rankings, latest batch (138 rows, 2 AA snapshots) -> events
--   C. ModelsDev_Raw_Selected sheet (4 rows) -> price_events
--   D. provider_policies seed rows (window behavior 'unknown', to verify)

do $$
begin
  if exists (select 1 from ainventory.measurement_events
             where source_kind = 'workbook-import') then
    raise exception 'backfill already applied (workbook-import events exist)';
  end if;
end $$;

-- ------------------------------------------------------------ batches
insert into ainventory.ingest_batches (id, source_kind, source_ref, ran_at, note)
select s.import_batch,
       'workbook-import',
       string_agg(distinct s.name, ' + '),
       min(s.imported_at),
       'Backfill carrier batch (issue #1248 Phase 1): original Drive '
       || 'workbook/CSV import; events under this batch carry their '
       || 'sources'' own dates in source_date.'
from ainventory.sources s
group by s.import_batch;

-- ------------------------------------------------- Set A: typed results
insert into ainventory.measurement_events (
  model_id, model_name, model_variant_key, run_key, effort,
  benchmark, benchmark_version, metric, value_num, intelligence_index,
  output_tps, output_tokens_per_task, cost_per_task_usd, task_time_seconds,
  source_kind, source_ref, source_date, ingested_at, ingest_batch_id, raw)
select
  coalesce(m1.id, m2.id),
  br.model_name,
  br.raw->>'model_variant_key',
  br.raw->>'observation_key',
  br.effort,
  regexp_replace(br.benchmark, ' v[0-9]+(\.[0-9]+)*$', ''),
  substring(br.benchmark from ' v([0-9]+(\.[0-9]+)*)$'),
  br.metric,
  br.value_num,
  case when br.metric = 'intelligence_index' then br.value_num end,
  br.speed_tps,
  case when coalesce(br.raw->>'CAI_tokens_per_task',
                     br.raw->>'token_usage_per_task')
            ~ '^[0-9]+(\.[0-9]+)?$'
       then coalesce(br.raw->>'CAI_tokens_per_task',
                     br.raw->>'token_usage_per_task')::numeric end,
  br.cost_per_task_usd,
  case when coalesce(br.raw->>'selected_time_seconds',
                     br.raw->>'time_per_task_seconds',
                     br.raw->>'CAI_agent_wall_seconds_per_task')
            ~ '^[0-9]+(\.[0-9]+)?$'
       then coalesce(br.raw->>'selected_time_seconds',
                     br.raw->>'time_per_task_seconds',
                     br.raw->>'CAI_agent_wall_seconds_per_task')::numeric end,
  'workbook-import',
  coalesce(br.raw->>'url', br.raw->>'AA_source_url',
           br.raw->>'CAI_source_url', br.raw->>'source_url'),
  case when coalesce(br.raw->>'AA_source_snapshot', br.raw->>'snapshot_date')
            ~ '^\d{4}-\d{2}-\d{2}'
       then coalesce(br.raw->>'AA_source_snapshot',
                     br.raw->>'snapshot_date')::date end,
  s.imported_at,
  br.import_batch,
  br.raw
from ainventory.benchmark_results br
join ainventory.sources s on s.id = br.source_id
left join ainventory.models m1 on m1.name = br.model_name
left join ainventory.models m2
  on m2.name = split_part(br.raw->>'model_variant_key', '|', 1) || '|'
            || split_part(br.raw->>'model_variant_key', '|', 2)
-- 3 of the 645 rows carry no measurement at all (the workbook cell was
-- an Excel #VALUE! — AA had published no score for DeepSeek V4 Flash
-- 0731, Gemini 4 Argon, GLM-5.3 (effort 'not stated') in that snapshot).
-- A measurement event requires a measured value, so they are excluded
-- here and accounted for in the batch note instead.
where br.value_num is not null;

-- --------------------------------------- Set B: latest Rankings snapshot
insert into ainventory.measurement_events (
  model_id, model_name, model_variant_key, run_key, effort,
  benchmark, benchmark_version, metric, value_num, intelligence_index,
  output_tps, cost_per_task_usd, task_time_seconds,
  source_kind, source_ref, source_date, ingested_at, ingest_batch_id, raw)
select
  m.id,
  split_part(r.model_variant_key, '|', 1) || '|'
    || split_part(r.model_variant_key, '|', 2),
  r.model_variant_key,
  r.test_run_key,
  r.effort,
  'AA Intelligence Index',
  replace(r.benchmark_version_key, 'AA|v', ''),
  'intelligence_index',
  r.raw_score,
  r.raw_score,
  r.speed_tps,
  r.cost_task,
  r.time_task_sec,
  'workbook-import',
  'drive-workbook:Rankings/Run_Metrics '
    || '(ai_model_benchmark_inventory_advanced_2026-10-21.xlsx)',
  (regexp_match(r.test_run_key, 'snapshot-(\d{4}-\d{2}-\d{2})'))[1]::date,
  s.imported_at,
  s.import_batch,
  to_jsonb(r)
from ainventory.v_rankings r
cross join (select import_batch, max(imported_at) as imported_at
            from ainventory.sources
            where kind = 'drive-workbook'
            group by import_batch
            order by max(imported_at) desc limit 1) s
left join ainventory.models m
  on m.name = split_part(r.model_variant_key, '|', 1) || '|'
           || split_part(r.model_variant_key, '|', 2)
-- 1 of the 138 Rankings rows (anthropic|claude-sonnet-5 xhigh,
-- snapshot 2026-09-28) has a blank score cell: no measurement existed
-- in that snapshot, so no event is fabricated for it.
where r.raw_score is not null;

-- -------------------------------------------- Set C: models.dev prices
insert into ainventory.price_events (
  model_name, input_usd_per_1m, output_usd_per_1m, cached_input_usd_per_1m,
  cache_write_usd_per_1m, context_min_tokens, context_max_tokens,
  window_kind, source_kind, source_ref, ingested_at, ingest_batch_id, raw)
select
  sr.data->'cells'->>0,
  (sr.data->'cells'->>5)::numeric * 1000000,
  (sr.data->'cells'->>6)::numeric * 1000000,
  nullif(sr.data->'cells'->>7, '')::numeric * 1000000,
  nullif(sr.data->'cells'->>8, '')::numeric * 1000000,
  0,
  (sr.data->'cells'->>4)::bigint,
  'flat',
  'workbook-import',
  sr.data->'cells'->>11,
  s.imported_at,
  s.import_batch,
  sr.data
from ainventory.sheet_rows sr
join ainventory.sources s on s.id = sr.source_id
where sr.sheet_name = 'ModelsDev_Raw_Selected'
  and sr.import_batch = (select import_batch
                         from ainventory.v_latest_workbook_batch)
  and sr.row_index >= 2;

-- ------------------------------------------ Set D: provider policy seeds
-- The design's open question, recorded as data: whether each DeepSeek
-- door passes peak/off-peak windows through is NOT yet verified, so the
-- seed rows say 'unknown' rather than encoding a guess.
insert into ainventory.provider_policies
  (provider, scope_kind, scope_value, window_behavior, note, source_kind)
values
  ('deepseek', 'all', null, 'unknown',
   'Direct DeepSeek API publishes peak/off-peak windows; pass-through to '
   || 'our usage unverified (design open question, 2026-10-26).',
   'provider-doc'),
  ('opencode-go', 'all', null, 'unknown',
   'Whether OpenCode Go seats meter DeepSeek windowed pricing or a flat '
   || 'rate is unverified (design open question, 2026-10-26).',
   'provider-doc'),
  ('cline-pass', 'all', null, 'unknown',
   'Whether ClinePass seats meter DeepSeek windowed pricing or a flat '
   || 'rate is unverified (design open question, 2026-10-26).',
   'provider-doc'),
  ('opendesign', 'all', null, 'unknown',
   'Whether OpenDesign seats meter DeepSeek windowed pricing or a flat '
   || 'rate is unverified (design open question, 2026-10-26).',
   'provider-doc');

-- ------------------------------------------------------------ batch note
insert into ainventory.notes (ingest_batch_id, kind, body, author)
values (
  (select import_batch from ainventory.v_latest_workbook_batch),
  'agent_note',
  'Phase 1 backfill (issue #1248): workbook-era facts loaded as '
  || 'append-only events — 642 of 645 benchmark_results rows (3 carried '
  || 'an Excel #VALUE! in place of a score: no AA measurement existed '
  || 'for them, so no event was fabricated) + 137 of 138 latest-batch '
  || 'Rankings rows (1 blank score cell, same treatment) '
  || 'as measurement_events, 4 ModelsDev_Raw_Selected '
  || 'rows as price_events. source_date preserves AA snapshot dates '
  || '(2026-09-28 / 2026-10-16 in Rankings; per-row raw dates in '
  || 'benchmark_results); ingested_at is each row''s original workbook '
  || 'import time. Per-token price history before this point exists '
  || 'only for the 4 models.dev-selected models; TTFT was never carried '
  || 'by benchmark_results (it lived only in Test_Runs sheet rows) and '
  || 'starts with the live gatherer.',
  'phase1-backfill (issue #1248)');

-- ------------------------------------------------------- batch counts
update ainventory.ingest_batches b
set inserted_counts = jsonb_build_object(
  'measurement_events',
    (select count(*) from ainventory.measurement_events me
     where me.ingest_batch_id = b.id),
  'price_events',
    (select count(*) from ainventory.price_events pe
     where pe.ingest_batch_id = b.id))
where b.source_kind = 'workbook-import';
