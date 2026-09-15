#define _GNU_SOURCE
#include <TractandaPlatform.h>
#include <stdio.h>

#ifdef __linux__

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

enum { maximum_username = 128, maximum_password = 4096, maximum_payload = 4226, maximum_workers = 4 };
static volatile sig_atomic_t stopping = 0;
static volatile sig_atomic_t child_changed = 0;

static void clear_bytes(void *bytes, size_t count) {
    volatile unsigned char *cursor = bytes;
    while (count--) *cursor++ = 0;
}

static void request_stop(int ignored) { (void)ignored; stopping = 1; }
static void note_child(int ignored) { (void)ignored; child_changed = 1; }
static void deadline(int ignored) { (void)ignored; _exit(124); }

static int name_is_safe(const char *name, size_t length) {
    if (!length || length > maximum_username) return 0;
    for (size_t index = 0; index < length; ++index) {
        unsigned char byte = (unsigned char)name[index];
        if (!((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
              (byte >= '0' && byte <= '9') || byte == '-' || byte == '.' || byte == '_' || byte == '$')) return 0;
    }
    return 1;
}

static int wait_for(int descriptor, short events, int timeout_ms) {
    struct pollfd item = {.fd = descriptor, .events = events, .revents = 0};
    for (;;) {
        int result = poll(&item, 1, timeout_ms);
        if (result > 0 && (item.revents & events)) return 0;
        if (result > 0 && (item.revents & (POLLERR | POLLHUP | POLLNVAL))) { errno = EPROTO; return -1; }
        if (result == 0) { errno = ETIMEDOUT; return -1; }
        if (result < 0 && errno == EINTR) {
            if (stopping) { errno = EINTR; return -1; }
            continue;
        }
        if (result >= 0) errno = EPROTO;
        return -1;
    }
}

static int read_all(int descriptor, void *bytes, size_t count) {
    unsigned char *cursor = bytes;
    while (count) {
        if (wait_for(descriptor, POLLIN, 5000) != 0) return -1;
        ssize_t received = read(descriptor, cursor, count);
        if (received > 0) { cursor += received; count -= (size_t)received; continue; }
        if (received < 0 && errno == EINTR) continue;
        if (!received) errno = ECONNRESET;
        return -1;
    }
    return 0;
}

static int write_all(int descriptor, const void *bytes, size_t count) {
    const unsigned char *cursor = bytes;
    while (count) {
        if (wait_for(descriptor, POLLOUT, 5000) != 0) return -1;
        ssize_t written = send(descriptor, cursor, count, MSG_NOSIGNAL);
        if (written > 0) { cursor += written; count -= (size_t)written; continue; }
        if (written < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

// Opens every path component with O_NOFOLLOW and requires root ownership/no group-or-other write.
static int open_safe_parent(const char *path) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    char copy[sizeof(((struct sockaddr_un *)0)->sun_path)];
    size_t length = strlen(path);
    if (length < 2 || length >= sizeof(copy)) { errno = ENAMETOOLONG; return -1; }
    memcpy(copy, path, length + 1);
    char *final_slash = strrchr(copy, '/');
    if (!final_slash || final_slash == copy || !final_slash[1]) { errno = EINVAL; return -1; }
    *final_slash = 0;
    int descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) return -1;
    char *component = copy + 1;
    while (*component) {
        char *slash = strchr(component, '/');
        if (slash) *slash = 0;
        if (!*component || !strcmp(component, ".") || !strcmp(component, "..")) { errno = EINVAL; goto failed; }
        int next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) goto failed;
        struct stat metadata;
        if (fstat(next, &metadata) != 0 || !S_ISDIR(metadata.st_mode) || metadata.st_uid != 0 ||
            (metadata.st_mode & (S_IWGRP | S_IWOTH))) { close(next); errno = EACCES; goto failed; }
        close(descriptor); descriptor = next;
        if (!slash) break;
        component = slash + 1;
    }
    return descriptor;
failed:
    close(descriptor);
    return -1;
}

static int bind_private_socket(const char *path, uid_t allowed_uid, dev_t *device, ino_t *inode) {
    int parent = open_safe_parent(path);
    if (parent < 0) return -1;
    const char *leaf = strrchr(path, '/') + 1;
    struct stat existing;
    if (fstatat(parent, leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        // Restart must be explicit after investigation; never replace any extant object.
        close(parent); errno = EEXIST; return -1;
    }
    if (errno != ENOENT) { close(parent); return -1; }
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0) { close(parent); return -1; }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address)); address.sun_family = AF_UNIX;
    size_t path_length = strlen(path);
    memcpy(address.sun_path, path, path_length + 1);
    mode_t old_mask = umask(0077);
    int bound = bind(listener, (struct sockaddr *)&address, sizeof(address));
    umask(old_mask);
    if (bound != 0) { close(listener); close(parent); return -1; }
    if (chown(path, allowed_uid, (gid_t)-1) != 0 || chmod(path, 0600) != 0 ||
        fstatat(parent, leaf, &existing, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISSOCK(existing.st_mode) ||
        existing.st_uid != allowed_uid ||
        (existing.st_mode & 0777) != 0600 || listen(listener, 16) != 0) {
        int saved = errno; close(listener); unlinkat(parent, leaf, 0); close(parent); errno = saved; return -1;
    }
    *device = existing.st_dev; *inode = existing.st_ino;
    close(parent);
    int flags = fcntl(listener, F_GETFL);
    if (flags < 0 || fcntl(listener, F_SETFL, flags | O_NONBLOCK) != 0) { close(listener); return -1; }
    return listener;
}

static void reply(int descriptor, uint32_t status, uint32_t uid) {
    uint32_t response[2] = {htonl(status), htonl(uid)};
    (void)write_all(descriptor, response, sizeof(response));
}

static void handle_client(int descriptor, uid_t allowed_uid) {
    unsigned char payload[maximum_payload] = {0};
    uint32_t wire_length = 0, uid = 0, status = 3;
    struct ucred peer;
    socklen_t peer_length = sizeof(peer);
    if (getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &peer, &peer_length) != 0 ||
        peer_length != sizeof(peer) || peer.uid != allowed_uid) goto done;
    if (read_all(descriptor, &wire_length, sizeof(wire_length)) != 0) goto done;
    size_t length = ntohl(wire_length);
    if (length < 3 || length > sizeof(payload) || read_all(descriptor, payload, length) != 0) goto done;
    unsigned char *separator = memchr(payload, 0, length);
    if (!separator || separator == payload || (size_t)(separator - payload) > maximum_username ||
        separator + 1 >= payload + length || payload[length - 1] != 0 ||
        memchr(separator + 1, 0, (size_t)(payload + length - separator - 1)) != payload + length - 1 ||
        length - (size_t)(separator - payload) - 2 > maximum_password ||
        !name_is_safe((const char *)payload, (size_t)(separator - payload))) { status = 2; goto done; }
    int verified = tractanda_authenticate_password((const char *)payload, (const char *)separator + 1, &uid);
    if (verified == 1) status = 1;
    else if (verified == 0) status = 2;
done:
    reply(descriptor, status, status == 1 ? uid : 0);
    clear_bytes(payload, sizeof(payload));
}

static void clean_own_socket(const char *path, dev_t device, ino_t inode) {
    struct stat metadata;
    if (lstat(path, &metadata) == 0 && S_ISSOCK(metadata.st_mode) && metadata.st_dev == device && metadata.st_ino == inode)
        (void)unlink(path);
}

int main(int argc, char **argv) {
    const char *socket_path = NULL, *allowed_name = NULL;
    if (argc != 5 || strcmp(argv[1], "--socket") || strcmp(argv[3], "--allowed-user")) {
        fprintf(stderr, "usage: tractanda-auth-helper --socket ABSOLUTE_PATH --allowed-user USERNAME\n"); return 64;
    }
    socket_path = argv[2]; allowed_name = argv[4];
    if (getuid() != 0 || geteuid() != 0 || !name_is_safe(allowed_name, strlen(allowed_name))) {
        fprintf(stderr, "tractanda-auth-helper requires root and a valid non-root allowed user\n"); return 77;
    }
    struct passwd account, *found = NULL; char account_buffer[16384];
    if (getpwnam_r(allowed_name, &account, account_buffer, sizeof(account_buffer), &found) != 0 || !found || account.pw_uid == 0) {
        fprintf(stderr, "tractanda-auth-helper allowed user is unavailable or root\n"); return 77;
    }
    struct rlimit limit = {.rlim_cur = 0, .rlim_max = 0};
    if (setrlimit(RLIMIT_CORE, &limit) != 0 || prctl(PR_SET_DUMPABLE, 0) != 0) {
        fprintf(stderr, "tractanda-auth-helper could not disable core dumps\n"); return 70;
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = request_stop; sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGTERM, &action, NULL) != 0) return 70;
    action.sa_handler = note_child; action.sa_flags = SA_RESTART;
    if (sigaction(SIGCHLD, &action, NULL) != 0) return 70;
    dev_t socket_device; ino_t socket_inode;
    int listener = bind_private_socket(socket_path, account.pw_uid, &socket_device, &socket_inode);
    if (listener < 0) { perror("tractanda-auth-helper socket"); return 73; }
    pid_t workers[maximum_workers] = {0}; size_t worker_count = 0;
    while (!stopping) {
        if (child_changed) {
            child_changed = 0;
            for (size_t index = 0; index < maximum_workers; ++index) if (workers[index] &&
                waitpid(workers[index], NULL, WNOHANG) == workers[index]) { workers[index] = 0; --worker_count; }
        }
        struct pollfd item = {.fd = listener, .events = POLLIN, .revents = 0};
        int ready = poll(&item, 1, 250);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0 || !(item.revents & POLLIN)) continue;
        int client = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
        if (client < 0) { if (errno == EINTR || errno == EAGAIN || errno == ECONNABORTED) continue; break; }
        if (worker_count == maximum_workers) { close(client); continue; }
        pid_t child = fork();
        if (child < 0) { close(client); continue; }
        if (child == 0) {
            close(listener); struct sigaction timer;
            memset(&timer, 0, sizeof(timer)); timer.sa_handler = deadline; sigemptyset(&timer.sa_mask);
            (void)sigaction(SIGALRM, &timer, NULL); alarm(10);
            handle_client(client, account.pw_uid); close(client); _exit(0);
        }
        close(client);
        for (size_t index = 0; index < maximum_workers; ++index) if (!workers[index]) { workers[index] = child; ++worker_count; break; }
    }
    close(listener);
    for (size_t index = 0; index < maximum_workers; ++index) if (workers[index]) (void)kill(workers[index], SIGTERM);
    while (worker_count) for (size_t index = 0; index < maximum_workers; ++index) if (workers[index] &&
        waitpid(workers[index], NULL, 0) == workers[index]) { workers[index] = 0; --worker_count; }
    clean_own_socket(socket_path, socket_device, socket_inode);
    clear_bytes(account_buffer, sizeof(account_buffer));
    return 0;
}

#else

int main(void) {
    fputs("tractanda-auth-helper is supported only on Linux.\n", stderr);
    return 69;
}

#endif
