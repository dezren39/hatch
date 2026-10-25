#!/usr/bin/env python3
"""Restore an `api`-transport backup (.api.jsonl.zst/.gz) into SQL files.

Reads the streamed JSONL records and writes, into the output directory:
  schema.sql — the bundled migrations if present (authoritative), else the
               generated DDL record
  data.sql   — INSERT statements for every table's rows + sequence setvals
Apply with psql (or supabase-exec.py) against the target database:
  psql "$TARGET" -f schema.sql && psql "$TARGET" -f data.sql
This tool only writes local files; it never touches a database itself.

Usage: restore_api.py <backup-file> <output-dir>
"""
import gzip
import json
import os
import subprocess
import sys


def open_stream(path):
    if path.endswith(".zst"):
        p = subprocess.Popen(["zstd", "-d", "-c", path], stdout=subprocess.PIPE)
        return p.stdout
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    return open(path, "rb")


def sql_literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (dict, list)):
        s = json.dumps(v, separators=(",", ":"))
        return "'" + s.replace("'", "''") + "'::jsonb"
    return "'" + str(v).replace("'", "''") + "'"


def qident(name):
    return '"' + name.replace('"', '""') + '"'


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    migrations, ddl = {}, None
    tables, sequences = {}, []
    stream = open_stream(src)
    for line in stream:
        if not line.strip():
            continue
        rec = json.loads(line)
        t = rec["type"]
        if t == "migrations":
            migrations = rec["files"]
        elif t == "schema_sql":
            ddl = rec["sql"]
        elif t == "table":
            tables[(rec["schema"], rec["table"])] = {
                "columns": rec["columns"], "rows": []}
        elif t == "rows":
            tables[(rec["schema"], rec["table"])]["rows"].extend(rec["rows"])
        elif t == "sequence":
            sequences.append(rec)

    with open(os.path.join(outdir, "schema.sql"), "w") as f:
        if migrations:
            for name in sorted(migrations):
                f.write(f"-- migration: {name}\n{migrations[name]}\n")
        elif ddl:
            f.write(ddl + "\n")
        else:
            f.write("-- no schema records found in backup\n")

    n_rows = 0
    with open(os.path.join(outdir, "data.sql"), "w") as f:
        for (schema, table), info in tables.items():
            cols = info["columns"]
            collist = ", ".join(qident(c) for c in cols)
            for row in info["rows"]:
                vals = ", ".join(sql_literal(row.get(c)) for c in cols)
                f.write(f"INSERT INTO {qident(schema)}.{qident(table)} "
                        f"({collist}) VALUES ({vals}) "
                        f"ON CONFLICT DO NOTHING;\n")
                n_rows += 1
        for s in sequences:
            f.write(f"SELECT setval('{qident(s['schema'])}.{qident(s['name'])}', "
                    f"{s['value']});\n")
    print(json.dumps({"tables": len(tables), "rows": n_rows,
                      "sequences": len(sequences),
                      "schema_source": "migrations" if migrations else "ddl",
                      "outdir": outdir}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
