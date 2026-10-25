#!/usr/bin/env python3
"""mem — token-friendly memory CLI for agent sessions.

Append to MEMORY.md / memory topic files and search/show them in bounded
form WITHOUT reading whole files into context. Writes are append-only and
flock-serialized so concurrent sessions never interleave or lose lines.

Base dir: $MEM_HOME (default /home/hatch).
  MEMORY.md  $MEM_HOME/MEMORY.md
  topics     $MEM_HOME/memory/topics/<slug>.md
  lockfile   $MEM_HOME/memory/.mem.lock
"""
import fcntl
import os
import re
import sys
from datetime import date

MEM_HOME = os.environ.get("MEM_HOME", "/home/hatch")
MEMORY_MD = os.path.join(MEM_HOME, "MEMORY.md")
TOPICS_DIR = os.path.join(MEM_HOME, "memory", "topics")
LOCKFILE = os.path.join(MEM_HOME, "memory", ".mem.lock")

ADD_LIMIT = 600          # MEMORY.md hygiene rule: bullets <= ~600 chars
TOPIC_WARN = 2000        # warn (but still write) above this
SEARCH_CAP = 20
SLUG_RE = re.compile(r"^[a-z0-9-]+$")


def ensure_dirs():
    os.makedirs(TOPICS_DIR, exist_ok=True)


class Lock:
    """Exclusive flock on the lockfile for the whole read-modify-append."""

    def __enter__(self):
        ensure_dirs()
        self._fh = open(LOCKFILE, "a+")
        fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
        self._fh.close()
        return False


def append_bytes(path, data: bytes):
    """Single write + flush + fsync append."""
    with open(path, "ab") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())


def read_text(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------- topics ---
def cmd_topics(_args):
    ensure_dirs()
    rows = []
    for name in sorted(os.listdir(TOPICS_DIR)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(TOPICS_DIR, name)
        if not os.path.isfile(path):
            continue
        slug = name[:-3]
        size = os.path.getsize(path)
        first = ""
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    first = line.lstrip("#").strip()
                    break
        rows.append(f"{slug}\t{size}\t{first[:80]}")
    for row in rows:
        print(row)
    return 0


# ------------------------------------------------------------------- add ---
def cmd_add(args):
    if len(args) != 1:
        print('usage: mem add "<text>"', file=sys.stderr)
        return 2
    text = args[0]
    if len(text) > ADD_LIMIT:
        print(
            f"refused: {len(text)} chars exceeds the {ADD_LIMIT}-char MEMORY.md "
            "bullet limit. Long detail belongs in a topic file: use "
            "`mem topic <slug> \"<text>\"` and, if it must be in MEMORY.md, add "
            "a short summary + pointer with `mem add` instead.",
            file=sys.stderr,
        )
        return 3
    bullet = f"- {text}\n"
    with Lock():
        content = read_text(MEMORY_MD)
        lines = content.splitlines(keepends=True)
        # Find the last "## Inbox" section, if any.
        inbox_idx = None
        for i, line in enumerate(lines):
            if line.strip() == "## Inbox":
                inbox_idx = i
        if inbox_idx is None:
            chunk = ("" if (not content or content.endswith("\n")) else "\n")
            chunk += "\n## Inbox\n\n" + bullet
            append_bytes(MEMORY_MD, chunk.encode("utf-8"))
        else:
            # End of the Inbox section = next "## " header or EOF.
            end = len(lines)
            for j in range(inbox_idx + 1, len(lines)):
                if lines[j].startswith("## "):
                    end = j
                    break
            if end == len(lines):
                chunk = bullet
                if content and not content.endswith("\n"):
                    chunk = "\n" + chunk
                append_bytes(MEMORY_MD, chunk.encode("utf-8"))
            else:
                lines.insert(end, bullet)
                with open(MEMORY_MD, "w", encoding="utf-8") as fh:
                    fh.write("".join(lines))
                    fh.flush()
                    os.fsync(fh.fileno())
    print(f"ok: MEMORY.md now {os.path.getsize(MEMORY_MD)} bytes")
    return 0


# ----------------------------------------------------------------- topic ---
def cmd_topic(args):
    if len(args) != 2:
        print('usage: mem topic <slug> "<text>"', file=sys.stderr)
        return 2
    slug, text = args
    if not SLUG_RE.match(slug):
        print(
            f"bad slug {slug!r}: lowercase letters, digits and hyphens only.",
            file=sys.stderr,
        )
        return 2
    today = date.today().isoformat()
    path = os.path.join(TOPICS_DIR, f"{slug}.md")
    line = f"- [{today}] {text}\n"
    with Lock():
        ensure_dirs()
        if not os.path.exists(path):
            header = (
                f"# {slug}\n\n"
                f"<!-- Created by mem CLI {today}. Full-detail overflow for "
                "MEMORY.md bullets. -->\n"
            )
            append_bytes(path, header.encode("utf-8"))
        append_bytes(path, line.encode("utf-8"))
    if len(text) > TOPIC_WARN:
        print(
            f"warning: text is {len(text)} chars (> {TOPIC_WARN}); "
            "written anyway, but consider trimming."
        )
    print(f"ok: topic {slug} now {os.path.getsize(path)} bytes")
    return 0


# ---------------------------------------------------------------- search ---
def cmd_search(args):
    if len(args) != 1:
        print('usage: mem search "<term>"', file=sys.stderr)
        return 2
    needle = args[0].lower()
    matches = []  # (source, line)
    sources = [("MEMORY", MEMORY_MD)]
    if os.path.isdir(TOPICS_DIR):
        for name in sorted(os.listdir(TOPICS_DIR)):
            if name.endswith(".md"):
                sources.append((name[:-3], os.path.join(TOPICS_DIR, name)))
    total = 0
    for source, path in sources:
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if needle in line.lower():
                    total += 1
                    if len(matches) < SEARCH_CAP:
                        matches.append((source, line[:200]))
    for source, line in matches:
        print(f"{source}: {line}")
    if total > SEARCH_CAP:
        print(f"({total} matches, capped at {SEARCH_CAP})")
    return 0


# ------------------------------------------------------------------ show ---
def cmd_show(args):
    if len(args) != 1:
        print("usage: mem show <slug>", file=sys.stderr)
        return 2
    slug = args[0]
    if not SLUG_RE.match(slug):
        print(
            f"bad slug {slug!r}: lowercase letters, digits and hyphens only.",
            file=sys.stderr,
        )
        return 2
    path = os.path.join(TOPICS_DIR, f"{slug}.md")
    if not os.path.exists(path):
        print(f"no such topic: {slug}", file=sys.stderr)
        return 1
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    n = len(lines)
    if n <= 200:
        for line in lines:
            print(line)
    else:
        for line in lines[:50]:
            print(line)
        print(f"... ({n} lines total, showing head/tail)")
        for line in lines[-20:]:
            print(line)
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    handlers = {
        "topics": cmd_topics,
        "add": cmd_add,
        "topic": cmd_topic,
        "search": cmd_search,
        "show": cmd_show,
    }
    if cmd not in handlers:
        print(f"unknown command: {cmd}", file=sys.stderr)
        print("commands: topics | add | topic | search | show", file=sys.stderr)
        return 2
    return handlers[cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
