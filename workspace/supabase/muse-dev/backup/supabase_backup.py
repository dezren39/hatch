#!/usr/bin/env python3
"""Content-addressed streaming backup of the Supabase `muse-dev` Postgres DB.

Two transports (config "transport"):
  pgdump — pg_dump via the session pooler. Full fidelity. For machines with
           normal outbound TCP (Drew's laptop). Sandbox cannot use it: its
           egress is an HTTP proxy that will not tunnel port 5432.
  api    — schema + data export through the Supabase Management API (HTTPS).
           Streamed as newline-delimited JSON records (migrations bundle,
           best-effort generated DDL, per-table row batches, sequence values).
           Restore with restore_api.py. This is what the sandbox schedule runs.

Pipeline (dump bytes never touch local disk):
    source -> zstd/gzip subprocess -> SHA-256 while streaming
    -> S3 multipart upload to a staging key in Cloudflare R2
    -> copied to its content-addressed key
       pg/<project>/<yyyy>/<mm>/<sha256>.<ext>
       If that hash already exists, the upload is aborted (dedupe).
    -> pg/<project>/manifest.json updated.

Secrets come from Bitwarden Secrets Manager (`bws`) by name, or from env vars
(SUPABASE_DB_PASSWORD / SUPABASE_ACCESS_TOKEN / R2_ACCESS_KEY_ID /
R2_SECRET_ACCESS_KEY) when set.

Usage: supabase_backup.py [--if-due] [--list]
Exit 0 on success (incl. not-due and dedupe-hit), 1 on failure.
"""
import hashlib
import hmac
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
import urllib.parse
import uuid
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PART_SIZE = 8 * 1024 * 1024
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"


def load_config():
    with open(os.path.join(HERE, "config.json")) as f:
        cfg = json.load(f)
    if os.environ.get("BACKUP_INTERVAL_HOURS"):
        cfg["interval_hours"] = float(os.environ["BACKUP_INTERVAL_HOURS"])
    if os.environ.get("BACKUP_TRANSPORT"):
        cfg["transport"] = os.environ["BACKUP_TRANSPORT"]
    return cfg


# ---------- secrets ----------
_bws_cache = {}

# `bws` lives in ~/tools/bin, which scheduler/cron environments often do
# not have on PATH (the 2026-10-25 backup failures: bare "bws" not found).
# Resolve it robustly, following the PG_DUMP_BIN override convention used
# for pg_dump below: $BWS_BIN wins, then PATH, then the known install path.
BWS_FALLBACK = os.path.expanduser("~/tools/bin/bws")


def bws_bin():
    env_bin = os.environ.get("BWS_BIN")
    if env_bin:
        return env_bin
    found = shutil.which("bws")
    if found:
        return found
    if os.path.isfile(BWS_FALLBACK) and os.access(BWS_FALLBACK, os.X_OK):
        return BWS_FALLBACK
    return "bws"  # let subprocess raise a clear FileNotFoundError


def bws_secret(name):
    if name in _bws_cache:
        return _bws_cache[name]
    last_err = None
    for attempt in range(4):
        try:
            out = subprocess.run([bws_bin(), "secret", "list", "-o", "json"],
                                 capture_output=True, text=True, check=True).stdout
            sid = next(s["id"] for s in json.loads(out) if s["key"] == name)
            time.sleep(1.0)  # bws rate-limits rapid calls (429s seen live)
            out = subprocess.run([bws_bin(), "secret", "get", sid, "-o", "json"],
                                 capture_output=True, text=True, check=True).stdout
            val = json.loads(out)["value"]
            _bws_cache[name] = val
            return val
        except Exception as e:
            last_err = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"bws fetch failed for {name}: {last_err}")


def get_secret(env_name, bws_name):
    return os.environ.get(env_name) or bws_secret(bws_name)


# ---------- minimal S3 (SigV4, path-style) ----------
class S3:
    def __init__(self, endpoint, bucket, access_key, secret_key, region="auto"):
        self.endpoint = endpoint.rstrip("/")
        self.bucket = bucket
        self.ak = access_key
        self.sk = secret_key
        self.region = region

    def _sign(self, method, key, body, extra_headers=None, query=""):
        now = datetime.now(timezone.utc)
        amzdate = now.strftime("%Y%m%dT%H%M%SZ")
        datestamp = now.strftime("%Y%m%d")
        payload_hash = hashlib.sha256(body).hexdigest()
        host = self.endpoint.split("://", 1)[1]
        headers = {"host": host, "x-amz-content-sha256": payload_hash,
                   "x-amz-date": amzdate}
        if extra_headers:
            # SigV4 canonical form requires lowercase header names; a
            # mixed-case "Content-Type" here silently breaks signatures
            # (found the hard way against R2, 2026-10-21)
            headers.update({k.lower(): v for k, v in extra_headers.items()})
        signed = ";".join(sorted(headers))
        canon_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
        uri = f"/{self.bucket}/{key}"
        if query:
            pairs = []
            for part in query.split("&"):
                if "=" in part:
                    k, v = part.split("=", 1)
                else:
                    k, v = part, ""
                pairs.append((urllib.parse.quote(k, safe=""),
                              urllib.parse.quote(v, safe="-_~")))
            canon_query = "&".join(f"{k}={v}" for k, v in sorted(pairs))
        else:
            canon_query = ""
        canon_req = "\n".join([method, uri, canon_query, canon_headers,
                               signed, payload_hash])
        # the wire URL must carry the SAME percent-encoding as the canonical
        # query, or ids containing +/= break the signature server-side
        scope = f"{datestamp}/{self.region}/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope,
                             hashlib.sha256(canon_req.encode()).hexdigest()])

        def H(k, m):
            return hmac.new(k, m.encode(), hashlib.sha256).digest()
        k = H(H(H(H(("AWS4" + self.sk).encode(), datestamp), self.region), "s3"),
              "aws4_request")
        sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
        headers["Authorization"] = (
            f"AWS4-HMAC-SHA256 Credential={self.ak}/{scope}, "
            f"SignedHeaders={signed}, Signature={sig}")
        url = f"{self.endpoint}{uri}"
        if canon_query:
            url += "?" + canon_query
        return url, headers

    def request(self, method, key, body=b"", headers=None, query=""):
        attempts = 4 if method in ("GET", "HEAD", "PUT", "DELETE") else 2
        last = None
        for attempt in range(attempts):
            url, hdrs = self._sign(method, key, body, headers, query)
            req = urllib.request.Request(
                url, data=body if method in ("PUT", "POST") else None,
                headers={**hdrs, "User-Agent": UA}, method=method)
            try:
                with urllib.request.urlopen(req, timeout=300) as resp:
                    return resp.status, dict(resp.headers), resp.read()
            except urllib.error.HTTPError as e:
                result = (e.code, dict(e.headers), e.read())
                if e.code < 500 and e.code != 429:
                    return result
                last = result
            except Exception as e:  # proxy drops / resets: retry idempotent ops
                last = e
            time.sleep(2 * (attempt + 1))
        if isinstance(last, tuple):
            return last
        if method == "GET":
            # urllib downloads through some proxies truncate chunked bodies
            # (IncompleteRead); curl is the proven transport — replay the
            # signed request with it.
            url, hdrs = self._sign(method, key, body, headers, query)
            args = ["curl", "-s", "-A", UA]
            for hk, hv in hdrs.items():
                args += ["-H", f"{hk}: {hv}"]
            args.append(url)
            p = subprocess.run(args, capture_output=True)
            if p.returncode == 0 and p.stdout:
                return 200, {}, p.stdout
        raise RuntimeError(f"S3 {method} {key} failed after retries: {last}")

    def head(self, key):
        return self.request("HEAD", key)[0] == 200

    def get(self, key):
        status, _, body = self.request("GET", key)
        return body if status == 200 else None

    def put(self, key, body, content_type="application/octet-stream"):
        status, _, resp = self.request("PUT", key, body,
                                       {"Content-Type": content_type})
        if status != 200:
            raise RuntimeError(f"PUT {key} -> {status}: {resp[:200]!r}")

    def create_multipart(self, key):
        status, _, body = self.request("POST", key, b"", query="uploads")
        if status != 200:
            raise RuntimeError(f"CreateMultipart -> {status}: {body[:200]!r}")
        return body.decode().split("<UploadId>")[1].split("</UploadId>")[0]

    def upload_part(self, key, upload_id, number, data):
        status, headers, body = self.request(
            "PUT", key, data, query=f"partNumber={number}&uploadId={upload_id}")
        if status != 200:
            raise RuntimeError(f"UploadPart {number} -> {status}: {body[:200]!r}")
        return headers.get("ETag") or headers.get("Etag")

    def complete_multipart(self, key, upload_id, parts):
        xml = "<CompleteMultipartUpload>" + "".join(
            f"<Part><PartNumber>{n}</PartNumber><ETag>{e}</ETag></Part>"
            for n, e in parts) + "</CompleteMultipartUpload>"
        status, _, body = self.request("POST", key, xml.encode(),
                                       {"Content-Type": "application/xml"},
                                       query=f"uploadId={upload_id}")
        if status != 200 or b"<Error>" in body:
            raise RuntimeError(f"CompleteMultipart -> {status}: {body[:300]!r}")

    def abort_multipart(self, key, upload_id):
        self.request("DELETE", key, query=f"uploadId={upload_id}")

    def copy(self, src_key, dst_key):
        status, _, body = self.request(
            "PUT", dst_key, b"",
            {"x-amz-copy-source": f"/{self.bucket}/{src_key}"})
        if status != 200 or b"<Error>" in body:
            raise RuntimeError(f"Copy -> {status}: {body[:300]!r}")

    def delete(self, key):
        self.request("DELETE", key)


# ---------- Supabase Management API SQL (curl transport; urllib truncates) --
def mgmt_sql(cfg, token, sql):
    payload = json.dumps({"query": sql})
    for attempt in range(4):
        p = subprocess.run(
            ["curl", "-s", "-A", UA, "-X", "POST",
             f"https://api.supabase.com/v1/projects/{cfg['project_ref']}/database/query",
             "-H", f"Authorization: Bearer {token}",
             "-H", "Content-Type: application/json", "--data-binary", "@-"],
            input=payload, capture_output=True, text=True)
        try:
            rows = json.loads(p.stdout)
            if isinstance(rows, list):
                return rows
        except Exception:
            pass
        time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Management API SQL failed: {p.stdout[:200]!r}")


def qident(name):
    return '"' + name.replace('"', '""') + '"'


# ---------- producers: write backup bytes into a pipe ----------
def produce_pgdump(cfg, wfile):
    pg = cfg["pg"]
    env = {**os.environ,
           "PGPASSWORD": get_secret("SUPABASE_DB_PASSWORD", pg["password_bws"])}
    dump = subprocess.Popen(
        [os.environ.get("PG_DUMP_BIN", "pg_dump"),
         "-h", pg["host"], "-p", str(pg["port"]), "-U", pg["user"],
         "-d", pg["dbname"], "--no-owner", "--no-privileges", "--format=plain"],
        stdout=subprocess.PIPE, env=env)
    while True:
        chunk = dump.stdout.read(1024 * 1024)
        if not chunk:
            break
        wfile.write(chunk)
    if dump.wait() != 0:
        raise RuntimeError("pg_dump exited non-zero")


DDL_SQL = r"""
WITH obj AS (
  SELECT 1 ord, '-- extensions' t, string_agg('CREATE EXTENSION IF NOT EXISTS ' || quote_ident(extname) || ';', E'\n') AS s
    FROM pg_extension WHERE extname <> 'plpgsql'
  UNION ALL SELECT 2, '-- schemas', string_agg('CREATE SCHEMA IF NOT EXISTS ' || quote_ident(nspname) || ';', E'\n')
    FROM pg_namespace WHERE nspname = ANY($SCHEMAS$)
  UNION ALL SELECT 3, '-- sequences', string_agg('CREATE SEQUENCE IF NOT EXISTS ' || quote_ident(nspname) || '.' || quote_ident(relname) || ';', E'\n')
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S' AND n.nspname = ANY($SCHEMAS$)
  UNION ALL SELECT 4, '-- tables', string_agg(stmt, E'\n')
    FROM (SELECT 'CREATE TABLE IF NOT EXISTS ' || quote_ident(table_schema) || '.' || quote_ident(table_name) || ' (' ||
            (SELECT string_agg(coldef, ', ') FROM (
               SELECT quote_ident(column_name) || ' ' || data_type ||
                 CASE WHEN character_maximum_length IS NOT NULL AND data_type IN ('character varying','character')
                      THEN '(' || character_maximum_length || ')' ELSE '' END ||
                 CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END ||
                 CASE WHEN column_default IS NOT NULL THEN ' DEFAULT ' || column_default ELSE '' END AS coldef
               FROM information_schema.columns c
               WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name
               ORDER BY ordinal_position) cols) || ');' AS stmt
          FROM information_schema.tables t
          WHERE t.table_schema = ANY($SCHEMAS$) AND t.table_type = 'BASE TABLE') x
  UNION ALL SELECT 5, '-- constraints', string_agg('ALTER TABLE ' || quote_ident(nspname) || '.' || quote_ident(relname) ||
            ' ADD CONSTRAINT ' || quote_ident(conname) || ' ' || pg_get_constraintdef(c.oid) || ';', E'\n')
    FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = ANY($SCHEMAS$)
  UNION ALL SELECT 6, '-- indexes', string_agg(indexdef || ';', E'\n')
    FROM pg_indexes i WHERE i.schemaname = ANY($SCHEMAS$)
      AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid =
        (SELECT cl.oid FROM pg_class cl JOIN pg_namespace ns ON ns.oid = cl.relnamespace
         WHERE cl.relname = i.indexname AND ns.nspname = i.schemaname))
  UNION ALL SELECT 7, '-- views', string_agg('CREATE OR REPLACE VIEW ' || quote_ident(table_schema) || '.' || quote_ident(table_name) ||
            ' AS ' || pg_get_viewdef((quote_ident(table_schema) || '.' || quote_ident(table_name))::regclass, true) || ';', E'\n')
    FROM information_schema.views WHERE table_schema = ANY($SCHEMAS$)
  UNION ALL SELECT 8, '-- functions', string_agg(pg_get_functiondef(p.oid) || ';', E'\n')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = ANY($SCHEMAS$)
  UNION ALL SELECT 9, '-- rls + policies', string_agg(stmt, E'\n') FROM (
      SELECT 'ALTER TABLE ' || quote_ident(schemaname) || '.' || quote_ident(tablename) || ' ENABLE ROW LEVEL SECURITY;' AS stmt
        FROM pg_tables WHERE schemaname = ANY($SCHEMAS$) AND rowsecurity
      UNION ALL
      SELECT 'CREATE POLICY ' || quote_ident(policyname) || ' ON ' || quote_ident(schemaname) || '.' || quote_ident(tablename) ||
             ' AS ' || permissive || ' FOR ' || cmd || ' TO ' || array_to_string(roles, ', ') ||
             CASE WHEN qual IS NOT NULL THEN ' USING (' || qual || ')' ELSE '' END ||
             CASE WHEN with_check IS NOT NULL THEN ' WITH CHECK (' || with_check || ')' ELSE '' END || ';'
        FROM pg_policies WHERE schemaname = ANY($SCHEMAS$)) pol
  UNION ALL SELECT 10, '-- triggers', string_agg(pg_get_triggerdef(oid) || ';', E'\n')
    FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN
      (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = ANY($SCHEMAS$))
)
SELECT string_agg(s, E'\n\n' ORDER BY ord) AS ddl FROM obj WHERE s IS NOT NULL;
"""


def produce_api(cfg, token, wfile):
    schemas = cfg["schemas"]
    schemas_lit = "ARRAY[" + ",".join("'" + s.replace("'", "''") + "'" for s in schemas) + "]"

    def rec(obj):
        wfile.write((json.dumps(obj, separators=(",", ":")) + "\n").encode())

    # NOTE: no timestamp in the stream — byte-identical DB state should hash
    # identically so dedupe can hit. The manifest records when each was taken.
    rec({"type": "meta", "format_version": 1, "transport": "api",
         "project_ref": cfg["project_ref"], "schemas": schemas})

    # migrations bundle = authoritative schema when the dir is available
    mig_dir = os.path.normpath(os.path.join(HERE, cfg.get("migrations_dir", "")))
    if cfg.get("migrations_dir") and os.path.isdir(mig_dir):
        files = {}
        for name in sorted(os.listdir(mig_dir)):
            if name.endswith(".sql"):
                with open(os.path.join(mig_dir, name)) as f:
                    files[name] = f.read()
        if files:
            rec({"type": "migrations", "files": files})

    ddl = mgmt_sql(cfg, token, DDL_SQL.replace("$SCHEMAS$", schemas_lit))
    if ddl and ddl[0].get("ddl"):
        rec({"type": "schema_sql", "sql": ddl[0]["ddl"]})

    tables = mgmt_sql(cfg, token,
                      "SELECT table_schema, table_name FROM information_schema.tables "
                      f"WHERE table_schema IN ({','.join(repr(s) for s in schemas)}) "
                      "AND table_type='BASE TABLE' ORDER BY 1,2")
    for t in tables:
        schema, table = t["table_schema"], t["table_name"]
        cols = mgmt_sql(cfg, token,
                        "SELECT column_name FROM information_schema.columns "
                        f"WHERE table_schema='{schema}' AND table_name='{table}' "
                        "ORDER BY ordinal_position")
        rec({"type": "table", "schema": schema, "table": table,
             "columns": [c["column_name"] for c in cols]})
        offset = 0
        while True:
            rows = mgmt_sql(cfg, token,
                            "SELECT COALESCE(json_agg(r), '[]'::json) AS rows FROM "
                            f"(SELECT row_to_json(t) AS r FROM {qident(schema)}.{qident(table)} t "
                            f"LIMIT 500 OFFSET {offset}) x")
            batch = rows[0]["rows"] if rows else []
            if isinstance(batch, str):
                batch = json.loads(batch)
            if not batch:
                break
            rec({"type": "rows", "schema": schema, "table": table, "rows": batch})
            offset += len(batch)
            if len(batch) < 500:
                break

    seqs = mgmt_sql(cfg, token,
                    "SELECT schemaname, sequencename, last_value FROM pg_sequences "
                    f"WHERE schemaname IN ({','.join(repr(s) for s in schemas)}) "
                    "AND last_value IS NOT NULL")
    for s in seqs:
        rec({"type": "sequence", "schema": s["schemaname"],
             "name": s["sequencename"], "value": s["last_value"]})
    rec({"type": "end"})


# ---------- main ----------
def compressor_cmd(name):
    if name == "zstd":
        return ["zstd", "-q", "-c", "-3"], ".zst"
    if name == "gzip":
        return ["gzip", "-c"], ".gz"
    return ["cat"], ""


def main():
    cfg = load_config()
    s3cfg = cfg["s3"]
    prefix = s3cfg["prefix"].strip("/")
    manifest_key = f"{prefix}/manifest.json"
    s3 = S3(s3cfg["endpoint"], s3cfg["bucket"],
            get_secret("R2_ACCESS_KEY_ID", s3cfg["access_key_bws"]),
            get_secret("R2_SECRET_ACCESS_KEY", s3cfg["secret_key_bws"]))

    raw = s3.get(manifest_key)
    manifest = json.loads(raw) if raw else {"backups": []}
    if "--list" in sys.argv:
        print(json.dumps(manifest, indent=2))
        return 0
    if "--if-due" in sys.argv and manifest["backups"]:
        last = max(b["created_utc"] for b in manifest["backups"])
        age_h = (datetime.now(timezone.utc)
                 - datetime.fromisoformat(last)).total_seconds() / 3600
        if age_h < cfg["interval_hours"]:
            print(json.dumps({"status": "not_due", "age_hours": round(age_h, 2),
                              "interval_hours": cfg["interval_hours"]}))
            return 0

    transport = cfg.get("transport", "pgdump")
    comp_cmd, comp_suffix = compressor_cmd(cfg.get("compressor", "zstd"))
    kind = "pgdump.sql" if transport == "pgdump" else "api.jsonl"
    staging_key = f"{prefix}/staging/{uuid.uuid4()}.{kind}{comp_suffix}"

    upload_id = s3.create_multipart(staging_key)
    comp = subprocess.Popen(comp_cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE)
    state = {"sha": hashlib.sha256(), "total": 0, "parts": [], "error": None}

    def reader():
        buf = bytearray()
        try:
            while True:
                chunk = comp.stdout.read(1024 * 1024)
                if not chunk:
                    break
                state["sha"].update(chunk)
                state["total"] += len(chunk)
                buf.extend(chunk)
                while len(buf) >= PART_SIZE:
                    part, buf = bytes(buf[:PART_SIZE]), buf[PART_SIZE:]
                    etag = s3.upload_part(staging_key, upload_id,
                                          len(state["parts"]) + 1, part)
                    state["parts"].append((len(state["parts"]) + 1, etag))
            if buf or not state["parts"]:
                etag = s3.upload_part(staging_key, upload_id,
                                      len(state["parts"]) + 1, bytes(buf))
                state["parts"].append((len(state["parts"]) + 1, etag))
        except Exception as e:
            state["error"] = e

    rt = threading.Thread(target=reader, daemon=True)
    rt.start()
    try:
        if transport == "pgdump":
            produce_pgdump(cfg, comp.stdin)
        else:
            token = get_secret("SUPABASE_ACCESS_TOKEN",
                               cfg["management_token_bws"])
            produce_api(cfg, token, comp.stdin)
        comp.stdin.close()
    except Exception as e:
        try:
            comp.stdin.close()
        except Exception:
            pass
        comp.kill()
        s3.abort_multipart(staging_key, upload_id)
        print(json.dumps({"status": "error", "error": str(e)}), file=sys.stderr)
        return 1
    rt.join()
    if comp.wait() != 0 or state["error"] is not None:
        s3.abort_multipart(staging_key, upload_id)
        print(json.dumps({"status": "error",
                          "error": str(state["error"] or "compressor failed")}),
              file=sys.stderr)
        return 1

    digest = state["sha"].hexdigest()
    now = datetime.now(timezone.utc)
    final_key = f"{prefix}/{now:%Y}/{now:%m}/{digest}.{kind}{comp_suffix}"
    if s3.head(final_key):
        s3.abort_multipart(staging_key, upload_id)
        print(json.dumps({"status": "dedupe_hit", "sha256": digest,
                          "key": final_key, "bytes": state["total"]}))
        return 0
    s3.complete_multipart(staging_key, upload_id, state["parts"])
    s3.copy(staging_key, final_key)
    s3.delete(staging_key)

    entry = {"sha256": digest, "key": final_key, "bytes": state["total"],
             "created_utc": now.isoformat(), "transport": transport,
             "compressor": cfg.get("compressor", "zstd"),
             "project_ref": cfg["project_ref"]}
    if not any(b["sha256"] == digest for b in manifest["backups"]):
        manifest["backups"].append(entry)
    manifest["backups"].sort(key=lambda b: b["created_utc"])
    s3.put(manifest_key, json.dumps(manifest, indent=2).encode(),
           "application/json")
    print(json.dumps({"status": "stored", **entry}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
