# Doc practices (loose, not a standard)

Common habits for documents in these repos. Loose on purpose — Drew, 2026-10-21: no header needs to go absolutely everywhere, but consistency where it's cheap makes versions comparable ("I liked this about 0.2, but this part of 0.35 I did not understand").

- **Cut versions get the version in the filename** (`turso-plan-v0.2.md`) at the moment you cut/upload them to a library.
- **Keep an unversioned "latest" copy** next to the versioned ones (`turso-plan.md`) — the file apps/other docs should point at. Update it in the same commit as the new version.
- **Iterative documents carry a Status line and a Changelog.** If work on a doc is chained and ongoing (not just "someone edited it 3 months later"), the changelog is how a reader reconstructs what changed and why. One line per version is enough.
- **One author in a file? Edit directly.** Many agents touching related files, or conflicts actually appearing? Work on a branch, push a **pull request, and merge it** — no reviews, no waiting on checks; the PR is merge protection and a conflict funnel, not a gate.
- **Merge commits are fine — preferred, even.** No squash/rebase dogma, and **never force-push main**. Rebase locally if you like; the merge history records what actually happened when a feature was built, which agents read better than humans read DAGs.
- **Worktrees are fair game**: a session can work in its own worktree and merge to main locally; commits to main get pushed promptly — never hoard them or ask "should I push?"
