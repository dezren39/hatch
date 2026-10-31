#!/usr/bin/env python3
"""session-count.py — the fleet session-cap tally, scripted (Drew, 2026-10-31).

Implements Drew's counting rule (2026-10-30) for the OpenChamber
conductor's capacity line, replacing per-cycle model arithmetic:

  The cap (30) counts only UNFINISHED ROOT sessions. A session in the
  /api/session list counts iff: root (no parentID), time.archived
  unset, and no terminal outcome recorded. Subsessions, archived
  sessions, and finished sessions never count. Sessions are only
  counted here — never modified, archived, or deleted.

Data sources (laptop OpenChamber, read from the laptop over ssh):
  GET /api/session?limit=1000   -> {"data": [session records]}
  GET /api/session-activity     -> {"sessions": {id: {...}}}  (cross-check)

Usage:
  session-count.py                     fetch live via ~/tools/laptop-ssh.sh
  session-count.py --list F --activity F
                                       read payloads from files instead
  session-count.py --json              also print the machine-readable tally

Population: the session-activity map (the live/recent window). The
/api/session list is full history and only supplies each activity
session's parentID / time.archived / outcome for classification.

Output (stdout), always exactly one capacity line first:
  unfinished roots N / 30 (raw listed M = archived A + finished F + subsessions S + unfinished N)
followed by one "UNFIN <id> <title>" line per unfinished root, and a
NOTE line when some activity sessions have no list record (counted
as neither finished nor unfinished). Exit 0 on success; exit 3 when
the enumeration itself failed (the conductor's global-stop condition).
"""
import argparse
import json
import subprocess
import sys

CAP = 30
SSH = "/home/hatch/tools/laptop-ssh.sh"
BASE = "http://localhost:3000"


def fetch_live():
    remote = (
        f"curl -s {BASE}/api/session?limit=1000; echo; "
        f"curl -s {BASE}/api/session-activity"
    )
    try:
        out = subprocess.run(
            [SSH, remote], capture_output=True, text=True, timeout=180
        )
    except Exception as e:  # ssh itself failed to run
        print(f"session-count: fetch failed: {e}", file=sys.stderr)
        sys.exit(3)
    if out.returncode != 0:
        print(
            f"session-count: fetch failed (rc={out.returncode}): "
            f"{out.stderr.strip()[:200]}",
            file=sys.stderr,
        )
        sys.exit(3)
    lines = [ln for ln in out.stdout.splitlines() if ln.strip()]
    if len(lines) < 2:
        print("session-count: fetch returned incomplete payloads", file=sys.stderr)
        sys.exit(3)
    try:
        return json.loads(lines[0]), json.loads(lines[1])
    except json.JSONDecodeError as e:
        print(f"session-count: unparseable payload: {e}", file=sys.stderr)
        sys.exit(3)


def load_file(path):
    with open(path) as f:
        return json.load(f)


def tally(list_payload, activity_payload):
    items = list_payload.get("data")
    if items is None and isinstance(list_payload, list):
        items = list_payload
    if items is None:
        print("session-count: session list payload has no 'data' array", file=sys.stderr)
        sys.exit(3)
    activity_sessions = (activity_payload or {}).get("sessions")
    if not isinstance(activity_sessions, dict) or not activity_sessions:
        print(
            "session-count: session-activity payload has no sessions map "
            "(the enumeration itself failed)",
            file=sys.stderr,
        )
        sys.exit(3)
    # Population = the activity map (the live/recent window the API
    # tracks). The /api/session list is full history (1000+ records of
    # long-dead sessions with no outcome field) — classifying it raw
    # was the 2026-10-30 failure in a new costume. List records only
    # supply parentID / time.archived / outcome for activity ids.
    by_id = {s.get("id"): s for s in items}
    archived = finished = subs = unrecorded = 0
    unfinished = []
    for sid in activity_sessions:
        s = by_id.get(sid)
        if s is None:
            unrecorded += 1
            continue
        if s.get("parentID"):
            subs += 1
            continue
        if (s.get("time") or {}).get("archived"):
            archived += 1
            continue
        if s.get("outcome"):
            finished += 1
            continue
        unfinished.append({"id": sid, "title": s.get("title")})
    return {
        "cap": CAP,
        "raw_listed": len(activity_sessions),
        "archived": archived,
        "finished": finished,
        "subsessions": subs,
        "unrecorded": unrecorded,
        "unfinished_roots": len(unfinished),
        "unfinished": unfinished,
    }


def main():
    ap = argparse.ArgumentParser(description="Fleet session-cap tally (Drew's counting rule).")
    ap.add_argument("--list", dest="list_file", help="session list payload file (skip live fetch)")
    ap.add_argument("--activity", dest="activity_file", help="session-activity payload file")
    ap.add_argument("--json", action="store_true", help="print the tally as JSON after the capacity line")
    args = ap.parse_args()

    if args.list_file:
        list_payload = load_file(args.list_file)
        activity_payload = load_file(args.activity_file) if args.activity_file else {}
    else:
        list_payload, activity_payload = fetch_live()

    r = tally(list_payload, activity_payload)
    equation = (
        f"archived {r['archived']} + finished {r['finished']} + "
        f"subsessions {r['subsessions']} + unfinished {r['unfinished_roots']}"
    )
    if r["unrecorded"]:
        equation += f" + unrecorded {r['unrecorded']}"
    print(
        f"unfinished roots {r['unfinished_roots']} / {r['cap']} "
        f"(raw listed {r['raw_listed']} = {equation})"
    )
    for u in r["unfinished"]:
        print(f"UNFIN {u['id']} {u.get('title') or ''}".rstrip())
    if r["unrecorded"]:
        print(
            f"NOTE {r['unrecorded']} activity sessions have no record in the "
            "session list window; they are counted as neither finished nor "
            "unfinished — treat the unfinished count as a lower bound."
        )
    if args.json:
        print(json.dumps(r, indent=2))


if __name__ == "__main__":
    main()
