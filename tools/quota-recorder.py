#!/usr/bin/env python3
"""Quota recorder (Drew's directive 2026-10-28; Supabase landing added
2026-10-28 at Drew's direction): every tick, append a timestamped record
of Muse's own subscription quota, read via the premade
`subscription-status` CLI (plan, weekly percent used, reset, additional
token pool). Value or error — whatever the source returns is recorded.

The fleet providers' quotas are already recorded 24/7 on the laptop by the
PM quota-gatherer (every 15 min: aggregator quota-current + the monthly
usage-snapshots JSONL), so this recorder covers the one pool that had no
recording: the assistant's own subscription.

Two sinks, file first:
1. FILE (primary, always): one JSON object per tick appended to
     ~/workspace/goals/stewardship-commission-recurring-review-and-dispatch/
       hidden_files/visibility/quota-records-YYYY-MM.jsonl
   The file is append-only and is the source of truth.
2. SUPABASE (secondary): the same records are upserted into
   agent.quota_records (muse-dev project) via ~/tools/supabase-exec.py,
   PK (source, id, ts) — id is the record's pool id for per-pool sources
   ("" for muse-subscription) — INSERT ... ON CONFLICT DO NOTHING, so
   re-sends are harmless. Every record is born UNSENT; a record counts as sent only
   when an ack line in the same JSONL covers its ts. After appending its
   tick, the recorder flushes ALL unsent records in the current and
   previous month files (this tick's plus any backlog) in one upsert per
   file, then appends a receipt line to that file:
     success: {"kind": "supabase-ack",   "ts": ..., "through": <max record
               ts landed>, "count": <records landed by this flush>}
     failure: {"kind": "supabase-error", "ts": ..., "error": <what failed>,
               "pending": <records still unsent in that file>}
   Unsent state is derivable from the file alone: records with a ts later
   than the last ack line's "through" (or all records, if no ack exists)
   are pending. Failures never lose data — the next tick retries
   everything un-acked. The flush subprocess gets its egress proxy from
   ~/tools/secrets.d/mcpx-daemon.env when the caller's env has none
   (the systemd unit's minimal env has no proxy; same pattern as the
   fleet-feed collector).

No LLM involved. Always exits 0; failures are recorded as data.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

OUT_DIR = os.path.expanduser(
    "~/workspace/goals/stewardship-commission-recurring-review-and-dispatch"
    "/hidden_files/visibility"
)
SUBSCRIPTION_STATUS = "/opt/hatch/bin/subscription-status"
SUPABASE_EXEC = os.path.expanduser("~/tools/supabase-exec.py")
TABLE = "agent.quota_records"


def record_subscription(ts):
    rec = {"ts": ts, "source": "muse-subscription"}
    try:
        p = subprocess.run(
            [SUBSCRIPTION_STATUS, "status"],
            capture_output=True, text=True, timeout=60,
        )
        text = (p.stdout or "") + (p.stderr or "")
        m = re.search(r"on the (\w+) subscription", text)
        if m:
            rec["plan"] = m.group(1)
        m = re.search(r"Usage:\s*([\d.]+)% of weekly limit", text)
        if m:
            rec["weekly_percent"] = float(m.group(1))
        m = re.search(r"Weekly limit resets (.+)", text)
        if m:
            rec["resets"] = m.group(1).strip()
        m = re.search(
            r"Additional tokens:\s*([\d.]+)% used \(([^)]+)\)", text
        )
        if m:
            rec["additional_percent"] = float(m.group(1))
            rec["additional_left"] = m.group(2).strip()
        if "weekly_percent" not in rec:
            rec["error"] = "unparsed subscription-status output"
            rec["raw"] = text.strip()[:400]
    except Exception as e:  # failure is data, per Drew
        rec["error"] = f"{type(e).__name__}: {e}"
    return rec


# --- Supabase landing -----------------------------------------------------

def _sql_str(v):
    if v is None:
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def _sql_num(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return repr(float(v))
    return "NULL"


def build_upsert(records):
    rows = []
    for r in records:
        rows.append(
            "("
            + ", ".join([
                _sql_str(r.get("source")),
                _sql_str(r.get("id") or ""),
                _sql_str(r.get("ts")) + "::timestamptz",
                _sql_str(r.get("plan")),
                _sql_num(r.get("weekly_percent")),
                _sql_str(r.get("resets")),
                _sql_num(r.get("additional_percent")),
                _sql_str(r.get("additional_left")),
                _sql_str(r.get("error")),
                _sql_str(json.dumps(r)) + "::jsonb",
            ])
            + ")"
        )
    return (
        f"INSERT INTO {TABLE} (source, id, ts, plan, weekly_percent, resets,"
        " additional_percent, additional_left, error, payload) VALUES\n"
        + ",\n".join(rows)
        + "\nON CONFLICT (source, id, ts) DO NOTHING;"
    )


def load_file_state(path):
    """Return (records, acked_through) parsed from one JSONL file.

    Records are lines without a "kind" field; receipt lines carry one.
    acked_through is the "through" of the file's last supabase-ack line,
    or None when no flush has ever landed for this file.
    """
    records = []
    acked_through = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("kind") == "supabase-ack":
                acked_through = obj.get("through", acked_through)
            elif "kind" not in obj and "ts" in obj:
                records.append(obj)
    return records, acked_through


PROXY_ENV_FILE = os.path.expanduser("~/tools/secrets.d/mcpx-daemon.env")
PROXY_KEYS = (
    "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
    "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
)


def flush_env():
    """Env for the supabase-exec subprocess. Under the systemd unit's
    minimal env there is no egress proxy, and both hops of the flush
    (bws -> Bitwarden API, curl -> Supabase API) need one; mirror the
    fleet-feed collector's pattern: when no proxy is set, load the proxy
    values from ~/tools/secrets.d/mcpx-daemon.env into the child's env
    only (memory only — never argv, never a file)."""
    env = dict(os.environ)
    if not (env.get("HTTPS_PROXY") or env.get("https_proxy")):
        try:
            with open(PROXY_ENV_FILE) as f:
                for line in f:
                    k, sep, v = line.strip().partition("=")
                    if sep and k in PROXY_KEYS and k not in env:
                        env[k] = v.strip().strip('"').strip("'")
        except OSError:
            pass
    return env


def run_flush_sql(sql):
    """Run one SQL statement file through supabase-exec.py.

    Returns (ok, error_text)."""
    fd, fname = tempfile.mkstemp(suffix=".sql", prefix="quota-flush-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(sql)
        p = subprocess.run(
            [sys.executable, SUPABASE_EXEC, fname],
            capture_output=True, text=True, timeout=240, env=flush_env(),
        )
        if p.returncode == 0:
            return True, ""
        tail = (p.stderr or "").strip().splitlines()
        head = (p.stdout or "").strip().splitlines()
        err = tail[-1] if tail else (head[0] if head else "unknown failure")
        return False, f"supabase-exec exit {p.returncode}: {err}"[:300]
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"[:300]
    finally:
        try:
            os.unlink(fname)
        except OSError:
            pass


def flush_file(path, now_ts):
    """Flush every unsent record in one JSONL file; append the receipt.

    Returns the number of records still pending after this attempt."""
    if not os.path.exists(path):
        return 0
    records, acked_through = load_file_state(path)
    pending = [
        r for r in records
        if acked_through is None or r["ts"] > acked_through
    ]
    if not pending:
        return 0
    ok, err = run_flush_sql(build_upsert(pending))
    with open(path, "a") as f:
        if ok:
            f.write(json.dumps({
                "kind": "supabase-ack",
                "ts": now_ts,
                "through": max(r["ts"] for r in pending),
                "count": len(pending),
            }) + "\n")
            return 0
        f.write(json.dumps({
            "kind": "supabase-error",
            "ts": now_ts,
            "error": err,
            "pending": len(pending),
        }) + "\n")
        return len(pending)


def month_paths(now):
    """Current month's JSONL plus last month's (a month boundary must not
    strand un-acked records in the old file)."""
    paths = []
    y, m = now.year, now.month
    for _ in range(2):
        paths.append(os.path.join(
            OUT_DIR, f"quota-records-{y:04d}-{m:02d}.jsonl"))
        m -= 1
        if m == 0:
            y, m = y - 1, 12
    return paths


def main():
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(
        OUT_DIR, datetime.now().strftime("quota-records-%Y-%m.jsonl")
    )
    with open(path, "a") as f:
        f.write(json.dumps(record_subscription(ts)) + "\n")
    still_pending = 0
    for p in month_paths(datetime.now()):
        still_pending += flush_file(p, ts)
    msg = f"{ts} recorded muse-subscription tick -> {path}"
    if still_pending:
        msg += f" (supabase: {still_pending} record(s) still pending)"
    else:
        msg += " (supabase: all records landed)"
    print(msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
