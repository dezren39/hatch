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
# KNOWN STATE (2026-11-04, reconciled): the laptop's permanent password was
# RESET to the Bitwarden value per Drew's ruling (2026-11-04 07:01) and the
# vault value is now ACCEPTED — sessions advance past auth to the host's
# Wayland screen-share step. Do not re-litigate the credential. How the reset
# was done (the CLI is a dead end — see README): the stored field was written
# directly into the laptop's RustDesk.toml in RustDesk 1.5.0's exact storage
# format ("01" + secretbox("00" + base64(SHA256(pw || config.salt))), salt
# kept stable), service stopped during the splice, then restarted.
# REMAINING BLOCKER is NOT the password: the host's Wayland ScreenCast /
# PipeWire pipeline never delivers frames (client: "Connection error:
# Timeout"; host log: portal handshake OK, AV1 encoder selected, connection
# closed on Timeout). See README "Video leg" before burning time on it.
#
# Dialog geometry on the 1600x1000 display (fresh connect): password field
# ~(1120,768) — VERIFIED (24 dots land). The dialog RE-CENTERS with the
# remote window, so re-measure from a fresh screenshot if the window moved;
# the old (1070,720) point hits the "Remember password" row and submits
# EMPTY. Submit with `xdotool key Return` (the field keeps focus after
# paste) instead of clicking OK — immune to dialog drift. Focus MUST be set
# with `windowfocus` (raw X focus): there is no window manager, so
# `windowactivate` (_NET_ACTIVE_WINDOW) silently no-ops.
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
$XD xdotool mousemove 1120 768 click 1
sleep 1
printf %s "$PW" | $XCLIP -selection clipboard -i
unset PW
sleep 1
$XD xdotool key ctrl+v
sleep 1
$XD xdotool key Return
echo "auth: submitted"
