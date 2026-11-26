#!/bin/bash
# test-resolve-bin.sh — regression test for test-exec binary
# resolution (developing-today/code#12498).
#
# Plants the candidate shapes the sandbox actually produces — a
# present-but-unexecutable binary (bad ELF interpreter: passes -x,
# every exec fails ENOENT), a binary that runs but exits non-zero,
# and a working binary — and asserts resolve_test_exec skips the
# first two and selects the third, preserving candidate order. Also
# asserts no bare `-x` fleet gate remains in the two callers.
set -u
cd "$(dirname "$0")"
. ./resolve-bin.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected [$2] got [$3]"
    fail=1
  fi
}

# 1. Present but unexecutable: +x file with a nonexistent interpreter.
printf '#!/nonexistent/interpreter\n' >"$TMP/fleet-dead"
chmod +x "$TMP/fleet-dead"
[ -x "$TMP/fleet-dead" ] || {
  echo "FAIL: fixture fleet-dead is not -x"
  fail=1
}
if "$TMP/fleet-dead" --version >/dev/null 2>&1; then
  echo "FAIL: fixture fleet-dead unexpectedly executes"
  fail=1
fi

# 2. Executes but exits non-zero on --version.
printf '#!/bin/sh\nexit 1\n' >"$TMP/fleet-broken"
chmod +x "$TMP/fleet-broken"

# 3. Working binary.
printf '#!/bin/sh\necho testbin 1.0.0\n' >"$TMP/fleet-good"
chmod +x "$TMP/fleet-good"

got=$(resolve_test_exec "$TMP/fleet-dead" "$TMP/fleet-broken" "$TMP/fleet-good" || true)
check "skips dead + broken, picks working" "$TMP/fleet-good" "$got"

got=$(resolve_test_exec "$TMP/fleet-good" "$TMP/fleet-broken" || true)
check "preserves candidate order" "$TMP/fleet-good" "$got"

if resolve_test_exec "$TMP/fleet-dead" "$TMP/fleet-broken" >/dev/null 2>&1; then
  echo "FAIL: expected failure when no candidate runs"
  fail=1
else
  echo "ok: fails when no candidate runs"
fi

if resolve_test_exec "$TMP/does-not-exist" >/dev/null 2>&1; then
  echo "FAIL: expected failure for missing candidate"
  fail=1
else
  echo "ok: fails for missing candidate"
fi

# The callers must actually use the helper: no bare -x fleet gates left.
if grep -n '\[ -x /home/hatch/tools/fleet \]' ./init-ensure.sh ./gh-shim.sh >/dev/null; then
  echo "FAIL: a bare -x fleet gate remains"
  fail=1
else
  echo "ok: no bare -x fleet gates remain"
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
