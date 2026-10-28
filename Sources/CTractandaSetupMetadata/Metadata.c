#define _GNU_SOURCE
#include "TractandaSetupMetadata.h"
#include "TractandaPlatform.h"
#include <sys/types.h>
#include <sys/xattr.h>
#include <errno.h>
#ifdef __APPLE__
#include <sys/acl.h>
#endif

// Bounded caller-owned metadata capture for the explicit system-layout relocation.
// Never follows the final link. Linux POSIX ACLs are included by llistxattr.
int64_t tractanda_layout_xattr_names(const char *path, char *buffer, size_t capacity) {
#ifdef __APPLE__
    return (int64_t)listxattr(path, buffer, capacity, XATTR_NOFOLLOW);
#else
    return (int64_t)llistxattr(path, buffer, capacity);
#endif
}
int64_t tractanda_layout_xattr_value(const char *path, const char *name, void *buffer, size_t capacity) {
#ifdef __APPLE__
    return (int64_t)getxattr(path, name, buffer, capacity, 0, XATTR_NOFOLLOW);
#else
    return (int64_t)lgetxattr(path, name, buffer, capacity);
#endif
}
int64_t tractanda_layout_acl_bytes(const char *path, void *buffer, size_t capacity) {
#ifdef __APPLE__
    acl_t acl = acl_get_link_np(path, ACL_TYPE_EXTENDED);
    if (!acl) { if (errno == ENOENT) return 0; return -1; }
    ssize_t length = acl_size(acl);
    if (length < 0) { acl_free(acl); return -1; }
    if (!buffer && capacity == 0) { acl_free(acl); return (int64_t)length; }
    if ((size_t)length > capacity) { acl_free(acl); errno = ERANGE; return -1; }
    ssize_t result = acl_copy_ext(buffer, acl, capacity);
    acl_free(acl); return (int64_t)result;
#else
    (void)path; (void)buffer; (void)capacity;
    return 0;
#endif
}

#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

struct runtime_context { int parent; int root; uint32_t owner; };
static int runtime_named(struct runtime_context *context) {
    struct stat held, named;
    if (fstat(context->root, &held) ||
        fstatat(context->parent, "tractanda", &named, AT_SYMLINK_NOFOLLOW) ||
        !S_ISDIR(named.st_mode) || named.st_uid != context->owner ||
        (named.st_mode & 07777) != 0755 ||
        held.st_dev != named.st_dev || held.st_ino != named.st_ino ||
        tractanda_peer_configuration_no_mutation_acl(context->root)) { errno = EACCES; return -1; }
    return 0;
}
void *tractanda_setup_runtime_open(const char *parent_path, uint32_t owner, uint32_t writable_group) {
    if (!parent_path || geteuid() != owner) { errno = EPERM; return NULL; }
    int parent = open(parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent < 0) return NULL;
    struct stat metadata;
    if (fstat(parent, &metadata) || !S_ISDIR(metadata.st_mode) || metadata.st_uid != owner ||
        (metadata.st_mode & 0002) || ((metadata.st_mode & 0020) && metadata.st_gid != writable_group)) {
        close(parent); errno = EACCES; return NULL;
    }
    if (mkdirat(parent, "tractanda", 0755) && errno != EEXIST) { close(parent); return NULL; }
    int root = openat(parent, "tractanda", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) { close(parent); return NULL; }
    struct runtime_context *context = malloc(sizeof(*context));
    if (!context) { close(root); close(parent); return NULL; }
    *context = (struct runtime_context){parent, root, owner};
    if (runtime_named(context)) { close(root); close(parent); free(context); return NULL; }
    return context;
}
int tractanda_setup_runtime_validate(void *opaque) {
    if (!opaque) { errno = EINVAL; return -1; }
    return runtime_named(opaque);
}
static int runtime_instance_name(const char *name) {
    if (!name || !*name || strlen(name) > 32 || name[0] == '-') return 0;
    for (const unsigned char *p = (const unsigned char *)name; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '-')) return 0;
    return name[strlen(name)-1] != '-';
}
int tractanda_setup_runtime_prepare(void *opaque, const char *instance, uint32_t service_uid) {
    struct runtime_context *context = opaque;
    if (!context || !runtime_instance_name(instance) || runtime_named(context)) { errno = EACCES; return -1; }
    int created = mkdirat(context->root, instance, 0711) == 0;
    if (!created && errno != EEXIST) return -1;
    int directory = openat(context->root, instance, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return -1;
    struct stat metadata;
    int result = -1;
    if (fstat(directory, &metadata) || !S_ISDIR(metadata.st_mode) || runtime_named(context)) goto done;
    if (created) {
        if (metadata.st_uid != context->owner || (metadata.st_mode & 07777) != 0711 ||
            fchown(directory, service_uid, (gid_t)-1) || fchmod(directory, 0711)) goto done;
    }
    if (fstat(directory, &metadata) || metadata.st_uid != service_uid ||
        (metadata.st_mode & 07777) != 0711 || runtime_named(context)) { errno = EACCES; goto done; }
    result = 0;
done:
    close(directory); return result;
}
int tractanda_setup_runtime_lock(void *opaque) {
    struct runtime_context *context = opaque;
    if (!context || runtime_named(context)) { errno = EACCES; return -1; }
    int lock = openat(context->root, "installer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    if (lock < 0) return -1;
    struct stat metadata;
    if (fstat(lock, &metadata) || !S_ISREG(metadata.st_mode) || metadata.st_uid != context->owner ||
        metadata.st_nlink != 1 || (metadata.st_mode & 07777) != 0600 ||
        flock(lock, LOCK_EX | LOCK_NB) || runtime_named(context)) { close(lock); errno = EACCES; return -1; }
    return lock;
}
void tractanda_setup_runtime_close(void *opaque) {
    struct runtime_context *context = opaque;
    if (context) { close(context->root); close(context->parent); free(context); }
}
