#ifndef TRACTANDA_PLATFORM_H
#define TRACTANDA_PLATFORM_H
#include <stdint.h>
#include <stddef.h>
uint32_t tractanda_uid(void);
// Reads POSIX lstat metadata without following the final symlink. The returned mode includes
// both the file type and permission bits. All output pointers are required.
int tractanda_file_metadata(
    const char *path, uint32_t *mode, uint32_t *uid, uint32_t *gid, uint64_t *size,
    uint64_t *inode, uint64_t *device, int64_t *mtime_seconds, int32_t *mtime_nanoseconds);
// Opaque immediate-directory iterator. Names exclude . and ..; 1 = entry, 0 = end, -1 = error.
// Callers must close a non-null handle. The iterator never follows child symlinks.
void *tractanda_directory_open(const char *path);
// Duplicates an already no-follow opened directory descriptor.
void *tractanda_directory_open_fd(int32_t descriptor);
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
// Spawns one owned process group with only explicit stdio inherited. Parent pipe endpoints
// are CLOEXEC/nonblocking and >=3; caller must kill-group/waitpid and close every endpoint.
// Returns 0 on success, -1 with errno on failure; no child exists after a spawn failure.
int tractanda_document_spawn(
    const char *executable, const char *const argv[], int32_t *pid,
    int32_t *input, int32_t *output, int32_t *error);
// Observe an owned child's exit without reaping, retaining PID/group ownership until cleanup.
int tractanda_document_exited(int32_t pid);
// Thread-scoped SIGPIPE suppression; preserves the process's global signal policy.
int64_t tractanda_document_write(int32_t fd, const void *bytes, size_t count);
int tractanda_lock(const char *path);
// Describes the immediately preceding tractanda_lock failure on this thread.
// A non-zero result from tractanda_lock_was_busy means another live lock holder
// won the advisory lock; other failures must be surfaced to callers.
int tractanda_lock_was_busy(void);
int tractanda_unlock(int descriptor);
int tractanda_publish(const char *path, const void *bytes, size_t count);
// Durable regular-file barrier: fsync, and macOS F_FULLFSYNC to flush device caches.
// Call after synchronizing publication directories as well as before exposing new bytes.
int tractanda_durable_sync(int fd);
// Atomically moves a complete private directory without replacing an existing destination.
int tractanda_publish_directory_at(int source_parent, const char *source, int target_parent, const char *target);
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
// Connected IO preserves partial frames across idle timeout wakeups until cancel/disconnect/error.
int tractanda_send_connected_frame(int descriptor, const void *bytes, uint32_t count);
int tractanda_receive_connected_frame(int descriptor, void **bytes, uint32_t *count);
// Fixed local enrollment launch: actual current image path; no argv/PATH fallback.
int tractanda_current_executable(char *buffer, uint32_t capacity);
// Fixed basename only, no-follow trusted-owner chain; reject mutation-granting ACLs.
int tractanda_validate_enrollment_helper(const char *path, int root_only);
int tractanda_validate_enrollment_ssh(void);
int tractanda_peer_configuration_no_mutation_acl(int fd);
// Secret-bearing enrollment files/directories: refuse every extended access ACL.
int tractanda_secret_file_no_acl(int fd);
// Scoped non-echo input, restoring terminal/handlers on input, error or cancellation.
int tractanda_private_terminal_line(int fd, void *bytes, size_t cap, size_t *count);
// Enrollment source socket only, CLOCK_MONOTONIC absolute deadline at most20seconds away.
int tractanda_private_connect_until(const char *path, uint64_t deadline);
// Private native input only: owned client socket, one monotonic 20-second IO budget.
uint64_t tractanda_private_io_begin(int descriptor);
int tractanda_private_send_begin(int descriptor, const void *bytes, uint32_t count, uint64_t deadline);
int tractanda_private_send_frame(int descriptor, const void *bytes, uint32_t count, uint64_t deadline);
int tractanda_private_receive_frame(int descriptor, void **bytes, uint32_t *count, uint32_t maximum, uint64_t deadline);
// Caller-owned no-follow regular input; returns a bounded copy, never a pathname-derived grant.
int tractanda_capture_private_credential(const char *path, void **bytes, uint32_t *count);
// Local enrollment artifacts only; operation-specific callers retain their smaller exact caps.
//0=copy,1=actual final-open absence,-1=unsafe/change/error (errno never implies absence).
int tractanda_capture_private_artifact(const char *path, void **bytes, uint32_t *count, uint32_t maximum);
int tractanda_capture_private_artifact_at(int parent, const char *name, void **bytes, uint32_t *count, uint32_t maximum);
int tractanda_capture_peer_preparation(const char *path, void **bytes, uint32_t *count);
// Synchronous test-only after-stat boundary; no callback/context is retained.
int tractanda_capture_private_artifact_for_testing(const char *path, void **bytes, uint32_t *count,
    uint32_t maximum, void (*after_stat)(void *), void *context);
int tractanda_open_private_directory(const char *path);
//0=exclusive atomic publication,1=published but directory fsync uncertain,-1=failure.
int tractanda_write_private_artifact_at(int parent, const char *temporary, const char *target,
    const void *bytes, uint32_t count);
void tractanda_private_free(void *bytes, uint32_t count);
void tractanda_free(void *bytes);
void tractanda_close(int descriptor);
#endif
