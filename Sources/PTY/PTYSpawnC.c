#include "PTYSpawnC.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

pid_t pty_spawn_fork(int master_fd,
                     int slave_fd,
                     const char *command,
                     char *const argv[],
                     char *const envp[],
                     const char *cwd) {
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child: only async-signal-safe APIs from here until execve.
        (void)setsid();
        (void)ioctl(slave_fd, TIOCSCTTY, 0);
        (void)dup2(slave_fd, 0);
        (void)dup2(slave_fd, 1);
        (void)dup2(slave_fd, 2);
        if (slave_fd > 2) {
            (void)close(slave_fd);
        }
        (void)close(master_fd);
        if (cwd != NULL) {
            (void)chdir(cwd);
        }
        (void)execve(command, argv, envp);
        const char err[] = "execve failed\n";
        (void)write(2, err, sizeof(err) - 1);
        _exit(127);
    }
    return pid;
}
