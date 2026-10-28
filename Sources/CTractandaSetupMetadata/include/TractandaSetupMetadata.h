#ifndef TRACTANDA_SETUP_METADATA_H
#define TRACTANDA_SETUP_METADATA_H
#include <stdint.h>
#include <stddef.h>
// No-follow metadata reads for explicit layout relocation. NULL/0 probes required length;
// -1 indicates an OS error. Linux ACLs appear in xattrs; macOS ACL bytes are separate.
int64_t tractanda_layout_xattr_names(const char *path, char *buffer, size_t capacity);
int64_t tractanda_layout_xattr_value(const char *path, const char *name, void *buffer, size_t capacity);
int64_t tractanda_layout_acl_bytes(const char *path, void *buffer, size_t capacity);
// Descriptor-anchored transient runtime custody. Production caller supplies only its
// fixed platform parent and root UID; fixture injection is internal to private tests.
void *tractanda_setup_runtime_open(const char *parent_path, uint32_t owner, uint32_t writable_group);
int tractanda_setup_runtime_validate(void *context);
int tractanda_setup_runtime_prepare(void *context, const char *instance, uint32_t service_uid);
int tractanda_setup_runtime_lock(void *context);
void tractanda_setup_runtime_close(void *context);
#endif
