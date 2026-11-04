#!/bin/bash
# rustdesk-gl/auth.sh — submit the laptop RustDesk permanent password to the
# already-open "Password required" dialog on DISPLAY :99.
#
# Method (proven 2026-11-04): the value is fetched from Bitwarden Secrets
# Manager at runtime (key: rustdesk.amd-6-password) and PASTED via the X
# clipboard (xclip reads it from stdin; Ctrl+V in the field). Paste is
# byte-exact — xdotool `type` depends on the Xvfb keymap for symbol chars.
# The value never appears in argv, in any file, or on stdout (only its
# length is echoed). Verify the field shows exactly ${#PW} dots before OK:
#   import -window root /tmp/rd-check.png
#   convert /tmp/rd-check.png -crop 260x36+940+702 -resize 300% /tmp/rd-dots.png
#
# KNOWN STATE (2026-11-04): the vault value was REJECTED 4 times by the
# laptop service — typed x2, pasted byte-exact x2, once after restarting the
# laptop's rustdesk.service so it re-read its config (written 05:49:59, 16s
# after that service start). Dot count verified = 24 = secret length every
# time. Conclusion: the vault entry does NOT match the permanent password
# currently configured on the laptop. Do not burn more attempts until the
# credential is reconciled (update the vault entry, or reset the laptop's
# password to the vault value via its CLI + service restart).
#
# Dialog geometry on the 1600x1000 display (fresh connect): password field
# ~(1070,720), OK ~(1151,818). The "Remember password" row sits at y~764 —
# do not click there. Focus MUST be set with `windowfocus` (raw X focus):
# there is no window manager, so `windowactivate` (_NET_ACTIVE_WINDOW)
# silently no-ops and keystrokes go nowhere.
set -euo pipefail
export DISPLAY=:99
XCLIP=/nix/store/s5dlvs8ripp19rc31n55hrrcg7ngfb8c-xclip-0.13/bin/xclip
source ~/tools/bws-env.sh 2>/dev/null

ID=$(bws secret list -o json | python3 -c "import json,sys; [print(s['id']) for s in json.load(sys.stdin) if s.get('key')=='rustdesk.amd-6-password']")
[ -n "$ID" ] || { echo "auth: secret id not found" >&2; exit 1; }
PW=$(bws secret get "$ID" -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['value'], end='')")
[ -n "$PW" ] || { echo "auth: empty secret" >&2; exit 1; }
echo "auth: secret fetched (${#PW} chars), pasting..." >&2

XD="$HOME/tools/dispatcher.sh"
WIN=$($XD xdotool search --name 'Remote Desktop - RustDesk' 2>/dev/null | head -1)
[ -n "${WIN:-}" ] || { echo "auth: remote window not found" >&2; exit 1; }
$XD xdotool windowfocus --sync "$WIN"
$XD xdotool mousemove 1070 720 click 1
sleep 1
printf %s "$PW" | $XCLIP -selection clipboard -i
unset PW
sleep 1
$XD xdotool key ctrl+v
sleep 1
$XD xdotool mousemove 1151 818 click 1
echo "auth: submitted"
