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
# VIDEO STATE (2026-11-04, RESOLVED — code#5509 closed): frames flow and
# sessions are stable. The blockers were a wedged xdg-desktop-portal-
# hyprland (restarted) and the RustDesk route riding the shared SSH
# ControlMaster (now a dedicated forward — see launch.sh/forward.sh and
# README "Video leg"). If video ever regresses, check those two first.
#
# Dialog interaction (corrected 2026-11-04): DO NOT CLICK ANYTHING. The
# fresh dialog auto-focuses the password field; the dialog also RE-CENTERS
# whenever the remote window re-renders, so any baked coordinate is a trap
# (two pastes were lost to clicks landing on the "Remember password" row).
# The proven sequence is: `windowfocus` (raw X focus — there is no window
# manager, so `windowactivate` silently no-ops) -> feed clipboard -> Ctrl+V
# -> verify the dots in a screenshot -> `xdotool key Return`.
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
# NO mouse click (corrected 2026-11-04): on a fresh dialog the password
# field is ALREADY focused (blue border + live cursor). Clicking is what
# breaks the paste — the dialog re-centers between screenshots, the click
# lands on the "Remember password" row, focus leaves the field, and Ctrl+V
# goes nowhere. Focus the window only, then paste.
printf %s "$PW" | $XCLIP -selection clipboard -i
unset PW
sleep 1
$XD xdotool key ctrl+v
sleep 1
$XD xdotool key Return
echo "auth: submitted"
