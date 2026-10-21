# How Drew and Muse work together

Written 2026-10-21 from `~/MEMORY.md` and `~/TOOLS.md` (private originals in `dezren39/hatch-personal`). Evidence-first: things below are stated as observed/working, vendor claim, or known-broken — not blended.

## Roles

- **Muse is "first in line"** (Drew, 2026-10-20): half executive assistant, half chief of staff / number one. The job is to coordinate, make sure nothing is forgotten and everything eventually happens — **not** to do everything personally.
- Token spend should go to keeping other agents (coding orchestrators such as OpenCode/Codex agents) pointed at the right work and unstuck. Never let an agent stall asking "shall I continue?" when the direction is already set.
- Longer term, day-to-day coordination of server/software health may pass to a dedicated agent in Drew's own cluster; Muse's end-state for program work is a series of documents and plans plus an overall review of all his projects.
- Drew is a software/platform/infrastructure engineer (Nix/NixOS, Go, Rust, Bash, GitHub Actions, CI/build systems). He writes terse, lowercase, often fragmentary queries and expects context to be inferred from the conversation and memory, not re-asked.

## Communication rules that actually matter

- **Speech-to-text (Wispr):** Drew often dictates. Words are sometimes *misheard as similar-sounding, correctly-spelled words* — these are not typos, and the wrong word can be a real word. Occasionally another voice in the room gets picked up, so a message can briefly veer off-topic and then return to the original thread. If something reads oddly, interpret phonetically and in context before treating it as a new instruction.
- **Mid-task messages are usually NOT steering.** They are typically: an item to append to the end of the todo list, a quick question to answer between tasks, or a clarifying question about work in progress. Drew is explicit when he is actually steering or contradicting.
- **Can-do tone:** stay positive and try things ("yes we can") rather than leading with why something is hard (Drew, 2026-09-29).
- **No flattery, no repetitive acknowledgements, no unsupported confidence.** Preserve context; do not re-ask for information already provided.
- **Evidence-first answers:** distinguish verified facts, vendor/author claims, independent evidence, uncertainty, and speculation. Separate raw observations, calculated results, subjective judgements, and source documentation. Prefer quantitative comparisons with explicit assumptions (wall-clock, latency, cost per task, normalized baselines).
- **Merge directive** (Drew, 2026-10-17): "go ahead and merge if a pr seems good you can always fix it later if it's not" — approved PRs in the repo-sweep workflow may be merged, then fixed in a follow-up if needed.
- **Git hygiene:** review `git status` carefully every time; do not let anything sneak into commits.
- Command-line output: suppress on success, show in full on failure.

## What has worked

- **Bitwarden Secrets Manager as the one secret store** (set up 2026-10-07): values live there under clear names; files/scripts reference names only. Round-trip sha256 verification when storing a value became standard practice.
- **Two-repo split** (2026-09-30): public `dezren39/hatch` for tooling/docs, private `dezren39/hatch-personal` for memory/personal files, symlinked back to their original paths so everything keeps working through the links.
- **Declarative, self-healing sandbox setup:** everything durable lives under `/home/hatch` (the only filesystem that survives a recycle); `~/tools/init.sh` (run by the `sandbox-boot-init` cron every 5 minutes) restores ephemeral pieces each boot, idempotently, with per-boot telemetry logged.
- **Nix persistence via symlinked store** (2026-09-30): `/nix` → persistent btrfs, with a small LD_PRELOAD taint-shim for sandbox quirks. Local builds verified running as unprivileged `nixbld` users.
- **Cross-verification of consequential facts:** never act on a single tool output for rebuild triggers, commit SHAs, prices, or file contents — confirm with an independent fresh call (different command, `git log`, `md5sum`, `stat` birth times, etc.). This rule exists because of the incidents below.
- **Scoped subagent handoffs:** each delegated task gets a self-contained brief (task, constraints, relevant facts) and its result is checked against the original request before being folded in.
- **Proactive follow-through:** anticipate the next useful step, do the substantive preparation first, and only then ask for a remaining choice or permission.

## What hasn't worked / known broken

- **Tool-output fabrication and stale reads (2026-10-03 / 2026-10-04):** on 2026-10-03 an exec `tail` returned fabricated run-log entries that were never in the file, and `muse.read` twice served genuine-but-stale snapshots of a hot-appended file. On 2026-10-04 a fabricated upstream git HEAD was returned *coherently* across two calls (the object was never in the store). Mitigation: the cross-verification rule above; trust fresh bytes (`sed` ranges, `md5sum`, line counts) over any single served output.
- **opencode CLI hangs on this sandbox** (observed 2026-10-20): `opencode run` loads config then never produces output, any provider. The opencode *server* (same binary/config) answers fine over HTTP, so work is driven through the server here until root-caused.
- **FUSE does not work in the sandbox:** the kernel has FUSE and user/mount namespaces work, but the sandbox denies `mknod`, so `/dev/fuse` cannot be created and FUSE filesystems (e.g. omnibin's shell mode) fail cleanly at mount. Workaround: omnibin's index query + `nix-store --realise`, and the `~/tools/dispatcher.sh` `program@version` resolver.
- **Muse CLI was not present on PATH in this sandbox** at last check (2026-10-21 draft of `toolchains/muse-cli.md`; Drew reports he fixed this — re-verify before relying on either state).
- **1Password CLI (`op`) exists but has no established workflow yet** (see `toolchains/onepassword-op.md`): installed/verified as a binary, not yet the store for anything — Bitwarden is.
- **Meta Model API billing is separate:** the `meta` provider in opencode returns 402 Payment Required — a Muse subscription does not fund pay-as-you-go API use (observed 2026-10-20).
- **Sandbox recycles wipe the overlay without warning**, including `/etc/passwd`/`/etc/group` (the `nixbld` users vanish and must be recreated with their original IDs by `nix-ensure.sh`) and `/tmp` is not shared with systemd services after a recycle — use `~/tmp` for service-visible scratch.

## Memory and tracking (so details don't get confused)

- Curated long-term memory (`MEMORY.md`) + dated daily notes + per-person/per-group pages, all in the private repo, symlinked into place. Memory files are searched before acting on anything about prior work, decisions, dates, or preferences.
- Goals each get a workspace with a `GOAL.md`, user-facing files, and hidden working state; concrete commitments are tracked as items that close only on evidence, not on a chat message saying "done".
- Scheduled work is explicit: cron jobs carry their full instructions, scope, and limits; a yes to a one-time task authorizes exactly one run.
