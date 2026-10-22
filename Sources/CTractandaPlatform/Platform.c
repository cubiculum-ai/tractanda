#define _GNU_SOURCE
#include "TractandaPlatform.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <signal.h>
#include <stdatomic.h>
#include <poll.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <pwd.h>
#include <grp.h>
#include <sys/statvfs.h>
#include <dirent.h>
#include <time.h>
#ifdef __APPLE__
#include <sys/acl.h>
#include <libproc.h>
#else
#include <sys/xattr.h>
#endif
#include <security/pam_appl.h>
#include <uuid/uuid.h>
#include <pthread.h>
#ifdef __linux__
#include <ifaddrs.h>
#include <net/if.h>
#include <linux/ethtool.h>
#include <linux/fs.h>
#include <sys/syscall.h>
#include <linux/sockios.h>
#include <sys/ioctl.h>
#endif

int tractanda_uuid_hardware_node(uint8_t bytes[6], char *interface_name, size_t capacity) {
#ifdef __linux__
    if (!bytes || !interface_name || capacity < IFNAMSIZ) { errno = EINVAL; return -1; }
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return -1;
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { freeifaddrs(interfaces); return -1; }
    char selected[IFNAMSIZ] = {0};
    uint8_t selected_bytes[6] = {0};
    for (struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_PACKET ||
            (entry->ifa_flags & IFF_LOOPBACK) || !entry->ifa_name ||
            strlen(entry->ifa_name) >= IFNAMSIZ) continue;
        struct ethtool_perm_addr *address = calloc(1, sizeof(*address) + 32);
        if (!address) { close(fd); freeifaddrs(interfaces); return -1; }
        address->cmd = ETHTOOL_GPERMADDR;
        address->size = 32;
        struct ifreq request;
        memset(&request, 0, sizeof(request));
        memcpy(request.ifr_name, entry->ifa_name, strlen(entry->ifa_name) + 1);
        request.ifr_data = (char *)address;
        if (ioctl(fd, SIOCETHTOOL, &request) == 0 && address->size == 6 &&
            !(address->data[0] & 3) && memcmp(address->data, "\0\0\0\0\0\0", 6) != 0 &&
            (!selected[0] ||
             (strcmp(entry->ifa_name, "en0") == 0 && strcmp(selected, "en0") != 0) ||
             (strcmp(selected, "en0") != 0 && strcmp(entry->ifa_name, selected) < 0))) {
            memcpy(selected_bytes, address->data, 6);
            memcpy(selected, entry->ifa_name, strlen(entry->ifa_name) + 1);
        }
        free(address);
    }
    close(fd);
    freeifaddrs(interfaces);
    if (!selected[0]) { errno = ENODEV; return -1; }
    memcpy(bytes, selected_bytes, 6);
    memcpy(interface_name, selected, strlen(selected) + 1);
    return 0;
#else
    (void)bytes; (void)interface_name; (void)capacity;
    errno = ENOTSUP;
    return -1;
#endif
}

int tractanda_uuid_v1(uint8_t bytes[16]) {
    static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    if (!bytes) { errno = EINVAL; return -1; }
    int result = pthread_mutex_lock(&mutex);
    if (result) { errno = result; return -1; }
#ifdef __linux__
    // Swift corelibs Foundation also exports uuid_generate_time; that implementation
    // uses a different clock. libuuid's distinct entry point avoids symbol interposition.
    // Its return value describes optional inter-process synchronization, not UUID validity.
    (void)uuid_generate_time_safe(bytes);
#else
    uuid_generate_time(bytes);
#endif
    result = pthread_mutex_unlock(&mutex);
    if (result) { errno = result; return -1; }
    return 0;
}

struct password_conversation {
    const char *username;
    const char *password;
    int password_prompts;
};

static int provide_password(int count, const struct pam_message **messages,
                            struct pam_response **response, void *context) {
    if (count < 1 || count > 32 || !messages || !response || !context) return PAM_CONV_ERR;
    struct password_conversation *input = context;
    struct pam_response *answers = calloc((size_t)count, sizeof(*answers));
    if (!answers) return PAM_BUF_ERR;
    for (int i = 0; i < count; ++i) {
        if (!messages[i]) goto failure;
        switch (messages[i]->msg_style) {
            case PAM_PROMPT_ECHO_ON:
                answers[i].resp = strdup(input->username);
                if (!answers[i].resp) goto failure;
                break;
            case PAM_PROMPT_ECHO_OFF:
                // This UI supports one password, not arbitrary MFA/password-change conversations.
                if (input->password_prompts++ != 0) goto failure;
                answers[i].resp = strdup(input->password);
                if (!answers[i].resp) goto failure;
                break;
            case PAM_ERROR_MSG: case PAM_TEXT_INFO: break;
            default: goto failure;
        }
    }
    *response = answers;
    return PAM_SUCCESS;
failure:
    for (int i = 0; i < count; ++i) {
        if (answers[i].resp) {
            size_t length = strlen(answers[i].resp);
            volatile unsigned char *bytes = (volatile unsigned char *)answers[i].resp;
            while (length--) *bytes++ = 0;
            free(answers[i].resp);
        }
    }
    free(answers);
    return PAM_CONV_ERR;
}

int tractanda_verify_local_password(const char *username, const char *password) {
    uint32_t uid;
    if (!username || !password || !*password || tractanda_user_id(username, &uid) != 0 || uid != geteuid()) return 0;
    struct password_conversation input = {username, password, 0};
    struct pam_conv conversation = {provide_password, &input};
    pam_handle_t *handle = NULL;
    int result = pam_start("login", username, &conversation, &handle);
    if (result == PAM_SUCCESS)
        result = pam_authenticate(handle, PAM_SILENT | PAM_DISALLOW_NULL_AUTHTOK);
    if (result == PAM_SUCCESS) result = pam_acct_mgmt(handle, PAM_SILENT);
    if (result == PAM_SUCCESS) {
        const void *authenticated_user = NULL;
        if (pam_get_item(handle, PAM_USER, &authenticated_user) != PAM_SUCCESS || !authenticated_user ||
            tractanda_user_id(authenticated_user, &uid) != 0 || uid != geteuid()) result = PAM_AUTH_ERR;
    }
    if (handle) pam_end(handle, result);
    if (result == PAM_SUCCESS) return 1;
    if (result == PAM_SYSTEM_ERR || result == PAM_SERVICE_ERR || result == PAM_ABORT ||
        result == PAM_OPEN_ERR || result == PAM_SYMBOL_ERR || result == PAM_BUF_ERR) return -1;
    return 0;
}

int tractanda_authenticate_password(const char *username, const char *password, uint32_t *authenticated_uid) {
    uint32_t requested_uid = 0, final_uid = 0;
    if (authenticated_uid) *authenticated_uid = 0;
    if (!username || !password || !authenticated_uid || !*username || !*password ||
        strlen(username) > 128 || strlen(password) > 4096 ||
        tractanda_user_id(username, &requested_uid) != 0) return 0;
#ifdef __linux__
    if (requested_uid != (uint32_t)geteuid() && geteuid() != 0) return -2;
#endif
    struct password_conversation input = {username, password, 0};
    struct pam_conv conversation = {provide_password, &input};
    pam_handle_t *handle = NULL;
    int result = pam_start("login", username, &conversation, &handle);
    if (result == PAM_SUCCESS) result = pam_authenticate(handle, PAM_SILENT | PAM_DISALLOW_NULL_AUTHTOK);
    if (result == PAM_SUCCESS) result = pam_acct_mgmt(handle, PAM_SILENT);
    if (result == PAM_SUCCESS) {
        const void *authenticated_user = NULL;
        if (pam_get_item(handle, PAM_USER, &authenticated_user) != PAM_SUCCESS || !authenticated_user ||
            tractanda_user_id(authenticated_user, &final_uid) != 0 || final_uid != requested_uid) result = PAM_AUTH_ERR;
    }
    if (handle) pam_end(handle, result);
    if (result == PAM_SUCCESS) { *authenticated_uid = requested_uid; return 1; }
    if (result == PAM_SYSTEM_ERR || result == PAM_SERVICE_ERR || result == PAM_ABORT ||
        result == PAM_OPEN_ERR || result == PAM_SYMBOL_ERR || result == PAM_BUF_ERR) return -1;
    return 0;
}

static int broker_wait(int descriptor, short events) {
    struct pollfd item = {.fd = descriptor, .events = events, .revents = 0};
    for (;;) {
        int result = poll(&item, 1, 5000);
        if (result > 0 && (item.revents & events)) return 0;
        if (result > 0 && (item.revents & (POLLERR | POLLHUP | POLLNVAL))) { errno = EPROTO; return -1; }
        if (result == 0) { errno = ETIMEDOUT; return -1; }
        if (result < 0 && errno == EINTR) continue;
        if (result >= 0) errno = EPROTO;
        return -1;
    }
}

static int broker_write_all(int descriptor, const void *bytes, size_t count) {
    const unsigned char *cursor = bytes;
    while (count) {
        if (broker_wait(descriptor, POLLOUT) != 0) return -1;
        ssize_t written = send(descriptor, cursor, count, MSG_NOSIGNAL);
        if (written > 0) { cursor += written; count -= (size_t)written; continue; }
        if (written < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static int broker_read_all(int descriptor, void *bytes, size_t count) {
    unsigned char *cursor = bytes;
    while (count) {
        if (broker_wait(descriptor, POLLIN) != 0) return -1;
        ssize_t read_count = read(descriptor, cursor, count);
        if (read_count > 0) { cursor += read_count; count -= (size_t)read_count; continue; }
        if (read_count < 0 && errno == EINTR) continue;
        if (read_count == 0) errno = ECONNRESET;
        return -1;
    }
    return 0;
}

int tractanda_authenticate_password_broker(
    const char *socket_path, const char *username, const char *password, uint32_t expected_uid) {
#ifndef __linux__
    (void)socket_path; (void)username; (void)password; (void)expected_uid;
    errno = ENOTSUP;
    return -1;
#else
    unsigned char payload[4226] = {0};
    unsigned char reply[8] = {0};
    int descriptor = -1, result = -1;
    size_t path_length, username_length, password_length, payload_length;
    if (!socket_path || !username || !password || !*username || !*password ||
        socket_path[0] != '/' || (path_length = strlen(socket_path)) >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
        (username_length = strlen(username)) > 128 || (password_length = strlen(password)) > 4096) {
        errno = EINVAL;
        return -1;
    }
    payload_length = username_length + 1 + password_length + 1;
    memcpy(payload, username, username_length);
    memcpy(payload + username_length + 1, password, password_length);
    uint32_t wire_length = htonl((uint32_t)payload_length);
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, socket_path, path_length + 1);
    descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (descriptor < 0) goto done;
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) goto done;
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (errno != EINPROGRESS || broker_wait(descriptor, POLLOUT) != 0) goto done;
        int connection_error = 0;
        socklen_t error_length = sizeof(connection_error);
        if (getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connection_error, &error_length) != 0 ||
            error_length != sizeof(connection_error) || connection_error != 0) {
            if (connection_error) errno = connection_error;
            goto done;
        }
    }
    struct ucred peer;
    socklen_t peer_length = sizeof(peer);
    if (getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &peer, &peer_length) != 0 ||
        peer_length != sizeof(peer) || peer.uid != 0) { errno = EACCES; goto done; }
    if (broker_write_all(descriptor, &wire_length, sizeof(wire_length)) != 0 ||
        broker_write_all(descriptor, payload, payload_length) != 0 ||
        broker_read_all(descriptor, reply, sizeof(reply)) != 0) goto done;
    uint32_t status, returned_uid;
    memcpy(&status, reply, sizeof(status));
    memcpy(&returned_uid, reply + sizeof(status), sizeof(returned_uid));
    status = ntohl(status); returned_uid = ntohl(returned_uid);
    if (status == 1 && returned_uid == expected_uid) result = 1;
    else if (status == 2 && returned_uid == 0) result = 0;
    else { errno = EPROTO; result = -1; }
done:
    if (descriptor >= 0) close(descriptor);
    volatile unsigned char *clear = payload;
    for (size_t index = 0; index < sizeof(payload); ++index) clear[index] = 0;
    return result;
#endif
}

// The signal handler performs only lock-free atomic stores/CAS. arm64 and supported Linux targets
// guarantee this width; reject a platform rather than silently emitting a locking signal handler.
#if ATOMIC_INT_LOCK_FREE != 2
#error "Tractanda requires lock-free int atomics for signal handling"
#endif
enum startup_state { startup_idle, startup_starting, startup_stopping, startup_ready };
static _Atomic int stop_requested = startup_idle;
static _Atomic int startup_shutdown_state = startup_idle;
static struct sigaction previous_int, previous_term;
static void request_stop(int signal_number) {
    (void)signal_number;
    atomic_store_explicit(&stop_requested, 1, memory_order_relaxed);
    int expected = startup_starting;
    (void)atomic_compare_exchange_strong_explicit(
        &startup_shutdown_state, &expected, startup_stopping,
        memory_order_relaxed, memory_order_relaxed);
}
int tractanda_start_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    atomic_store_explicit(&stop_requested, 0, memory_order_relaxed);
    atomic_store_explicit(&startup_shutdown_state, startup_idle, memory_order_relaxed);
    if (sigaction(SIGINT, &action, &previous_int) != 0) return -1;
    if (sigaction(SIGTERM, &action, &previous_term) != 0) {
        sigaction(SIGINT, &previous_int, NULL); return -1;
    }
    return 0;
}
int tractanda_stopping(void) { return atomic_load_explicit(&stop_requested, memory_order_relaxed) != 0; }
void tractanda_restore_signals(void) {
    sigaction(SIGINT, &previous_int, NULL); sigaction(SIGTERM, &previous_term, NULL);
}
void tractanda_startup_shutdown_guard_begin(void) {
    atomic_store_explicit(&startup_shutdown_state, startup_starting, memory_order_release);
    // A signal can arrive after handler installation but before startup enters this guard.
    if (atomic_load_explicit(&stop_requested, memory_order_acquire)) {
        int expected = startup_starting;
        (void)atomic_compare_exchange_strong_explicit(
            &startup_shutdown_state, &expected, startup_stopping,
            memory_order_acq_rel, memory_order_acquire);
    }
}
void tractanda_startup_shutdown_guard_end(void) {
    atomic_store_explicit(&startup_shutdown_state, startup_idle, memory_order_release);
}
int tractanda_startup_shutdown_guard_ready(void) {
    int expected = startup_starting;
    return atomic_compare_exchange_strong_explicit(
        &startup_shutdown_state, &expected, startup_ready,
        memory_order_acq_rel, memory_order_acquire) ? 1 : 0;
}
int tractanda_terminate_if_stopping(void) {
    if (!atomic_load_explicit(&stop_requested, memory_order_acquire)
        || atomic_load_explicit(&startup_shutdown_state, memory_order_acquire) != startup_stopping) return 0;
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) return -1;
    return kill(getpid(), SIGTERM) == 0 ? 1 : -1;
}

uint32_t tractanda_uid(void) { return (uint32_t)geteuid(); }

int tractanda_file_metadata(
    const char *path, uint32_t *mode, uint32_t *uid, uint32_t *gid, uint64_t *size,
    uint64_t *inode, uint64_t *device, int64_t *mtime_seconds, int32_t *mtime_nanoseconds) {
    if (!path || !*path || !mode || !uid || !gid || !size || !inode || !device
        || !mtime_seconds || !mtime_nanoseconds) {
        errno = EINVAL;
        return -1;
    }
    struct stat metadata;
    if (lstat(path, &metadata) != 0) return -1;
    *mode = (uint32_t)metadata.st_mode;
    *uid = (uint32_t)metadata.st_uid;
    *gid = (uint32_t)metadata.st_gid;
    *size = (uint64_t)metadata.st_size;
    *inode = (uint64_t)metadata.st_ino;
    *device = (uint64_t)metadata.st_dev;
#ifdef __APPLE__
    *mtime_seconds = (int64_t)metadata.st_mtimespec.tv_sec;
    *mtime_nanoseconds = (int32_t)metadata.st_mtimespec.tv_nsec;
#else
    *mtime_seconds = (int64_t)metadata.st_mtim.tv_sec;
    *mtime_nanoseconds = (int32_t)metadata.st_mtim.tv_nsec;
#endif
    return 0;
}

void *tractanda_directory_open(const char *path) {
    if (!path || !*path) { errno = EINVAL; return NULL; }
    return opendir(path);
}

void *tractanda_directory_open_fd(int32_t descriptor) {
    int copied = fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
    if (copied < 0) return NULL;
    DIR *directory = fdopendir(copied);
    if (!directory) close(copied);
    return directory;
}

int tractanda_directory_next(void *directory, char *name, size_t capacity) {
    if (!directory || !name || capacity < 2) { errno = EINVAL; return -1; }
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir((DIR *)directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        size_t length = strlen(entry->d_name);
        if (length >= capacity) { errno = ENAMETOOLONG; return -1; }
        memcpy(name, entry->d_name, length + 1);
        return 1;
    }
    return errno == 0 ? 0 : -1;
}

int tractanda_directory_close(void *directory) {
    if (!directory) { errno = EINVAL; return -1; }
    return closedir((DIR *)directory);
}
// Copy NSS results before releasing the scratch buffer; never expose passwd fields.
int tractanda_user_name(uint32_t uid, char *name, size_t size, uint32_t *primary_group) {
    struct passwd record, *found = NULL;
    char *buffer = malloc(1024 * 1024);
    if (!buffer) return -1;
    int result = getpwuid_r((uid_t)uid, &record, buffer, 1024 * 1024, &found);
    if (result || !found || strlen(found->pw_name) >= size) { free(buffer); return -1; }
    strcpy(name, found->pw_name); *primary_group = (uint32_t)found->pw_gid;
    free(buffer); return 0;
}
int tractanda_user_id(const char *name, uint32_t *uid) {
    struct passwd record, *found = NULL;
    char *buffer = malloc(1024 * 1024);
    if (!buffer) return -1;
    int result = getpwnam_r(name, &record, buffer, 1024 * 1024, &found);
    if (result || !found) { free(buffer); return -1; }
    *uid = (uint32_t)found->pw_uid; free(buffer); return 0;
}
int tractanda_group_name(uint32_t gid, char *name, size_t size) {
    struct group record, *found = NULL;
    char *buffer = malloc(1024 * 1024);
    if (!buffer) return -1;
    int result = getgrgid_r((gid_t)gid, &record, buffer, 1024 * 1024, &found);
    if (result || !found || strlen(found->gr_name) >= size) { free(buffer); return -1; }
    strcpy(name, found->gr_name); free(buffer); return 0;
}
int tractanda_group_id(const char *name, uint32_t *gid) {
    struct group record, *found = NULL;
    char *buffer = malloc(1024 * 1024);
    if (!buffer) return -1;
    int result = getgrnam_r(name, &record, buffer, 1024 * 1024, &found);
    if (result || !found) { free(buffer); return -1; }
    *gid = (uint32_t)found->gr_gid; free(buffer); return 0;
}
int tractanda_user_groups(const char *name, uint32_t primary, uint32_t *groups, int *count) {
    if (*count < 1 || *count > 65536) return -1;
#ifdef __APPLE__
    int *native = calloc((size_t)*count, sizeof(int));
#else
    gid_t *native = calloc((size_t)*count, sizeof(gid_t));
#endif
    if (!native) return -1;
    int capacity = *count;
    int result = getgrouplist(name, primary, native, count);
    if (result >= 0 && *count <= capacity)
        for (int i = 0; i < *count; ++i) groups[i] = (uint32_t)native[i];
    else result = -1;
    free(native); return result;
}
int tractanda_path_read_only(const char *path) {
    struct statvfs information;
    if (statvfs(path, &information) != 0) return -1;
    return (information.f_flag & ST_RDONLY) != 0;
}
static _Thread_local int tractanda_lock_error = 0;

int tractanda_lock(const char *path) {
    tractanda_lock_error = 0;
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { tractanda_lock_error = errno; return -1; }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        tractanda_lock_error = errno;
        close(fd);
        return -1;
    }
    return fd;
}
int tractanda_lock_was_busy(void) {
    return tractanda_lock_error == EWOULDBLOCK || tractanda_lock_error == EAGAIN;
}
int tractanda_unlock(int fd) { flock(fd, LOCK_UN); return close(fd); }
void tractanda_close(int fd) { if (fd >= 0) close(fd); }
void tractanda_free(void *bytes) { free(bytes); }

static int write_bytes(int fd, const void *data, size_t count, int is_socket) {
    const char *bytes = data;
    while (count) {
#ifdef MSG_NOSIGNAL
        ssize_t n = is_socket ? send(fd, bytes, count, MSG_NOSIGNAL) : write(fd, bytes, count);
#else
        ssize_t n = write(fd, bytes, count);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes += n; count -= (size_t)n;
    }
    return 0;
}

// Hard-link publication never replaces an existing revision. Staging is on
// the destination filesystem so publication is one directory operation.
int tractanda_publish(const char *path, const void *bytes, size_t count) {
    size_t length = strlen(path);
    char *temporary = malloc(length + 16);
    if (!temporary) return -1;
    snprintf(temporary, length + 16, "%s.XXXXXX", path);
    int fd = mkstemp(temporary);
    if (fd < 0) { free(temporary); return -1; }
    int result = write_bytes(fd, bytes, count, 0);
    if (result == 0) result = fchmod(fd, 0400);
    if (result == 0) result = fsync(fd);
    int saved = errno;
    close(fd);
    errno = saved;
    if (result == 0) result = link(temporary, path);
    saved = errno;
    unlink(temporary);
    free(temporary);
    if (result == 0) {
        char *directory = strdup(path);
        if (!directory) return 1;
        char *slash = strrchr(directory, '/');
        if (slash) {
            *slash = 0;
            int parent = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            // 1 means published but directory durability could not be confirmed.
            if (parent < 0 || fsync(parent) != 0) result = 1;
            if (parent >= 0) close(parent);
        }
        free(directory);
    }
    errno = saved;
    return result;
}

static void socket_options(int fd) {
    struct timeval timeout = { 15, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#ifdef SO_NOSIGPIPE
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
}
static int socket_address(const char *path, struct sockaddr_un *address) {
    if (strlen(path) >= sizeof(address->sun_path)) { errno = ENAMETOOLONG; return -1; }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, strlen(path) + 1);
    return 0;
}
int tractanda_listen(const char *path) {
    return tractanda_listen_mode(path, 0600);
}
int tractanda_listen_mode(const char *path, uint32_t mode) {
    if (mode != 0600 && mode != 0666) { errno = EINVAL; return -1; }
    struct sockaddr_un address;
    if (socket_address(path, &address) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    mode_t previous = umask(0077);
    int result = bind(fd, (struct sockaddr *)&address, sizeof(address));
    umask(previous);
    if (result != 0) { close(fd); return -1; }
    if (chmod(path, mode) != 0 || listen(fd, 16) != 0) {
        int saved = errno; close(fd); unlink(path); errno = saved; return -1;
    }
    return fd;
}
int tractanda_connect(const char *path) {
    struct sockaddr_un address;
    if (socket_address(path, &address) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    socket_options(fd);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}
int tractanda_remove_stale_socket(const char *path) {
    struct stat before, after;
    if (lstat(path, &before) != 0) return errno == ENOENT ? 0 : -1;
    if (!S_ISSOCK(before.st_mode) || before.st_uid != geteuid()) { errno = EACCES; return -1; }
    int fd = tractanda_connect(path);
    if (fd >= 0) { close(fd); errno = EADDRINUSE; return -1; }
    if (errno != ECONNREFUSED) return -1;
    if (lstat(path, &after) != 0) return -1;
    if (before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        !S_ISSOCK(after.st_mode) || after.st_uid != geteuid()) { errno = EAGAIN; return -1; }
    return unlink(path);
}
int tractanda_accept(int listener) {
    struct pollfd event = { listener, POLLIN, 0 };
    int ready = poll(&event, 1, 500);
    if (ready == 0 || (ready < 0 && errno == EINTR)) return -2;
    if (ready < 0) return -1;
    int fd = accept(listener, NULL, NULL);
    if (fd >= 0) socket_options(fd);
    return fd;
}
int tractanda_peer_uid(int fd, uint32_t *uid) {
#ifdef __APPLE__
    uid_t user; gid_t group;
    if (getpeereid(fd, &user, &group) != 0) return -1;
    *uid = (uint32_t)user;
#else
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) != 0) return -1;
    *uid = (uint32_t)credentials.uid;
#endif
    return 0;
}
static int read_bytes(int fd, void *data, size_t count) {
    char *bytes = data;
    while (count) {
        ssize_t n = read(fd, bytes, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes += n; count -= (size_t)n;
    }
    return 0;
}
int tractanda_send_frame(int fd, const void *bytes, uint32_t count) {
    uint32_t length = htonl(count);
    if (write_bytes(fd, &length, sizeof(length), 1) != 0) return -1;
    return write_bytes(fd, bytes, count, 1);
}
int tractanda_receive_frame(int fd, void **bytes, uint32_t *count) {
    uint32_t length;
    if (read_bytes(fd, &length, sizeof(length)) != 0) return -1;
    length = ntohl(length);
    if (!length || length > 8 * 1024 * 1024) { errno = EMSGSIZE; return -1; }
    void *buffer = malloc(length);
    if (!buffer) return -1;
    if (read_bytes(fd, buffer, length) != 0) { free(buffer); return -1; }
    *bytes = buffer; *count = length; return 0;
}

/* Installer mutations only: preserve partial header/body bytes across bounded socket waits.
 * The request is sent once. EOF, cancellation and other transport failures still terminate. */
static int read_installer_response(int fd, void *data, size_t count) {
    char *cursor = data;
    while (count) {
        if (tractanda_stopping()) { errno = ECANCELED; return -1; }
        ssize_t amount = read(fd, cursor, count);
        if (amount < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT)) continue;
        if (amount == 0) { errno = ECONNRESET; return -1; }
        if (amount < 0) return -1;
        cursor += amount; count -= (size_t)amount;
    }
    return 0;
}
int tractanda_receive_installer_frame(int fd, void **bytes, uint32_t *count) {
    uint32_t length;
    if (read_installer_response(fd, &length, sizeof(length)) != 0) return -1;
    length = ntohl(length);
    if (!length || length > 8 * 1024 * 1024) { errno = EMSGSIZE; return -1; }
    void *buffer = malloc(length);
    if (!buffer) return -1;
    if (read_installer_response(fd, buffer, length) != 0) {
        int saved = errno; free(buffer); errno = saved; return -1;
    }
    *bytes = buffer; *count = length; return 0;
}

void tractanda_private_free(void *bytes, uint32_t count) {
    if (bytes) {
        volatile unsigned char *cursor = bytes;
        while (count--) *cursor++ = 0;
        free(bytes);
    }
}
static uint64_t private_now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000ull + (uint64_t)value.tv_nsec;
}
/* Enrollment supervisor only: actual image, never argv[0] or a mutable launch alias. */
int tractanda_current_executable(char *buffer, uint32_t capacity) {
    if (!buffer || capacity < 2 || capacity > 16384) { errno = EINVAL; return -1; }
    memset(buffer, 0, capacity);
#ifdef __APPLE__
    int amount = proc_pidpath(getpid(), buffer, capacity);
    if (amount <= 0) return -1;
    if ((uint32_t)amount >= capacity || strnlen(buffer, capacity) >= capacity) { errno = ENAMETOOLONG; return -1; }
#else
    ssize_t amount = readlink("/proc/self/exe", buffer, capacity - 1);
    if (amount <= 0) return -1;
    if ((uint32_t)amount >= capacity - 1) { errno = ENAMETOOLONG; return -1; }
    buffer[amount] = 0;
#endif
    if (buffer[0] != '/') { errno = EINVAL; return -1; }
    return 0;
}
/* One CLOCK_MONOTONIC cutoff covers connect and all subsequent bounded frame IO. */
int tractanda_private_connect_until(const char *path, uint64_t deadline) {
    struct sockaddr_un address;
    uint64_t now = private_now();
    if (!now || now >= deadline) { errno = ETIMEDOUT; return -1; }
    if (deadline - now > 20000000000ull) { errno = EINVAL; return -1; }
    if (socket_address(path, &address) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL), descriptor_flags = fcntl(fd, F_GETFD);
    if (flags < 0 || descriptor_flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 ||
        fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) != 0) goto failure;
    socket_options(fd);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (errno != EINPROGRESS) goto failure; /* Includes immediate bounded AF_UNIX backlog rejection. */
        for (;;) {
            now = private_now();
            if (!now || now >= deadline) { errno = ETIMEDOUT; goto failure; }
            struct pollfd event = { fd, POLLOUT, 0 };
            int ready = poll(&event, 1, (int)((deadline - now + 999999ull) / 1000000ull));
            if (ready < 0 && errno == EINTR) continue;
            if (ready <= 0) { if (!ready) errno = ETIMEDOUT; goto failure; }
            int connection_error = 0; socklen_t length = sizeof(connection_error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &connection_error, &length) != 0) goto failure;
            if (length != sizeof(connection_error)) { errno = EIO; goto failure; }
            if (connection_error) { errno = connection_error; goto failure; }
            break;
        }
    }
    now = private_now();
    if (!now || now >= deadline) { errno = ETIMEDOUT; goto failure; }
    return fd;
failure: {
    int saved = errno; close(fd); errno = saved; return -1;
    }
}
uint64_t tractanda_private_io_begin(int fd) {
    int flags = fcntl(fd, F_GETFL);
    int descriptor_flags = fcntl(fd, F_GETFD);
    uint64_t now = private_now();
    if (flags < 0 || descriptor_flags < 0 || !now ||
        fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) != 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return 0;
    return now + 20000000000ull;
}
static int private_io(int fd, void *data, size_t count, int writing, uint64_t deadline) {
    unsigned char *cursor = data;
    while (count) {
        uint64_t now = private_now();
        if (!now || now >= deadline) { errno = ETIMEDOUT; return -1; }
        if (deadline - now > 20000000000ull) { errno = EINVAL; return -1; }
        int timeout = (int)((deadline - now + 999999ull) / 1000000ull);
        struct pollfd event = { fd, writing ? POLLOUT : POLLIN, 0 };
        int ready = poll(&event, 1, timeout);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) { if (!ready) errno = ETIMEDOUT; return -1; }
        ssize_t n;
        if (writing) {
#ifdef MSG_NOSIGNAL
            n = send(fd, cursor, count, MSG_NOSIGNAL);
#else
            n = send(fd, cursor, count, 0);
#endif
        } else n = recv(fd, cursor, count, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) { if (!n) errno = ECONNRESET; return -1; }
        cursor += n; count -= (size_t)n;
    }
    return 0;
}
int tractanda_private_send_frame(int fd, const void *bytes, uint32_t count, uint64_t deadline) {
    if (!bytes || !count || count > 16384) { errno = EMSGSIZE; return -1; }
    uint32_t header = htonl(count);
    if (private_io(fd, &header, sizeof(header), 1, deadline) != 0) return -1;
    return private_io(fd, (void *)bytes, count, 1, deadline);
}
int tractanda_private_send_begin(int fd, const void *bytes, uint32_t count, uint64_t deadline) {
    if (!bytes || !count || count > 16384) { errno = EMSGSIZE; return -1; }
    uint32_t header = htonl(count | 0x80000000u);
    if (private_io(fd, &header, sizeof(header), 1, deadline) != 0) return -1;
    return private_io(fd, (void *)bytes, count, 1, deadline);
}
int tractanda_private_receive_frame(int fd, void **bytes, uint32_t *count, uint32_t maximum, uint64_t deadline) {
    if (!bytes || !count || !maximum || maximum > 135184) { errno = EINVAL; return -1; }
    *bytes = NULL; *count = 0;
    uint32_t header;
    if (private_io(fd, &header, sizeof(header), 0, deadline) != 0) return -1;
    uint32_t length = ntohl(header);
    if (!length || length > maximum) { errno = EMSGSIZE; return -1; }
    void *buffer = malloc(length);
    if (!buffer) return -1;
    if (private_io(fd, buffer, length, 0, deadline) != 0) {
        int saved = errno; tractanda_private_free(buffer, length); errno = saved; return -1;
    }
    *bytes = buffer; *count = length; return 0;
}
static int private_no_acl(int fd) {
#ifdef __APPLE__
    errno = 0;
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    // Darwin reports an absent FILESEC_ACL property as NULL/ENOENT. The caller
    // verifies this same open regular file, including nlink, before and after.
    if (!acl) { if (errno == ENOENT) { errno = 0; return 0; } return -1; }
    int valid = acl_valid(acl);
    acl_entry_t entry;
    errno = 0;
    int first = valid == 0 ? acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) : 0;
    int empty = valid == 0 && first == -1 && errno == EINVAL;
    acl_free(acl);
    if (!empty) { errno = EACCES; return -1; }
#else
    ssize_t length = fgetxattr(fd, "system.posix_acl_access", NULL, 0);
    if (length >= 0 || errno != ENODATA) { errno = EACCES; return -1; }
#endif
    errno = 0; return 0;
}
/* Fixed helper trust only. Deny-only macOS home ACLs do not grant mutation. */
static int helper_no_write_acl(int fd) {
#ifdef __APPLE__
    errno = 0; acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (!acl) { if (errno == ENOENT) { errno = 0; return 0; } return -1; }
    if (acl_valid(acl) != 0) { acl_free(acl); errno = EACCES; return -1; }
    acl_entry_t entry; int which = ACL_FIRST_ENTRY, result, count = 0;
    errno = 0;
    while ((result = acl_get_entry(acl, which, &entry)) == 0) {
        which = ACL_NEXT_ENTRY;
        acl_tag_t tag;
        if (++count > 128 || acl_get_tag_type(entry, &tag) != 0) goto denied;
        if (tag == ACL_EXTENDED_DENY) continue;
        if (tag != ACL_EXTENDED_ALLOW) goto denied;
        acl_permset_t permissions;
        if (acl_get_permset(entry, &permissions) != 0) goto denied;
        const acl_perm_t writes[] = { ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
            ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
            ACL_WRITE_SECURITY, ACL_CHANGE_OWNER };
        for (size_t i = 0; i < sizeof(writes) / sizeof(writes[0]); ++i)
            if (acl_get_perm_np(permissions, writes[i]) != 0) goto denied;
    }
    if (result != -1 || errno != EINVAL) goto denied;
    acl_free(acl); errno = 0; return 0;
denied:
    acl_free(acl); errno = EACCES; return -1;
#else
    /* Conservative access-ACL refusal; no new Linux ACL library or policy inference. */
    return private_no_acl(fd);
#endif
}
/* Read-only ACL gate for an already opened managed peer configuration/parent. */
int tractanda_peer_configuration_no_mutation_acl(int fd) { return helper_no_write_acl(fd); }
static int validate_enrollment_executable(const char *path, int root_only, const char *basename) {
    size_t length;
    if (!path || path[0] != '/' || !(length = strnlen(path, 4097)) || length > 4096) { errno = EINVAL; return -1; }
    char copy[4097]; memcpy(copy, path, length + 1);
    int directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) return -1;
    char *state = NULL, *part = strtok_r(copy + 1, "/", &state);
    if (!part) { close(directory); errno = EINVAL; return -1; }
    int count = 0;
    while (part) {
        char *next = strtok_r(NULL, "/", &state);
        if (++count > 256 || !strcmp(part, ".") || !strcmp(part, "..") ||
            (!next && strcmp(part, basename))) { errno = EACCES; goto failed; }
        int fd = openat(directory, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (next ? O_DIRECTORY : 0));
        if (fd < 0) goto failed;
        struct stat metadata;
        if (fstat(fd, &metadata) != 0) { int saved = errno; close(fd); errno = saved; goto failed; }
        int trusted_owner = metadata.st_uid == 0 || (!root_only && metadata.st_uid == geteuid());
        int kind = next ? S_ISDIR(metadata.st_mode) : S_ISREG(metadata.st_mode);
        int mutable_mode = metadata.st_mode & 0022;
        if (!trusted_owner || !kind || (!next && !(metadata.st_mode & 0111)) ||
            (mutable_mode && !(next && (metadata.st_mode & S_ISVTX))) || helper_no_write_acl(fd) != 0) {
            close(fd); errno = EACCES; goto failed;
        }
        close(directory); directory = fd; part = next;
    }
    close(directory); return 0;
failed: {
    int saved = errno; close(directory); errno = saved; return -1;
    }
}
int tractanda_validate_enrollment_helper(const char *path, int root_only) {
    return validate_enrollment_executable(path, root_only, "tractanda-setup");
}
int tractanda_validate_enrollment_ssh(void) {
    return validate_enrollment_executable("/usr/bin/ssh", 1, "ssh");
}
static int capture_peer_fd(int fd, void **bytes, uint32_t *count, uint32_t minimum, uint32_t maximum, int private_input, void (*after_stat)(void *), void *test_context) {
    struct stat before, after;
    void *buffer = NULL; uint32_t size = 0;
    if (fstat(fd, &before) != 0) return -1;
    if (!S_ISREG(before.st_mode) || before.st_nlink != 1 || before.st_size < minimum ||
        (uint64_t)before.st_size > maximum || (private_input && (before.st_uid != geteuid() ||
        ((before.st_mode & 07777) != 0600 && (before.st_mode & 07777) != 0400)))) { errno = EACCES; return -1; }
    if (private_input && private_no_acl(fd) != 0) return -1;
    if (after_stat) after_stat(test_context); // Synchronous test boundary; never retained.
    size = (uint32_t)before.st_size; buffer = malloc(size ? size : 1);
    if (!buffer) return -1;
    size_t offset = 0; int interrupted = 0;
    while (offset < size) {
        ssize_t n = pread(fd, (char *)buffer + offset, size - offset, (off_t)offset);
        if (n < 0 && errno == EINTR && ++interrupted <= 16) continue;
        if (n <= 0) { if (!n) errno = EIO; goto fail; }
        offset += (size_t)n;
    }
    unsigned char extra;
    ssize_t more = pread(fd, &extra, 1, size);
    if (more < 0) goto fail;
    if (more != 0) { errno = EAGAIN; goto fail; }
    if (fstat(fd, &after) != 0 || (private_input && private_no_acl(fd) != 0)) goto fail;
#ifdef __APPLE__
#define PRIVATE_MTIME(s) ((s).st_mtimespec)
#define PRIVATE_CTIME(s) ((s).st_ctimespec)
#else
#define PRIVATE_MTIME(s) ((s).st_mtim)
#define PRIVATE_CTIME(s) ((s).st_ctim)
#endif
    if (before.st_dev != after.st_dev || before.st_ino != after.st_ino || before.st_size != after.st_size ||
        before.st_uid != after.st_uid || before.st_gid != after.st_gid || before.st_mode != after.st_mode ||
        before.st_nlink != after.st_nlink || PRIVATE_MTIME(before).tv_sec != PRIVATE_MTIME(after).tv_sec ||
        PRIVATE_MTIME(before).tv_nsec != PRIVATE_MTIME(after).tv_nsec ||
        PRIVATE_CTIME(before).tv_sec != PRIVATE_CTIME(after).tv_sec ||
        PRIVATE_CTIME(before).tv_nsec != PRIVATE_CTIME(after).tv_nsec) { errno = EAGAIN; goto fail; }
#undef PRIVATE_MTIME
#undef PRIVATE_CTIME
    *bytes = buffer; *count = size; return 0;
fail: {
    int saved = errno ? errno : EIO;
    tractanda_private_free(buffer, size); errno = saved; return -1;
    }
}
static int capture_peer_at(int parent, const char *name, void **bytes, uint32_t *count,
                           uint32_t minimum, uint32_t maximum, int private_input, void (*after_stat)(void *), void *test_context) {
    *bytes = NULL; *count = 0;
    int fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 1 : -1; // Only this actual final open can report absence.
    int result = capture_peer_fd(fd, bytes, count, minimum, maximum, private_input, after_stat, test_context);
    if (result == 0) {
        struct stat held, named;
        if (fstat(fd, &held) != 0 || fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
            held.st_dev != named.st_dev || held.st_ino != named.st_ino) {
            tractanda_private_free(*bytes, *count); *bytes = NULL; *count = 0; errno = EAGAIN; result = -1;
        }
    }
    int saved = errno; close(fd); errno = saved; return result;
}
static int capture_peer_file(const char *path, void **bytes, uint32_t *count, uint32_t minimum, uint32_t maximum, int private_input, void (*after_stat)(void *), void *test_context) {
    if (!path || path[0] != '/' || !bytes || !count || strlen(path) > 4096) { errno = EINVAL; return -1; }
    *bytes = NULL; *count = 0;
    char *copy = strdup(path);
    if (!copy) return -1;
    int parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), result = -1, saved;
    char *state = NULL, *name = strtok_r(copy, "/", &state);
    if (parent < 0 || !name) { if (parent >= 0) errno = EINVAL; goto done; }
    while (name) {
        char *next = strtok_r(NULL, "/", &state);
        if (!next) { result = capture_peer_at(parent, name, bytes, count, minimum, maximum, private_input, after_stat, test_context); break; }
        int child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        saved = errno; close(parent); parent = child; errno = saved;
        if (parent < 0) break;
        name = next;
    }
done:
    saved = errno; if (parent >= 0) close(parent); free(copy); errno = saved; return result;
}
int tractanda_capture_private_credential(const char *path, void **bytes, uint32_t *count) {
    int result = capture_peer_file(path, bytes, count, 36, 4096, 1, NULL, NULL);
    return result == 1 ? -1 : result;
}
// Only trusted local callers choose an artifact bound. No daemon wire request supplies a path.
int tractanda_capture_private_artifact(const char *path, void **bytes, uint32_t *count, uint32_t maximum) {
    if (!maximum || maximum > 1048576) { errno = EINVAL; return -1; }
    return capture_peer_file(path, bytes, count, 0, maximum, 1, NULL, NULL);
}
int tractanda_capture_private_artifact_at(int parent, const char *name, void **bytes, uint32_t *count, uint32_t maximum) {
    if (!bytes || !count || !maximum || maximum > 1048576 || !name || !*name || strchr(name, '/') ||
        !strcmp(name, ".") || !strcmp(name, "..")) { errno = EINVAL; return -1; }
    return capture_peer_at(parent, name, bytes, count, 0, maximum, 1, NULL, NULL);
}
int tractanda_capture_peer_preparation(const char *path, void **bytes, uint32_t *count) {
    int result = capture_peer_file(path, bytes, count, 1, 4096, 0, NULL, NULL);
    return result == 1 ? -1 : result;
}
int tractanda_capture_private_artifact_for_testing(const char *path, void **bytes, uint32_t *count,
        uint32_t maximum, void (*after_stat)(void *), void *context) {
    if (!maximum || maximum > 1048576) { errno = EINVAL; return -1; }
    return capture_peer_file(path, bytes, count, 0, maximum, 1, after_stat, context);
}
int tractanda_open_private_directory(const char *path) {
    if (!path || path[0] != '/' || strlen(path) > 4096) { errno = EINVAL; return -1; }
    char *copy = strdup(path);
    if (!copy) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), saved;
    char *state = NULL;
    for (char *name = strtok_r(copy, "/", &state); name; name = strtok_r(NULL, "/", &state)) {
        if (fd < 0) break;
        int child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        saved = errno; close(fd); fd = child; errno = saved;
    }
    free(copy);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != geteuid() ||
        (info.st_mode & 07777) != 0700 || private_no_acl(fd) != 0) {
        saved = errno ? errno : EACCES; close(fd); errno = saved; return -1;
    }
    return fd;
}

int tractanda_publish_directory_at(int source_parent, const char *source, int target_parent, const char *target) {
    if (!source || !target || !*source || !*target || strchr(source, '/') || strchr(target, '/') ||
        !strcmp(source, ".") || !strcmp(source, "..") || !strcmp(target, ".") || !strcmp(target, "..")) {
        errno = EINVAL;
        return -1;
    }
#ifdef __APPLE__
    return renameatx_np(source_parent, source, target_parent, target, RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2, source_parent, source, target_parent, target, RENAME_NOREPLACE);
#else
    errno = ENOTSUP;
    return -1;
#endif
}

// Caller-only atomic private artifact publication. The parent was traversed without
// symlinks; no daemon request supplies any path to this function.
int tractanda_write_private_artifact_at(int parent, const char *temporary, const char *target,
                                       const void *bytes, uint32_t count) {
    if ((!bytes && count) || count > 1048576 || !temporary || !target || !*temporary || !*target ||
        strchr(temporary, '/') || strchr(target, '/') || !strcmp(target, ".") || !strcmp(target, "..") ||
        !strcmp(temporary, ".") || !strcmp(temporary, "..")) { errno = EINVAL; return -1; }
    struct stat directory, held, named;
    if (fstat(parent, &directory) != 0 || !S_ISDIR(directory.st_mode) || directory.st_uid != geteuid() ||
        (directory.st_mode & 07777) != 0700 || private_no_acl(parent) != 0) { errno = EACCES; return -1; }
    struct statvfs capacity;
    if (fstatvfs(parent, &capacity) != 0 || !capacity.f_frsize ||
        (uint64_t)capacity.f_bavail > UINT64_MAX / capacity.f_frsize ||
        (uint64_t)capacity.f_bavail * capacity.f_frsize < count) { errno = ENOSPC; return -1; }
    int fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int result = -1, saved = 0, published = 0;
    if (fstat(fd, &held) != 0 || !S_ISREG(held.st_mode) || held.st_uid != geteuid() || held.st_nlink != 1 ||
        (held.st_mode & 07777) != 0600 || private_no_acl(fd) != 0) { errno = EACCES; goto done; }
    if (write_bytes(fd, bytes, count, 0) != 0 || fchmod(fd, 0400) != 0 || fsync(fd) != 0 || private_no_acl(fd) != 0) goto done;
    if (fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
        fstat(fd, &held) != 0 || named.st_dev != held.st_dev || named.st_ino != held.st_ino ||
        held.st_nlink != 1 || held.st_size != count) { errno = EAGAIN; goto done; }
    // RENAME_EXCL/RENAME_NOREPLACE also works for regular files, and avoids the
    // link/unlink crash window leaving two names for a supposedly single-link key.
    if (tractanda_publish_directory_at(parent, temporary, parent, target) != 0) goto done;
    published = 1;
    result = fsync(parent) == 0 ? 0 : 1; //1=published, acknowledgment/durability uncertain.
done:
    saved = errno;
    if (!published && fstat(fd, &held) == 0 && fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
        named.st_dev == held.st_dev && named.st_ino == held.st_ino) (void)unlinkat(parent, temporary, 0);
    close(fd); errno = saved; return result;
}


// Child stdio must use a real dup2, even when the parent's 0/1/2 were closed.
static int document_pipe(int fds[2]) {
    if (pipe(fds) != 0) return -1;
    for (int i = 0; i < 2; ++i) {
        if (fds[i] < 3) {
            int replacement = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) goto failure;
            close(fds[i]); fds[i] = replacement;
        }
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) != 0) goto failure;
    }
    return 0;
failure: {
    int saved = errno;
    close(fds[0]); close(fds[1]); fds[0] = fds[1] = -1;
    errno = saved; return -1;
    }
}

extern char **environ;
int tractanda_document_spawn(
    const char *executable, const char *const argv[], int32_t *pid,
    int32_t *input, int32_t *output, int32_t *error) {
    if (!executable || !*executable || !argv || !argv[0] || !pid || !input || !output || !error) {
        errno = EINVAL; return -1;
    }
    *pid = *input = *output = *error = -1;
    int fds[6] = {-1, -1, -1, -1, -1, -1};
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int has_attributes = 0, has_actions = 0, result, saved;
    pid_t child;
#define DOCUMENT_APPLY(expression) do { result = (expression); if (result) { errno = result; goto failure; } } while (0)
    for (int i = 0; i < 6; i += 2) if (document_pipe(&fds[i]) != 0) goto failure;
    int parent_ends[] = {1, 2, 4};
    for (int i = 0; i < 3; ++i) {
        int fd = fds[parent_ends[i]], flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) goto failure;
    }
    DOCUMENT_APPLY(posix_spawnattr_init(&attributes)); has_attributes = 1;
    DOCUMENT_APPLY(posix_spawn_file_actions_init(&actions)); has_actions = 1;
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef __APPLE__
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    DOCUMENT_APPLY(posix_spawnattr_setflags(&attributes, flags));
    DOCUMENT_APPLY(posix_spawnattr_setpgroup(&attributes, 0));
    sigset_t empty, defaults;
    sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGHUP);
    sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGCHLD);
    DOCUMENT_APPLY(posix_spawnattr_setsigmask(&attributes, &empty));
    DOCUMENT_APPLY(posix_spawnattr_setsigdefault(&attributes, &defaults));
    DOCUMENT_APPLY(posix_spawn_file_actions_adddup2(&actions, fds[0], STDIN_FILENO));
    DOCUMENT_APPLY(posix_spawn_file_actions_adddup2(&actions, fds[3], STDOUT_FILENO));
    DOCUMENT_APPLY(posix_spawn_file_actions_adddup2(&actions, fds[5], STDERR_FILENO));
    for (int i = 0; i < 6; ++i) DOCUMENT_APPLY(posix_spawn_file_actions_addclose(&actions, fds[i]));
#ifndef __APPLE__
#if defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 34)
#define TRACTANDA_SPAWN_CLOSEFROM 1
#endif
#endif
#ifdef TRACTANDA_SPAWN_CLOSEFROM
    DOCUMENT_APPLY(posix_spawn_file_actions_addclosefrom_np(&actions, 3));
#else
    // A bounded fallback covers the hard limit, including descriptors opened before a soft-limit drop.
    struct rlimit descriptor_limit;
    if (getrlimit(RLIMIT_NOFILE, &descriptor_limit) != 0) goto failure;
    if (descriptor_limit.rlim_max == RLIM_INFINITY || descriptor_limit.rlim_max > 4096) {
        errno = ENOTSUP; goto failure;
    }
    for (int fd = 3; (rlim_t)fd < descriptor_limit.rlim_max; ++fd) {
        int is_pipe = 0;
        for (int i = 0; i < 6; ++i) if (fd == fds[i]) is_pipe = 1;
        if (!is_pipe) DOCUMENT_APPLY(posix_spawn_file_actions_addclose(&actions, fd));
    }
#endif
#endif
    DOCUMENT_APPLY(posix_spawn(&child, executable, &actions, &attributes, (char *const *)argv, environ));
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    close(fds[0]); close(fds[3]); close(fds[5]);
    *pid = (int32_t)child; *input = fds[1]; *output = fds[2]; *error = fds[4];
    return 0;
failure:
    saved = errno;
    if (has_actions) posix_spawn_file_actions_destroy(&actions);
    if (has_attributes) posix_spawnattr_destroy(&attributes);
    for (int i = 0; i < 6; ++i) if (fds[i] >= 0) close(fds[i]);
    errno = saved; return -1;
#undef DOCUMENT_APPLY
}


int tractanda_document_exited(int32_t pid) {
    if (pid <= 0) { errno = EINVAL; return -1; }
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0) return -1;
    return info.si_pid == pid ? 1 : 0;
}

int64_t tractanda_document_write(int32_t fd, const void *bytes, size_t count) {
    sigset_t blocked, original, pending;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    int result = pthread_sigmask(SIG_BLOCK, &blocked, &original);
    if (result) { errno = result; return -1; }
    int already_pending = sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE);
    ssize_t written = write(fd, bytes, count);
    int saved = errno;
    if (written < 0 && saved == EPIPE && !already_pending
        && sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE)) {
        int signal_number;
        (void)sigwait(&blocked, &signal_number);
    }
    result = pthread_sigmask(SIG_SETMASK, &original, NULL);
    if (result && written >= 0) { errno = result; return -1; }
    errno = saved; return (int64_t)written;
}
