#ifndef PTYSPAWNC_H
#define PTYSPAWNC_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forks a child that becomes the session leader of slave_fd, dup2s slave_fd
// onto stdin/stdout/stderr, then execve's command/argv/envp. Optionally
// chdirs to cwd (NULL skips). Returns the child PID on success; returns
// -1 with errno set on fork failure.
//
// Why C: Swift's stdlib marks fork() unavailable. The child path must use
// only async-signal-safe APIs between fork and execve, which is much easier
// to express in C than in Swift.
pid_t pty_spawn_fork(int master_fd,
                     int slave_fd,
                     const char *command,
                     char *const argv[],
                     char *const envp[],
                     const char *cwd);

#ifdef __cplusplus
}
#endif

#endif
