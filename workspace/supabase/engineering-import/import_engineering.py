#!/usr/bin/env python3
"""Import the Engineering Research Ledger into Supabase schema `engineering`.

Source (prepped by the Sheets download step, see SOURCE_SUMMARY.json):
  the Ledger workbook (Drive 1PWLW4Rv7P1VIHKo9NGNMDNoK8lFdrV1QR18dXRHgCNE),
  exported as one CSV per tab in ./sheets/
Loads:
  1. engineering.sources    — one row (provenance)
  2. engineering.sheet_rows — EVERY csv row, as {"cells": [...]}, append-only
  3. engineering.records    — typed extract for tabs whose column 1 is a
     stable ID: header->value `fields` map + title/status lifted from the
     per-tab columns in TITLE_COL / STATUS_COL below.
All inserts are upserts on natural unique keys with a per-run import_batch,
so re-running is safe. Auth: service_role key from Bitwarden; never printed.
Pattern follows ~/workspace/supabase/ainventory-import/import_ainventory.py.
"""
import csv
import json
import os
import subprocess
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REF = "nltgxorqwxhgfzseiirt"
BASE = f"https://{REF}.supabase.co/rest/v1"
BWS = os.path.expanduser("~/tools/bin/bws")
BATCH = str(uuid.uuid4())
DRIVE_ID = "1PWLW4Rv7P1VIHKo9NGNMDNoK8lFdrV1QR18dXRHgCNE"
DRIVE_MODIFIED = "2026-10-21T17:04:34.861Z"

# tab -> (title column, status column); tabs absent here have no clean
# stable-ID extract (Overview = free text, Archive = text chunks,
# Audit = check/control pairs) and are preserved in sheet_rows only.
TITLE_COL = {
    "Topics": "Topic / alias", "Research": "Question", "Stories": "Title",
    "Follow-ups": "Original request", "Feedback": "Target",
    "Sources": "Canonical URL", "Changes": "Feature", "Reviews": "Mode",
    "Prompts": "Job", "Watches": "Name", "Watch Facts": "Subject",
    "Requests": "subject",
}
STATUS_COL = {
    "Topics": "Research state", "Research": "Disposition",
    "Stories": "Publication / delivery state",
    "Reports": "Prepared/delivered", "Follow-ups": "Status",
    "Feedback": "Rating", "Watches": "Status", "Watch Facts": "Status",
    "Requests": "status",
}
ID_TABS = ["Topics", "Research", "Stories", "Reports", "Follow-ups",
           "Feedback", "Sources", "Changes", "Reviews", "Prompts",
           "Watches", "Watch Facts", "Requests"]


def service_role_key():
    env = dict(os.environ)
    env["BWS_ACCESS_TOKEN"] = open(
        os.path.expanduser("~/.config/bitwarden/access-token")).read().strip()
    out = subprocess.run([BWS, "secret", "list", "-o", "json"],
                         capture_output=True, text=True, env=env, check=True).stdout
    sid = next(s["id"] for s in json.loads(out)
               if s["key"] == "supabase.service-role-key")
    got = subprocess.run([BWS, "secret", "get", sid, "-o", "json"],
                         capture_output=True, text=True, env=env, check=True).stdout
    return json.loads(got)["value"]


KEY = None


def rest(method, path, rows=None, on_conflict=None, select=None):
    url = BASE + path
    params = []
    if on_conflict:
        params.append(f"on_conflict={on_conflict}")
    if select:
        params.append(f"select={select}")
    if params:
        url += "?" + "&".join(params)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        if rows is not None:
            json.dump(rows, f)
        fname = f.name
    try:
        cmd = ["curl", "-sS", "-m", "120", "-A", "Mozilla/5.0", "-X", method,
               "-H", f"apikey: {KEY}", "-H", f"Authorization: Bearer {KEY}",
               "-H", "Content-Type: application/json",
               "-H", "Accept-Profile: engineering",
               "-H", "Content-Profile: engineering",
               "-H", "Prefer: resolution=merge-duplicates,return=representation",
               "-w", "\n%{http_code}", url]
        if rows is not None:
            cmd += ["--data", f"@{fname}"]
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        body, _, code = out.rpartition("\n")
        if int(code) >= 300:
            raise SystemExit(f"{method} {path} -> HTTP {code}: {body[:400]}")
        return json.loads(body) if body.strip() else []
    finally:
        os.unlink(fname)


def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.reader(f))


def main():
    global KEY
    KEY = service_role_key()
    summary = json.load(open(os.path.join(HERE, "SOURCE_SUMMARY.json")))
    sheets_dir = os.path.join(HERE, "sheets")

    src = rest("POST", "/sources", [{
        "name": "Engineering Research Ledger", "kind": "drive-workbook",
        "drive_file_id": DRIVE_ID, "drive_modified_at": DRIVE_MODIFIED,
        "import_batch": BATCH,
        "note": "Imported 2026-10-25 under agent task 1018 ahead of the "
                "2026-11-05 Gemini/ChatGPT cleanup; Ledger rename to "
                "[ARCHIVED] held until this import verified."}],
        select="id")
    src_id = src[0]["id"]
    print(f"source: id={src_id}, batch={BATCH}")

    # ---- sheet_rows: every row of every tab -------------------------------
    total = 0
    per_sheet = {}
    all_rows = {}
    for tab, info in summary.items():
        rows = read_csv(os.path.join(sheets_dir, info["csv_file"]))
        all_rows[tab] = rows
        payload = [{"source_id": src_id, "import_batch": BATCH,
                    "sheet_name": tab, "row_index": i + 1,
                    "data": {"cells": r}} for i, r in enumerate(rows)]
        for j in range(0, len(payload), 100):
            rest("POST", "/sheet_rows", payload[j:j + 100],
                 on_conflict="source_id,import_batch,sheet_name,row_index")
        per_sheet[tab] = len(payload)
        total += len(payload)
        print(f"sheet_rows {tab}: {len(payload)}")
    print(f"sheet_rows total: {total}")

    # ---- records: typed extract for stable-ID tabs -------------------------
    rec_total = 0
    for tab in ID_TABS:
        rows = all_rows[tab]
        if not rows:
            continue
        hdr = rows[0]
        payload = []
        for i, r in enumerate(rows[1:], start=2):
            if not r or not (r[0] or "").strip():
                continue
            fields = {h: (r[k] if k < len(r) else "")
                      for k, h in enumerate(hdr) if h}
            payload.append({
                "source_id": src_id, "import_batch": BATCH,
                "sheet_name": tab, "row_index": i,
                "record_id": r[0].strip(),
                "title": (fields.get(TITLE_COL.get(tab, "")) or None),
                "status": (fields.get(STATUS_COL.get(tab, "")) or None),
                "fields": fields})
        for j in range(0, len(payload), 100):
            rest("POST", "/records", payload[j:j + 100],
                 on_conflict="source_id,import_batch,sheet_name,row_index")
        rec_total += len(payload)
        print(f"records {tab}: {len(payload)}")
    print(f"records total: {rec_total}")
    print(f"BATCH={BATCH}")


if __name__ == "__main__":
    main()
