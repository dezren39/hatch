# TOOLS.d/git.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

## Git credential helper (fixed 2026-10-02)
- `~/.gitconfig`'s `credential.https://github.com.helper` had pinned a literal nix store path (`!/home/hatch/nix-persist/store/<hash>-gh-2.101.0/bin/.gh-wrapped auth git-credential`); store layout drift killed the `.gh-wrapped` wrapper and every `git push` died with "could not read Username". NEVER pin absolute nix store paths in user configs — use the PATH-resolved `!gh auth git-credential` (gh reads its token from ~/.config/gh/hosts.yml). Backup at ~/.gitconfig.bak-20261002-1356.

## Git repo layout (hit 2026-10-01)
- `~/hatch-personal` is the tracked git repo for notes/TODO/docs (origin → dezren39/hatch-personal).
- `/home/hatch` is ALSO its own separate enclosing git repo — do NOT run `git status/add/commit` from there for nix-program work; it shows a clean/foreign tree and is not where the check commits live.
- `~/notes/TODO.md` is a SYMLINK to `~/hatch-personal/nix-program-TODO.md` — commit with `git -C ~/hatch-personal`. `~/workspace` is a REAL directory in the dezren39/hatch repo (/home/hatch) — but `~/workspace/goals` is a SYMLINK → `/home/hatch/hatch-personal/workspace/goals`, so goal files/demo-script live in the hatch-personal tree (commit them with `git -C ~/hatch-personal`, alongside the TODO edits). Other symlinks into the repo: `~/memory` → `~/hatch-personal/memory`, `~/logs` → `~/hatch-personal/logs`.

## plaza git-env object dir (found 2026-10-28)
- Laptop fleet worktrees: `source /home/user/.local/share/plaza-tools/git-env.sh` sets GIT_OBJECT_DIRECTORY=/home/user/code/.git/plaza-objects. If that dir does not exist, EVERY git command in the worktree dies with `fatal: not a git repository: (null)` and long jobs hang silently. Fix: `mkdir -p /home/user/code/.git/plaza-objects`. It was missing on 2026-10-28 (cost ~35 min on a hung patch job); created it and git worked immediately.
