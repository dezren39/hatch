#!/usr/bin/env bash
# laptop-ssh.sh — RETIRED as an SSH transport 2026-11-04 (code#5343).
#
# Drew's order: the SSH shim is retired; this file is now a compatibility
# redirect to the laptop-agent path. Exec-style invocations delegate to
# the laptop-agent client (~/tools/laptop-agent.py), which reaches the
# laptop daemon (:4799) through the fleet session proxy
# (`fleet proxy serve`, pool 50) — no SSH, no sshd pre-auth bursts, and
# every delegated call lands in the trip logs
# (~/.local/state/laptop-agent/trips.jsonl on both sides).
#
# Delegate target note: the fleet binary's `laptop-agent` domain is a
# registry stub in build 0.1.0 (answers exit 69, "lands in a later step
# of epic #5412" — verified in crates/fleet/src/main.rs). The working
# client of the fleet laptop-agent path today is laptop-agent.py; when
# the binary domain lands, flip AGENT below to `fleet laptop-agent`
# (same verbs: exec / run / poll / kill / jobs).
#
# What delegates (the dominant calling conventions):
#   laptop-ssh.sh 'remote command'          -> agent exec --shell
#   laptop-ssh.sh cmd arg...                -> args joined with spaces,
#                                              exactly as ssh joined them
#   laptop-ssh.sh 'bash -s' < script        -> script text becomes the
#   laptop-ssh.sh 'python3 -' < script         agent shell string
# Remote exit codes propagate (the client exits with the remote code).
# Differences vs real ssh: exec output is capped at 1 MiB per stream
# (tail kept) and the daemon caps a synchronous exec at 600 s — for
# longer work use the agent's detached jobs (run / poll) directly.
#
# What does NOT delegate (falls back to real SSH, stdin untouched):
#   - LAPTOP_SSH_REAL=1 in the environment (the daemon-down recovery
#     path; also the explicit escape hatch for any shape below)
#   - no arguments (interactive session) or a leading ssh option
#     (-L/-R/-W/-N/-t/-p/-l/-i/-o ...: forwards and TTY allocation are
#     shapes the agent cannot express)
#   - stdin carrying DATA for the remote command (sudo -S password
#     feeds, `cat > file` pushes, ...): the daemon has no stdin
#     channel. Detected as a non-empty redirected file, or pipe data
#     that arrives promptly (0.2 s probe; a deliberately slow producer
#     is the one miss — use LAPTOP_SSH_REAL=1 for those).
#
# The preserved original SSH implementation is
# ~/tools/laptop-ssh-real.sh (byte-identical to the pre-retirement
# shim, md5 95f647590274779bcaef7ea9a66f0670).
set -uo pipefail

REAL="$HOME/tools/laptop-ssh-real.sh"
AGENT="$HOME/tools/laptop-agent.py"
TIMEOUT="${LAPTOP_SSH_TIMEOUT:-600}"

if [ "${LAPTOP_SSH_REAL:-}" = "1" ]; then
  exec "$REAL" "$@"
fi
if [ "$#" -eq 0 ]; then
  exec "$REAL" "$@"
fi
case "$1" in
  -*) exec "$REAL" "$@" ;;
esac

cmd="$*"

# --- Script-on-stdin: the command is a shell/interpreter reading its
# script from stdin. Convert: the script text becomes the shell string
# (JSON transport, so none of the old ssh heredoc mangling applies).
case "$cmd" in
  'bash -s'|'bash -s '*|'sh -s'|'sh -s '*|'bash -'|'sh -')
    if [ ! -t 0 ]; then
      script=$(cat)
      exec python3 "$AGENT" exec --shell --timeout "$TIMEOUT" -- "$script"
    fi
    ;;
  'python3 -'|'python3 - '*|'python -'|'python - '*)
    if [ ! -t 0 ]; then
      script=$(cat)
      delim="LAPTOP_AGENT_STDIN_$$"
      exec python3 "$AGENT" exec --shell --timeout "$TIMEOUT" -- \
        "$cmd <<'$delim'
$script
$delim"
    fi
    ;;
esac

# --- stdin carrying data for the remote command -> real SSH.
if [ ! -t 0 ]; then
  if [ -f /dev/stdin ] && [ -s /dev/stdin ]; then
    exec "$REAL" "$@"
  fi
  if [ -p /dev/stdin ]; then
    peek=$(mktemp)
    if timeout 0.2 dd if=/dev/stdin of="$peek" bs=1 count=1 2>/dev/null \
       && [ -s "$peek" ]; then
      cat "$peek" - | "$REAL" "$@"
      rc=${PIPESTATUS[1]}
      rm -f "$peek"
      exit "$rc"
    fi
    rm -f "$peek"
  fi
fi

# --- The dominant path: one remote command string through the agent.
exec python3 "$AGENT" exec --shell --timeout "$TIMEOUT" -- "$cmd"
