#!/usr/bin/env python3
"""Addendum: typed benchmark_results from Benchmark_Comparison's embedded
table (CSV row 40 = header, rows 41+ = 25 model rows, paired AA v4.3.2 +
CAI v1.5). Uses the same import_batch as import_ainventory.py's first run.
'#VALUE!' cells are source formula errors -> stored as value_text, no value_num."""
import csv, json, os, subprocess, tempfile
HERE=os.path.dirname(os.path.abspath(__file__))
BATCH="3bae32bd-0b3b-4a10-b7e0-0f51d8f22171"; WB_ID=1
REF="nltgxorqwxhgfzseiirt"; BASE=f"https://{REF}.supabase.co/rest/v1"
BWS=os.path.expanduser("~/tools/bin/bws")
env=dict(os.environ); env["BWS_ACCESS_TOKEN"]=open(os.path.expanduser("~/.config/bitwarden/access-token")).read().strip()
out=subprocess.run([BWS,"secret","list","-o","json"],capture_output=True,text=True,env=env,check=True).stdout
sid=next(s["id"] for s in json.loads(out) if s["key"]=="supabase.service-role-key")
KEY=json.loads(subprocess.run([BWS,"secret","get",sid,"-o","json"],capture_output=True,text=True,env=env,check=True).stdout)["value"]
def num(x):
    try: return float(str(x).replace(",","").replace("$","").strip())
    except Exception: return None
rows=list(csv.reader(open(os.path.join(HERE,"sheets","Benchmark_Comparison.csv"),newline="",encoding="utf-8-sig")))
hdr=rows[39]; data=rows[40:]
payload=[]
for r in data:
    if not r or not r[0].strip(): continue
    d=dict(zip(hdr,r))
    model=d["model_as_reported"].strip(); effort=d.get("effort_as_reported") or None
    for bench,metric,score_col,cost_col in [
        ("AA Intelligence Index v4.3.2","intelligence_index","AA_score_v4_3_2","AA_cost_per_Index_task_USD"),
        ("Artificial Analysis Coding Agent Index v1.5","cai_index_score","CAI_score_v1_5","CAI_cost_per_agent_task_USD")]:
        raw_score=(d.get(score_col) or "").strip()
        payload.append({"source_id":WB_ID,"import_batch":BATCH,"model_name":model,
          "benchmark":bench,"metric":metric,"effort":effort,
          "value_num":num(raw_score),"value_text":raw_score if raw_score.startswith("#") else None,
          "cost_per_task_usd":num(d.get(cost_col)),
          "speed_tps":num(d.get("AA_output_tokens_per_second")) if bench.startswith("AA") else None,
          "raw":d})
with tempfile.NamedTemporaryFile("w",suffix=".json",delete=False) as f: json.dump(payload,f); fn=f.name
cmd=["curl","-sS","-m","120","-A","Mozilla/5.0","-X","POST","-H",f"apikey: {KEY}","-H",f"Authorization: Bearer {KEY}",
 "-H","Content-Type: application/json","-H","Accept-Profile: ainventory","-H","Content-Profile: ainventory",
 "-H","Prefer: resolution=merge-duplicates,return=minimal","--data",f"@{fn}",
 BASE+"/benchmark_results?on_conflict=source_id,import_batch,model_name,benchmark,metric,effort","-w","\n%{http_code}"]
print("payload rows:",len(payload))
print(subprocess.run(cmd,capture_output=True,text=True,check=True).stdout)
os.unlink(fn)
