#ifndef TRACTANDA_TERMINAL_H
#define TRACTANDA_TERMINAL_H
#include <stdint.h>
#include <stddef.h>
// One terminal session per process; restores termios and signal handlers on close.
int tractanda_terminal_open(void);
void tractanda_terminal_close(void);
// Positive byte count, 0 timeout, -1 EOF/error, -2 termination signal.
int tractanda_terminal_read(void *buffer, size_t size, int timeout_ms);
int tractanda_terminal_write(const void *buffer, size_t size);
void tractanda_terminal_size(int *columns, int *rows);
int tractanda_terminal_width(uint32_t scalar);
#endif
