#!/bin/bash
# produce-charge-candidates-scheduled.sh — unattended runner for the
# fleet-feed charge candidates producer (developing-today/code#2205).
#
# Runs pm-stack/aggregator/scripts/produce-charge-candidates.ts from the
# sandbox checkout ~/git/devtoday-code (kept on main; ff-pull attempted
# first, fail-soft). The producer itself shells out to the sandbox
# connector CLIs (/opt/hatch/bin/plaid, /opt/hatch/bin/hatch_gws_cli) —
# that is why it runs on the sandbox and not on the laptop, where the
# fleet-feed collector consumes the file every ~5 minutes.
#
# Every run appends one JSON line to the run log below — success or
# failure — so a stale or failing producer is visible to monitors
# instead of failing soft and silent (code#2205 acceptance).
set -u
export HOME=/home/hatch
REPO=/home/hatch/git/devtoday-code
OUT=/home/hatch/workspace/goals/keep-the-four-repos-healthy/hidden_files/charges-candidates.json
RUNLOG=/home/hatch/workspace/goals/keep-the-four-repos-healthy/hidden_files/charges-producer-runs.jsonl
BUN=/opt/hatch-image/bin/bun

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git -C "$REPO" pull --ff-only --quiet 2>/dev/null || true
cd "$REPO/pm-stack/aggregator" || { echo "{\"at\":\"$ts\",\"status\":\"failed\",\"error\":\"cd failed\"}" >> "$RUNLOG"; exit 1; }

if output=$("$BUN" run scripts/produce-charge-candidates.ts 2>&1); then
  gen=$(python3 -c "import json;print(json.load(open('$OUT'))['generatedAt'])" 2>/dev/null || echo unknown)
  count=$(python3 -c "import json;print(len(json.load(open('$OUT'))['candidates']))" 2>/dev/null || echo unknown)
  echo "{\"at\":\"$ts\",\"status\":\"ok\",\"generatedAt\":\"$gen\",\"candidates\":$count}" >> "$RUNLOG"
  echo "$output"
else
  esc=$(printf '%s' "$output" | tail -c 300 | python3 -c "import json,sys;print(json.dumps(sys.stdin.read()))")
  echo "{\"at\":\"$ts\",\"status\":\"failed\",\"error\":$esc}" >> "$RUNLOG"
  echo "$output" >&2
  exit 1
fi
