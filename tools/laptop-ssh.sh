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
# Timeout semantics (2026-11-10, code#5343): every delegated path ends
# in `exec`, so an outer `timeout N`'s SIGTERM reaches the agent client
# directly; the client catches it, cancels the remote command's whole
# process group via the daemon (/cancel), and exits 124. The shim's
# own LAPTOP_SSH_TIMEOUT (default 600) is the DAEMON-side cap for the
# remote command; the client's local backstop is that + 15 s. The
# real-SSH fallback path cannot cancel remotely (sshd owns the remote
# process) — `timeout` there bounds only the local wait; see
# TOOLS.d/laptop.md.
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

# If our parent is GNU timeout(1) (e.g. `timeout 30 laptop-ssh.sh ...`),
# read its -t budget from /proc and export it so the agent client hands
# the SAME deadline to the daemon — the remote process group is then
# reaped at the deadline even if the signal path fails. Detection is
# best-effort and silent: any miss just keeps the old signal-only path.
if [ -r "/proc/$PPID/cmdline" ]; then
  _pcomm=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null)
  case "$_pcomm" in
    *timeout*)
      _t=$(printf '%s' "$_pcomm" | grep -oE 'timeout[^ ]* +(-t +)?[0-9]+(\.[0-9]+)?[smhd]?' | grep -oE '[0-9]+(\.[0-9]+)?[smhd]?$' | head -1)
      case "$_t" in
        *s) _secs=${_t%s} ;;
        *m) _secs=$(awk -v v="${_t%m}" 'BEGIN{print v*60}') ;;
        *h) _secs=$(awk -v v="${_t%h}" 'BEGIN{print v*3600}') ;;
        *d) _secs=$(awk -v v="${_t%d}" 'BEGIN{print v*86400}') ;;
        *) _secs=$_t ;;
      esac
      if [ -n "${_secs:-}" ]; then
        export LAPTOP_AGENT_DEADLINE_S="$_secs"
      fi
      unset _t _secs
      ;;
  esac
  unset _pcomm
fi

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
