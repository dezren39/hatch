#!/usr/bin/env python3
"""Mirror the Supabase `agent` schema (PRIMARY since Phase 1, 2026-10-21)
into the Turso `muse-meta` coord_* tables (READ-ONLY mirror).

Direction is strictly one-way: Supabase -> Turso. Nothing writes back.
Workers/tasks/checkpoints are upserted in full; events are appended
incrementally by id watermark (state.json next to this script). Leases are
intentionally not mirrored — they are second-scale ephemeral state; the
mirror exists for observation and emergency reference during the Phase 1
observation week (2026-10-21 -> 2026-10-28).

Usage: sync_agent_to_turso.py [--full]   (prints one JSON summary line)
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.path.join(HERE, "state.json")
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
REF = "nltgxorqwxhgfzseiirt"
TURSO_DB = "muse-meta"


def bws_secret(name):
    for attempt in range(4):
        try:
            out = subprocess.run(["bws", "secret", "list", "-o", "json"],
                                 capture_output=True, text=True, check=True).stdout
            sid = next(s["id"] for s in json.loads(out) if s["key"] == name)
            time.sleep(1.0)
            out = subprocess.run(["bws", "secret", "get", sid, "-o", "json"],
                                 capture_output=True, text=True, check=True).stdout
            return json.loads(out)["value"]
        except Exception:
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"bws fetch failed for {name}")


def mgmt_sql(token, sql):
    payload = json.dumps({"query": sql})
    for attempt in range(4):
        p = subprocess.run(
            ["curl", "-s", "-A", UA, "-X", "POST",
             f"https://api.supabase.com/v1/projects/{REF}/database/query",
             "-H", f"Authorization: Bearer {token}",
             "-H", "Content-Type: application/json", "--data-binary", "@-"],
            input=payload, capture_output=True, text=True)
        try:
            rows = json.loads(p.stdout)
            if isinstance(rows, list):
                return rows
        except Exception:
            pass
        time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Management API SQL failed: {p.stdout[:200]!r}")


def lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (dict, list)):
        v = json.dumps(v, separators=(",", ":"))
    return "'" + str(v).replace("'", "''") + "'"


def main():
    full = "--full" in sys.argv
    state = {"last_event_id": 0}
    if os.path.exists(STATE_PATH) and not full:
        with open(STATE_PATH) as f:
            state = json.load(f)
    token = os.environ.get("SUPABASE_ACCESS_TOKEN") or \
        bws_secret("supabase.access-token-muse-cli")

    workers = mgmt_sql(token,
        "SELECT id, role, status, last_heartbeat_at, display_name "
        "FROM agent.workers")
    tasks = mgmt_sql(token,
        "SELECT id, queue, title, payload, status, priority, dedupe_key, "
        "created_at, updated_at FROM agent.tasks ORDER BY id")
    events = mgmt_sql(token,
        "SELECT id, task_id, worker_id, kind, detail, ts FROM agent.events "
        f"WHERE id > {int(state['last_event_id'])} ORDER BY id")
    checkpoints = mgmt_sql(token,
        "SELECT worker_id, key, value, updated_at FROM agent.checkpoints")

    stmts = []
    for w in workers:
        stmts.append(
            "INSERT INTO coord_workers (name, role, status, last_seen_at, notes) "
            f"VALUES ({lit(w['id'])}, {lit(w['role'])}, {lit(w['status'])}, "
            f"{lit(w['last_heartbeat_at'])}, {lit(w['display_name'])}) "
            "ON CONFLICT(name) DO UPDATE SET role=excluded.role, "
            "status=excluded.status, last_seen_at=excluded.last_seen_at, "
            "notes=excluded.notes;")
    for t in tasks:
        stmts.append(
            "INSERT INTO coord_tasks (id, queue, title, payload, status, "
            "priority, dedupe_key, created_at, updated_at) VALUES "
            f"({lit(t['id'])}, {lit(t['queue'])}, {lit(t['title'])}, "
            f"{lit(t['payload'])}, {lit(t['status'])}, {lit(t['priority'])}, "
            f"{lit(t['dedupe_key'])}, {lit(t['created_at'])}, "
            f"{lit(t['updated_at'])}) "
            "ON CONFLICT(id) DO UPDATE SET queue=excluded.queue, "
            "title=excluded.title, payload=excluded.payload, "
            "status=excluded.status, priority=excluded.priority, "
            "dedupe_key=excluded.dedupe_key, updated_at=excluded.updated_at;")
    max_event = state["last_event_id"]
    for e in events:
        stmts.append(
            "INSERT OR IGNORE INTO coord_events (id, task_id, worker, kind, "
            f"detail, created_at) VALUES ({lit(e['id'])}, {lit(e['task_id'])}, "
            f"{lit(e['worker_id'])}, {lit(e['kind'])}, {lit(e['detail'])}, "
            f"{lit(e['ts'])});")
        max_event = max(max_event, e["id"])
    for c in checkpoints:
        stmts.append(
            "INSERT INTO coord_checkpoints (worker, key, value, updated_at) "
            f"VALUES ({lit(c['worker_id'])}, {lit(c['key'])}, {lit(c['value'])}, "
            f"{lit(c['updated_at'])}) "
            "ON CONFLICT(worker, key) DO UPDATE SET value=excluded.value, "
            "updated_at=excluded.updated_at;")

    sql_path = os.path.join(HERE, "sync.sql")
    with open(sql_path, "w") as f:
        f.write("\n".join(stmts) + "\n")
    p = subprocess.run(["python3", os.path.expanduser("~/tools/turso-exec.py"),
                        TURSO_DB, sql_path], capture_output=True, text=True)
    if p.returncode != 0 or '"error"' in (p.stdout or ""):
        print(json.dumps({"status": "error",
                          "detail": (p.stdout or p.stderr)[:300]}))
        return 1

    state = {"last_event_id": max_event,
             "last_run_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)
    print(json.dumps({"status": "ok", "workers": len(workers),
                      "tasks": len(tasks), "events_new": len(events),
                      "checkpoints": len(checkpoints),
                      "last_event_id": max_event}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
