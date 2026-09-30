#!/bin/bash
# ~/tools/omnibin-refresh.sh — explicit maintenance: update the pinned
# omnibin flake revision used by dispatcher.sh.
#
# This is the ONLY thing that changes ~/tools/dispatcher/omnibin-pin.
# The dispatcher never refreshes on a cache miss; run this manually when
# you want a newer omnibin/index.
set -u
DISPATCHER_DIR=/home/hatch/tools/dispatcher
PIN_FILE=$DISPATCHER_DIR/omnibin-pin
NIXBIN=/nix/var/nix/profiles/bootstrap/bin/nix
SHIM=/home/hatch/tools/taint-shim/taint_shim.so

old=$(cat "$PIN_FILE" 2>/dev/null || echo none)
new=$(LD_PRELOAD="$SHIM" "$NIXBIN" flake metadata github:fzakaria/omnibin \
  --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['revision'])")
[ -n "$new" ] || { echo "omnibin-refresh: could not resolve flake" >&2; exit 1; }
if [ "$new" = "$old" ]; then
  echo "omnibin pin already current: $old"
else
  printf '%s' "$new" > "$PIN_FILE"
  echo "omnibin pin updated: $old -> $new"
  echo "note: cached resolutions in $DISPATCHER_DIR/cache are still valid;"
  echo "they are keyed by name[@version], not by the pin."
fi
