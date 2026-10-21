#!/usr/bin/env bash
# link-submodules.sh — materialize a registered submodule on demand.
#
# Submodules under repos/ in dezren39/hatch are a REGISTRY, not checked-out
# working trees (see library/submodules.md). This script clones one named
# submodule shallow, in place under repos/, and symlinks it to its usual
# working location if a mapping exists in the table below.
#
# Usage: scripts/link-submodules.sh <name> [<name> ...]
#   e.g. scripts/link-submodules.sh nix code
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

for name in "$@"; do
  path="repos/$name"
  if [ ! -e "$REPO_ROOT/$path/.git" ] && [ ! -f "$REPO_ROOT/$path/.git" ]; then
    # Shallow, single-submodule clone at the recorded gitlink SHA.
    git -C "$REPO_ROOT" submodule update --init --depth 1 -- "$path"
  else
    echo "$name: already materialized at $path"
  fi

  target="${WORKDIR[$name]:-}"
  if [ -n "$target" ]; then
    if [ -e "$target" ] || [ -L "$target" ]; then
      echo "$name: working location $target already exists — leaving it alone"
    else
      mkdir -p "$(dirname "$target")"
      ln -s "$REPO_ROOT/$path" "$target"
      echo "$name: $target -> $path"
    fi
  fi
done
