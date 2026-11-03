#ifndef TRACTANDA_LAYOUT17_MOVES_H
#define TRACTANDA_LAYOUT17_MOVES_H

#include <sys/types.h>
#include <stdint.h>

/* File move by no-replace hard link and unlink. A crash between those two
 * operations is retried only when both names still identify the same inode.
 * The journal must have pinned device and inode before this function runs. */
int layout17_move_file(int source_dir, const char *source, int target_dir,
                       const char *target, uid_t owner, uint64_t device,
                       uint64_t inode, int fault_boundary);

/* The pinned directory is moved exclusively within its filesystem. */
int layout17_move_directory(int source_dir, const char *source, int target_dir,
                            const char *target, uid_t owner, uint64_t device,
                            uint64_t inode, int fault_after_rename);
int layout17_rename_exclusive(int source_dir, const char *source, int target_dir, const char *target);
int layout17_durable_sync(int fd);

#endif
