-- Pre-migration snapshot (2026-10-25, before 0008_repo_queue_pilot.sql)
-- pg_get_functiondef for every function in schema agent, muse-dev (nltgxorqwxhgfzseiirt)

-- function: agent.claim_task
CREATE OR REPLACE FUNCTION agent.claim_task(p_worker text, p_queue text DEFAULT NULL::text, p_lease_seconds integer DEFAULT 900)
 RETURNS agent.tasks
 LANGUAGE plpgsql
AS $function$
declare t agent.tasks;
begin
  perform agent.expire_leases();
  select * into t from agent.tasks
   where status = 'queued' and (p_queue is null or queue = p_queue)
   order by priority asc, created_at asc
   for update skip locked limit 1;
  if not found then return null; end if;
  update agent.tasks
     set status = 'claimed', worker_id = p_worker, claimed_at = now(),
         lease_until = now() + make_interval(secs => p_lease_seconds),
         attempts = attempts + 1, updated_at = now()
   where id = t.id returning * into t;
  insert into agent.leases (task_id, worker_id, lease_until, heartbeat_at)
  values (t.id, p_worker, t.lease_until, now())
  on conflict (task_id) do update
    set worker_id = excluded.worker_id,
        lease_until = excluded.lease_until, heartbeat_at = now();
  insert into agent.events (worker_id, task_id, kind, detail)
  values (p_worker, t.id, 'claimed',
          jsonb_build_object('lease_seconds', p_lease_seconds));
  return t;
end $function$


-- function: agent.complete_task
CREATE OR REPLACE FUNCTION agent.complete_task(p_task_id bigint, p_worker text, p_result jsonb DEFAULT '{}'::jsonb)
 RETURNS agent.tasks
 LANGUAGE plpgsql
AS $function$
declare t agent.tasks;
begin
  update agent.tasks
     set status = 'done', result = p_result, completed_at = now(),
         updated_at = now(), lease_until = null
   where id = p_task_id and worker_id = p_worker and status = 'claimed'
   returning * into t;
  if not found then return null; end if;
  delete from agent.leases where task_id = p_task_id;
  insert into agent.events (worker_id, task_id, kind, detail)
  values (p_worker, p_task_id, 'completed', p_result);
  return t;
end $function$


-- function: agent.expire_leases
CREATE OR REPLACE FUNCTION agent.expire_leases()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare n integer;
begin
  with expired as (
    update agent.tasks set status = 'queued', worker_id = null,
           lease_until = null, updated_at = now()
     where status = 'claimed' and lease_until < now()
     returning id, worker_id)
  insert into agent.events (worker_id, task_id, kind)
  select worker_id, id, 'lease_expired' from expired;
  get diagnostics n = row_count;
  delete from agent.leases where lease_until < now();
  return n;
end $function$


-- function: agent.fail_task
CREATE OR REPLACE FUNCTION agent.fail_task(p_task_id bigint, p_worker text, p_error text, p_requeue boolean DEFAULT true)
 RETURNS agent.tasks
 LANGUAGE plpgsql
AS $function$
declare t agent.tasks;
begin
  update agent.tasks
     set status = case when p_requeue then 'queued' else 'failed' end,
         worker_id = null, lease_until = null, updated_at = now()
   where id = p_task_id and worker_id = p_worker and status = 'claimed'
   returning * into t;
  if not found then return null; end if;
  delete from agent.leases where task_id = p_task_id;
  insert into agent.events (worker_id, task_id, kind, detail)
  values (p_worker, p_task_id, 'failed',
          jsonb_build_object('error', p_error, 'requeued', p_requeue));
  return t;
end $function$


-- function: agent.prune_events
CREATE OR REPLACE FUNCTION agent.prune_events(p_keep_days integer DEFAULT 30)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare n integer;
begin
  delete from agent.events
   where ts < now() - make_interval(days => p_keep_days)
     and kind <> 'events_pruned';
  get diagnostics n = row_count;
  delete from agent.events
   where ts < now() - make_interval(days => p_keep_days)
     and kind = 'events_pruned';
  insert into agent.events (worker_id, kind, detail)
  values ('system', 'events_pruned',
          jsonb_build_object('deleted', n, 'keep_days', p_keep_days));
  return n;
end $function$

