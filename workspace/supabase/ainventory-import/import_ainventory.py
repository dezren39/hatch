#!/usr/bin/env python3
"""Import AInventory into Supabase schema `ainventory`.

Sources (prepped by the Drive download step, see SOURCE_SUMMARY.json):
  - the freshest AInventory workbook, as one CSV per sheet in ./sheets/
  - Drive's model_value_data.csv
Loads:
  1. ainventory.sources      — one row per source file (provenance)
  2. ainventory.sheet_rows   — EVERY csv row, as {"cells": [...]}, append-only
  3. ainventory.models       — from Model_Catalog + model_value_data
  4. ainventory.benchmark_results — typed rows from model_value_data (AA
     Intelligence Index) and Coding_Agent_Results (CAI v1.5)
All inserts are upserts on natural unique keys with a per-run import_batch,
so re-running is safe. Auth: service_role key from Bitwarden; never printed.
"""
import csv
import json
import os
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REF = "nltgxorqwxhgfzseiirt"
BASE = f"https://{REF}.supabase.co/rest/v1"
BWS = os.path.expanduser("~/tools/bin/bws")
BATCH = str(uuid.uuid4())


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
               "-H", "Accept-Profile: ainventory",
               "-H", "Content-Profile: ainventory",
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


def num(x):
    try:
        return float(str(x).replace(",", "").replace("$", "").strip())
    except Exception:
        return None


def main():
    global KEY
    KEY = service_role_key()
    summary = json.load(open(os.path.join(HERE, "SOURCE_SUMMARY.json")))
    sheets_dir = os.path.join(HERE, "sheets")

    wb = summary["workbook"]
    src_wb = rest("POST", "/sources", [{
        "name": wb["name"], "kind": "drive-workbook",
        "drive_file_id": wb["driveFileId"],
        "drive_modified_at": wb["modifiedTime"],
        "import_batch": BATCH,
        "note": wb.get("note", "")}], on_conflict=None, select="id")
    # sources has no unique on name; fetch/create guard: query by name+batch
    wb_id = src_wb[0]["id"]

    mv = summary["model_value_csv"]
    src_mv = rest("POST", "/sources", [{
        "name": mv["name"], "kind": "drive-csv",
        "drive_file_id": mv["driveFileId"],
        "drive_modified_at": mv["modifiedTime"],
        "import_batch": BATCH,
        "note": mv.get("note", "")}], select="id")
    mv_id = src_mv[0]["id"]
    print(f"sources: workbook id={wb_id}, model_value id={mv_id}, batch={BATCH}")

    # ---- sheet_rows: every row of every sheet -----------------------------
    total = 0
    sheet_files = [(s["sheet"], s["csv_file"], wb_id) for s in summary["sheets"]]
    sheet_files.append(("model_value_data", "model_value_data.csv", mv_id))
    for sheet, fname, sid in sheet_files:
        rows = read_csv(os.path.join(sheets_dir, fname))
        payload = [{"source_id": sid, "import_batch": BATCH, "sheet_name": sheet,
                    "row_index": i + 1, "data": {"cells": r}}
                   for i, r in enumerate(rows)]
        for j in range(0, len(payload), 250):
            rest("POST", "/sheet_rows", payload[j:j + 250],
                 on_conflict="source_id,import_batch,sheet_name,row_index")
        total += len(payload)
        print(f"sheet_rows {sheet}: {len(payload)}")
    print(f"sheet_rows total: {total}")

    # ---- models ------------------------------------------------------------
    models = {}
    catalog = read_csv(os.path.join(sheets_dir, "Model_Catalog.csv"))
    hdr = catalog[0]
    for r in catalog[1:]:
        d = dict(zip(hdr, r))
        if d.get("model_key"):
            models[d["model_key"]] = d.get("creator")
    mv_rows = read_csv(os.path.join(sheets_dir, "model_value_data.csv"))
    mv_hdr = mv_rows[0]
    for r in mv_rows[1:]:
        d = dict(zip(mv_hdr, r))
        name = (d.get("model") or "").strip()
        if name:
            base = name.split(" (")[0]
            models.setdefault(base, None)
    payload = [{"name": n, "provider": p} for n, p in sorted(models.items())]
    for j in range(0, len(payload), 250):
        rest("POST", "/models", payload[j:j + 250], on_conflict="name")
    print(f"models: {len(payload)}")

    # ---- benchmark_results: model_value_data (AA Intelligence Index) -------
    results = []
    for r in mv_rows[1:]:
        d = dict(zip(mv_hdr, r))
        name = (d.get("model") or "").strip()
        if not name:
            continue
        effort = None
        base = name
        if name.endswith(")") and " (" in name:
            base, effort = name[:-1].rsplit(" (", 1)
        results.append({
            "source_id": mv_id, "import_batch": BATCH,
            "model_name": base, "benchmark": "AA Intelligence Index",
            "metric": "intelligence_index", "effort": effort,
            "value_num": num(d.get("score")),
            "cost_per_task_usd": num(d.get("cost")),
            "speed_tps": num(d.get("speed")),
            "raw": d})
    # ---- benchmark_results: Coding_Agent_Results (CAI) ---------------------
    car = read_csv(os.path.join(sheets_dir, "Coding_Agent_Results.csv"))
    car_hdr = car[1]  # row 1 is a title; row 2 is the header
    for r in car[2:]:
        if not r or not any(c.strip() for c in r):
            continue
        d = dict(zip(car_hdr, r))
        if not d.get("model_as_reported"):
            continue
        results.append({
            "source_id": wb_id, "import_batch": BATCH,
            "model_name": d["model_as_reported"].strip(),
            "benchmark": f"Artificial Analysis Coding Agent Index {d.get('benchmark_version','')}".strip(),
            "metric": "cai_index_score",
            "effort": (d.get("effort_as_reported") or None),
            "value_num": num(d.get("cai_index_score")),
            "cost_per_task_usd": num(d.get("cost_per_task_usd")),
            "speed_tps": None,
            "raw": d})
    for j in range(0, len(results), 250):
        rest("POST", "/benchmark_results", results[j:j + 250],
             on_conflict="source_id,import_batch,model_name,benchmark,metric,effort")
    print(f"benchmark_results: {len(results)}")
    print(f"BATCH={BATCH}")


if __name__ == "__main__":
    main()
