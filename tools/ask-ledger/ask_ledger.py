#!/usr/bin/env python3
"""ask-ledger — Ask-the-ledger: Atlas's edge Q&A surface (code#6266).

Atlas stays the source of truth. This tool:
  export  snapshot the allowlisted operational corpus to the R2 bucket
          (incremental, sha256 manifest in the ledger DB; secret-shape
          scan aborts on any hit; the Atlas secret tier is structurally
          excluded — allowlist only + denylist check).
  ask     route a question: Cloudflare AI Search while this month's
          ledger counters are under the config caps; at a cap, fall
          back to Atlas search (atlas-search CLI, FTS/BM25 leg) until
          the monthly reset. Every query is logged (hit/miss) in the
          Turso ledger DB `atlas-ask-ledger`.
  usage   print this month's counters vs caps.
  misses  print recent misses (the documentation work list).

Caps live in config.json — never hardcoded. Retrieval only: AI Search
/chat/completions is never called, and Cloudflare AI Gateway is never
used (standing ban). Answer text is the caller's job.
"""
import hashlib
import hmac
import json
import math
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(HERE, "config.json")))
HOME = os.path.expanduser("~")


def http(method, url, headers=None, body=None, timeout=120):
    """HTTP via curl: urllib's proxy tunneling dies intermittently in
    this sandbox (same failure family supabase-exec.py documents);
    curl through the egress proxy is the proven transport."""
    cmd = ["curl", "-s", "-S", "--retry", "2", "--max-time", str(timeout),
           "-X", method, "-w", "\n%{http_code}"]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    if body is not None:
        cmd += ["--data-binary", "@-"]
    cmd.append(url)
    r = subprocess.run(cmd, input=body, capture_output=True, timeout=timeout + 30)
    if r.returncode != 0:
        raise RuntimeError(f"curl {method} {url}: {r.stderr.decode()[:200]}")
    out, _, code = r.stdout.rpartition(b"\n")
    return int(code), out

SECRET_PATTERNS = [
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    r"ghp_[A-Za-z0-9]{30,}",
    r"github_pat_[A-Za-z0-9_]{30,}",
    r"AKIA[0-9A-Z]{16}",
    r"LLM_[A-Za-z0-9]{20,}",
    r"sk-[A-Za-z0-9]{32,}",
    r"0\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[A-Za-z0-9+/=]{20,}",
    r"eyJ[A-Za-z0-9_-]{40,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}",
    r"(?i)(?:api[-_ ]?key|secret|password|passwd|token)\s*[:=]\s*[\"'][A-Za-z0-9+/=_.\-]{24,}[\"']",
]


def fetch_secret(name):
    """fleet secrets get first; bws emergency route if the verb returns
    empty (the broker path has been observed returning empty while
    Bitwarden holds the value — see TOOLS.d/secrets.md)."""
    try:
        r = subprocess.run(["fleet", "secrets", "get", name],
                           capture_output=True, text=True, timeout=180)
        v = r.stdout.strip()
        if v:
            return v
    except Exception as e:
        print(f"ask-ledger: fleet secrets error for {name}: {e}", file=sys.stderr)
    print(f"ask-ledger: warning: fleet secrets get {name} empty; "
          "using bws emergency route", file=sys.stderr)
    env = dict(os.environ)
    with open(os.path.join(HOME, ".config/bitwarden/access-token")) as f:
        env["BWS_ACCESS_TOKEN"] = f.read().strip()
    bws = os.path.join(HOME, "tools/bin/bws")
    lst = subprocess.run([bws, "secret", "list", "-o", "json"],
                         capture_output=True, text=True, env=env, check=True)
    sid = [s["id"] for s in json.loads(lst.stdout) if s["key"] == name][0]
    got = subprocess.run([bws, "secret", "get", sid, "-o", "json"],
                         capture_output=True, text=True, env=env, check=True)
    return json.loads(got.stdout)["value"]


# ---------------------------------------------------------------- Turso
def _arg(v):
    if v is None:
        return {"type": "null"}
    if isinstance(v, int):
        return {"type": "integer", "value": str(v)}
    return {"type": "text", "value": str(v)}


class Ledger:
    def __init__(self):
        self.url = CFG["ledger_http_url"]
        self.token = fetch_secret("turso.atlas-ask-ledger-token")

    def run(self, stmts):
        reqs = [{"type": "execute",
                 "stmt": {"sql": sql, "args": [_arg(a) for a in args]}}
                for sql, args in stmts]
        reqs.append({"type": "close"})
        body = json.dumps({"requests": reqs}).encode()
        code, out = http("POST", self.url + "/v2/pipeline",
                         {"Authorization": f"Bearer {self.token}",
                          "Content-Type": "application/json"}, body, timeout=60)
        if code != 200:
            raise RuntimeError(f"ledger HTTP {code}: {out[:200]!r}")
        out = json.loads(out)
        results = []
        for item in out["results"]:
            if item["type"] == "error":
                raise RuntimeError(f"ledger: {item['error']['message']}")
            if item["response"]["type"] == "close":
                continue
            res = item["response"]["result"]
            cols = [c["name"] for c in res["cols"]]
            rows = [{cols[i]: (cell.get("value") if cell["type"] != "null" else None)
                     for i, cell in enumerate(row)} for row in res["rows"]]
            results.append(rows)
        return results

    def init(self):
        self.run([
            ("""CREATE TABLE IF NOT EXISTS queries(
                  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL,
                  asker TEXT NOT NULL DEFAULT 'cli', question TEXT NOT NULL,
                  route TEXT NOT NULL, hit INTEGER NOT NULL,
                  result_count INTEGER NOT NULL DEFAULT 0,
                  top_source TEXT, month TEXT NOT NULL)""", []),
            ("""CREATE TABLE IF NOT EXISTS usage_counters(
                  month TEXT NOT NULL, metric TEXT NOT NULL,
                  value INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
                  PRIMARY KEY (month, metric))""", []),
            ("""CREATE TABLE IF NOT EXISTS exports(
                  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL,
                  source_id TEXT NOT NULL, r2_key TEXT NOT NULL,
                  sha256 TEXT NOT NULL, bytes INTEGER NOT NULL,
                  est_tokens INTEGER NOT NULL)""", []),
        ])

    def counter(self, month, metric):
        rows = self.run([("SELECT value FROM usage_counters WHERE month=? AND metric=?",
                          [month, metric])])[0]
        return int(rows[0]["value"]) if rows else 0

    def bump(self, month, metric, delta):
        now = datetime.now(timezone.utc).isoformat()
        self.run([("""INSERT INTO usage_counters(month, metric, value, updated_at)
                      VALUES(?,?,?,?)
                      ON CONFLICT(month, metric) DO UPDATE SET
                        value = value + excluded.value, updated_at = excluded.updated_at""",
                     [month, metric, delta, now])])

    def set_counter(self, month, metric, value):
        now = datetime.now(timezone.utc).isoformat()
        self.run([("""INSERT INTO usage_counters(month, metric, value, updated_at)
                      VALUES(?,?,?,?)
                      ON CONFLICT(month, metric) DO UPDATE SET
                        value = excluded.value, updated_at = excluded.updated_at""",
                     [month, metric, value, now])])

    def log_query(self, asker, question, route, hit, count, top_source, month):
        self.run([("""INSERT INTO queries(ts, asker, question, route, hit,
                       result_count, top_source, month) VALUES(?,?,?,?,?,?,?,?)""",
                     [datetime.now(timezone.utc).isoformat(), asker, question,
                      route, 1 if hit else 0, count, top_source, month])])


# ------------------------------------------------------------------- R2
def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def s3(method, key, body=None, content_type=None):
    acct = CFG["account_id"]
    host = f"{CFG['bucket']}.{acct}.r2.cloudflarestorage.com"
    akid = fetch_secret("cloudflare.r2-atlas-ledger-access-key-id")
    secret = fetch_secret("cloudflare.r2-atlas-ledger-secret-access-key")
    now = datetime.now(timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body or b"").hexdigest()
    headers = {"host": host, "x-amz-content-sha256": payload_hash,
               "x-amz-date": amzdate}
    if content_type:
        headers["content-type"] = content_type
    signed = ";".join(sorted(headers))
    canon = "\n".join([method, "/" + (key or ""), "",
                       "".join(f"{h}:{headers[h]}\n" for h in sorted(headers)),
                       signed, payload_hash])
    scope = f"{datestamp}/auto/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope,
                         hashlib.sha256(canon.encode()).hexdigest()])
    k = _sign(("AWS4" + secret).encode(), datestamp)
    k = _sign(k, "auto")
    k = _sign(k, "s3")
    k = _sign(k, "aws4_request")
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={akid}/{scope}, "
        f"SignedHeaders={signed}, Signature={sig}")
    url = f"https://{host}/" + (key or "")
    return http(method, url, headers, body, timeout=120)


def s3_list():
    """Return [(key, size)] for the whole bucket (single page is ample)."""
    _, data = s3("GET", "")
    keys = re.findall(r"<Key>([^<]+)</Key>", data.decode())
    sizes = re.findall(r"<Size>(\d+)</Size>", data.decode())
    return list(zip(keys, [int(s) for s in sizes]))


# ---------------------------------------------------------------- export
def read_source(src):
    if "laptop_path" in src:
        cmd = [os.path.join(HOME, "tools/laptop-ssh.sh"),
               f"cat -- ~/{src['laptop_path']}"]
        r = subprocess.run(cmd, capture_output=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"laptop read failed for {src['id']}: "
                               f"{r.stderr.decode()[:200]}")
        return r.stdout
    with open(os.path.join(HOME, src["path"]), "rb") as f:
        return f.read()


def scan_for_secrets(src_id, text):
    for db in CFG["secret_dbs_denylist"]:
        if db in src_id:
            raise RuntimeError(f"denied: source {src_id} names secret DB {db}")
    for pat in SECRET_PATTERNS:
        m = re.search(pat, text)
        if m:
            raise RuntimeError(
                f"secret-shape hit in {src_id} (pattern {pat[:40]}…) — export aborted")


def cmd_export(args):
    led = Ledger()
    led.init()
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    manifest = []
    changed = 0
    for src in CFG["sources"]:
        raw = read_source(src)
        text = raw.decode("utf-8", errors="replace")
        scan_for_secrets(src["id"], text)
        sha = hashlib.sha256(raw).hexdigest()
        last = led.run([("SELECT sha256 FROM exports WHERE source_id=? "
                         "ORDER BY id DESC LIMIT 1", [src["id"]])])[0]
        est = len(text) // 4 + 1
        if last and last[0]["sha256"] == sha and not args.force:
            print(f"skip (unchanged): {src['id']}")
        else:
            s3("PUT", src["key"], raw, "text/markdown; charset=utf-8")
            led.run([("INSERT INTO exports(ts, source_id, r2_key, sha256, bytes,"
                      " est_tokens) VALUES(?,?,?,?,?,?)",
                      [datetime.now(timezone.utc).isoformat(), src["id"],
                       src["key"], sha, len(raw), est])])
            led.bump(month, "ingestion_tokens", est)
            changed += 1
            print(f"uploaded: {src['id']} ({len(raw)} B, ~{est} tokens)")
        manifest.append({"source_id": src["id"], "r2_key": src["key"],
                         "sha256": sha, "bytes": len(raw)})
    objs = s3_list()
    total = sum(s for _, s in objs)
    led.set_counter(month, "storage_bytes", total)
    man = json.dumps({"generated_at": datetime.now(timezone.utc).isoformat(),
                      "bucket": CFG["bucket"], "objects": manifest},
                     indent=1).encode()
    s3("PUT", "_manifest.json", man, "application/json")
    print(f"export done: {changed} changed, bucket total {total} B "
          f"across {len(objs)} objects")


# -------------------------------------------------------------------- ask
def ai_search(question):
    acct = CFG["account_id"]
    token = fetch_secret("cloudflare.api-token-ai-search")
    url = (f"https://api.cloudflare.com/client/v4/accounts/{acct}"
           f"/ai-search/namespaces/{CFG['namespace']}"
           f"/instances/{CFG['instance']}/search")
    body = json.dumps({"messages": [{"role": "user",
                                     "content": question}]}).encode()
    code, out = http("POST", url,
                     {"Authorization": f"Bearer {token}",
                      "Content-Type": "application/json",
                      "User-Agent": "Mozilla/5.0"}, body, timeout=90)
    if code != 200:
        raise RuntimeError(f"ai-search HTTP {code}: {out[:300]!r}")
    return json.loads(out)


def extract_chunks(resp):
    """(score, source, text) from a search reply. Primary shape:
    result.chunks[] with item.key (the R2 key = the citation) and
    scoring_details.vector_score. A tolerant walk covers shape drift."""
    res = resp.get("result", resp) if isinstance(resp, dict) else {}
    raw = res.get("chunks") or res.get("data") or []
    chunks = []
    for c in raw:
        if not isinstance(c, dict):
            continue
        det = c.get("scoring_details") or {}
        score = det.get("vector_score", c.get("score") or 0)
        item = c.get("item") or {}
        src = item.get("key") or item.get("name")
        txt = c.get("text", "")
        if isinstance(txt, list):
            txt = "\n".join(t.get("text", "") for t in txt
                            if isinstance(t, dict))
        if txt:
            chunks.append((float(score), src, str(txt)))
    if chunks:
        return chunks

    def walk(node):
        if isinstance(node, dict):
            if "text" in node and ("score" in node or "attributes" in node):
                attrs = node.get("attributes") or {}
                f = attrs.get("file") or {}
                src = None
                if isinstance(f, dict):
                    src = f.get("name") or f.get("filename")
                src = src or attrs.get("title") or node.get("id")
                txt = node["text"]
                if isinstance(txt, list):
                    txt = "\n".join(t.get("text", "") for t in txt
                                    if isinstance(t, dict))
                chunks.append((float(node.get("score") or 0), src, str(txt)))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(resp)
    return chunks


def bm25_fallback(question):
    binp = os.path.join(HOME, "tools/bin/atlas-search")
    r = subprocess.run([binp, "search", question],
                       capture_output=True, text=True, timeout=1200)
    out = (r.stdout or "").strip()
    hits = 0
    if out.startswith("{"):
        try:
            hits = len(json.loads(out).get("results", []))
        except Exception:
            hits = 0
    if not hits:
        m = re.search(r"(\d+) hit\(s\)", out)
        hits = int(m.group(1)) if m else (1 if out else 0)
    return out, hits


def cmd_ask(args):
    led = Ledger()
    led.init()
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    metric = "fulltext_queries" if args.fulltext else "semantic_queries"
    cap = CFG["caps"][metric]
    used = led.counter(month, metric)
    route = "ai-search"
    if used >= cap:
        route = "bm25-fallback"
        print(f"[cap reached: {metric} {used}/{cap} this month — "
              "falling back to Atlas search]", file=sys.stderr)
    if route == "ai-search":
        resp = ai_search(args.question)
        led.bump(month, metric, 1)
        chunks = extract_chunks(resp)
        floor = CFG["miss_score_floor"]
        good = [c for c in chunks if c[0] >= floor]
        hit = bool(good)
        top = good[0][1] if good else (chunks[0][1] if chunks else None)
        led.log_query(args.asker, args.question, "ai-search", hit,
                      len(chunks), top, month)
        print(f"[route: ai-search] [{'HIT' if hit else 'MISS'}] "
              f"{len(chunks)} chunk(s)")
        for score, src, txt in sorted(chunks, reverse=True)[:CFG["max_results"]]:
            print(f"\n--- source: {src} (score {score:.3f}) ---")
            print(txt[:1200])
        if not hit:
            print("\n(no chunk at/above the hit floor — recorded as a miss)")
    else:
        out, nhits = bm25_fallback(args.question)
        hit = nhits > 0
        led.log_query(args.asker, args.question, "bm25-fallback", hit,
                      nhits, "atlas-search" if hit else None, month)
        print(f"[route: bm25-fallback] [{'HIT' if hit else 'MISS'}]")
        print(out[:4000] if out else "(atlas-search returned nothing)")


def cmd_usage(_args):
    led = Ledger()
    led.init()
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    for metric, cap in sorted(CFG["caps"].items()):
        print(f"{metric}: {led.counter(month, metric)}/{cap} ({month})")


def cmd_misses(args):
    led = Ledger()
    led.init()
    rows = led.run([("SELECT ts, asker, question, route FROM queries "
                     "WHERE hit=0 ORDER BY id DESC LIMIT ?", [args.limit])])[0]
    for r in rows:
        print(f"{r['ts']}  [{r['route']}]  {r['asker']}: {r['question']}")
    print(f"({len(rows)} miss(es))")


def main():
    import argparse
    ap = argparse.ArgumentParser(prog="ask-ledger")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pe = sub.add_parser("export")
    pe.add_argument("--force", action="store_true")
    pe.set_defaults(fn=cmd_export)
    pa = sub.add_parser("ask")
    pa.add_argument("question")
    pa.add_argument("--asker", default=os.environ.get("USER", "cli"))
    pa.add_argument("--fulltext", action="store_true")
    pa.set_defaults(fn=cmd_ask)
    pu = sub.add_parser("usage")
    pu.set_defaults(fn=cmd_usage)
    pm = sub.add_parser("misses")
    pm.add_argument("--limit", type=int, default=20)
    pm.set_defaults(fn=cmd_misses)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
