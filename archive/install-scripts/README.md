# Install-scripts archive — index

**Standing rule (Drew, 2026-10-21):** for every CLI we install via a
script (`curl … | bash` and friends), keep at least one copy of the actual
install script in this archive, plus a README breaking down how it works —
captured the same day we run it. An install script is small, versioned,
and replayable evidence of provenance; a binary that "just exists" on the
box is none of those. When a tool turns out to have no recorded provenance
(like turso did), delete/reinstall it properly via its official script
and write down what was done — see the turso log below.

## Archived here

| Tool | Script | Source URL | Size | sha256 | Breakdown |
|---|---|---|---|---|---|
| Muse (Muse Code) | `muse-install-2026-10-21.sh` | https://dev.meta.ai/install.sh | 9,314 B | `5196d820…a0ca` | [README-muse-install.md](README-muse-install.md) |
| Turso CLI | `turso-install-2026-10-21.sh` | https://get.tur.so/install.sh | 8,091 B | `87e74f65…1931` | [README-turso-install.md](README-turso-install.md) |

Both were fetched 2026-10-21 with no redirect (final URL = source URL) and
are **byte-identical under a browser User-Agent** — neither endpoint does
UA-based switching. Full hashes are in the per-tool READMEs.

## Appendix — provenance of the other script-adjacent tools (no curl-install script to archive)

- **bws (Bitwarden Secrets Manager CLI) 2.1.0** — NOT a script install:
  official GitHub release zip (`github.com/bitwarden/sdk-sm`,
  `bws-x86_64-unknown-linux-gnu-2.1.0.zip`), binary at `~/tools/bin/bws`.
  Provenance documented in TOOLS.md (2026-10-07 entry). Token lives at
  `~/.config/bitwarden/access-token` (600); never archive the token here.
- **wrangler 4.147.0** — npm, deliberately off the ephemeral `/usr` prefix:
  installed with `npm --prefix ~/tools/wrangler`, reached via the
  `~/tools/bin/wrangler` symlink. Provenance in TOOLS.md / the library's
  cloudflare-wrangler doc.
- **opencode 1.18.31** — Nix flake/profile package (see `~/tools`, TOOLS.md
  opencode-service notes); served by the `opencode-serve` systemd unit via
  `~/tools/install-opencode-service.sh`. No curl-install involved.
- **turso (before 2026-10-21)** — was a dispatcher/omnibin stub resolving
  to a Nix store build (v1.0.30); replaced by the official install
  (v1.0.34) — full story in [README-turso-install.md](README-turso-install.md).
- **Everything else in `~/tools/bin`** — mostly dispatcher stubs (nix /
  omnibin resolution) or nix-profile symlinks; the toolchain docs in the
  library (`library/toolchains/`) are their provenance record.

## How to add an entry

1. `curl` the install URL to `<tool>-install-YYYY-MM-DD.sh` in this
   directory **before** (or the same day as) executing it — verbatim, no
   edits.
2. Record: final URL after redirects, HTTP status, byte size, sha256, and
   a UA check (default vs browser UA, diff).
3. Read the script; write `README-<tool>-install.md`: what it downloads,
   OS/arch switching, install location, checksum verification (or its
   absence), profile/PATH edits, and any env overrides.
4. If you run it, append a dated install log + post-install verification
   (version, auth/config still working) to that README.
