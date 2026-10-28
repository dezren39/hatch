#!/usr/bin/env python3
"""Parse the freshest AInventory workbook into per-sheet CSVs + SOURCE_SUMMARY.json.
Data prep only; no database access."""
import csv, json, re, sys
from pathlib import Path
import openpyxl

BASE = Path.home() / "workspace/supabase/ainventory-import"
SRC = BASE / "source"
SHEETS = BASE / "sheets"
SHEETS.mkdir(parents=True, exist_ok=True)

WB_PATH = SRC / "ai_model_benchmark_inventory_advanced_2026-10-21.xlsx"
MVD_SRC = SRC / "model_value_data.csv"

def sanitize(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_")
    return s or "sheet"

wb = openpyxl.load_workbook(WB_PATH, data_only=True, read_only=True)
sheets_info = []
used = {}
for ws in wb.worksheets:
    base = sanitize(ws.title)
    name = base
    i = 2
    while name in used:
        name = f"{base}_{i}"; i += 1
    used[name] = ws.title
    csv_file = f"{name}.csv"
    rows_iter = ws.iter_rows(values_only=True)
    all_rows = []
    for r in rows_iter:
        all_rows.append(["" if c is None else c for c in r])
    # trim trailing fully-empty rows
    while all_rows and all(str(c).strip() == "" for c in all_rows[-1]):
        all_rows.pop()
    if not all_rows:
        sheets_info.append({"sheet": ws.title, "csv_file": csv_file, "rows": 0, "columns": []})
        (SHEETS / csv_file).write_text("")
        continue
    header = [str(c) for c in all_rows[0]]
    data = all_rows[1:]
    with open(SHEETS / csv_file, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(all_rows[0])
        w.writerows(data)
    sheets_info.append({"sheet": ws.title, "csv_file": csv_file, "rows": len(data), "columns": header})
    print(f"SHEET {ws.title!r} -> {csv_file}: {len(data)} data rows, {len(header)} cols: {header}")

# copy model_value_data.csv into sheets/
dest = SHEETS / "model_value_data.csv"
dest.write_bytes(MVD_SRC.read_bytes())
print("copied model_value_data.csv ->", dest)

def distinct_models(csv_path, label):
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        rdr = csv.reader(f)
        rows = list(rdr)
    if not rows:
        print(f"DISTINCT {label}: no rows"); return None
    header = rows[0]
    idx = None
    for i, h in enumerate(header):
        if "model" in h.strip().lower():
            idx = i; break
    if idx is None:
        idx = 0
        print(f"DISTINCT {label}: no 'model' column in {header}; using col 0 ({header[0]!r})")
    else:
        print(f"DISTINCT {label}: model column = {header[idx]!r} (idx {idx})")
    vals = [r[idx].strip() for r in rows[1:] if len(r) > idx and r[idx].strip()]
    print(f"DISTINCT {label}: {len(set(vals))} distinct, {len(vals)} non-empty values")
    return {"column": header[idx], "distinct": len(set(vals)), "values": sorted(set(vals))}

mvd = distinct_models(dest, "model_value_data.csv")
bc_path = None
for s in sheets_info:
    if s["sheet"] == "Benchmark_Comparison":
        bc_path = SHEETS / s["csv_file"]
bc = distinct_models(bc_path, "Benchmark_Comparison") if bc_path else None
if bc_path is None:
    print("DISTINCT Benchmark_Comparison: sheet not found; sheets are:", [s["sheet"] for s in sheets_info])

# does model_value_data match any workbook sheet in content?
mvd_rows = dest.read_text(encoding="utf-8-sig").strip().splitlines()
match_note = "no workbook sheet has identical row content to model_value_data.csv"
for s in sheets_info:
    p = SHEETS / s["csv_file"]
    other = p.read_text(encoding="utf-8-sig").strip().splitlines() if p.stat().st_size else []
    if [r.strip() for r in other] == [r.strip() for r in mvd_rows]:
        match_note = f"identical content to workbook sheet {s['sheet']!r}"
        break
print("MODEL_VALUE_MATCH:", match_note)

summary = {
    "workbook": {
        "name": "ai_model_benchmark_inventory_advanced_2026-10-21.xlsx",
        "modifiedTime": "2026-10-28T13:09:08.064Z",
        "driveFileId": "1v2cGy9Bb8qwC7lIRp-r8I2m6e4u6WDxV",
        "note": "Drive canonical updated 2026-10-28 by Coding Plan Watch (md5 b108928bf7ba71f0e649ee962d541958): targeted scan since 2026-10-27 plus seven-day lookback found NO material change - no Plan_Events appended, only +1 Maintenance_Log row (28). All tracked prices/limits/lineups re-verified unchanged on official sources, incl. Command Code GOAT up to $100 / Pro up to $110 docs read first-hand (consistent with the 2026-10-27 update) and Meta Muse Code directly verified 2026-10-28 via live browser (baseline exact). Tailscale failed again (ERR_CONNECTION_RESET; last direct verification 2026-10-21). Unverified cluster claims of 2026-10-28 GitHub changelog entries were not confirmed first-hand and not recorded. Archives: AInventory_Archive_2026-10-28_0800-pre.xlsx, AInventory_Archive_2026-10-28_0809.xlsx",
    },
    "model_value_csv": {
        "name": "model_value_data.csv",
        "modifiedTime": "2026-10-19T06:55:29.102Z",
        "driveFileId": "1LEIi5n6rt_KeQxA20aJK_JVJocM3Zf0a",
        "note": match_note,
    },
    "sheets": sheets_info,
    "distinct_models": {"model_value_data": mvd, "benchmark_comparison": bc},
}
(BASE / "SOURCE_SUMMARY.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
print("WROTE", BASE / "SOURCE_SUMMARY.json")
