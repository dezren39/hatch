# How files reach Drew (and where things live)

Written 2026-10-21 because Drew asked the fair question: when a file is "in the library", how did it get there, and how would anyone find it again without digging through 50 chats?

## The places

- **`dezren39/hatch` (this repo, public)** — tooling, sandbox docs, `library/` (curated docs), `reports/` (dated reports/summaries), `archive/` (verbatim copies kept for tracking changes). Rooted at `/home/hatch` itself.
- **`dezren39/hatch-personal` (private)** — memory, personality, instructions, goals, private docs (e.g. the Turso plan), `junk/` for private bulk copies. Real files live there; symlinks at their original home paths point into it.
- **`~/workspace/`** — the agent's working area on this machine, defined by Muse's own system/runtime documentation (not a git worktree, not a per-chat thing). Inside it: `goals/<slug>/` per goal or tracked item (`files/` = documents Drew sees as that item's documents in the Goals tab; `hidden_files/` = the agent's bookkeeping, not shown), `your_files/` for deliverables not tied to a goal, `custom-skills/`, and topic folders (e.g. `workspace/turso/`).
- **The Muse app Library tab** — surfaces artifacts and files the agent produces through the app's own mechanisms; it is a *view*, not a directory the agent writes to directly. If Drew needs a file, the reliable paths are: a goal's `files/` (shown in the app), an artifact link, a GitHub link, or a Google Drive link — not "search the chats".
- **Google Drive** — bulky backups that don't belong in git: `Muse Backups` (session-log tarballs) and `Muse Avatar Backup` (avatar source + renders). See `reports/` for the backup ledger.

## The chain of events that puts a doc in `library/`

1. Work happens wherever it happens (a chat, a subagent, a sweep) and produces drafts, usually under `~/workspace/library-build/` or a goal workspace.
2. The main agent reviews, classifies (public-safe vs private vs secret), and copies the finished doc into `library/` (public) or hatch-personal's `library/` (private) — the curation step. `library/` is a *gathered, curated* selection: relevant, kept current, worth knowing.
3. The copy is committed and pushed in the same pass; the commit is the record of when that version landed.
4. Nothing leaves `library/` without a trace: git history holds the last hash of every removed version, so deletion from the library never destroys the content.

## Reports vs library

- `reports/` = dated outputs of work: summaries, audits, one-off analyses, things that may grow to 50 pages with graphs, images, even a short video. They record what happened at a time.
- `library/` = the curated shelf: the subset of documents that stay relevant and maintained. A report graduates to the library when it becomes reference material; it doesn't have to.
