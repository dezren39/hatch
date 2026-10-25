#!/usr/bin/env bash
# restore-workspace-links.sh — recreate the workspace symlink layer.
#
# Canonical content lives in ~/hatch-personal (private repo); ~/workspace
# entries are absolute symlinks into it (pattern established 2026-09-30 for
# goals/ + user/, extended 2026-10-25 to 27 more trees plus the supabase
# private-only subsets and the archer-slack puller state dir).
#
# init.sh's PERSONAL_LINKS guard covers the root personal files and
# workspace/goals + workspace/user. THIS script covers the workspace set
# below. It is idempotent and quiet when every link is correct: it prints
# one line per repair and exits non-zero only if something is broken and
# cannot be repaired. A real file/dir found where a link belongs is never
# clobbered: a newer real FILE is synced into the repo first, then the
# real path is moved aside to hatch-personal/.desync-backup/ and linked
# (same convention as init.sh's guard).
#
# Run after a fresh clone of hatch-personal or whenever links look wrong.
set -u
PERSONAL_REPO=/home/hatch/hatch-personal
WS=/home/hatch/workspace
STAMP=$(date +%Y%m%d-%H%M%S)
rc=0

if [ ! -d "$PERSONAL_REPO/.git" ]; then
  echo "restore-workspace-links: $PERSONAL_REPO is not a git checkout — aborting" >&2
  exit 1
fi

# rel-path-under-workspace  (target is $PERSONAL_REPO/workspace/<rel>)
LINKS="
agent-inbox ai-subscriptions browser_downloads cloudflare
context-diet-2026-10-24 cron.d custom-connectors custom-skills duns-docs
email feature-request feed general-board google google-drive-cold-store
library-build objectives onboarding_tour opencode-research play-upload
profile-images research_notes self_improvement ts-spaces visual_grounding
webhook-gateway your_files
supabase/ainventory-import/sheets supabase/ainventory-import/source
supabase/ainventory-import/SOURCE_SUMMARY.json
supabase/muse-dev/backup/config.json
archer-slack/puller/state
"

for rel in $LINKS; do
  link="$WS/$rel"
  target="$PERSONAL_REPO/workspace/$rel"
  if [ -L "$link" ]; then
    if [ "$(readlink "$link")" != "$target" ]; then
      ln -sfn "$target" "$link"
      echo "re-pointed: workspace/$rel"
    elif [ ! -e "$target" ]; then
      echo "DANGLING: workspace/$rel — target missing from repo" >&2
      rc=1
    fi
    continue
  fi
  if [ ! -e "$target" ]; then
    echo "BROKEN: workspace/$rel — repo target $target missing, cannot repair" >&2
    rc=1
    continue
  fi
  if [ -e "$link" ]; then
    mkdir -p "$PERSONAL_REPO/.desync-backup"
    if [ -f "$link" ] && [ -f "$target" ] && [ "$link" -nt "$target" ]; then
      cp -p "$link" "$target"
      echo "synced newer real file into repo: workspace/$rel"
    fi
    mv "$link" "$PERSONAL_REPO/.desync-backup/$(printf '%s' "$rel" | tr '/' '_').$STAMP"
    echo "moved real path aside to .desync-backup, re-linking: workspace/$rel"
  else
    echo "re-created missing link: workspace/$rel"
  fi
  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
done

exit $rc
