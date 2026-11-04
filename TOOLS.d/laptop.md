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
  offset polling, exit codes propagate), keep laptop-ssh.sh for single quick
  commands, interactive work, and sudo. Phase 2 (migrate fleet call sites) and
  phase 3 (declare in dezren39/darwin-nix NixOS config) are open on #5343.

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
