/* fsyncfail: fdatasync fault injection for pg_logtap's e2e suite.
 *
 * LD_PRELOAD shim, no PostgreSQL headers: it wraps fdatasync and fails it
 * with EIO, but ONLY for the fd whose /proc/self/fd link points at the path
 * in /tmp/fsyncfail-target and only the first FSYNCFAIL_COUNT calls in this
 * process. Everything else — WAL, the data dir, every other file — syncs
 * for real, so a whole postmaster can run under the shim and only the one
 * file we name misbehaves.
 *
 * The watched path arrives via a file, not an env var: it depends on the
 * server's PGDATA, which is only known after the container boots — the
 * harness writes the file then, and until it exists every call passes
 * through untouched. The count stays an env var (set at create time; the
 * number does not depend on PGDATA). The counter is per-process on
 * purpose: the export worker is one forked child, and a fork must not
 * inherit the parent's spent budget.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int (*real_fdatasync)(int);

int fdatasync(int fd)
{
    if (!real_fdatasync)
        real_fdatasync = dlsym(RTLD_NEXT, "fdatasync");

    int tf = open("/tmp/fsyncfail-target", O_RDONLY);
    if (tf >= 0)
    {
        char want[PATH_MAX];
        ssize_t wl = read(tf, want, sizeof want - 1);
        close(tf);
        while (wl > 0 && (want[wl - 1] == '\n' || want[wl - 1] == ' '))
            wl--;
        if (wl > 0)
        {
            want[wl] = '\0';
            char link[32], target[PATH_MAX];
            snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
            ssize_t n = readlink(link, target, sizeof target - 1);
            if (n > 0)
            {
                target[n] = '\0';
                static int left = -1; /* -1 = not read yet; counts down in-process */
                if (left < 0)
                {
                    const char *cnt = getenv("FSYNCFAIL_COUNT");
                    left = cnt ? atoi(cnt) : 0;
                }
                if (strcmp(target, want) == 0 && left > 0)
                {
                    left--;
                    errno = EIO;
                    return -1;
                }
            }
        }
    }
    return real_fdatasync(fd);
}
