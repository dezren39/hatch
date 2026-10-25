// github-ci — Supabase Edge Function (Deno)
// Receives GitHub webhooks. Auth: HMAC-SHA256 signature in
// X-Hub-Signature-256, verified against the GITHUB_WEBHOOK_SECRET
// function secret. The function itself is deployed with
// verify_jwt = false (GitHub cannot present a Supabase JWT); the
// HMAC is the gate.
//
// Behavior:
// - workflow_run (any repo): insert one row per event into ci.events.
//   Duplicate deliveries are absorbed by ci.events.dedupe_key (unique)
//   + ignore-duplicates upsert. (Original v1/v2 behavior, unchanged.)
// - Fleet repos only (Phase B part 2): near-real-time state layer on
//   top of the fleet-fetch polling snapshots in agent.repo_snapshots.
//   - push: advance head_sha (default-branch pushes only), mark
//     fetch_source='webhook', and log an agent.events row.
//   - pull_request / issues: log an agent.events row and set the
//     agent.watermarks key 'dirty:<repo>' so consumers know the
//     snapshot counts may be stale until the fetcher's next pass.
// - Everything else: 202 ignored, as before.

import { createClient } from "jsr:@supabase/supabase-js@2";

const FLEET_REPOS = new Set([
  "developing-today/code",
  "developing-today/opencode",
  "developing-today/openchamber",
  "dezren39/nix",
]);

async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const raw = await req.text();
  const secret = Deno.env.get("GITHUB_WEBHOOK_SECRET") ?? "";
  if (secret) {
    const given = (req.headers.get("x-hub-signature-256") ?? "").replace("sha256=", "");
    const expected = await hmacHex(secret, raw);
    if (!timingSafeEqual(given, expected)) {
      return new Response("bad signature", { status: 401 });
    }
  }

  let payload: Record<string, unknown>;
  try { payload = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }

  const eventType = req.headers.get("x-github-event") ?? "workflow_run";
  if (eventType === "ping") return new Response("pong", { status: 200 });

  const repo = (payload.repository ?? {}) as Record<string, unknown>;
  const repoName = String(repo.full_name ?? "unknown");
  const isFleet = FLEET_REPOS.has(repoName);

  const newClient = () => createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ------------------------------------------------------------- push ---
  if (eventType === "push" && isFleet) {
    const after = String(payload.after ?? "");
    const ref = String(payload.ref ?? "");
    const supabase = newClient();

    // Advance head_sha only for a push to the repo's default branch
    // (a side-branch push must not move the snapshot's head). If no
    // snapshot row exists yet, insert a minimal one (fetcher fills in
    // counts/arrays on its next pass).
    const { data: existing, error: selErr } = await supabase
      .schema("agent").from("repo_snapshots")
      .select("default_branch").eq("repo", repoName).maybeSingle();
    if (selErr) return new Response(`snapshot read failed: ${selErr.message}`, { status: 500 });

    const zeroSha = /^0+$/.test(after);
    let headUpdate: Record<string, unknown> | null = null;
    if (existing) {
      const def = (existing as Record<string, unknown>).default_branch as string | null;
      if (!zeroSha && (!def || ref === `refs/heads/${def}`)) {
        headUpdate = { head_sha: after };
      }
    } else if (!zeroSha && ref.startsWith("refs/heads/")) {
      headUpdate = { head_sha: after };
    }

    if (headUpdate || !existing) {
      const row: Record<string, unknown> = {
        repo: repoName,
        fetched_at: new Date().toISOString(),
        fetch_source: "webhook",
        ...headUpdate,
      };
      const { error } = await supabase.schema("agent").from("repo_snapshots")
        .upsert(row, { onConflict: "repo" });
      if (error) return new Response(`snapshot upsert failed: ${error.message}`, { status: 500 });
    }

    const { error: evErr } = await supabase.schema("agent").from("events")
      .insert({ worker_id: "github-webhook", kind: "push",
                detail: { repo: repoName, after, ref } });
    if (evErr) return new Response(`event insert failed: ${evErr.message}`, { status: 500 });

    return new Response(JSON.stringify({ ok: true, repo: repoName, after }),
      { status: 200, headers: { "content-type": "application/json" } });
  }

  // ------------------------------------------- pull_request / issues ---
  if ((eventType === "pull_request" || eventType === "issues") && isFleet) {
    const obj = (payload.pull_request ?? payload.issue ?? {}) as Record<string, unknown>;
    const action = String(payload.action ?? "");
    const supabase = newClient();

    const { error: evErr } = await supabase.schema("agent").from("events")
      .insert({ worker_id: "github-webhook", kind: eventType,
                detail: { repo: repoName, action,
                          number: Number(obj.number ?? 0) || null,
                          title: (obj.title as string) ?? null } });
    if (evErr) return new Response(`event insert failed: ${evErr.message}`, { status: 500 });

    const now = new Date().toISOString();
    const { error: wmErr } = await supabase.schema("agent").from("watermarks")
      .upsert({ key: `dirty:${repoName}`,
                value: { reason: eventType, at: now }, updated_at: now },
              { onConflict: "key" });
    if (wmErr) return new Response(`watermark upsert failed: ${wmErr.message}`, { status: 500 });

    return new Response(JSON.stringify({ ok: true, repo: repoName, event: eventType }),
      { status: 200, headers: { "content-type": "application/json" } });
  }

  if (eventType !== "workflow_run") {
    return new Response(`ignored event ${eventType}`, { status: 202 });
  }

  // ------------------------------------------------------ workflow_run ---
  const run = (payload.workflow_run ?? {}) as Record<string, unknown>;
  const runId = Number(run.id ?? 0) || null;
  const attempt = Number(run.run_attempt ?? 1) || 1;
  const action = String(payload.action ?? "");

  const row = {
    source: "github",
    event_type: eventType,
    action,
    repo: repoName,
    workflow_name: run.name ?? null,
    workflow_id: Number(run.workflow_id ?? 0) || null,
    run_id: runId,
    run_attempt: attempt,
    branch: run.head_branch ?? null,
    sha: run.head_sha ?? null,
    status: run.status ?? null,
    conclusion: run.conclusion ?? null,
    actor: ((run.actor as Record<string, unknown> | undefined)?.login as string) ?? null,
    html_url: run.html_url ?? null,
    ci_started_at: run.run_started_at ?? run.created_at ?? null,
    ci_updated_at: run.updated_at ?? null,
    payload,
    dedupe_key: `github:${repoName}:${runId}:${attempt}:${action}`,
  };

  const supabase = newClient();
  const { error } = await supabase.schema("ci").from("events")
    .upsert(row, { onConflict: "dedupe_key", ignoreDuplicates: true });
  if (error) return new Response(`insert failed: ${error.message}`, { status: 500 });

  return new Response(JSON.stringify({ ok: true, repo: repoName, run_id: runId, conclusion: row.conclusion }),
    { status: 200, headers: { "content-type": "application/json" } });
});
