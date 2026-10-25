# memory-cli.md — the `mem` CLI

`mem` (~/tools/mem.py, shim at ~/tools/mem, symlinked from ~/tools/bin/mem) lets
sessions write to memory and look things up WITHOUT reading MEMORY.md (~47KB)
or a whole topic file into context. Writes are append-only and flock-serialized
($MEM_HOME/memory/.mem.lock), so concurrent sessions never interleave or lose
lines. Base dir is $MEM_HOME (default /home/hatch).

Rule of thumb: **writes are append-only — never read a file just to append to it.**

Commands:
- `mem topics` — list topics: slug, bytes, first heading (stat + first line only).
  Example: `mem topics`
- `mem add "<text>"` — append a bullet under `## Inbox` at the end of MEMORY.md.
  Example: `mem add "Fact: the fleet backup runs nightly."`
- `mem topic <slug> "<text>"` — append a dated bullet to memory/topics/<slug>.md
  (created with a header if new). Example: `mem topic nix-notes "Store pin bumped to rev abc123."`
- `mem search "<term>"` — case-insensitive search over MEMORY.md + all topics,
  max 20 lines shown. Example: `mem search "tailscale"`
- `mem show <slug>` — print a topic; >200 lines shows head 50 + tail 20 only.
  Example: `mem show nix-notes`

Limits:
- `mem add --force "<reason>" "<text>"` bypasses the size limit; the reason
  is required and the override is logged to ~/memory/mem-events.log.
- `mem add` refuses text over **600 chars** (exit 3) — that's MEMORY.md's
  hygiene rule enforced mechanically. Put the long text in a topic with
  `mem topic`, then `mem add` a short summary + pointer.
- `mem topic` warns over 2,000 chars but still writes. Slugs are lowercase
  letters/digits/hyphens only (exit 2 otherwise).
