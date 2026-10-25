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
        "modifiedTime": "2026-10-25T13:08:29.837Z",
        "driveFileId": "1v2cGy9Bb8qwC7lIRp-r8I2m6e4u6WDxV",
        "note": "Drive canonical updated 2026-10-25 by Coding Plan Watch (final md5 910140861ade262eda03d2f0f4dd4be7 after same-day correction): no material change confirmed in the targeted scan since 2026-10-24; +1 Maintenance_Log run row (24) and +1 correction row (25) recording that Meta WAS directly verified on 2026-10-25 via live browser (dev.meta.ai/products/muse-code: Everyday $5 / High $15 5x / Power $50 20x / Maximum $200 80x, 10-50 prompts per 5h - baseline exact; the old docs/pricing URL now returns a page-not-available notice) while Tailscale failed again with ERR_CONNECTION_RESET (last direct verification 2026-10-21; Silver/Gold/Platinum support-tier report still unverified). No Plan_Events or catalog changes. Noted not recorded: GitHub Actions Linux 2-core $0.006/min is a 2026-01-01 pre-baseline reduction with no catalog row. Archives: AInventory_Archive_2026-10-25_0800-pre.xlsx, AInventory_Archive_2026-10-25_0804.xlsx, AInventory_Archive_2026-10-25_0804-pre-correction.xlsx, AInventory_Archive_2026-10-25_0808.xlsx",
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
