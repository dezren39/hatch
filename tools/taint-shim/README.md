# taint-shim — LD_PRELOAD workaround for the sandbox taint-xattr filter

## Problem
This sandbox's kernel filter denies `removexattr()` on `user.hatch_tainted*`
with EPERM (verified on tmpfs and btrfs, even when the attribute doesn't exist).
nix-portable (bwrap backend, nix 2.20.6) hit this in two places:

1. **Unpacking flake inputs**: nix strips xattrs after unpacking tarballs into
   the store -> EPERM -> abort. (`nix run nixpkgs#hello`, 2026-09-29.)
2. **`nix::canonicalisePathMetaData_`** (libnixstore.so) calls
   `llistxattr(path, NULL, 0)` on every store path it canonicalises; with the
   taint attrs present it got `ERANGE` ("querying extended attributes of
   '<path>': Numerical result out of range") and threw. (2026-09-30.)
3. **Startup ownership fixup**: nix's LocalStore does `chown("/nix/store", ...)`
   on startup; the sandbox denies chown on the btrfs home volume even for
   root -> "changing ownership of '/nix/store': Operation not permitted".
   (2026-09-30.)

## What the shim does
Makes `user.hatch_tainted*` invisible to the process, elides redundant chowns,
and masks the /nix symlink's mode so the build sandbox accepts it:
- `removexattr`/`lremovexattr`/`fremovexattr` on taint attrs -> pretend success
- `getxattr`/`lgetxattr`/`fgetxattr` on taint attrs -> pretend absent (ENODATA)
- `listxattr`/`llistxattr` -> report and return the TAINT-FREE view only
- `chown`/`lchown`/`fchown`/`fchownat` -> elide when the requested uid/gid
  already match (or are -1); otherwise pass through and fail honestly
- `stat`/`lstat`/`stat64`/`lstat64` on `/nix` -> if it's a symlink, mask the
  mode to 0755 (symlinks always report 0777, which trips nix 2.35.2's build
  sandbox `checkNotWorldWritable`, derivation-builder.cc:356, when building
  as a build user). The symlink bit itself is reported truthfully.
- everything else passes through to real libc untouched

Phase-2 change (2026-09-30): the old full symlink spoofing (reporting /nix
as a directory) was removed. On nix 2.35.2, `allow-symlinked-store = true`
covers the LocalStore guard, and eval / local builds (as nixbld1) / add-file /
profile / gc / flake metadata+update all pass with only the mode mask. The
`real` store-dir setting from the phase-1 research does not exist in this nix
version ("unknown setting 'real'"). One pre-existing limitation, unaffected
by this change: fetching a fresh tarball flake (e.g. `builtins.getFlake
"nixpkgs"`) fails with "(or its ancestor) is a symlink" under both the old
and new shim — kernel-level O_NOFOLLOW check, not bypassable via stat.

Safety: nix hashing/NAR serialization ignores xattrs; ~500 MB of tainted
store paths already work fine. These attrs are sandbox metadata, not content.
Elided chowns are true no-ops by construction (stat shows the requested
uid/gid already match, or are -1 = unchanged); anything else passes through
and fails honestly. The shim is loaded for every nix invocation via
LD_PRELOAD in ~/tools/nix-ensure.sh (needed since /nix moved to btrfs).

## Subtlety found during testing (2026-09-30)
The sandbox mutates `user.hatch_tainted*` **asynchronously** (variants
`user.hatch_tainted`, `.n`, `.u` appear/disappear between syscalls), so a naive
size-query-then-fill races: the size query can return 19 while the fill then
fails ERANGE. The shim therefore does query+fill with bounded retries (8x) and
always reports the filtered size, so callers like nix allocate consistently.
Debug logging: `TAINT_SHIM_LOG=1` (per-call stderr lines).

## Build
gcc -shared -fPIC -O2 -o taint_shim.so taint_shim.c -ldl

## Use with nix-portable
export LD_PRELOAD=/home/hatch/tools/taint-shim/taint_shim.so
./nix-portable nix run nixpkgs#hello

## Verification (2026-09-30)
- Unit: removexattr on taint attr -> 0 (was EPERM); other attrs pass through.
- Unit: llistxattr on a tainted .drv -> empty list (was 3 taint names).
- End-to-end: `nix run nixpkgs#hello -- --version` with the shim now SUCCEEDS
  fully — passes both previously-fatal stages (flake-input unpack,
  store-path canonicalisation), builds the bootstrap closure, and prints
  GNU hello 2.12.3's version with exit code 0. (Confirmed 2026-09-30.)
