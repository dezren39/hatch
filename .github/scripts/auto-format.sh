#!/usr/bin/env bash
# auto-format.sh — one shfmt pass over this repo's hand-written shell
# sources: tools/, scripts/, .claude/hooks/ and .github/scripts/,
# plus the extensionless bash scripts tools/fleet-build-lock and
# tools/mem.
#
# Scope is deliberate (hatch#15, adapting the developing-today/code
# auto-format PoC, code#2015, as adapted for hatch-personal#52):
#   - archive/ is dated snapshots (2026-10-21 install scripts) —
#     historical records, never reformatted.
#   - tools/nix-installer.sh is the vendored upstream Nix installer,
#     not hand-written — excluded by name below.
#   - tools/bws-backup-secrets.sh is hand-written but shfmt cannot
#     parse it: its associative-array keys contain dots (e.g.
#     [nix-cache.upload-secret]), which shfmt's parser reads as zsh
#     floating-point arithmetic and rejects with exit 1. Excluded by
#     name below so the pass cannot fail on it every run.
#   - The rest of the tree (media, notes, reports, library) is data,
#     not shell sources.
# Python and .mjs files exist in the tree but carry no in-repo
# formatter config; scope stays shell-only, as in #52.
#
# The pass is idempotent: shfmt over already-formatted files changes
# nothing, so the scheduled workflow cannot loop on its own commits
# and needs no success-marker variable.
#
# Usage: auto-format.sh [shfmt-binary]   (default: shfmt from PATH)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SHFMT="${1:-shfmt}"

# Style flags settled in hatch-personal#52 (fleet-command runs
# 45738418879 + 45739796823, measured against that tree and adopted
# here without re-derivation): -i 2 -ci -bn (2-space indent,
# indented case branches, binary ops at line starts) is the closest
# clean fit to the fleet trees' de-facto style. (-i 2 -kp measured
# marginally fewer diff lines there but keeps column padding even
# where restructuring deforms case branches — rejected on review.)
FLAGS=(-i 2 -ci -bn)

roots=()
for d in tools scripts .claude/hooks .github/scripts; do
  if [ -d "$d" ]; then
    roots+=("$d")
  fi
done
if [ "${#roots[@]}" -eq 0 ]; then
  echo "auto-format: no source dirs found" >&2
  exit 1
fi

{
  find "${roots[@]}" -name '*.sh' -type f ! -path 'tools/nix-installer.sh' ! -path 'tools/bws-backup-secrets.sh' -print0
  for f in tools/fleet-build-lock tools/mem; do
    if [ -f "$f" ]; then
      printf '%s\0' "$f"
    fi
  done
} | sort -z | xargs -0 --no-run-if-empty "$SHFMT" "${FLAGS[@]}" -w --
