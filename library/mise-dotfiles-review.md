# Mise + dotfiles-manager patterns — review of our submodule/symlink replication setup

Date: 2026-10-21. Status: REVIEW / proposals only. Nothing in this document has been
applied — `scripts/link-submodules.sh`, `~/tools/init.sh`, and all repo files are
unchanged. Fixes are proposals; tiny ones are given as diffs in the appendix.

Scope: Drew asked (a) what Mise is and whether it could be a straightforward
replication/bootstrap layer for limited environments like this sandbox, and
(b) whether our hand-rolled pattern — git submodule registry + on-demand
materialize + absolute symlinks into a second (private) repo, restored by
`init.sh` on every boot — is aligned with what the mature dotfiles tools
(chezmoi, yadm, GNU Stow, rcm, dotbot, the bare-git-repo trick) have learned,
and where the obvious pitfalls are.

Sources are cited inline as [n] and listed at the end. All web sources were
accessed 2026-10-21. Claims about our own setup cite the file and, where it
matters, the exact lines read on 2026-10-21.

---

## 1. Mise — what it is, and the replication question

### 1.1 What it is

Mise (formerly rtx; jdx/mise) is a single-binary, polyglot **dev-environment
manager**: asdf-style tool version management + direnv-style per-directory
environment variables + a make/just-style task runner, in one Rust binary
[11][5]. It consolidates what used to be nvm/pyenv/rbenv/asdf + direnv + a
taskfile into one `mise.toml` per project (merged hierarchically: global
`~/.config/mise/config.toml` ← parent dirs ← project ← `mise.local.toml`
personal override, closer wins) [1].

Capabilities relevant here:

- **Tool versions from many backends**, not one registry: built-in "core"
  tools (node, python, go, rust, bun, deno, …), `aqua:` (aqua registry
  recipes, which carry verification metadata), `github:`/`gitlab:`/`forgejo:`
  (release assets), `packslip:` (signed manifests), `http:`/`s3:` (your own
  URLs), and language backends `npm:`, `pypi:`, `cargo:`, `go:`, `gem:`,
  `dotnet:`, `conda:`. asdf plugins are supported but **legacy**; ubi is
  deprecated and scheduled for removal in mise 2027.1.0; new asdf/vfox
  registry entries are *rejected for supply-chain security reasons* [7][8].
- **`mise.toml`** declares tools, `[env]`, and `[tasks]` in one file.
  `mise use` installs and records; version requests can be loose prefixes
  (`node = "24"` resolves differently on different machines) or exact
  (`--pin`) [3][10].
- **`mise.lock` lockfile** records the exact resolved version, per-platform
  download URL, and checksum *where the backend provides one* — and is
  committed alongside `mise.toml`. `mise install --locked` installs the
  recorded builds without re-resolving [1][2][9]. The caveat is in mise's own
  table: for `asdf`, `cargo`, `go`, `gem`, `dotnet`, `spm` backends the
  lockfile records **the top-level version only** — no URL, no checksum —
  because those installers resolve/build on their own [9].
- **`mise trust`** is a real security gate, not ceremony: a `mise.toml` with
  `[env]`, hooks, templates, or tasks *can run code*, so mise refuses to load
  an untrusted project's config until you run a command that implies trust
  (`mise install`, `mise exec`, `mise run`, or explicit `mise trust`) [3].
  There is also a safe mode (`MISE_SAFE=1`) for reading untrusted config —
  which the docs warn does **not** make `mise install` safe, since installing
  can run build scripts (e.g. a cargo crate's `build.rs`) [4].
- **Shims vs activation**: shims are symlinks to the mise binary in
  `~/.local/share/mise/shims`; every call re-reads the config for the current
  directory and dispatches the right version. Shell activation
  (`eval "$(mise activate bash)"`) instead puts the real tool dirs on PATH per
  directory — faster, but only in activated shells; shims work from scripts,
  editors, and cron at the cost of a dispatch hop [13][14]. For a
  non-interactive bootstrap context, `mise exec` / `mise run` need neither:
  they load tools+env per invocation with no startup-file changes [13].
- **Idiomatic version files**: mise natively reads `.tool-versions`, and can
  be told to read `.node-version`, `.python-version`, etc. per-tool — useful
  for adopting projects that already carry those files [10][12].
- **Wrapper bootstrap**: `mise generate install-script --localize --write`
  produces a committed wrapper that downloads a *pinned* mise release on
  first use, for machines/teammates that don't have mise yet [1].

### 1.2 Why people call it "easier than Nix"

The claim holds up, for the layer mise actually covers:

- **One static binary.** No daemon, no store, no profile generations, no
  evaluator, no expression language. Install = download one file.
- **It fetches prebuilt binaries** for most registry tools instead of
  building from source derivations; there is no equivalent of a purity
  check, a sandbox build user, or a symlinked-store guard to trip over.
- **The config is TOML you can read at a glance**, hierarchical in the
  ordinary "closer directory wins" way, versus flake inputs/outputs.
- **Failure modes are shallower**: a bad version request fails as "not
  found", not as a derivation that built for 20 minutes and failed linking.

The trade is exactly the other side of the same coin: mise has **no
content-addressed store, no closure guarantees, no atomic profile
generations/rollback, and no OS-level reach**. It manages user-space tools
in `~/.local/share/mise`; it does not create system users, systemd units,
`/etc` files, or kernel-adjacent state. (Recent mise is growing bootstrap /
system-package / dotfiles features [14], but they are young compared to the
tool-version core, and this review does not rely on them.)

### 1.3 Could mise be the replication/bootstrap layer in a limited environment?

The specific scenario: an environment like this sandbox (no root guarantees,
no nix, ephemeral overlay, only `$HOME` persistent) where we want
"clone a repo, run one command, get the documented tool versions back."

**Yes for the tool layer, with four hard limits:**

1. **It can recreate tool *versions*, not tool *provenance*.** With
   `mise.toml` + a committed `mise.lock`, `mise install --locked` reproduces
   exact versions and checksum-verified artifacts for the binary-download
   backends (core download tools, aqua, github, http) [2][9]. For
   cargo/go/gem/asdf-backend tools the lockfile pins only the version string
   and the language toolchain resolves/builds the rest — reproducible in
   practice, not in the nix sense [9].
2. **Some of our toolchain is outside its reach.** From our own index
   (`library/toolchains/index.md`): nix itself (obviously), the gh CLI's
   credential-helper configuration, Bitwarden `bws` (no confirmed registry
   entry — would be a `github:`/`http:` backend entry at best, unverified),
   the Cloudflare `cf` beta binary, wrangler (installable via `npm:`), the
   sandbox's own wrappers/dispatcher, systemd services (mcpx, opencode), the
   nixbld users, and the `/nix` symlink + taint-shim arrangement. Mise would
   cover the language runtimes (go, rust, bun, uv, node-class tools) — maybe
   half the index — and none of the sandbox-specific machinery.
3. **Trust + network are the bootstrap's attack surface.** A cloned
   `mise.toml` is code-adjacent: tasks, hooks, and `[env]` execute. The
   trust model handles this for *other people's* configs [3][4]; for our own
   committed config the residual risk is the download path itself — checksums
   exist only where backends provide them [9], and asdf-style plugins are
   arbitrary shell (which is why mise itself is phasing them out of the
   registry) [8]. A mise bootstrap in a network-restricted environment also
   just fails: everything is fetched live from GitHub/registries at install
   time; there is no offline store to fall back to unless one is pre-seeded.
4. **Tasks are not idempotency-checked.** `mise run` executes what you
   wrote; whether re-running is safe is the author's problem — the same
   contract dotbot states explicitly for its `shell` directive [20]. A
   bootstrap built on mise tasks inherits the discipline requirement, it
   doesn't remove it.

**The overlap problem specific to us:** this sandbox already has a
version-pinning resolver — the omnibin-backed dispatcher with a pinned flake
input, a disk cache, GC roots, and a *loud failure on inexact version* rule
(`~/TOOLS.md`). Mise's default resolution semantics are the opposite
(loose prefixes, tightened only via `--pin` + lockfile) [3][10]. Running
both means two pinning systems with different failure behaviour resolving
the same command names — shims vs dispatcher stubs would fight over PATH
precedence exactly the way mise's own docs warn shims can silently fall back
to an unrelated system binary when a version is unresolved [13]. That is a
real pitfall, not a taste preference.

### 1.4 Verdict (detail; one-paragraph form in the summary)

**Borrow the pattern, don't adopt the tool — on this machine. Optionally
adopt for nix-less environments, as an experiment.** The pattern worth
borrowing is the *artifact shape*: one small committed file that declares
exact tool versions + checksums next to the code that needs them
(`mise.toml` + `mise.lock`), instead of versions being discoverable only by
reading prose docs and `TOOLS.md`. Our toolchain index is already the prose
half of that; a machine-checkable manifest is the missing half. On Drew's
other machines (Framework laptop/NixOS, work Mac), nix/home-manager already
covers this layer and mise would be a second system to keep honest. The one
place mise earns its keep is the hypothetical (and occasionally real)
nix-less limited environment — a borrowed laptop, a minimal container, a
teammate machine — where "one static binary + `mise install --locked`"
recreates the language toolchain in minutes and nix is not an option. The
draft `mise.toml` in this folder is scoped to exactly that experiment.

---

## 2. Dotfiles managers — the patterns the mature tools converged on

Five tools/mechanisms, one paragraph each, focused on transferable patterns.

**chezmoi** — *three-state model*: a **source state** (a git working tree,
default `~/.local/share/chezmoi`) is rendered through templates and
attributes into a computed **target state**, which is reconciled against the
**destination state** (what's actually in `$HOME`) [15]. The commands that
fall out of the model are the point: `chezmoi diff` (target vs destination,
no changes), `chezmoi status` (two-letter per-file summary), `chezmoi
verify` (exit 1 if destination ≠ target — built to be run from a timer/CI to
*detect drift*) [15][17][18]. Templates carry per-host/per-OS conditionals
(`.chezmoi.hostname`, `.chezmoi.os`) so one source produces different files
per machine [16]; filename attributes encode permissions (`private_`
→ 0600, e.g. `dot_ssh/private_config` → `~/.ssh/config` mode 600) because
git itself doesn't preserve them [16][18]; secrets are pulled from external
managers at apply time rather than committed [1-analogous: our rule, and
chezmoi documents secret-manager template functions].

**yadm** — *bare repo + in-place files*: yadm is git with a separate repo
dir and `$HOME` as work tree, plus three additions. (1) **Alternate files**:
`file##os.Darwin,hostname.host2` naming; yadm scores all variants and
symlinks the most specific matching one — per-class/OS/host/user variation
without templates [19]. (2) **Jinja templates** (`##yadm.j2`) when a symlink
variant isn't enough. (3) **Encryption of a listed file set** into an archive
in the repo (GPG/openssl), and a **bootstrap** hook run after clone.
Permissions get first-class treatment too (e.g. `yadm.ssh-perms` fixes
`~/.ssh` modes by default) [from yadm man page in 19 batch].

**GNU Stow** — *symlink farm with a two-phase algorithm*: packages are
directory trees; stowing links their contents into a target tree, **folding**
a whole subdirectory into one symlink when possible and splitting it open
when another package needs in. Since Stow 2.0, installation is two-phase:
scan *everything* for conflicts first; if any conflict exists, report all of
them and **modify nothing** — no more half-stowed trees [21]. A symlink that
already points where Stow wants is *not* a conflict (re-stowing is a no-op);
a plain file in the way *is*, and the only sanctioned resolutions are
manual or `--adopt`, which moves the file *into* the package (so you can
`git diff` it) rather than deleting it [20][21]. `-n/--simulate` is the
built-in dry run.

**The bare-git-repo trick** (Atlassian-style) — yadm without yadm:
`git init --bare ~/.dotfiles`, an alias
`config = git --git-dir=… --work-tree=$HOME`, and the one setting everyone
learns the hard way: `status.showUntrackedFiles no`, without which every
`status` drowns in the entire untracked home directory [22][23]. Files are
tracked *in place* (no symlinks at all); checkout on a new machine fails on
pre-existing files (`.bashrc` etc.) until they're removed or forced [23] —
the conflict problem again, solved by hand.

**dotbot** — *declarative YAML, boring on purpose*: `link` (map of
target → source, with per-link `create`/`relink`/`force` semantics), `clean`
(remove dead links *that point into the dotfiles dir*), `create`
(directories, with modes), `shell` (arbitrary commands). The stated design
contract: **"bootstrap configurations should be idempotent — the installer
should be able to be run multiple times without causing any problems"**
[24]. Note its defaults are more aggressive than ours (relink replaces
wrong-target symlinks; force overwrites) — the difference is that dotbot
makes you *say so in config*, per link if you want.

**rcm** (thoughtbot) — worth one line for two ideas: `lsrc`, a *read-only
listing* of every managed file and its destination (the whole suite is built
on that enumeration — `rcup`/`rcdn`/`mkrc` all consume it), and priority
tiers `host-HOSTNAME/` > `tag-TAG/` > base for per-host variation [25].

---

## 3. Audit — our setup against those patterns

Our setup has **two different symlink systems**, and they audit very
differently. Conflating them is the easiest way to misread this table:

- **System P (personal links)** — `~/tools/init.sh`, `check_personal_links()`:
  13 canonical paths (`MEMORY.md`, `USER.md`, …, `memory`, `logs`,
  `workspace/goals`, …) are absolute symlinks into the sibling private repo
  `~/hatch-personal`. Runs on every 5-minute boot-init poll, not just boot.
- **System S (submodule registry)** — `library/submodules.md` +
  `scripts/link-submodules.sh`: 7 core repos pinned as bare gitlinks under
  `repos/` in the public repo; the script shallow-materializes one on demand
  (`git submodule update --init --depth 1`) and symlinks it to its working
  location (`~/git/…`) *only if nothing exists there*.

| # | Pattern / pitfall | What mature tools do | What we do | Aligned? | Recommended fix (proposal) |
|---|---|---|---|---|---|
| 1 | **Drift detection / verify mode** | chezmoi: `status`/`diff`/`verify` (exit code) as first-class read-only commands, meant to run on a timer [17][18]. rcm: `lsrc` read-only enumeration under everything [25]. | **P: yes, and better than detect-only** — every poll re-points wrong-target links and logs it; that's drift *repair*, continuously. **S: none** — nothing checks that a materialized submodule is at its pinned SHA, that `~/git/<x>` matches the pin, or that the pin still matches upstream intent. Also **P has one hole**: a link whose `readlink` string is correct but whose target is *missing* (dangling) passes the check silently — the `-L` branch `continue`s on string equality without testing target existence. | Partial (P strong w/ hole, S absent) | Add a read-only `--verify` mode to `link-submodules.sh` (and a `verify-personal-links` equivalent report): link exists? target exists? materialized SHA == gitlink SHA? Report, don't repair. Fix the dangling-link hole in P (appendix A.2). |
| 2 | **Conflict: target already exists as a real file/dir** | Stow: two-phase — any conflict aborts *before any modification*, all conflicts listed [21]. dotbot: explicit per-link `force`/`relink` in config [24]. Bare-git: checkout refuses, you resolve by hand [23]. | **S: silently leaves it alone** and prints one line. Safe (never destroys), but *ambiguous*: "real clone, identical to pin" and "real clone, 400 commits diverged from pin" produce the same message and no record. **P: the mature behaviour** — a real file where a link belongs is moved to a timestamped `.desync-backup/`, and if it's a file *newer* than the repo copy its content is first copied into the repo. Nothing is silently dropped. | S: safe but under-specified. P: aligned | S: keep never-overwrite, but classify and report: real dir + is a git repo → print its HEAD and ahead/behind vs the pin; non-repo → warn loudly. (Appendix A.1.) |
| 3 | **Backup before overwrite** | Stow `--adopt` moves the conflicting file *into* version control for diffing, never deletes [20]. chezmoi apply prompts/backs up per config. | **P: yes** (`.desync-backup/<name>.<timestamp>`, plus newer-content sync — arguably better than `--adopt` for our case). **S: n/a** (never overwrites). init.sh's other steps follow the documented house rule (nix-ensure moves a bad tree aside as `.bad.<timestamp>`, never deletes — `~/TOOLS.md`). | Yes | None for P. Keep the rule explicit when S gains any replace mode: backup first, always, timestamped. |
| 4 | **Dry-run / simulate mode** | Stow `-n`; chezmoi `apply --dry-run --verbose`, `diff` [18][21]. | **Neither system has one.** The script's actions are few and mostly read-only-safe, but "what would this do on a fresh recycle / a new machine?" currently can't be answered without running it. P's guard runs automatically every 5 min — there is no way to preview its repairs either. | No | `--dry-run` flag on `link-submodules.sh` (echo the submodule update + link actions; appendix A.1 includes it). For P, a `DRY_RUN=1` env gate on the repair actions of `check_personal_links`, log-only. |
| 5 | **Idempotency & half-applied state** | dotbot's stated contract: re-runnable without problems [24]. Stow 2.0 two-phase exists precisely to avoid half-applied trees [21]. | **Mostly yes, by smallness.** `link-submodules.sh` re-run is a no-op where work is done; but it's a sequential loop under `set -e`: if name #2's `submodule update` fails (network), #1 stays materialized and #3 never runs — a half-applied *batch* (recoverable by re-running, and each item is independent, so severity is low). P's guard is per-link independent and re-runs every poll — self-healing by design (and TOOLS.md records it recovering a mid-run interrupted init: re-run was the whole fix). | Yes, with a note | Make S's loop collect failures and continue, exiting non-zero with a summary at the end (appendix A.1) — same semantics as init.sh's `run_step` failure accounting. |
| 6 | **Absolute vs relative symlinks** | Stow creates *relative* links by default (its trees are designed to be relocatable); chezmoi copies/renders real files (no link-target problem); yadm links are within `$HOME`. | **Absolute everywhere**: P links point at `/home/hatch/hatch-personal/…`; S links at `$REPO_ROOT/repos/…` resolved absolutely. In *this* environment that's the right call: `/home/hatch` is the fixed persistent root, the overlay/recycle model means relative links offer nothing, and absolute targets make `readlink` audits unambiguous. The cost appears only on *other* machines: clone hatch-personal anywhere else (Framework laptop home is not `/home/hatch`) and every link points at a nonexistent path. | Yes — for this environment | Document the assumption in submodules.md ("links assume the canonical home root; on another host, re-run the linker rather than copying links"). If cross-machine reuse ever becomes real, P's links could be relative (`hatch-personal/MEMORY.md` resolves from the link's own directory) — note as an option, don't do it now. |
| 7 | **Permissions / modes on linked & sensitive files** | chezmoi encodes modes in filename attributes (`private_` → 0600) because git tracks only the exec bit [16][18]. yadm actively repairs `~/.ssh` perms [19]. | **Avoided structurally**: secret *values* are never in either repo (AGENTS.md STRICT rule), token files live outside the repos and are inventoried by path/size only, so no link in P or S points at a secret. Residual gaps: (a) git won't preserve a 600 mode if a sensitive-ish file ever *is* committed to hatch-personal — nothing checks modes after checkout; (b) P's desync path copies a real file's *content* into hatch-personal — if that file ever contained a secret, the copy lands in a git working tree, one careless `git add -A` from a private-repo commit (private, but still a secret in git history). | Mostly | Add a modes line to the proposed `--verify`: for the 13 P targets, warn if any is group/world-readable. Add a comment at the desync branch reminding that the synced copy must be eyeballed before committing. |
| 8 | **Empty-directory handling** | git itself tracks no empty dirs — every tool works around it (dotbot `create`, chezmoi `empty_` attribute). | P links whole directories (`memory`, `logs`, `workspace/goals`); if a target dir is deleted from hatch-personal, that's the dangling case in row 1. S: `mkdir -p` of the link's parent only. No empty-dir placeholders needed anywhere so far. | Yes | None, beyond row 1's fix. |
| 9 | **`.gitignore` interplay** | chezmoi has `.chezmoiignore` as a deliberate, visible list; bare-git setups use `showUntrackedFiles no` as the equivalent pressure valve [22]. | **Known live case**: root `.gitignore` line 56 is `AGENTS.md`, which made `library/AGENTS.md` invisible to git until force-added (`git add -f`) during the library build — recorded in MEMORY.md. Hazard: any *future* agent adding a file matching an ignore pattern gets a silent no-op commit and believes the file is published. S itself is clean (gitlinks + `.gitmodules` are tracked normally). | Partial | Add a pre-commit habit (already half a house rule): after staging, `git status` *and* `git check-ignore` on any new path that didn't stage. Cheap fix: narrow `.gitignore:56` to `/AGENTS.md` (root-only) — the root AGENTS.md is the private symlink and stays ignored; `library/AGENTS.md` stops needing `-f`. (Proposal only — `.gitignore` not edited.) |
| 10 | **Submodule pin drift & uncommitted submodule content** | (git-native problem; dotfiles tools mostly dodge it by not using submodules for state.) | **Pin drift: handled by policy, not mechanism** — submodules.md says updating a pin is a deliberate commit with a reason, and registration SHAs were verified against live HEADs at registration (verified again for this review: `git ls-files -s repos/` matches the doc table; all 7 show `-` = unmaterialized in `git submodule status`, as designed). But nothing *re*-checks: a pin can silently rot for months and the first symptom is a confused materialize. **Uncommitted content: dodged by design** — working clones live in `~/git/…` as real repos; the `repos/` gitlink is touched only deliberately. If someone *does* work inside a materialized `repos/<name>`, nothing warns them their commits are on a detached HEAD at the pin. | Partial | The row-1 `--verify` should also compare each pin against the remote default-branch HEAD (network permitting) and report "pin is N commits behind upstream" as *information*, not an error. Add one line to submodules.md: never work inside `repos/`; it's a cache of the pin. |
| 11 | **Per-host conditional differences** | chezmoi templates on hostname/OS [16]; yadm alternates score class/OS/host/user [19]; rcm `host-`/`tag-` tiers [25]. | **None, and currently correctly so.** P and S exist only in this sandbox; Drew's Framework laptop is NixOS/home-manager and the work Mac is its own setup — three unrelated systems, not one config rendered three ways. `PERSONAL_LINKS` is a flat list with no host axis because there is exactly one host. The risk is future: if the hatch-personal pattern is ever cloned to a second machine, the flat list + absolute paths (row 6) break together. | Yes, for now | No mechanism. Add one sentence to submodules.md naming the trigger: "if this pattern is adopted on a second host, stop and add a host axis (per-host link list) first — borrow yadm's class/host scoring or chezmoi's template vars, don't improvise." |
| 12 | **Secrets leaking via template/link into the public repo** | chezmoi's answer is secret-manager template functions + never committing rendered output; mise's docs: keep secrets out of committed config, use a secret provider [1]. | **Strongest row in this audit.** There are no templates anywhere in P or S — links point at whole files in a *separate private repo*, the public/private split was made before the public flip with a leak audit (one real leak found and scrubbed, per MEMORY.md), and AGENTS.md's STRICT secrets rule + surgical-staging rule are written down. The one structural watch-item: S's links and the public repo's `library/` docs are one repo — any future doc-generation step that *renders* private content into `library/` would cross the boundary; today nothing renders anything. | Yes | Keep it that way: if a mise.toml or any templated file is ever added to the public repo, it must reference secrets by Bitwarden *name* only (as the draft in this folder does). |
| 13 | **Single source of truth for the link map** | dotbot/rcm: one declarative file enumerates everything; `lsrc` can list the managed set on demand [24][25]. | **Duplicated in S**: the name set lives in *three* places that must agree — `.gitmodules`, `git ls-files` gitlinks, the script's `WORKDIR` table — plus a fourth, the table in submodules.md (which today agrees; verified). `WORKDIR` also silently treats an *unknown* name as "no mapping" path: run the script with a typo'd name and git errors opaquely mid-loop (row 5) instead of "unknown submodule". P has the inverse shape: one list (`PERSONAL_LINKS`) in init.sh, no doc copy to drift. | Partial | Validate names against `WORKDIR`/`.gitmodules` up front with the known-names usage error the script already has for the no-args case (appendix A.1). Longer term, generate the script's table from `.gitmodules` + a small mapping file. |
| 14 | **Adoption path (existing file → managed)** | Stow `--adopt`, dotbot `force`, chezmoi `add`, rcm `mkrc`, yadm `add` — every mature tool has a deliberate "bring this existing file under management" verb [16][20][25]. | **P: yes, emergent** — the desync repair *is* an adoption path (real file → backed up → newer content synced → link restored), arrived at from failure, not design. **S: manual** — making an existing `~/git` clone "the" working location is just "it exists, script leaves it alone"; there's no verb that records *which* clone is canonical if two exist. | Mostly | None needed now; if S grows, name P's behaviour in init.sh's comments as the adoption path so a future agent recognizes it as a feature, not an accident. |

### 3.1 Prioritized fix list (proposals only)

1. **[P1 — correctness] Dangling-link hole in `check_personal_links`** (row 1):
   a link with the right target *string* but a missing target passes every
   poll. One-line existence test; diff in Appendix A.2.
2. **[P1 — visibility] `--verify` (report-only) mode covering both systems**
   (rows 1, 7, 10): links present/pointing right/targets exist; S pins vs
   materialized SHA vs remote HEAD; modes on P targets. chezmoi's lesson is
   that verify earns its keep as a *separate exit-coded command* you can run
   from a cron and alert on, not as more repair logic [17].
3. **[P2 — ambiguity] Classify the "working location already exists" case in
   `link-submodules.sh`** (row 2) + validate names + continue-on-error with a
   summary (rows 5, 13). Diff in Appendix A.1.
4. **[P2 — silent-publish hazard] Narrow `.gitignore`'s `AGENTS.md` to
   `/AGENTS.md`** (row 9), or document the force-add in the commit checklist
   in `library/AGENTS.md`. Either is fine; the current state (global pattern
   + tribal knowledge) is the only bad option.
5. **[P3 — ergonomics] `--dry-run` for S** (row 4) — mostly free once
   `--verify` exists (verify = state report; dry-run = action report).
6. **[P3 — documentation] Two sentences**: absolute-path assumption + re-run
   don't-copy-links (row 6), and the second-host trigger (row 11), into
   `library/submodules.md`.
7. **[P4 — experiment only] mise for nix-less environments** (§1.4): keep the
   draft `mise.toml` in this folder; do not install mise in the sandbox,
   where it would compete with the dispatcher.

---

## Appendix A — proposed diffs (NOT applied)

### A.1 `scripts/link-submodules.sh` — name validation, dry-run, continue-on-error, exists-classification

```diff
@@
 if [ "$#" -lt 1 ]; then
   echo "usage: $0 <name> [<name> ...]" >&2
   echo "known: ${!WORKDIR[*]}" >&2
   exit 2
 fi
+
+# Validate all names up front (a typo currently fails opaquely inside git,
+# mid-loop). Also accept --dry-run as the first argument.
+DRY_RUN=0
+if [ "$1" = "--dry-run" ]; then DRY_RUN=1; shift; fi
+for name in "$@"; do
+  if [ -z "${WORKDIR[$name]+x}" ]; then
+    echo "unknown submodule: $name (known: ${!WORKDIR[*]})" >&2
+    exit 2
+  fi
+done
+
+FAILURES=0
 for name in "$@"; do
   path="repos/$name"
   if [ ! -e "$REPO_ROOT/$path/.git" ] && [ ! -f "$REPO_ROOT/$path/.git" ]; then
-    git -C "$REPO_ROOT" submodule update --init --depth 1 -- "$path"
+    if [ "$DRY_RUN" = 1 ]; then
+      echo "$name: would run: git submodule update --init --depth 1 -- $path"
+    elif ! git -C "$REPO_ROOT" submodule update --init --depth 1 -- "$path"; then
+      echo "$name: submodule update FAILED" >&2; FAILURES=$((FAILURES+1)); continue
+    fi
   else
     echo "$name: already materialized at $path"
   fi
   target="${WORKDIR[$name]:-}"
   if [ -n "$target" ]; then
     if [ -e "$target" ] || [ -L "$target" ]; then
-      echo "$name: working location $target already exists — leaving it alone"
+      # Classify instead of a blanket 'leaving it alone': a real git clone
+      # gets its HEAD reported against the pin; anything else is a warning.
+      if [ -d "$target/.git" ] || [ -f "$target/.git" ]; then
+        head_sha=$(git -C "$target" rev-parse --short HEAD 2>/dev/null || echo "?")
+        pin_sha=$(git -C "$REPO_ROOT" ls-files -s "$path" | awk '{print substr($2,1,7)}')
+        echo "$name: working location $target is a real clone (HEAD $head_sha, pin $pin_sha) — leaving it alone"
+      elif [ -L "$target" ]; then
+        echo "$name: working location $target is a symlink to $(readlink "$target") — leaving it alone"
+      else
+        echo "$name: WARNING working location $target exists and is not a git repo — leaving it alone" >&2
+      fi
     else
-      mkdir -p "$(dirname "$target")"
-      ln -s "$REPO_ROOT/$path" "$target"
-      echo "$name: $target -> $path"
+      if [ "$DRY_RUN" = 1 ]; then
+        echo "$name: would link $target -> $REPO_ROOT/$path"
+      else
+        mkdir -p "$(dirname "$target")"
+        ln -s "$REPO_ROOT/$path" "$target"
+        echo "$name: $target -> $path"
+      fi
     fi
   fi
 done
+if [ "$FAILURES" -gt 0 ]; then
+  echo "link-submodules: $FAILURES failure(s)" >&2
+  exit 1
+fi
```

A companion `--verify` mode (row 1/10) is ~15 more lines in the same style:
for each registered name, print pin SHA (from `git ls-files -s`), whether
`repos/<name>` is materialized and at what SHA, whether the working-location
link/clone exists, and — when online — `git ls-remote` HEAD for comparison.
Report only; exit non-zero if any materialized SHA ≠ pin.

### A.2 `~/tools/init.sh` — dangling-link hole in `check_personal_links`

Current logic (read 2026-10-21): if the path is a symlink, it re-points it
when the target string differs, then `continue`s — never checking that the
target exists. A link can therefore dangle forever with a "correct" string.

```diff
     if [ -L "$link" ]; then
       if [ "$(readlink "$link")" != "$target" ]; then
         echo "[$START_DT] init: personal-link '$rel' pointed at $(readlink "$link") — re-pointing" >> "$LOG"
         ln -sfn "$target" "$link"
       fi
+      if [ ! -e "$target" ]; then
+        echo "[$START_DT] init: personal-link '$rel' DANGLING — target $target missing from repo" >> "$LOG"
+      fi
       continue
     fi
```

(Report-only: a missing target is a repo problem, not something init should
invent content for — matching the existing BROKEN branch's behaviour.)

---

## Sources (all accessed 2026-10-21)

Mise (official, mise.jdx.dev unless noted):
- [1] Use mise in an existing project / walkthrough — config hierarchy, `mise.local.toml`, lockfile commit, wrapper install script, trust-on-install: http://mise.jdx.dev/walkthrough.html
- [2] Mise in Docker — `mise trust && mise install --locked`, per-platform lockfiles: https://mise.jdx.dev/mise-cookbook/docker.html
- [3] Getting started — trust model ("config … can run code"), `mise use`, lockfile purpose: https://mise.jdx.dev/getting-started.html
- [4] Security overview — trust storage, safe mode and its limits: https://mise.jdx.dev/security.html
- [7] Backends — full backend table (core/aqua/github/packslip/http/cargo/go/npm/pypi/asdf legacy/ubi deprecated): http://mise.jdx.dev/dev-tools/backends/
- [8] Adding tools to the registry — backend tiers, asdf/vfox rejected for supply-chain reasons, ubi removal: https://mise.jdx.dev/contributing/registry.html
- [9] Lockfile (mise.lock) — per-backend record table (URL+checksum vs version-only): https://mise.jdx.dev/dev-tools/mise-lock.html
- [10] Walkthrough (existing project) — `.tool-versions` native, idiomatic version files opt-in, `--pin` vs prefixes: http://mise.jdx.dev/walkthrough.html
- [11] Python page — idiomatic version file mechanics: https://mise.jdx.dev/lang/python
- [12] Shims — shim mechanics, fallback-to-system-binary warning, `mise exec` without activation: https://mise.jdx.dev/dev-tools/shims.html
- [13] Shell activation & login shell — activate vs `--shims` per startup file: https://mise.jdx.dev/bootstrap/shell.html
- [14] Codebase architecture — core/backends/lockfile/bootstrap/dotfiles module map: https://mise.jdx.dev/architecture.html
- [5] Settings reference — lockfile settings/semantics: https://mise.jdx.dev/configuration/settings.html

chezmoi:
- [15] Chezmoi and Git: three-state model (source/target/destination), diff semantics: https://blog.hofstede.it/chezmoi-and-git-dotfiles-without-pretending-every-machine-is-the-same/
- [16] Chezmoi tutorial — `private_` attribute → 0600, `.tmpl` hostname/OS conditionals, `init --apply` bootstrap: https://www.amireslampanah.com/tutorials/chezmoi-dotfile-management.html
- [17] Core state management commands — status/diff/verify implementations, verify exit code: https://deepwiki.com/twpayne/chezmoi/4.2-core-state-management-commands
- [18] chezmoi verify reference (mirror) — verify as drift alarm incl. systemd timer pattern, status/diff loop: https://www.mintlify.com/twpayne/chezmoi/commands/verify

yadm:
- [19] Alternate files (official) — `##os.…##`, `##class.…##`, scoring, alt dir: https://yadm.io/docs/alternates ; yadm(1) man page (alternates, Jinja templates, encryption list, ssh-perms): https://manpages.debian.org/unstable/yadm/yadm.1.en.html

GNU Stow (official manual):
- [20] Stow manual (docs mirror) — `--adopt` semantics, `--simulate`: https://docs.jade.fyi/gnu/stow.html
- [21] Stow manual, Conflicts — two-phase algorithm since 2.0, same-target symlink is not a conflict, abort-without-modification: https://www.GNU.ORG/software/stow/manual/stow.html

Bare-git-repo trick:
- [22] Guide to work with dotfiles — bare repo + alias + `status.showUntrackedFiles no` rationale: https://github-wiki-see.page/m/dhruvinsh/dotfiles/wiki/Guide-to-work-with-dotfiles
- [23] Bare repo approach — checkout conflicts on pre-existing files, `-f` decision: https://www.bowmanjd.com/dotfiles/dotfiles-2-bare-repo/

dotbot:
- [24] Dotbot README (via GitHub mirror) — "bootstrap configurations should be idempotent", defaults/relink/create, clean/link/shell directives: https://github.heygears.com/anishathalye/dotbot/tree/b062aeaf15f1b174f6c9b88a0b2017b06d7fbd3e ; directive semantics: https://deepwiki.com/anishathalye/dotbot/3.2-create-shell-clean-and-defaults-directives

rcm:
- [25] rcm core commands — `lsrc` enumeration, `mkrc` adoption, `rcup`/`rcdn`, host/tag tiers, hooks: https://deepwiki.com/thoughtbot/rcm/3-core-commands

Local files read 2026-10-21: `/home/hatch/library/submodules.md`,
`/home/hatch/scripts/link-submodules.sh`, `/home/hatch/tools/init.sh`
(`check_personal_links`, lines 53–98), `/home/hatch/.gitmodules`,
`/home/hatch/.gitignore` (line 56), `git ls-files -s repos/`,
`git submodule status`, `/home/hatch/library/AGENTS.md`,
`/home/hatch/library/toolchains/index.md`, `~/TOOLS.md` (sandbox/recycle model,
dispatcher pinning rules, nix-ensure backup behaviour).
