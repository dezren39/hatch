#!/usr/bin/env python3
"""fleet-fetch.py — deterministic repo snapshot fetcher (Phase B part 1).

For each fleet repo: `git fetch` the canonical local clone (FETCH ONLY —
never pull/checkout/reset), pull current state via `gh api`, and upsert a
row into agent.repo_snapshots in Supabase muse-dev. One agent.events row
per run (worker_id 'fleet-fetcher', kind 'snapshot_refresh') plus
watermarks. Zero agent tokens: pure script, run by fleet-fetch.timer.

Writes go through ~/tools/supabase-exec.py (temp .sql files). Failure of
one repo never fails the others; exit is non-zero only if ALL repos fail.
"""
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
SUPABASE_EXEC = os.path.join(HOME, "tools", "supabase-exec.py")
LOG_FILE = os.path.join(HOME, "logs", "fleet-fetch.log")
SQL_TMPDIR = os.path.join(HOME, "tmp")  # /tmp is a small tmpfs on this box

# repo slug -> preferred clone paths (relative to $HOME), checked in order.
REPOS = {
    "developing-today/code": ["git/fleet/code", "git/devtoday-code"],
    "developing-today/opencode": ["git/fleet/opencode", "git/devtoday-opencode"],
    "developing-today/openchamber": ["git/fleet/openchamber",
                                     "git/devtoday-openchamber"],
    "dezren39/nix": ["git/fleet/nix", "git/devtoday-nix", "git/nix"],
}
NIX_REPO = "dezren39/nix"
UPSTREAM_WATERMARK_KEY = "upstream:nixpkgs-unstable"
CAP = 100


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def q(value):
    """SQL string literal with '' escaping (NULL for None)."""
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def jb(obj):
    """SQL jsonb literal."""
    return q(json.dumps(obj)) + "::jsonb"


def run(cmd, timeout=120, env_extra=None):
    env = dict(os.environ)
    env["TMPDIR"] = SQL_TMPDIR  # keep children off the small /tmp tmpfs
    if env_extra:
        env.update(env_extra)
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, env=env)


def gh_api(path):
    last_err = None
    for attempt in range(2):  # one retry: the egress proxy flakes transiently
        try:
            out = run(["gh", "api", path], timeout=120)
            if out.returncode == 0:
                return json.loads(out.stdout)
            last_err = out.stderr.strip()[:300]
        except Exception as exc:
            last_err = str(exc)[:300]
        if attempt == 0:
            import time
            time.sleep(5)
    raise RuntimeError(f"gh api {path}: {last_err}")


def normalize_remote(url):
    url = (url or "").strip()
    for prefix in ("https://github.com/", "http://github.com/",
                   "git@github.com:", "ssh://git@github.com/"):
        if url.startswith(prefix):
            url = url[len(prefix):]
            break
    if url.endswith(".git"):
        url = url[:-4]
    return url.rstrip("/").lower()


def find_clone(repo):
    """Return (path, remotes dict) for the first preferred clone whose
    origin remote matches the repo slug, else (None, {})."""
    for rel in REPOS[repo]:
        path = os.path.join(HOME, rel)
        if not os.path.isdir(path):
            continue
        try:
            out = run(["git", "-C", path, "remote"], timeout=30)
            if out.returncode != 0:
                continue
            remotes = {}
            for name in out.stdout.split():
                u = run(["git", "-C", path, "remote", "get-url", name],
                        timeout=30)
                if u.returncode == 0:
                    remotes[name] = u.stdout.strip()
            if normalize_remote(remotes.get("origin", "")) == repo.lower():
                return path, remotes
        except Exception:
            continue
    return None, {}


def git_fetch(clone, remote):
    out = run(["git", "-C", clone, "fetch", "--quiet", remote], timeout=300)
    if out.returncode != 0:
        raise RuntimeError(f"git fetch {remote}: {out.stderr.strip()[:300]}")


def git_rev_parse(clone, ref):
    out = run(["git", "-C", clone, "rev-parse", ref], timeout=30)
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def fetch_repo(repo):
    """Gather one repo's snapshot. Returns (snapshot dict, notes list).
    Raises on hard failure of the gh side."""
    notes = []
    clone, remotes = find_clone(repo)
    if clone is None:
        notes.append("no local clone found; git fetch skipped")
    else:
        git_fetch(clone, "origin")
        notes.append(f"git fetch origin ok ({clone})")
        if repo == NIX_REPO and "upstream" in remotes:
            git_fetch(clone, "upstream")
            notes.append("git fetch upstream ok")

    meta = gh_api(f"repos/{repo}")
    default_branch = meta.get("default_branch")

    commit = gh_api(f"repos/{repo}/commits/{default_branch}")
    head_sha = commit.get("sha")

    prs_raw = gh_api(f"repos/{repo}/pulls?state=open&per_page={CAP}")
    open_prs = [{
        "number": p["number"],
        "title": p.get("title"),
        "author": (p.get("user") or {}).get("login"),
        "head_ref": (p.get("head") or {}).get("ref"),
        "updated_at": p.get("updated_at"),
        "is_draft": bool(p.get("draft")),
    } for p in prs_raw]
    pr_count = gh_api(
        f"search/issues?q=repo:{repo}+type:pr+state:open&per_page=1"
    )["total_count"]

    issues_raw = gh_api(f"repos/{repo}/issues?state=open&per_page={CAP}")
    open_issues = [{
        "number": i["number"],
        "title": i.get("title"),
        "labels": [l.get("name") for l in i.get("labels", [])],
        "updated_at": i.get("updated_at"),
    } for i in issues_raw if "pull_request" not in i]
    issue_count = gh_api(
        f"search/issues?q=repo:{repo}+type:issue+state:open&per_page=1"
    )["total_count"]

    runs_raw = gh_api(f"repos/{repo}/actions/runs?per_page=10")
    ci_summary = {"runs": [{
        "name": r.get("name"),
        "status": r.get("status"),
        "conclusion": r.get("conclusion"),
        "updated_at": r.get("updated_at"),
    } for r in runs_raw.get("workflow_runs", [])]}

    snapshot = {
        "repo": repo,
        "head_sha": head_sha,
        "default_branch": default_branch,
        "open_prs": open_prs,
        "open_issues": open_issues,
        "open_pr_count": pr_count,
        "open_issue_count": issue_count,
        "ci_summary": ci_summary,
    }

    if repo == NIX_REPO and clone and "upstream" in remotes:
        sha = (git_rev_parse(clone, "upstream/nixpkgs-unstable")
               or git_rev_parse(clone, "upstream/HEAD"))
        if sha:
            snapshot["_upstream_sha"] = sha

    return snapshot, notes


def write_sql(statements):
    os.makedirs(SQL_TMPDIR, exist_ok=True)
    fd, path = tempfile.mkstemp(suffix=".sql", dir=SQL_TMPDIR)
    try:
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(statements) + "\n")
        out = run([sys.executable, SUPABASE_EXEC, path], timeout=180)
        if out.returncode != 0:
            raise RuntimeError(
                f"supabase-exec failed: {out.stderr.strip()[:300]} "
                f"{out.stdout.strip()[:300]}")
    finally:
        os.unlink(path)


def snapshot_statements(repo, snap, started):
    stmts = [
        "insert into agent.repo_snapshots (repo, head_sha, default_branch,"
        " open_prs, open_issues, open_pr_count, open_issue_count,"
        " ci_summary, fetched_at, fetch_source) values ("
        f"{q(repo)}, {q(snap['head_sha'])}, {q(snap['default_branch'])}, "
        f"{jb(snap['open_prs'])}, {jb(snap['open_issues'])}, "
        f"{snap['open_pr_count']}, {snap['open_issue_count']}, "
        f"{jb(snap['ci_summary'])}, now(), 'fetcher')"
        " on conflict (repo) do update set"
        " head_sha = excluded.head_sha,"
        " default_branch = excluded.default_branch,"
        " open_prs = excluded.open_prs,"
        " open_issues = excluded.open_issues,"
        " open_pr_count = excluded.open_pr_count,"
        " open_issue_count = excluded.open_issue_count,"
        " ci_summary = excluded.ci_summary,"
        " fetched_at = now(), fetch_source = 'fetcher';"
    ]
    if snap.get("_upstream_sha"):
        stmts.append(
            "insert into agent.watermarks (key, value, updated_at) values ("
            f"{q(UPSTREAM_WATERMARK_KEY)}, "
            f"{jb({'sha': snap['_upstream_sha'], 'repo': repo, 'fetched_at': started})}, "
            "now()) on conflict (key) do update set"
            " value = excluded.value, updated_at = now();"
        )
    return stmts


def main():
    from concurrent.futures import ThreadPoolExecutor

    started = now_iso()
    results = {}   # repo -> {"ok": bool, ...}
    snapshots = {}

    # Fetch all repos in parallel (subprocess-bound work); one repo's
    # failure never fails the others.
    with ThreadPoolExecutor(max_workers=len(REPOS)) as pool:
        futures = {pool.submit(fetch_repo, repo): repo for repo in REPOS}
        for fut, repo in futures.items():
            try:
                snap, notes = fut.result()
                snapshots[repo] = snap
                results[repo] = {
                    "ok": True,
                    "open_prs": snap["open_pr_count"],
                    "open_issues": snap["open_issue_count"],
                    "head_sha": snap["head_sha"],
                    "notes": notes,
                }
            except Exception as exc:
                results[repo] = {"ok": False, "error": str(exc)[:300]}

    # Write each snapshot in its own supabase-exec call so one bad write
    # cannot sink the repos that fetched fine.
    write_errors = []
    for repo, snap in snapshots.items():
        try:
            write_sql(snapshot_statements(repo, snap, started))
            results[repo]["write_ok"] = True
        except Exception as exc:
            results[repo]["write_ok"] = False
            write_errors.append(f"{repo}: {str(exc)[:200]}")

    ok_repos = [r for r, v in results.items() if v["ok"]]
    try:
        write_sql([
            "insert into agent.watermarks (key, value, updated_at) values ("
            f"'fetcher:last_run', {jb({'at': started, 'repos_ok': ok_repos, 'repos_failed': [r for r, v in results.items() if not v['ok']]})}, "
            "now()) on conflict (key) do update set"
            " value = excluded.value, updated_at = now();",
            "insert into agent.events (worker_id, kind, detail) values ("
            f"'fleet-fetcher', 'snapshot_refresh', {jb({'at': started, 'repos': results})});",
        ])
        db_ok = not write_errors
    except Exception as exc:
        db_ok = False
        write_errors.append(f"final: {str(exc)[:200]}")

    summary = (f"{started} fleet-fetch: "
               + " ".join(
                   f"{r}=ok(prs={v['open_prs']},issues={v['open_issues']})"
                   if v.get("ok") else f"{r}=FAIL({v.get('error', '?')[:80]})"
                   for r, v in results.items())
               + f" db_write={'ok' if db_ok else 'FAIL'}")
    if write_errors:
        summary += " write_errors=" + " | ".join(write_errors)
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(summary + "\n")
    print(summary)

    if not ok_repos:
        return 1
    return 0 if db_ok else 1


if __name__ == "__main__":
    sys.exit(main())
