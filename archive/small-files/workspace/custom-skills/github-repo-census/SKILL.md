# github-repo-census

Status: tentative, first draft 2026-10-21.

## Purpose

Produce a dated census of every GitHub repo across all of Drew's orgs/accounts, so clones, forks, and original work are distinguishable at a glance and nothing is rediscovered later.

## Method

1. Enumerate owners: `gh api user --jq .login` plus every org the account belongs to (`gh api user/orgs`). Expect dozens of orgs; do not sample.
2. Per repo (`gh api repos/{owner}/{repo}` + list endpoints), record:
   - repo name and owner
   - fork? (`fork` flag) and upstream (`parent.full_name` when a fork)
   - first commit and latest commit of the repo (date + SHA)
   - latest commit of the upstream
   - ahead/behind vs upstream (compare API)
   - counts: open issues, open PRs, discussions (if enabled), releases
   - recent workflow runs: count, success %, total minutes
   - one-paragraph description for repos with real code (read the README/tree — briefly)
3. Classify each repo explicitly: **clean clone** (even with upstream), **behind clone**, **true fork** (has own commits), or **original work**.
4. Verify a repo exists before writing anything that depends on it (`gh repo view`).

## Output rules

- The census lands in the **private repo first** (`hatch-personal/library/`), dated in the filename/header. A public version only after Drew reviews and cleans it.
- Plain text/Markdown tables that can be re-generated; record the census date and the API commands used so a later run can diff instead of restarting.
- No tokens, no private-repo contents beyond metadata counts.

## Pitfalls

- A fork with zero own commits is a clone in disguise — the ahead/behind numbers are the tell.
- Workflow minutes include failed/cancelled runs; report success % alongside the count or the minutes mislead.
