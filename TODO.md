# TODO

## Consider adding to git (currently untracked, on disk only)

These were pulled out of git on 2026-09-30 during the sensitivity audit.
Decide with Drewry whether each should stay out or go back in.

- [ ] **SOUL.md** — assistant persona. Currently untracked. Consider: is the
  persona something to share, or personal to this setup?
- [ ] **IDENTITY.md** — assistant name/vibe/avatar description. Currently
  untracked. Same question as SOUL.md.
- [ ] **HEARTBEAT.md** — recurring checks checklist (currently empty template).
  Will reveal what gets monitored once filled in. Consider: share the
  checklist, or keep private?
- [ ] **agents/** — subagent session metadata (sessions.json). Pulled out as
  too sensitive. Transcripts (.jsonl) were never tracked. Revisit only if a
  safe subset is identified.
- [ ] **AGENTS.md** — assistant operating manual / work conventions.
  Currently untracked. Consider: share the playbook, or keep private?

## Decided: keep out of git

- **MEMORY.md** — full personal history. Never track.
- **USER.md** — user profile. Never track.
- **PROACTIVE_PREFERENCES.md** — notification preferences. Never track.
- **docs/** — Meta's platform docs. Never track (Meta maintains them).
- **logs/**, **nix-persist/**, **user/**, **workspace/** (except avatars) —
  runtime state, too large or too personal.
