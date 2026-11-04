# SUPERSEDED — source of truth moved to developing-today/code

2026-11-04, fleet epic step 2 (developing-today/code#5430): the
broker family's canonical source now lives in the code repo at
`pkgs/fleet/crates/fleet-queue/` (with the standalone artifacts
built by the `fleet-brokers` nix package from the same tree).

This sandbox workspace is archived in place as the pre-migration
reference. Do not develop here; do not delete (rollback evidence).
The binaries it built remain the rollback inventory for the
laptop's broker units alongside the in-repo standalones.
