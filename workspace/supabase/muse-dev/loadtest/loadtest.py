#!/usr/bin/env python3
"""Load test the Supabase `agent` coordination schema with N simulated
worker clones claiming/completing tasks over PostgREST (the data plane).

Usage: loadtest.py [workers=20] [seconds=75] [seed_tasks=600]
Setup/teardown SQL is printed for ~/tools/supabase-exec.py by the caller;
this script only does the concurrent RPC traffic and prints JSON metrics.
Service key comes from $SUPABASE_SERVICE_ROLE_KEY or Bitwarden-fetched env
set by the caller wrapper. Latencies are measured from the caller's network
position — through the sandbox egress proxy they are an upper bound, not
the database's own cost.
"""
import json
import os
import statistics
import sys
import threading
import time
import urllib.request
import urllib.error

BASE = "https://nltgxorqwxhgfzseiirt.supabase.co/rest/v1"
KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
WORKERS = int(sys.argv[1]) if len(sys.argv) > 1 else 20
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 75
STOP = time.time() + SECONDS

results = {"claims": 0, "completes": 0, "empty_claims": 0, "errors": 0}
claim_lat, complete_lat = [], []
lock = threading.Lock()


USE_CURL = os.environ.get("LT_TRANSPORT") == "curl"


def rpc(fn, payload, lat_sink):
    body = json.dumps(payload).encode()
    t0 = time.time()
    try:
        if USE_CURL:
            import subprocess
            p = subprocess.run(
                ["curl", "-s", "--max-time", "30", "-X", "POST",
                 f"{BASE}/rpc/{fn}",
                 "-H", f"apikey: {KEY}", "-H", f"Authorization: Bearer {KEY}",
                 "-H", "Content-Type: application/json",
                 "-H", "Content-Profile: agent",
                 "-H", "User-Agent: Mozilla/5.0", "--data-binary", "@-"],
                input=body, capture_output=True, timeout=35)
            if p.returncode != 0:
                raise RuntimeError("curl failed")
            data = p.stdout
        else:
            req = urllib.request.Request(
                f"{BASE}/rpc/{fn}", data=body, method="POST",
                headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                         "Content-Type": "application/json",
                         "Content-Profile": "agent",
                         "User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
        lat_sink.append(time.time() - t0)
        return json.loads(data) if data else None
    except Exception:
        with lock:
            results["errors"] += 1
        return None


def worker(idx):
    wid = f"lt-{idx:02d}"
    while time.time() < STOP:
        task = rpc("claim_task",
                   {"p_worker": wid, "p_queue": "loadtest",
                    "p_lease_seconds": 300}, claim_lat)
        if task is None:
            with lock:
                results["empty_claims"] += 1
            time.sleep(0.25)
            continue
        with lock:
            results["claims"] += 1
        time.sleep(0.05)  # simulated work
        done = rpc("complete_task",
                   {"p_task_id": task["id"], "p_worker": wid,
                    "p_result": {"loadtest": True}}, complete_lat)
        if done:
            with lock:
                results["completes"] += 1


threads = [threading.Thread(target=worker, args=(i + 1,))
           for i in range(WORKERS)]
t0 = time.time()
for t in threads:
    t.start()
for t in threads:
    t.join()
elapsed = time.time() - t0


def pct(data, q):
    if not data:
        return None
    s = sorted(data)
    return round(s[min(len(s) - 1, int(len(s) * q))], 3)


print(json.dumps({
    "workers": WORKERS, "elapsed_s": round(elapsed, 1),
    **results,
    "claims_per_s": round(results["claims"] / elapsed, 2),
    "claim_latency_s": {"p50": pct(claim_lat, 0.5), "p95": pct(claim_lat, 0.95)},
    "complete_latency_s": {"p50": pct(complete_lat, 0.5),
                           "p95": pct(complete_lat, 0.95)},
}))
