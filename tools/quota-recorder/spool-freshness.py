#!/usr/bin/env python3
"""Quota-recorder spool freshness check (code#8022).

The #6148 init block proves the quota-recorder timer exists; this
proves ticks are actually LANDING. The file-first spool
(quota-records-YYYY-MM.jsonl) can stop growing, or records can pile
up unacked while the timer stays active — the DB then goes quiet
with no signal, the same silent-gap class #6148 fixed for the
units, one layer up.

Reads the current and previous month spool files (exactly the set
the recorder's flush covers each tick) and prints ONE line:

  ok ages: record=<s> unacked=<s|none> trailing_errors=<n> last_pending=<n>
  STALE: <reason>; ages: ...

Exit code: 0 when healthy, 1 when stale, 2 on usage error.

Fail-soft contract (mirrors the recorder's): a recording gap is
the alarm; a transient flush error that a later tick self-heals is
not. So the alarm conditions are only:

  * no record in either file, or the newest record is older than
    the threshold (default 1200s = 4 missed 5-minute ticks), or
  * some record has stayed unacked longer than the threshold
    (per file: record ts later than that file's last ack "through";
    an ack after an error receipt covers everything up to its
    "through", so healed transients leave only young pending).

Trailing turso-error count and the last receipt's pending are
reported as detail, never as alarm conditions on their own.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

DEFAULT_SPOOL_DIR = os.path.expanduser(
    "~/workspace/goals/stewardship-commission-recurring-review-and-dispatch"
    "/hidden_files/visibility"
)
ACK_KINDS = ("turso-ack", "supabase-ack")
ERROR_KINDS = ("turso-error", "supabase-error")


def parse_ts(value):
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def month_path(spool_dir, dt):
    return os.path.join(spool_dir, f"quota-records-{dt.year:04d}-{dt.month:02d}.jsonl")


def load_file_state(path):
    """(record_ts list, acked_through, receipts) for one spool file.

    Records are lines without a "kind" field (the recorder's own
    definition); receipts carry one. acked_through is the file's
    last ack "through", or None when no flush ever landed there.
    """
    record_ts = []
    acked_through = None
    receipts = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(obj.get("ts"))
            kind = obj.get("kind")
            if kind in ACK_KINDS:
                through = parse_ts(obj.get("through"))
                if through is not None:
                    acked_through = through
                if ts is not None:
                    receipts.append((ts, kind, obj.get("pending")))
            elif kind in ERROR_KINDS:
                if ts is not None:
                    receipts.append((ts, kind, obj.get("pending")))
            elif kind is None and ts is not None:
                record_ts.append(ts)
    return record_ts, acked_through, receipts


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spool-dir", default=DEFAULT_SPOOL_DIR)
    ap.add_argument("--threshold-seconds", type=int, default=1200)
    ap.add_argument("--now", default=None,
                    help="ISO timestamp to treat as now (tests only)")
    args = ap.parse_args()

    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc)
    if now is None:
        print("STALE: unparseable --now value", file=sys.stderr)
        return 2
    threshold = timedelta(seconds=args.threshold_seconds)

    first_of_month = now.replace(day=1)
    prev_month_ref = first_of_month - timedelta(days=1)
    paths = [month_path(args.spool_dir, prev_month_ref),
             month_path(args.spool_dir, now)]

    all_record_ts = []
    all_receipts = []
    oldest_unacked = None
    files_seen = 0
    for path in paths:
        if not os.path.isfile(path):
            continue
        files_seen += 1
        record_ts, acked_through, receipts = load_file_state(path)
        all_record_ts.extend(record_ts)
        all_receipts.extend(receipts)
        for ts in record_ts:
            if acked_through is None or ts > acked_through:
                if oldest_unacked is None or ts < oldest_unacked:
                    oldest_unacked = ts

    trailing_errors = 0
    last_pending = 0
    for _ts, kind, pending in sorted(all_receipts, key=lambda r: r[0]):
        if kind in ERROR_KINDS:
            trailing_errors += 1
        else:
            trailing_errors = 0
        if isinstance(pending, int):
            last_pending = pending

    if files_seen == 0:
        print("STALE: no spool file for current or previous month in "
              f"{args.spool_dir}; ages: record=none unacked=none "
              f"trailing_errors=0 last_pending=0")
        return 1
    if not all_record_ts:
        print("STALE: spool files exist but hold no records; ages: "
              "record=none unacked=none "
              f"trailing_errors={trailing_errors} last_pending={last_pending}")
        return 1

    record_age = now - max(all_record_ts)
    unacked_age = (now - oldest_unacked) if oldest_unacked is not None else None
    detail = (f"ages: record={int(record_age.total_seconds())}s "
              f"unacked={'none' if unacked_age is None else str(int(unacked_age.total_seconds())) + 's'} "
              f"trailing_errors={trailing_errors} last_pending={last_pending}")

    reasons = []
    if record_age > threshold:
        reasons.append(
            f"newest record is {int(record_age.total_seconds())}s old "
            f"(threshold {args.threshold_seconds}s) — recording gap")
    if unacked_age is not None and unacked_age > threshold:
        reasons.append(
            f"oldest unacked record is {int(unacked_age.total_seconds())}s old "
            f"(threshold {args.threshold_seconds}s) — DB landing stalled")
    if reasons:
        print("STALE: " + "; ".join(reasons) + "; " + detail)
        return 1
    print("ok " + detail)
    return 0


if __name__ == "__main__":
    sys.exit(main())
