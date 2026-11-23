#!/bin/bash
# resolve-bin.sh — shared binary resolution by TEST EXECUTION.
#
# A candidate binary counts only if it actually runs. A Nix
# dynamically-linked binary whose ELF interpreter is absent in the
# sandbox lists as executable (`test -x` passes) but every exec
# fails with ENOENT ("required file not found"), so selecting on -x
# alone pins callers to a dead binary and the fallbacks never
# trigger (developing-today/code#12498).
#
# resolve_test_exec CANDIDATE... runs `<candidate> --version` and
# prints the first candidate that exits 0, preserving the caller's
# fallback order. It prints nothing and returns 1 when no candidate
# runs.
#
# Sourced by init-ensure.sh and gh-shim.sh; exercised directly by
# tools/test-resolve-bin.sh.
resolve_test_exec() {
  local cand
  for cand in "$@"; do
    if [ -x "$cand" ] && timeout 10 "$cand" --version >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}
