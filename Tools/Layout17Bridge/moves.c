#include "moves.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/fs.h>
#endif

static int leaf(const char *name) {
    return name && *name && strcmp(name, ".") && strcmp(name, "..") && !strchr(name, '/');
}

static int same(const struct stat *a, uint64_t device, uint64_t inode, uid_t owner) {
    return S_ISREG(a->st_mode) && a->st_uid == owner &&
        (uint64_t)a->st_dev == device && (uint64_t)a->st_ino == inode;
}

int layout17_durable_sync(int fd) {
    int result;
    do { result = fsync(fd); } while (result != 0 && errno == EINTR);
    if (result != 0) return -1;
#if defined(__APPLE__)
    do { result = fcntl(fd, F_FULLFSYNC); } while (result != 0 && errno == EINTR);
#endif
    return result;
}

int layout17_rename_exclusive(int source_dir, const char *source, int target_dir, const char *target) {
    if (!leaf(source) || !leaf(target)) { errno = EINVAL; return -1; }
#if defined(__APPLE__)
    return renameatx_np(source_dir, source, target_dir, target, RENAME_EXCL);
#elif defined(__linux__)
    return (int)syscall(SYS_renameat2, source_dir, source, target_dir, target, RENAME_NOREPLACE);
#else
#error Unsupported operating system for exclusive rename
#endif
}

int layout17_move_file(int source_dir, const char *source, int target_dir,
                       const char *target, uid_t owner, uint64_t device,
                       uint64_t inode, int fault_boundary) {
    struct stat s, d;
    if (!leaf(source) || !leaf(target) || (source_dir == target_dir && !strcmp(source, target))) {
        errno = EINVAL; return -1;
    }
    int have_source = fstatat(source_dir, source, &s, AT_SYMLINK_NOFOLLOW) == 0;
    if (!have_source && errno != ENOENT) return -1;
    int have_target = fstatat(target_dir, target, &d, AT_SYMLINK_NOFOLLOW) == 0;
    if (!have_target && errno != ENOENT) return -1;
    if (have_source && !same(&s, device, inode, owner)) { errno = ESTALE; return -1; }
    if (have_target && !same(&d, device, inode, owner)) { errno = EEXIST; return -1; }
    if (!have_source && !have_target) { errno = ENOENT; return -1; }
    if (!have_source) {
        if (d.st_nlink != 1) { errno = EMLINK; return -1; }
        /* A previous unlink may have succeeded before its directory fsync failed. */
        if (fsync(target_dir) != 0) return -1;
        return fsync(source_dir);
    }
    if (have_target) {
        if (s.st_nlink != 2 || d.st_nlink != 2) { errno = EMLINK; return -1; }
    } else {
        if (s.st_nlink != 1) { errno = EMLINK; return -1; }
        if (linkat(source_dir, source, target_dir, target, 0) != 0) return -1;
        if (fsync(target_dir) != 0) return -1;
        if (fault_boundary == 1) { errno = EINTR; return -1; }
    }
    /* Recheck both names immediately before deleting the old name. */
    if (fstatat(source_dir, source, &s, AT_SYMLINK_NOFOLLOW) != 0 ||
        fstatat(target_dir, target, &d, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!same(&s, device, inode, owner) || !same(&d, device, inode, owner) ||
        s.st_nlink != 2 || d.st_nlink != 2) { errno = ESTALE; return -1; }
    if (unlinkat(source_dir, source, 0) != 0) return -1;
    if (fault_boundary == 2) { errno = EINTR; return -1; }
    return fsync(source_dir);
}

int layout17_move_directory(int source_dir, const char *source, int target_dir,
                            const char *target, uid_t owner, uint64_t device,
                            uint64_t inode, int fault_after_rename) {
    struct stat s, d;
    if (!leaf(source) || !leaf(target)) { errno = EINVAL; return -1; }
    int have_source = fstatat(source_dir, source, &s, AT_SYMLINK_NOFOLLOW) == 0;
    if (!have_source && errno != ENOENT) return -1;
    int have_target = fstatat(target_dir, target, &d, AT_SYMLINK_NOFOLLOW) == 0;
    if (!have_target && errno != ENOENT) return -1;
    if (have_source && (!S_ISDIR(s.st_mode) || s.st_uid != owner ||
        (uint64_t)s.st_dev != device || (uint64_t)s.st_ino != inode)) { errno = ESTALE; return -1; }
    if (have_target && (!S_ISDIR(d.st_mode) || d.st_uid != owner ||
        (uint64_t)d.st_dev != device || (uint64_t)d.st_ino != inode)) { errno = EEXIST; return -1; }
    if (have_source && have_target) { errno = EEXIST; return -1; }
    if (!have_source && !have_target) { errno = ENOENT; return -1; }
    if (have_source) {
        if (layout17_rename_exclusive(source_dir, source, target_dir, target) != 0) return -1;
        if (fstatat(target_dir, target, &d, AT_SYMLINK_NOFOLLOW) != 0) return -1;
        if (!S_ISDIR(d.st_mode) || d.st_uid != owner || (uint64_t)d.st_dev != device ||
            (uint64_t)d.st_ino != inode) { errno = ESTALE; return -1; }
        if (fault_after_rename) { errno = EINTR; return -1; }
    }
    if (fsync(target_dir) != 0) return -1;
    return fsync(source_dir);
}
