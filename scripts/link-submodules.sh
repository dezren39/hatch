#!/usr/bin/env bash
# link-submodules.sh — materialize a registered submodule on demand.
#
# Submodules under repos/ in dezren39/hatch are a REGISTRY, not checked-out
# working trees (see library/submodules.md). This script clones one named
# submodule shallow, in place under repos/, and symlinks it to its usual
# working location if a mapping exists in the table below.
#
# Usage: scripts/link-submodules.sh [--dry-run] <name> [<name> ...]
#   e.g. scripts/link-submodules.sh nix code
#   --dry-run: print what would happen (submodule update + link), change nothing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# name -> working location (empty = no standard working location; leave in place)
declare -A WORKDIR=(
  [nix]="$HOME/git/nix"
  [code]="$HOME/git/devtoday-code"
  [opencode]="$HOME/git/devtoday-opencode"
  [openchamber]="$HOME/git/devtoday-openchamber"
  [zettel-dezren39]=""
  [zettel-developing-today]=""
  [dezren39]=""
  # Note: developing-today/developing-today exists but is EMPTY (no commits),
  # so it has no gitlink yet — add it here once it has a first commit.
)

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <name> [<name> ...]" >&2
  echo "known: ${!WORKDIR[*]}" >&2
  exit 2
fi

# Validate all names up front (a typo currently fails opaquely inside git,
# mid-loop). Also accept --dry-run as the first argument.
DRY_RUN=0
if [ "$1" = "--dry-run" ]; then DRY_RUN=1; shift; fi
for name in "$@"; do
  if [ -z "${WORKDIR[$name]+x}" ]; then
    echo "unknown submodule: $name (known: ${!WORKDIR[*]})" >&2
    exit 2
  fi
done

FAILURES=0
for name in "$@"; do
  path="repos/$name"
  if [ ! -e "$REPO_ROOT/$path/.git" ] && [ ! -f "$REPO_ROOT/$path/.git" ]; then
    # Shallow, single-submodule clone at the recorded gitlink SHA.
    if [ "$DRY_RUN" = 1 ]; then
      echo "$name: would run: git submodule update --init --depth 1 -- $path"
    elif ! git -C "$REPO_ROOT" submodule update --init --depth 1 -- "$path"; then
      echo "$name: submodule update FAILED" >&2; FAILURES=$((FAILURES+1)); continue
    fi
  else
    echo "$name: already materialized at $path"
  fi

  target="${WORKDIR[$name]:-}"
  if [ -n "$target" ]; then
    if [ -e "$target" ] || [ -L "$target" ]; then
      # Classify instead of a blanket 'leaving it alone': a real git clone
      # gets its HEAD reported against the pin; anything else is a warning.
      if [ -d "$target/.git" ] || [ -f "$target/.git" ]; then
        head_sha=$(git -C "$target" rev-parse --short HEAD 2>/dev/null || echo "?")
        pin_sha=$(git -C "$REPO_ROOT" ls-files -s "$path" | awk '{print substr($2,1,7)}')
        echo "$name: working location $target is a real clone (HEAD $head_sha, pin $pin_sha) — leaving it alone"
      elif [ -L "$target" ]; then
        echo "$name: working location $target is a symlink to $(readlink "$target") — leaving it alone"
      else
        echo "$name: WARNING working location $target exists and is not a git repo — leaving it alone" >&2
      fi
    else
      if [ "$DRY_RUN" = 1 ]; then
        echo "$name: would link $target -> $REPO_ROOT/$path"
      else
        mkdir -p "$(dirname "$target")"
        ln -s "$REPO_ROOT/$path" "$target"
        echo "$name: $target -> $path"
      fi
    fi
  fi
done
if [ "$FAILURES" -gt 0 ]; then
  echo "link-submodules: $FAILURES failure(s)" >&2
  exit 1
fi
