# TOOLS.d/laptop.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

## SUDO + THE AMD SWITCH ARE MINE — NEVER DREW'S (standing rule since 2026-10-27; violated twice on 2026-11-04 alone)
- The laptop `user` sudo password is in 1Password: Dev vault item `user@amd`
  (id `nur7fn62w2utvuvfrqbtvp6pq4`, vault id `65am7pv6dofhrs2tuhvpzi6vay`).
  Fetch ONLY via `op item get <id> --vault <vault-id> --format json` (after
  `source ~/tools/op-env.sh`), taking the non-empty field with id `password`.
  `op item get --fields password` returns a bogus 65-char string sudo rejects.
  Pipe it, never print or file it: `printf '%s\n' "$PW" | ~/tools/laptop-ssh.sh 'sudo -S -p "" bash -c "..."'`
  (laptop-ssh.sh passes stdin through since the 2026-10-26 rewrite).
- The amd switch is Muse's job, full stop: primary `~/git/code` at latest
  origin/main + clean, then `sudo nixos-rebuild switch --flake ~/git/code#amd`.
  If the flake eval races (source changed during evaluation — pm-git-sync /
  tree churn), fall back to the direct path with the prebuilt toplevel:
  `nix-env --profile /nix/var/nix/profiles/system --set <toplevel>` then
  `<toplevel>/bin/switch-to-configuration switch`. Verify: profile generation
  incremented and /run/current-system resolves to the intended toplevel.
  NEVER tell Drew a switch or any laptop sudo step is "his" — that claim was
  wrong on 2026-10-27, corrected on 2026-10-28 (MEMORY.md + topics), and
  repeated on 2026-11-04; it does not get repeated again.

## Laptop SSH drops — ROOT CAUSED 2026-10-25 (MaxStartups, not "flakiness")
- The laptop's sshd runs stock **MaxStartups 10:30:100** (no override in
  /etc/ssh/sshd_config). New-connection setups through the tailnet route take
  5–45s (all sandbox↔laptop traffic hairpins via the **NYC DERP relay**;
  tailscale ping times out while SSH data flows), so each setup holds a
  startup slot for seconds. Bursts >10 concurrent pre-auth setups (watch +
  launchers + coordinators overlapping) get sshd's literal early-drop bytes
  `Not allowed at this time` → client sees "Connection closed by UNKNOWN port
  65535", rc 255. Established sessions are NEVER dropped. MaxStartups drops
  are NOT logged at INFO — the journal shows only successful accepts, which
  is why it looked like random flakiness that "recovers on its own".
  Reproduced 2026-10-25: 14 parallel laptop-ssh.sh calls → 2 failed.
- INTERIM FIX APPLIED 2026-10-25: ~/tools/laptop-ssh.sh now uses SSH
  connection multiplexing (ControlMaster=auto, ControlPath
  ~/.ssh/cm-%r@%h:%p, ControlPersist=600 — 600 chosen to bridge the 10-min
  watch cadence). Verified: warm-master burst 14/14 OK (cold-start race can
  still drop a couple while several clients race to create the master).
- PERMANENT FIX — APPLIED (verified live 2026-10-31): MaxStartups is raised
  to **200:30:500**. `/etc/ssh/sshd_config` (via /etc/static, current
  generation) carries `MaxStartups 200:30:500`, and the RUNNING listener's
  own proctitle reads `[listener] 0 of 200-500 startups` — the raise is
  effective in the daemon, not just on disk. Do NOT propose re-applying it
  or "raising to 100:30:300" (that would be a cut). Consequence: the SSH
  drops recurring since (code #2879, 2026-10-30/31) happen WITH the 200 cap
  live, so MaxStartups is no longer a sufficient explanation for them —
  recent reports are mostly setup timeouts on the DERP path that succeed
  on retry. #2879 needs fresh evidence (journal during a burst, cold-start
  repro) before any new root cause is claimed.

- 2026-10-25: laptop-ssh.sh eats piped stdin (its Python source arrives via heredoc) — sudo -S through the helper gets EOF ("no password was provided"). For stdin-carrying SSH (sudo -S, password feeds), build a direct ssh call with the same socat ProxyCommand (proxy creds from HTTPS_PROXY env) instead of the helper.

## Host-key + credential-in-argv FIXED 2026-10-26 (cf. code issue #948)
- laptop-ssh.sh rewritten: ProxyCommand is now ~/tools/laptop-proxy-connect.py,
  a Python HTTP CONNECT relay that reads the proxy credential from the
  HTTPS_PROXY env and sends it only inside the CONNECT request — the
  credential appears in NO process argv (the old socat line embedded
  proxyauth= in the argv of both ssh and socat).
- Host key verification ON: laptop ed25519 key (captured from the host
  itself via ssh-keyscan over the established channel) pinned in
  ~/.ssh/known_hosts_laptop; StrictHostKeyChecking=yes. Negative test
  (bogus key) verified rejected.
- Side benefit: no more Python heredoc — stdin passes through to ssh, so
  the sudo -S / password-feed workaround is obsolete.
- Old version kept at ~/tools/laptop-ssh.sh.bak-2026-10-26.
- Verified 2026-10-26: fresh strict connection OK, helper OK, stdin OK.

## laptop-agent (BUILT 2026-11-04, code issue #5343) — resident daemon, no SSH in data path
- Drew directed ("design it and then build it") after the CPU analysis showed the
  CONNECT relay at 0% CPU and per-command process-spawn volume as the real cost.
  Design doc: workspace/goals/keep-the-four-repos-healthy/files/laptop-agent-design-2026-11-04.md
- PROVEN transport fact: the tailnet tunnel proxy CONNECTs to ARBITRARY ports on
  100.99.113.103, not just :22 — plain HTTP flows over the CONNECT tunnel.
- Daemon: ~/laptop-agent/laptop_agent.py on the laptop (canonical copy
  ~/tools/laptop-agent-daemon.py, committed in the home repo), systemd USER
  service laptop-agent.service (enabled, Linger=yes, Restart=on-failure),
  binds ONLY 100.99.113.103:4799, token auth via X-Agent-Token (token files
  mode 600: laptop ~/.config/laptop-agent/token, sandbox ~/tools/laptop-agent-token
  — gitignored, never commit/print). Job spools: ~/.local/state/laptop-agent/jobs/.
- Client: ~/tools/laptop-agent.py — health | exec [--cwd D] [--timeout S] [--shell] -- cmd...
  | exec-batch FILE.json | run | poll JOB [--wait S] (offset state in
  ~/.cache/laptop-agent/) | kill JOB | jobs. NOTE: --cwd is a LAPTOP path —
  shell tilde expansion on the sandbox will silently rewrite ~/... to the
  sandbox home; pass absolute /home/user/... paths.
- Measured: batch of 10 commands in one request 1.96s wall vs 4.38s as 10 warm-mux
  ssh calls; single trivial command ~1.3s (fresh CONNECT) vs ~0.4s warm ssh —
  use the agent for BATCHES and LONG JOBS (detached, survive client death,
  offset polling, exit codes propagate). Phase 2 (migrate fleet call sites)
  landed 2026-11-04 — see "SSH shim RETIRED" at the end of this file;
  phase 3 (declare in dezren39/darwin-nix NixOS config) is open on #5343.

## laptop-agent broker — warm connections (2026-11-04, later)
- Cold-call anatomy measured: Python startup ~25-80ms; CONNECT handshake ~1.8s
  (DERP); warm request RTT ~0.22-0.35s. Python was never the problem.
- ~/tools/laptop-agent-broker.py: auto-started by the client when
  ~/.cache/laptop-agent/broker.sock is missing; pool of 2 keep-alive tunnels,
  180s keepalive, exits after 1 idle hour; client env LAPTOP_AGENT_NO_BROKER=1
  forces direct CONNECT. Warm single calls now ~0.39-0.45s ≈ warm ssh ~0.41s.
  Broker log: ~/.cache/laptop-agent/broker.log.

## fleet-brokers (BUILT + CUT OVER 2026-11-04, code issue #5362)
- Two Rust services on the laptop (systemd user units, enabled):
  `secrets-broker` on 100.99.113.103:4800 (runs `bws` on the laptop,
  caches the whole secret set, 900s TTL stale-while-revalidate) and
  `queue-broker` on 100.99.113.103:4801 (the repo-queue command surface
  as HTTP endpoints; holds NO key on disk — fetches
  `supabase.muse-dev2.service-role-key` / `.project-url` from the
  secrets broker at first use, re-fetches on a PostgREST 401).
- Sandbox side connects ONLY to the session proxy: `~/tools/repo-queue`
  (Rust client) goes through `~/tools/laptop-agent-broker.py`, whose
  pools are per-port and which presents the per-service token via its
  `token_file` field. Tokens (values never in files' content): sandbox
  `~/tools/queue-broker-token`, `~/tools/secrets-broker-token` (600,
  gitignored); laptop `~/.config/queue-broker/token`,
  `~/.config/secrets-broker/token`.
- The client is called directly as `repo-queue` (binary at
  `~/tools/repo-queue`, symlinked from `~/tools/bin/repo-queue` so it
  is on PATH). There is NO Python repo-queue on the sandbox anymore:
  the shim and the legacy module were removed 2026-11-04 (Drew's
  order); every cron body, instruction file, and helper script calls
  the bare binary, which connects through the session proxy on its
  own. Verified live 2026-11-04: bare `repo-queue health` ~0.3-3s;
  shadow-queue canary tasks 9343/9344 ran
  enqueue/claim/checkpoint/park/cancel/complete through the broker.
- Sources: sandbox `~/tools/fleet-brokers/` (Cargo workspace:
  secrets-broker, queue-broker, repo-queue); laptop build tree
  `~/fleet-brokers-src/`, binaries `~/fleet-brokers/bin/`. Nix package:
  `pkgs/fleet-brokers` + `pkgs/laptop-agent` in dezren39/darwin-nix, PR #1459
  (build + module check verified on amd; the home module launches all
  three services when enabled; no machine config enables it yet — the
  hand-installed units are live).
- Init autostarts the session proxy (2026-11-04): `~/tools/init-ensure.sh`
  ensures the laptop-agent broker is running on every prelude — cheap
  pgrep/socket gate, flock-serialized spawn, and the broker self-dedupes
  via its socket probe. No-op when already running (verified: pid
  stable across ensures; a killed broker came back on the next ensure).

## repo-queue on the laptop (claimant transport, 2026-11-04, code#5414)
- The opencode-claimant and its worker sessions run ON the laptop, where
  there is no session proxy. The `repo-queue` client therefore has a
  direct-broker transport: `REPO_QUEUE_BROKER_URL` env or
  `~/.config/repo-queue/broker-url` (laptop value
  `http://100.99.113.103:4801`) makes it POST straight to the
  queue-broker with `X-Agent-Token` from `REPO_QUEUE_TOKEN_FILE` or
  `~/.config/queue-broker/token`. Sandbox behavior is unchanged when
  neither is set. Laptop binary: `~/fleet-brokers/bin/repo-queue`
  (also symlinked from `~/.local/bin/repo-queue`).
- queue-broker `/list` accepts `rich: true` for the claim/binding
  fields (worker_id, lease_until, lane_id, attempts, max_attempts,
  progress) — that is how the claimant's poll.py reads the ledger now.
  It no longer imports any Python helper; when a fleet call-site sweep
  retires a tool, grep the code repo's pm-stack for consumers too.

## SSH shim RETIRED (2026-11-04, Drew's order, code issue #5343)
- ~/tools/laptop-ssh.sh is NO LONGER an SSH transport. It is a
  compatibility redirect: exec-style invocations (one quoted command
  string, or a script on stdin via 'bash -s' / 'python3 -') delegate to
  ~/tools/laptop-agent.py over the fleet session proxy; exit codes
  propagate; delegated calls appear in both trip logs. The earlier
  sections of this file describing laptop-ssh.sh as the SSH route are
  history — the agent is the route now.
- The original SSH implementation is preserved byte-identical at
  ~/tools/laptop-ssh-real.sh (md5 95f647590274779bcaef7ea9a66f0670). It
  is reached ONLY via LAPTOP_SSH_REAL=1 (the daemon-down recovery path)
  or automatically by the shim for shapes the agent cannot express:
  ssh options/forwards (-L/-N/-t...), interactive sessions, and stdin
  carrying DATA for the remote command (sudo -S feeds, `cat > file`
  pushes) — the daemon has no stdin channel.
- The fleet binary's `laptop-agent` domain is a registry stub in build
  0.1.0 (exit 69, "lands in a later step of epic #5412"); the working
  client of the fleet laptop-agent path is laptop-agent.py. When the
  binary domain lands, the shim's delegate flips to it.
- Daemon shell mode fixed the same day: it hardcoded /bin/bash, which
  does not exist on NixOS — shell specs now resolve bash from PATH /
  the per-user profile / the system profile. Canonical daemon copy
  ~/tools/laptop-agent-daemon.py == laptop ~/laptop-agent/laptop_agent.py.
- Known cosmetic difference: agent shell specs run via `bash -lc`
  (login shell), whose profile emits a window-title escape on some
  paths; harmless in captured output.
- Migration inventory + residuals: workspace/goals/keep-the-four-repos-healthy/hidden_files/laptop-ssh-migration-inventory-2026-11-04.md

## Timeout enforcement — FIXED 2026-11-10 (code#5343)
Caller deadlines now bound the WHOLE laptop call at every layer.
Before: `timeout 30` around a wrapper call could run 18 minutes and
ALWAYS orphaned the remote command — /exec children ran in the
daemon's own process group (subprocess.run, no session), the timeout
killed only the group leader (grandchildren survived reparented),
nothing cancelled the remote work when the client died, broker
threads parked up to 660 s on wedged tunnels, and the shim's
daemon-side cap was 600 s regardless of the caller's budget.
Semantics as fixed:
- Daemon: every /exec command runs in its OWN process group
  (start_new_session); the WHOLE group (grandchildren included) is
  TERM-then-KILLed when any of these fires: timeout_s, an explicit
  POST /exec/<trip>/cancel, or the request connection dying
  (half-close watchdog in the handler — covers SIGKILLed clients).
  Output is drained incrementally, so a killed grandchild holding
  the pipes can no longer wedge the reader. Detached /jobs are
  unchanged: they survive a graceful client exit by design; their
  kill endpoint escalates TERM→KILL after 5 s and KILLS THE WHOLE
  GROUP only if the TERM was deferred to — a process that ignores
  TERM entirely still takes the full escalation window (measured:
  poll-timeout test needed ~8 s settle for `bash -lc 'sleep N'` jobs).
- Client (laptop-agent.py): --timeout S arms a local backstop at
  S + 15 s (SIGALRM) and exits 124 (GNU timeout's code) even if the
  transport wedges; external SIGTERM/SIGINT are CAUGHT — the client
  cancels the in-flight exec (or kills the polled job) over a fresh
  direct CONNECT with a 3 s budget, then exits 124. If the cancel is
  not acknowledged it KILLs the broker (pid file broker.pid) so the
  pool restarts clean. poll has a reply watchdog thread for the case
  where a C-level recv defers the Python signal handler. Env
  LAPTOP_AGENT_DEADLINE_S (seconds) tightens exec's daemon-side
  timeout: the shim sets it automatically when its parent is GNU
  timeout(1), parsed from /proc/$PPID/cmdline — so via the shim the
  daemon itself reaps the command at the caller's deadline even if
  every signal path fails.
- Broker: per-request socket timeout from the caller's remaining
  deadline (no more flat 660 s); a timed-out/errored connection is
  closed, never repooled; a 0.2 s watchdog notices a client that
  vanished mid-request (unix-socket EOF) and hard-closes its tunnel,
  which both frees the handler thread and triggers the daemon's
  disconnect reap — this is what bounds even a SIGKILL. Broker
  writes ~/.cache/laptop-agent/broker.pid.
- Real-SSH path (laptop-ssh-real.sh): `timeout` bounds ONLY the
  local wait (rc 124, verified) — the remote command still runs to
  completion server-side because sshd owns it and nothing in the
  SSH protocol cancels it; multiplexed masters can also outlive the
  killed front-end. Prefer the agent path whenever a deadline
  matters; use LAPTOP_SSH_REAL=1 only for the recovery/forwards/
  stdin shapes it exists for.
- Proof (2026-11-10, live): sleep-300-class hangs — client
  --timeout 5: 5.5 s rc 124, no leftover (incl. `sleep & wait`
  grandchild case); external `timeout 5`: 5.1 s rc 124, no leftover;
  external `timeout -s KILL 5`: client rc 137 at 5.0 s, remote reaped
  within ~2 s by broker-watchdog + daemon disconnect reap; shim
  under `timeout 5`: 5.1 s rc 124, no leftover; poll of a detached
  job under `timeout 5`: rc 124, job done, no leftover after the
  TERM→KILL escalation; NO_BROKER direct path same as broker path;
  exec-batch timeout result + no leftover. Regressions: warm call
  0.5–0.9 s, cold (broker restart) 1.35 s, remote exit codes 3 and
  42 propagate exactly (distinct from timeout's 124), pool answers
  immediately after every kill. Backups: *.bak-20261110-timeout-fix
  beside each file (laptop daemon: laptop_agent.py.bak-20261110-
  timeout-fix + .bak2-20261110).

## OpenCode revision pin + parity (code#1362, recorded 2026-11-14, task 5007)
- Canonical rev: the running fleet service and the code repo agree —
  service exe (pid on :13420) = `opencode 2.0.30+0f5561c`; developing-today/code
  `flake.lock` opencode input = `0f5561c21cb84465cefef3881fa1d6f8eaa43a4d`
  (developing-today-forks/opencode). That pair is the verified pin.
- Known skew (fresh probe 2026-11-14, unchanged since the 2026-11-13
  inventory): laptop CLI (system bin + ~/.local/bin) = c43145b; sandbox
  CLI (/usr/local/bin/opencode) = 954ff7c; dezren39/darwin-nix flake.lock
  opencode pin = b80e509. Three surfaces, three non-canonical revs.
- Update procedure (QUIET WINDOW ONLY — a switch on amd can restart the
  socket-activated opencode.service and kill live fleet sessions):
  (1) bump the darwin-nix opencode pin to the canonical rev (or the rev
  the code pin moves to), (2) `sudo nixos-rebuild switch --flake
  ~/git/code#amd` per the amd-switch rule above, (3) repoint the laptop
  CLI wrapper and the sandbox nix profile to the same rev, (4) re-probe
  all three surfaces (`opencode --version` + the service exe store path)
  and record the result on code#1362.
