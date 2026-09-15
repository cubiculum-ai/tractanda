#ifndef TRACTANDA_PLATFORM_H
#define TRACTANDA_PLATFORM_H
#include <stdint.h>
#include <stddef.h>
uint32_t tractanda_uid(void);
// Reads POSIX lstat metadata without following the final symlink. The returned mode includes
// both the file type and permission bits. All output pointers are required.
int tractanda_file_metadata(
    const char *path, uint32_t *mode, uint32_t *uid, uint32_t *gid, uint64_t *size,
    uint64_t *inode, uint64_t *device);
// Opaque immediate-directory iterator. Names exclude . and ..; 1 = entry, 0 = end, -1 = error.
// Callers must close a non-null handle. The iterator never follows child symlinks.
void *tractanda_directory_open(const char *path);
int tractanda_directory_next(void *directory, char *name, size_t capacity);
int tractanda_directory_close(void *directory);
// Explicit time-based UUID generation. Calls are serialized within the process.
int tractanda_uuid_v1(uint8_t bytes[16]);
// Linux permanent hardware address discovery; macOS uses IOKit from Swift.
int tractanda_uuid_hardware_node(uint8_t bytes[6], char *interface_name, size_t capacity);
int tractanda_user_name(uint32_t uid, char *name, size_t size, uint32_t *primary_group);
int tractanda_user_id(const char *name, uint32_t *uid);
int tractanda_group_name(uint32_t gid, char *name, size_t size);
int tractanda_group_id(const char *name, uint32_t *gid);
int tractanda_user_groups(const char *name, uint32_t primary_group, uint32_t *groups, int *count);
int tractanda_path_read_only(const char *path);
// Checks only the web process's own account. 1 = accepted, 0 = denied, -1 = unavailable.
int tractanda_verify_local_password(const char *username, const char *password);
// Shared-daemon PAM verifier. 1 = success, 0 = credentials denied, -1 = backend failure,
// -2 = target needs a privileged verifier. authenticated_uid is set only on success.
int tractanda_authenticate_password(const char *username, const char *password, uint32_t *authenticated_uid);
// Talks only to the fixed local root PAM broker. 1 = verified and UID matches expected_uid,
// 0 = credentials denied, -1 = broker/protocol/peer verification failure.
int tractanda_authenticate_password_broker(
    const char *socket_path, const char *username, const char *password, uint32_t expected_uid);
int tractanda_lock(const char *path);
// Describes the immediately preceding tractanda_lock failure on this thread.
// A non-zero result from tractanda_lock_was_busy means another live lock holder
// won the advisory lock; other failures must be surfaced to callers.
int tractanda_lock_was_busy(void);
int tractanda_unlock(int descriptor);
int tractanda_publish(const char *path, const void *bytes, size_t count);
int tractanda_listen(const char *path);
int tractanda_listen_mode(const char *path, uint32_t mode);
// Removes only this user's dead Unix socket; refuses live sockets and other file types/owners.
int tractanda_remove_stale_socket(const char *path);
int tractanda_connect(const char *path);
int tractanda_accept(int listener);
int tractanda_start_signals(void);
int tractanda_stopping(void);
void tractanda_restore_signals(void);
void tractanda_startup_shutdown_guard_begin(void);
void tractanda_startup_shutdown_guard_end(void);
// Claims the transition from starting to serving. Returns 0 if SIGTERM/SIGINT won first.
int tractanda_startup_shutdown_guard_ready(void);
// During daemon startup only, restore SIGTERM's default disposition and terminate if requested.
// This is intentionally not used after the daemon begins serving writes.
int tractanda_terminate_if_stopping(void);
int tractanda_peer_uid(int descriptor, uint32_t *uid);
int tractanda_send_frame(int descriptor, const void *bytes, uint32_t count);
int tractanda_receive_frame(int descriptor, void **bytes, uint32_t *count);
void tractanda_free(void *bytes);
void tractanda_close(int descriptor);
#endif
