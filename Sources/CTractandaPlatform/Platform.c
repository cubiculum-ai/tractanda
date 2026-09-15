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
#include <pwd.h>
#include <grp.h>
#include <sys/statvfs.h>
#include <dirent.h>
#include <security/pam_appl.h>
#include <uuid/uuid.h>
#include <pthread.h>
#ifdef __linux__
#include <ifaddrs.h>
#include <net/if.h>
#include <linux/ethtool.h>
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
    uint64_t *inode, uint64_t *device) {
    if (!path || !*path || !mode || !uid || !gid || !size || !inode || !device) {
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
    return 0;
}

void *tractanda_directory_open(const char *path) {
    if (!path || !*path) { errno = EINVAL; return NULL; }
    return opendir(path);
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
