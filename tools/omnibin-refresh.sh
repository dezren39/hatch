#!/bin/bash
# ~/tools/omnibin-refresh.sh — explicit maintenance: update the pinned
# omnibin flake input used by dispatcher.sh.
#
# This is the ONLY thing that changes ~/tools/dispatcher/omnibin/flake.lock.
# The dispatcher never refreshes on a cache miss; run this manually when
# you want a newer omnibin/index.
set -u
FLAKE_DIR=/home/hatch/tools/dispatcher/omnibin
NIXBIN=/nix/var/nix/profiles/per-user/root/profile/bin/nix
SHIM=/home/hatch/tools/taint-shim/taint_shim.so

[ -f "$FLAKE_DIR/flake.nix" ] || { echo "omnibin flake missing: $FLAKE_DIR" >&2; exit 1; }
old=$(LD_PRELOAD="$SHIM" "$NIXBIN" flake metadata --json "$FLAKE_DIR" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['locks']['nodes']['omnibin']['locked']['rev'])")
# Update only the omnibin input (keeps the nixpkgs follows).
LD_PRELOAD="$SHIM" "$NIXBIN" flake update --flake "$FLAKE_DIR" omnibin 2>&1 | tail -3
# The flake lives in the /home/hatch git repo: stage the lock so the
# path flake keeps working (nix ignores untracked files).
git -C /home/hatch add "$FLAKE_DIR/flake.lock" 2>/dev/null || true
new=$(LD_PRELOAD="$SHIM" "$NIXBIN" flake metadata --json "$FLAKE_DIR" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['locks']['nodes']['omnibin']['locked']['rev'])")
[ -n "$new" ] || { echo "omnibin-refresh: could not resolve flake" >&2; exit 1; }
if [ "$new" = "$old" ]; then
  echo "omnibin input already current: $old"
else
  echo "omnibin input updated: $old -> $new"
  echo "note: cached resolutions in $FLAKE_DIR/../cache are still valid;"
  echo "they are keyed by name[@version], not by the pin."
fi
