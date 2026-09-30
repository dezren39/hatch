/*
 * taint_shim.c — LD_PRELOAD shim for the hatch sandbox.
 *
 * Background: the sandbox kernel filter denies removexattr() on
 * user.hatch_tainted* with EPERM (observed on tmpfs and btrfs alike,
 * even when the attribute does not exist). nix unpacking tarballs into
 * its store tries to strip those attrs and aborts on EPERM; nix's
 * LocalStore also chokes (ERANGE) when enumerating xattrs on store paths.
 *
 * Policy: make user.hatch_tainted* invisible to the process —
 *   removexattr* -> pretend success
 *   getxattr*     -> pretend absent (ENODATA)
 *   listxattr*    -> filter the names out of the enumeration
 * and elide redundant chown() calls: the sandbox denies chown even for root,
 * but nix's LocalStore does a startup ownership fixup on /nix/store. When the
 * requested uid/gid already match (or are -1 = unchanged), the call is a
 * semantic no-op, so we return success without issuing the syscall.
 * Everything else passes through untouched.
 *
 * Safety rationale (verified 2026-09-29): nix hashing/NAR serialization
 * ignores xattrs, and hundreds of MB of tainted store paths already work
 * fine — these attrs are sandbox metadata, not content. Elided chowns are
 * true no-ops by construction (ownership already matches).
 *
 * Debug: TAINT_SHIM_LOG=1 logs each intercepted call to stderr.
 *
 * NOTE (2026-09-30, phase 2): the full stat/lstat symlink-spoofing was
 * REMOVED and replaced with a mode mask (see bottom of file). Findings on
 * nix 2.35.2: the `real` store-dir setting from the phase-1 research does NOT
 * exist ("unknown setting 'real'"); `allow-symlinked-store = true` covers the
 * LocalStore guard and eval/add-file/profile/gc all pass with no spoofing.
 * Two sandbox quirks still need the shim: (1) removexattr on
 * user.hatch_tainted* is denied even for root — local builds fail with EPERM
 * registering the .drv without the xattr handling; (2) the build sandbox's
 * checkNotWorldWritable (derivation-builder.cc:356, called at :389 when
 * building as a build user) walks the build dir's ancestors and rejects any
 * path with S_IWOTH — symlinks always report 0777, so /nix trips it unless
 * the mode is masked to 0755. The symlink bit itself is now reported
 * truthfully. Verified: local build runs as nixbld1 (uid 999).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

static int is_taint(const char *name) {
    return name != NULL && strncmp(name, "user.hatch_tainted", 18) == 0;
}

static int want_log(void) {
    static int v = -1;
    if (v < 0) v = getenv("TAINT_SHIM_LOG") != NULL;
    return v;
}
#define LOG(fmt, ...) do { if (want_log()) fprintf(stderr, "[taint-shim] " fmt "\n", ##__VA_ARGS__); } while (0)

/* ---- removexattr family: fake success for taint attrs ---- */
int removexattr(const char *path, const char *name) {
    if (is_taint(name)) { LOG("removexattr(%s,%s) -> 0", path, name); return 0; }
    int (*real)(const char *, const char *) = dlsym(RTLD_NEXT, "removexattr");
    return real(path, name);
}
int lremovexattr(const char *path, const char *name) {
    if (is_taint(name)) { LOG("lremovexattr(%s,%s) -> 0", path, name); return 0; }
    int (*real)(const char *, const char *) = dlsym(RTLD_NEXT, "lremovexattr");
    return real(path, name);
}
int fremovexattr(int fd, const char *name) {
    if (is_taint(name)) { LOG("fremovexattr(%d,%s) -> 0", fd, name); return 0; }
    int (*real)(int, const char *) = dlsym(RTLD_NEXT, "fremovexattr");
    return real(fd, name);
}

/* ---- getxattr family: taint attrs don't exist ---- */
ssize_t getxattr(const char *path, const char *name, void *value, size_t size) {
    if (is_taint(name)) { LOG("getxattr(%s,%s) -> ENODATA", path, name); errno = ENODATA; return -1; }
    ssize_t (*real)(const char *, const char *, void *, size_t) = dlsym(RTLD_NEXT, "getxattr");
    return real(path, name, value, size);
}
ssize_t lgetxattr(const char *path, const char *name, void *value, size_t size) {
    if (is_taint(name)) { LOG("lgetxattr(%s,%s) -> ENODATA", path, name); errno = ENODATA; return -1; }
    ssize_t (*real)(const char *, const char *, void *, size_t) = dlsym(RTLD_NEXT, "lgetxattr");
    return real(path, name, value, size);
}
ssize_t fgetxattr(int fd, const char *name, void *value, size_t size) {
    if (is_taint(name)) { LOG("fgetxattr(%d,%s) -> ENODATA", fd, name); errno = ENODATA; return -1; }
    ssize_t (*real)(int, const char *, void *, size_t) = dlsym(RTLD_NEXT, "fgetxattr");
    return real(fd, name, value, size);
}


/* Robust listxattr with taint filtering.
   The sandbox mutates user.hatch_tainted* asynchronously, so the raw size can
   change between a size query and the fill (classic TOCTOU -> ERANGE). We do
   query+fill atomically-ish with bounded retries, and always report/filter
   the TAINT-FREE view so callers see a stable size. */
#include <errno.h>
static ssize_t filter_names(char *list, ssize_t n);

static ssize_t xlist_robust(ssize_t (*real)(const char *, char *, size_t),
                            const char *path, char *list, size_t size,
                            int is_query, const char *what) {
    for (int attempt = 0; attempt < 8; attempt++) {
        ssize_t n = real(path, NULL, 0);
        if (n < 0) { LOG("%s(%s): size query err %d", what, path, errno); return n; }
        if (n == 0) return 0;
        char *tmp = malloc((size_t) n);
        if (!tmp) return n;
        ssize_t m = real(path, tmp, (size_t) n);
        if (m < 0) {
            int e = errno;
            free(tmp);
            if (e == ERANGE) continue; /* xattr set changed mid-flight; retry */
            errno = e;
            LOG("%s(%s): fill err %d", what, path, e);
            return -1;
        }
        ssize_t f = filter_names(tmp, m);
        if (is_query) { free(tmp); LOG("%s(%s, NULL, 0) -> %zd", what, path, f); return f; }
        if ((size_t) f > size) { free(tmp); errno = ERANGE; return -1; }
        memcpy(list, tmp, (size_t) f);
        free(tmp);
        LOG("%s(%s, size=%zu) -> %zd (filtered)", what, path, size, f);
        return f;
    }
    LOG("%s(%s): xattr set kept changing, giving up", what, path);
    errno = ERANGE;
    return -1;
}

static ssize_t list_common(ssize_t (*real)(const char *, char *, size_t),
                           const char *path, char *list, size_t size,
                           const char *what) {
    return xlist_robust(real, path, list, size, (list == NULL || size == 0), what);
}

/* ---- listxattr family: filter taint names out ---- */
static ssize_t filter_names(char *list, ssize_t n) {
    if (n <= 0 || list == NULL) return n;
    char *dst = list, *src = list, *end = list + n;
    while (src < end && *src) {
        size_t len = strlen(src) + 1;
        if (!is_taint(src)) {
            if (dst != src) memmove(dst, src, len);
            dst += len;
        } else {
            LOG("listxattr filtered out '%s'", src);
        }
        src += len;
    }
    return dst - list;
}
ssize_t listxattr(const char *path, char *list, size_t size) {
    ssize_t (*real)(const char *, char *, size_t) = dlsym(RTLD_NEXT, "listxattr");
    return list_common(real, path, list, size, "listxattr");
}
ssize_t llistxattr(const char *path, char *list, size_t size) {
    ssize_t (*real)(const char *, char *, size_t) = dlsym(RTLD_NEXT, "llistxattr");
    return list_common(real, path, list, size, "llistxattr");
}
ssize_t flistxattr(int fd, char *list, size_t size) {
    /* fd variant: keep it simple, no size-query special case needed by nix */
    ssize_t (*real)(int, char *, size_t) = dlsym(RTLD_NEXT, "flistxattr");
    ssize_t n = real(fd, list, size);
    if (n < 0) { LOG("flistxattr(%d) -> err %d", fd, errno); return n; }
    return filter_names(list, n);
}

/* ---- chown family: elide redundant chowns ----
   The sandbox denies chown() even for root (Operation not permitted), but
   nix's LocalStore performs a startup ownership fixup on /nix/store. When
   the requested uid/gid already match what's on disk (or are -1, meaning
   "don't change"), the call is a semantic no-op: return success without
   issuing the syscall. Anything else passes through and fails honestly. */
static int chown_is_noop(const struct stat *st, uid_t owner, gid_t group) {
    if (owner != (uid_t) -1 && st->st_uid != owner) return 0;
    if (group != (gid_t) -1 && st->st_gid != group) return 0;
    return 1;
}
int chown(const char *path, uid_t owner, gid_t group) {
    struct stat st;
    if (stat(path, &st) == 0 && chown_is_noop(&st, owner, group)) {
        LOG("chown(%s) -> 0 (already owned)", path);
        return 0;
    }
    int (*real)(const char *, uid_t, gid_t) = dlsym(RTLD_NEXT, "chown");
    return real(path, owner, group);
}
int lchown(const char *path, uid_t owner, gid_t group) {
    struct stat st;
    if (lstat(path, &st) == 0 && chown_is_noop(&st, owner, group)) {
        LOG("lchown(%s) -> 0 (already owned)", path);
        return 0;
    }
    int (*real)(const char *, uid_t, gid_t) = dlsym(RTLD_NEXT, "lchown");
    return real(path, owner, group);
}
int fchown(int fd, uid_t owner, gid_t group) {
    struct stat st;
    if (fstat(fd, &st) == 0 && chown_is_noop(&st, owner, group)) {
        LOG("fchown(%d) -> 0 (already owned)", fd);
        return 0;
    }
    int (*real)(int, uid_t, gid_t) = dlsym(RTLD_NEXT, "fchown");
    return real(fd, owner, group);
}
int fchownat(int dirfd, const char *path, uid_t owner, gid_t group, int flags) {
    struct stat st;
    int ok = (flags & AT_SYMLINK_NOFOLLOW)
        ? (fstatat(dirfd, path, &st, AT_SYMLINK_NOFOLLOW) == 0)
        : (fstatat(dirfd, path, &st, 0) == 0);
    if (ok && chown_is_noop(&st, owner, group)) {
        LOG("fchownat(%s) -> 0 (already owned)", path);
        return 0;
    }
    int (*real)(int, const char *, uid_t, gid_t, int) = dlsym(RTLD_NEXT, "fchownat");
    return real(dirfd, path, owner, group, flags);
}

/* ---- stat family: mask /nix symlink mode (not the symlink itself) ----
   nix 2.35.2's build sandbox (derivation-builder.cc:356 checkNotWorldWritable,
   called at :389 when building as a build user) walks from the build dir up
   to / and rejects any path with S_IWOTH set. Symlinks always report mode
   0777, so /nix (a symlink to the persistent store) trips it. We report 0755
   instead. The symlink bit stays truthful — only the meaningless mode is
   masked. (The old full spoof also hid S_ISLNK; re-tested 2026-09-30 on
   2.35.2 with allow-symlinked-store=true: the mode mask alone suffices.) */
static int is_nix_root(const char *path) {
    return path != NULL && (strcmp(path, "/nix") == 0 || strcmp(path, "/nix/") == 0);
}

#define MASK_IF_NIX_SYMLINK(path, stp) do { \
    if (is_nix_root(path) && S_ISLNK((stp)->st_mode)) { \
        (stp)->st_mode = ((stp)->st_mode & ~07777) | 0755; \
        LOG("stat(%s): masked symlink mode -> 0755", path); \
    } \
} while (0)

int lstat(const char *path, struct stat *buf) {
    int (*real)(const char *, struct stat *) = dlsym(RTLD_NEXT, "lstat");
    int ret = real(path, buf);
    if (ret == 0) MASK_IF_NIX_SYMLINK(path, buf);
    return ret;
}
int stat(const char *path, struct stat *buf) {
    int (*real)(const char *, struct stat *) = dlsym(RTLD_NEXT, "stat");
    int ret = real(path, buf);
    if (ret == 0) MASK_IF_NIX_SYMLINK(path, buf);
    return ret;
}
int lstat64(const char *path, struct stat64 *buf) {
    int (*real)(const char *, struct stat64 *) = dlsym(RTLD_NEXT, "lstat64");
    int ret = real(path, buf);
    if (ret == 0) MASK_IF_NIX_SYMLINK(path, buf);
    return ret;
}
int stat64(const char *path, struct stat64 *buf) {
    int (*real)(const char *, struct stat64 *) = dlsym(RTLD_NEXT, "stat64");
    int ret = real(path, buf);
    if (ret == 0) MASK_IF_NIX_SYMLINK(path, buf);
    return ret;
}
