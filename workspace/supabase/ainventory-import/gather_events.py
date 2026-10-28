#!/usr/bin/env python3
"""Gatherer for the append-only AA event log (issue #1248) — DRY RUN.

Pulls Artificial Analysis model data (the /models page embeds a full
structured JSON payload per variant) and models.dev/api.json, diffs
both against the event log's current views, and emits the WOULD-INSERT
event diff: new observations only, plus NEW-MODEL DETECTION (a pulled
model with no events and no identity match anywhere in ainventory).

Phase 1: this script performs NO writes. It only GETs (AA, models.dev,
and PostgREST reads of ainventory). Phase 2 turns the diff into real
ingest_batches + measurement_events / price_events inserts and adds
the interpretation-agent dispatch for non-empty batches.

Usage: gather_events.py [--out DIR]   (default out: ./dry_runs)
Auth for reads: supabase.service-role-key from Bitwarden; never printed.
"""
import json
import os
import re
import subprocess
import sys
from datetime import date, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
REF = "nltgxorqwxhgfzseiirt"
BASE = f"https://{REF}.supabase.co/rest/v1"
BWS = os.path.expanduser("~/tools/bin/bws")
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
AA_MODELS_URL = "https://artificialanalysis.ai/models"
MODELSDEV_URL = "https://models.dev/api.json"
II_BENCHMARK = "AA Intelligence Index"
II_VERSION = "4.3.2"  # AA's current index version, as labelled in our data
NEW_MODEL_WINDOW_DAYS = 60

# ainventory.models provider label -> models.dev provider id
PROVIDER_MAP = {
    "OpenAI": "openai", "Anthropic": "anthropic", "DeepSeek": "deepseek",
    "Google": "google", "Meta": "meta", "Xiaomi": "xiaomi",
    "MiniMax": "minimax", "Mistral": "mistral", "Z AI": "zai",
    "Alibaba": "alibaba", "Kimi": "moonshotai", "SpaceXAI": "xai",
    "Inception": "inception", "NVIDIA": "nvidia", "Upstage": "upstage",
}


def fetch(url):
    out = subprocess.run(
        ["curl", "-sS", "-m", "120", "-A", UA, url],
        capture_output=True, text=True, check=True).stdout
    return out


def service_role_key():
    env = dict(os.environ)
    env["BWS_ACCESS_TOKEN"] = open(
        os.path.expanduser("~/.config/bitwarden/access-token")).read().strip()
    out = subprocess.run([BWS, "secret", "list", "-o", "json"],
                         capture_output=True, text=True, env=env,
                         check=True).stdout
    sid = next(s["id"] for s in json.loads(out)
               if s["key"] == "supabase.service-role-key")
    got = subprocess.run([BWS, "secret", "get", sid, "-o", "json"],
                         capture_output=True, text=True, env=env,
                         check=True).stdout
    return json.loads(got)["value"]


def rest_get(key, path):
    out = subprocess.run(
        ["curl", "-sS", "-m", "120", "-A", UA,
         "-H", f"apikey: {key}", "-H", f"Authorization: Bearer {key}",
         "-H", "Accept-Profile: ainventory", BASE + path],
        capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def norm(s):
    """Identity normalization: lowercase alphanumerics only."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


# ------------------------------------------------------------ AA parsing
def parse_aa_models(html):
    """Extract the embedded per-variant JSON objects from the AA page."""
    u = html.replace('\\"', '"').replace("\\\\", "\\")
    starts = [m.start() for m in
              re.finditer(r'\{"id":"[0-9a-f-]{36}","slug":"', u)]

    def extract(i):
        depth, instr, esc = 0, False, False
        for j in range(i, len(u)):
            c = u[j]
            if instr:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    instr = False
            else:
                if c == '"':
                    instr = True
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        return u[i:j + 1]
        return None

    variants = []
    for s in starts:
        raw = extract(s)
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if not o.get("release") or o.get("intelligenceIndex") is None:
            continue  # creator/aggregate entries, not model variants
        perf = o.get("performanceByPromptType") or {}
        speed = None
        for k in ("short", "medium", "long"):
            if isinstance(perf.get(k), dict) and perf[k].get("medianOutputSpeed"):
                speed = perf[k]["medianOutputSpeed"]
                break
        ttft = o.get("timeToFirstAnswerToken") or {}
        cpt = o.get("intelligenceIndexCostPerTask")
        if isinstance(cpt, dict):  # current AA payload: {cost: {total, ...}}
            cpt = (cpt.get("cost") or {}).get("total")
        variants.append({
            "release_slug": o["release"]["slug"],
            "release_name": o["release"]["name"],
            "creator_slug": (o.get("creator") or {}).get("slug"),
            "variant_slug": o.get("slug"),
            "effort": (o.get("effort") or {}).get("slug"),
            "release_date": o.get("releaseDate"),
            "intelligence_index": o.get("intelligenceIndex"),
            "cost_per_task_usd": cpt,
            "output_tokens_per_task": o.get("intelligenceIndexOutputTokensPerTask"),
            "ttft_seconds": ttft.get("total") if isinstance(ttft, dict) else None,
            "output_tps_short": speed,
            "price_input_per_1m": o.get("price1mInputTokens"),
            "price_output_per_1m": o.get("price1mOutputTokens"),
            "price_cached_input_per_1m": o.get("cacheHitPrice"),
            "source_ref": f"https://artificialanalysis.ai/models/{o['release']['slug']}",
        })
    return variants


def main():
    out_dir = os.path.join(HERE, "dry_runs")
    if "--out" in sys.argv:
        out_dir = sys.argv[sys.argv.index("--out") + 1]
    os.makedirs(out_dir, exist_ok=True)
    today = date.today().isoformat()
    key = service_role_key()

    # ---- current state (reads only)
    models = rest_get(key, "/models?select=name,provider&limit=1000")
    events = rest_get(key, "/measurement_events"
                           "?select=model_name,model_variant_key,effort"
                           "&limit=5000")
    current = rest_get(key, "/v_current_measurements"
                            "?select=model_name,model_variant_key,effort,"
                            "benchmark,benchmark_version,value_num,"
                            "cost_per_task_usd,output_tps,source_date"
                            "&limit=2000")
    prices = rest_get(key, "/v_current_prices?select=model_name,provider,"
                           "input_usd_per_1m,output_usd_per_1m,window_kind"
                           "&limit=2000")

    # ---- known identities (normalized model segment / display name)
    known = set()
    for m in models:
        name = m["name"]
        known.add(norm(name))
        if "|" in name:
            known.add(norm(name.split("|", 1)[1]))
    for e in events:
        known.add(norm(e.get("model_name")))
        vk = e.get("model_variant_key")
        if vk and vk.count("|") >= 2:
            known.add(norm(vk.split("|")[1]))

    # current II (current version) keyed by (identity, effort)
    cur_ii = {}
    for c in current:
        if c["benchmark"] == II_BENCHMARK and c["benchmark_version"] == II_VERSION:
            ident = norm((c.get("model_variant_key") or "").split("|")[1]
                         if c.get("model_variant_key") else c["model_name"])
            cur_ii[(ident, norm(c.get("effort")))] = c
    cur_price = {}
    for p in prices:
        if p.get("window_kind") == "flat" and not p.get("provider"):
            cur_price[norm(p["model_name"])] = p

    # ---- AA pull + diff
    aa = parse_aa_models(fetch(AA_MODELS_URL))
    aa_meas, aa_price, new_models = [], [], []
    seen_releases = {}
    unchanged = 0
    for v in aa:
        ident = norm(v["release_name"])
        if ident not in known and norm(v["release_slug"]) not in known:
            seen_releases.setdefault(v["release_slug"], {
                "model": v["release_name"], "creator": v["creator_slug"],
                "release_date": v["release_date"], "source": "aa",
                "source_ref": v["source_ref"],
                "best_intelligence_index": v["intelligence_index"]})
            prev = seen_releases[v["release_slug"]]
            if (v["intelligence_index"] or 0) > (prev["best_intelligence_index"] or 0):
                prev["best_intelligence_index"] = v["intelligence_index"]
            continue
        if v["effort"] is None:
            continue  # release-level entry duplicates the featured variant
        cur = cur_ii.get((ident, norm(v["effort"])))
        if cur is None or abs((cur["value_num"] or 0) - v["intelligence_index"]) > 0.05:
            aa_meas.append({
                "model": v["release_name"], "effort": v["effort"],
                "benchmark": II_BENCHMARK, "benchmark_version": II_VERSION,
                "intelligence_index": v["intelligence_index"],
                "cost_per_task_usd": v["cost_per_task_usd"],
                "output_tokens_per_task": v["output_tokens_per_task"],
                "ttft_seconds": v["ttft_seconds"],
                "output_tps_short": v["output_tps_short"],
                "current_value": None if cur is None else cur["value_num"],
                "source_kind": "aa", "source_ref": v["source_ref"],
                "source_date": today})
        else:
            unchanged += 1
        cp = cur_price.get(ident)
        if v["price_input_per_1m"] is not None and (
                cp is None or cp.get("input_usd_per_1m") != v["price_input_per_1m"]
                or cp.get("output_usd_per_1m") != v["price_output_per_1m"]):
            aa_price.append({
                "model": v["release_name"],
                "input_usd_per_1m": v["price_input_per_1m"],
                "output_usd_per_1m": v["price_output_per_1m"],
                "cached_input_usd_per_1m": v["price_cached_input_per_1m"],
                "source_kind": "aa", "source_ref": v["source_ref"],
                "source_date": today})
    new_models.extend(seen_releases.values())

    # ---- models.dev pull + diff (tracked providers only)
    md = json.loads(fetch(MODELSDEV_URL))
    md_price, md_new = [], []
    cutoff = (date.today() - timedelta(days=NEW_MODEL_WINDOW_DAYS)).isoformat()
    for our_label, md_provider in PROVIDER_MAP.items():
        prov = md.get(md_provider)
        if not prov:
            continue
        for mid, m in (prov.get("models") or {}).items():
            ident = norm(mid) or norm(m.get("name"))
            cost = m.get("cost") or {}
            if ident in known or norm(m.get("name")) in known:
                cp = cur_price.get(ident) or cur_price.get(norm(m.get("name")))
                # models.dev api.json costs are already USD per 1M tokens.
                pin, pout = cost.get("input"), cost.get("output")
                if pin is not None and (cp is None
                                        or cp.get("input_usd_per_1m") != pin
                                        or cp.get("output_usd_per_1m") != pout):
                    ctx_limit = (m.get("limit") or {}).get("context")
                    # Context-band dimension: a context tier splits the
                    # price into [0, size) and [size, limit] bands.
                    tiers = [t for t in (cost.get("tiers") or [])
                             if (t.get("tier") or {}).get("type") == "context"]
                    base_max = tiers[0]["tier"]["size"] if tiers else ctx_limit
                    md_price.append({
                        "model": f"{md_provider}/{mid}",
                        "input_usd_per_1m": pin, "output_usd_per_1m": pout,
                        "cached_input_usd_per_1m": cost.get("cache_read"),
                        "cache_write_usd_per_1m": cost.get("cache_write"),
                        "context_min_tokens": 0,
                        "context_max_tokens": base_max,
                        "source_kind": "modelsdev",
                        "source_ref": MODELSDEV_URL, "source_date": today})
                    for t in tiers:
                        md_price.append({
                            "model": f"{md_provider}/{mid}",
                            "input_usd_per_1m": t.get("input"),
                            "output_usd_per_1m": t.get("output"),
                            "cached_input_usd_per_1m": t.get("cache_read"),
                            "cache_write_usd_per_1m": t.get("cache_write"),
                            "context_min_tokens": t["tier"]["size"],
                            "context_max_tokens": ctx_limit,
                            "source_kind": "modelsdev",
                            "source_ref": MODELSDEV_URL, "source_date": today})
            else:
                rd = m.get("release_date") or ""
                if rd >= cutoff:
                    md_new.append({
                        "model": m.get("name") or mid,
                        "creator": md_provider, "release_date": rd,
                        "source": "modelsdev", "source_ref": MODELSDEV_URL})
    # de-dupe models.dev new flags against AA flags by normalized name
    aa_new_norms = {norm(n["model"]) for n in new_models}
    md_new = [n for n in md_new if norm(n["model"]) not in aa_new_norms]
    new_models.extend(md_new)

    diff = {
        "dry_run": True,
        "generated_at": today,
        "counts": {
            "aa_variants_pulled": len(aa),
            "aa_measurement_would_insert": len(aa_meas),
            "aa_measurement_unchanged": unchanged,
            "aa_price_would_insert": len(aa_price),
            "modelsdev_price_would_insert": len(md_price),
            "new_models_flagged": len(new_models),
        },
        "aa_measurement_would_insert": aa_meas,
        "aa_price_would_insert": aa_price,
        "modelsdev_price_would_insert": md_price,
        "new_models_flagged": new_models,
    }
    out_path = os.path.join(out_dir, f"gather_diff_{today}.json")
    with open(out_path, "w") as f:
        json.dump(diff, f, indent=2)
    print(json.dumps(diff["counts"], indent=2))
    print(f"\nDRY RUN — no rows inserted. Full diff: {out_path}")
    if new_models:
        print("\nNEW MODELS FLAGGED:")
        for n in new_models:
            print(f"  - {n['model']} ({n['creator']}, {n['release_date']}, "
                  f"via {n['source']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
