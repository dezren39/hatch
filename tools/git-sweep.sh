#!/bin/bash
# git-sweep.sh — commit + push pending work in the infra repos.
# Drew's rule (2026-10-25): everything that isn't huge belongs in git —
# prompts, scripts, logs of value. Sweeps /home/hatch + ~/hatch-personal.
# Fleet code repos under ~/git are REPORTED only (their working trees
# feed active PR workflows).
#
# What gets staged:
#  - all changes to TRACKED files (git add -u)
#  - untracked files under tools/, TOOLS.d/, workspace/, custom-skills/
#    that are <= 10 MB each (dependency trees, DBs and build junk in the
#    home-dir repo root are reported, never swept)
# Safety: skips a repo with a merge/rebase in progress; never force-pushes.
# Usage: git-sweep.sh [--dry-run]
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
MAXBYTES=10485760

sweep() {
  local repo="$1"
  [ -d "$repo/.git" ] || { echo "skip $repo (not a repo)"; return; }
  if [ -d "$repo/.git/MERGE_HEAD" ] || [ -d "$repo/.git/rebase-merge" ] || [ -d "$repo/.git/rebase-apply" ]; then
    echo "skip $repo (merge/rebase in progress)"; return
  fi
  local dirty
  dirty=$(git -C "$repo" status --porcelain | wc -l)
  [ "$dirty" -eq 0 ] && { echo "clean $repo"; return; }
  echo "$repo: $dirty changed paths"
  if [ "$DRY" -eq 1 ]; then git -C "$repo" status --short | head -20; return; fi
  git -C "$repo" add -u
  # Untracked files in content dirs, size-capped.
  git -C "$repo" ls-files --others --exclude-standard -- tools TOOLS.d workspace custom-skills 2>/dev/null \
  | while IFS= read -r f; do
      [ -f "$repo/$f" ] || continue
      sz=$(stat -c%s "$repo/$f" 2>/dev/null || echo 0)
      if [ "$sz" -le "$MAXBYTES" ]; then git -C "$repo" add -- "$f";
      else echo "  skipped (>$MAXBYTES bytes): $f"; fi
    done
  # Report untracked root-level / other-dir files we did not sweep.
  git -C "$repo" ls-files --others --exclude-standard 2>/dev/null \
    | grep -vE '^(tools|TOOLS\.d|workspace|custom-skills)/' | head -10 \
    | sed 's/^/  not swept (outside content dirs): /'
  if git -C "$repo" diff --cached --quiet; then echo "  nothing staged"; return; fi
  git -C "$repo" -c user.name='Drew' -c user.email='dezren39@gmail.com' \
    commit -q -m "sweep: $(date '+%Y-%m-%d %H:%M %Z') — commit pending work (Drew's everything-in-git rule)" \
    && git -C "$repo" push -q origin main \
    && echo "  committed + pushed $(git -C "$repo" rev-parse --short HEAD)"
}

sweep /home/hatch
sweep /home/hatch/hatch-personal

for repo in /home/hatch/git/*/; do
  [ -d "$repo/.git" ] || continue
  n=$(git -C "$repo" status --porcelain | wc -l)
  [ "$n" -gt 0 ] && echo "report-only $repo: $n changed paths (fleet repo — not swept)"
done
exit 0
