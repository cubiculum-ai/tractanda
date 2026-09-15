#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#include "TractandaTerminal.h"
#include <errno.h>
#include <locale.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <wchar.h>

static struct termios original;
static const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGPIPE};
static struct sigaction previous[6];
static int installed = 0;
static int active = 0;
static volatile sig_atomic_t stopping = 0;
static void stop(int signal_number) { stopping = signal_number; }

void tractanda_terminal_close(void) {
    if (active) {
        // Restore the terminal even when output is already disconnected.
        while (tcsetattr(STDIN_FILENO, TCSANOW, &original) < 0 && errno == EINTR) {}
        active = 0;
    }
    for (int i = 0; i < installed; i++) sigaction(signals[i], &previous[i], NULL);
    installed = 0;
}

int tractanda_terminal_open(void) {
    if (active || !isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return -1;
    if (tcgetattr(STDIN_FILENO, &original) < 0) return -1;
    setlocale(LC_CTYPE, "");
    stopping = 0;
    struct sigaction action = {0};
    action.sa_handler = stop;
    sigemptyset(&action.sa_mask);
    for (int i = 0; i < 6; i++) {
        if (sigaction(signals[i], &action, &previous[i]) < 0) {
            tractanda_terminal_close();
            return -1;
        }
        installed++;
    }
    struct termios raw = original;
    cfmakeraw(&raw);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) < 0) {
        tractanda_terminal_close();
        return -1;
    }
    active = 1;
    return 0;
}

int tractanda_terminal_read(void *buffer, size_t size, int timeout_ms) {
    if (stopping) return -2;
    struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
    int result = poll(&descriptor, 1, timeout_ms);
    if (stopping) return -2;
    if (result < 0) return errno == EINTR ? 0 : -1;
    if (!result) return 0;
    if (!(descriptor.revents & POLLIN)) return -1;
    ssize_t count = read(STDIN_FILENO, buffer, size);
    if (count < 0 && (errno == EINTR || errno == EAGAIN)) return 0;
    return count > 0 ? (int)count : -1;
}

int tractanda_terminal_write(const void *buffer, size_t size) {
    const unsigned char *bytes = buffer;
    while (size) {
        ssize_t count = write(STDOUT_FILENO, bytes, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += count;
        size -= (size_t)count;
    }
    return 0;
}

void tractanda_terminal_size(int *columns, int *rows) {
    struct winsize size = {0};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col && size.ws_row) {
        *columns = size.ws_col; *rows = size.ws_row;
    } else { *columns = 80; *rows = 24; }
}

int tractanda_terminal_width(uint32_t scalar) { return wcwidth((wchar_t)scalar); }
