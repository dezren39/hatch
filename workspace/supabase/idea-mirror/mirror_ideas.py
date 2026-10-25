#!/usr/bin/env python3
"""Mirror Drew's Markdown idea registers into Supabase schema `ideas`.

Source of truth stays the Markdown files; this is a refreshable mirror.
One row per ## / ### section. Upserts on dedupe_key, so re-runs are safe.
Usage: mirror_ideas.py [extra-markdown-file ...]
Default sources: the cluster idea register + the cloud ideas log.
Auth: service_role key fetched from Bitwarden at runtime; never printed.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

REF = "nltgxorqwxhgfzseiirt"
BASE = f"https://{REF}.supabase.co/rest/v1"
BWS = os.path.expanduser("~/tools/bin/bws")

DEFAULT_SOURCES = [
    ("cluster-idea-register-2026-10-20",
     os.path.expanduser("~/workspace/goals/stand-up-lab-cluster-talm-talos-cozystack-postgres-rustfs/files/idea-register-2026-10-20.md")),
    ("cloud-ideas-log",
     os.path.expanduser("~/workspace/goals/stand-up-lab-cluster-talm-talos-cozystack-postgres-rustfs/hidden_files/cloud-ideas-log.md")),
]


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


def rest(key, method, path, rows, profile="ideas", on_conflict=None):
    url = BASE + path
    if on_conflict:
        url += f"?on_conflict={on_conflict}"
    body = json.dumps(rows).encode() if rows is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers={
        "apikey": key, "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Accept-Profile": profile, "Content-Profile": profile,
        "Prefer": "resolution=merge-duplicates,return=minimal",
        "User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
        return json.loads(data) if data.strip() else []


def parse_sections(path):
    lines = open(path).read().splitlines()
    rows = []
    doc_title = ""
    cur = None  # dict(title, level, section, line, body_lines)
    section_stack = {}
    for i, line in enumerate(lines, 1):
        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            title = m.group(2).strip()
            if level == 1:
                doc_title = title
                section_stack = {1: title}
                cur = {"title": title, "level": 1, "section": title,
                       "line": i, "body": []}
                rows.append(cur)
                continue
            section_stack[level] = title
            for lv in list(section_stack):
                if lv > level:
                    del section_stack[lv]
            parent = section_stack.get(level - 1, doc_title)
            cur = {"title": title, "level": level, "section": parent,
                   "line": i, "body": []}
            rows.append(cur)
        elif cur is not None:
            cur["body"].append(line)
    out = []
    for r in rows:
        body = "\n".join(r["body"]).strip()
        out.append({"title": r["title"], "section": r["section"],
                    "body": body[:9000], "line": r["line"]})
    return doc_title, out


def main():
    key = service_role_key()
    total = 0
    for name, path in DEFAULT_SOURCES:
        doc_title, sections = parse_sections(path)
        rest(key, "POST", "/sources",
             [{"name": name, "kind": "markdown-register", "path": path,
               "note": f"Mirrored from {os.path.basename(path)}"}],
             on_conflict="name")
        got = rest(key, "GET", f"/sources?name=eq.{name}&select=id", None)
        source_id = got[0]["id"]
        rows = []
        for s in sections:
            rows.append({
                "source_id": source_id,
                "title": s["title"],
                "body": s["body"],
                "section": s["section"],
                "status": "captured",
                "source_ref": f"{os.path.basename(path)}:{s['line']}",
                "dedupe_key": f"{name}|{s['section']}|{s['title']}",
            })
        rest(key, "POST", "/ideas", rows, on_conflict="dedupe_key")
        rest(key, "PATCH", f"/sources?id=eq.{source_id}",
             [{"mirrored_at": "now()"}]) if False else None
        print(f"{name}: {len(rows)} sections mirrored (source_id={source_id})")
        total += len(rows)
    print(f"total sections: {total}")


if __name__ == "__main__":
    main()
