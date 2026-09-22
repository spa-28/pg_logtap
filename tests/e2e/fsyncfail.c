/* fsyncfail: narrow filesystem fault injection for pg_logtap's e2e suite.
 *
 * LD_PRELOAD shim, no PostgreSQL headers:
 *
 * - fdatasync fails with EIO only for the fd whose /proc/self/fd link points
 *   at the path in /tmp/fsyncfail-target, for FSYNCFAIL_COUNT calls;
 * - open/open64 fail only an O_CREAT|O_EXCL attempt for the pathname in
 *   /tmp/openfail-target, for OPENFAIL_COUNT calls, with OPENFAIL_ERRNO.
 *
 * Everything else — WAL, the data dir, every other file — passes through to
 * libc. Targets arrive via files because PGDATA is known only after container
 * startup; until a target exists, the corresponding fault is disabled.
 * Counters are per-process on purpose: the export worker is one forked child.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int (*real_fdatasync)(int);
static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);

static void resolve_symbols(void)
{
    if (!real_fdatasync)
        real_fdatasync = dlsym(RTLD_NEXT, "fdatasync");
    if (!real_open)
        real_open = dlsym(RTLD_NEXT, "open");
    if (!real_open64)
        real_open64 = dlsym(RTLD_NEXT, "open64");
}

static int read_target(const char *control, char *target, size_t size)
{
    resolve_symbols();
    if (!real_open)
        return 0;

    int fd = real_open(control, O_RDONLY);
    if (fd < 0)
        return 0;
    ssize_t len = read(fd, target, size - 1);
    close(fd);
    while (len > 0 && (target[len - 1] == '\n' || target[len - 1] == ' '))
        len--;
    if (len <= 0)
        return 0;
    target[len] = '\0';
    return 1;
}

static int configured_count(const char *name)
{
    const char *value = getenv(name);
    return value ? atoi(value) : 0;
}

static int open_should_fail(const char *pathname, int flags)
{
    static int left = -1;
    char target[PATH_MAX];

    if ((flags & (O_CREAT | O_EXCL)) != (O_CREAT | O_EXCL) ||
        !read_target("/tmp/openfail-target", target, sizeof target) ||
        strcmp(pathname, target) != 0)
        return 0;
    if (left < 0)
        left = configured_count("OPENFAIL_COUNT");
    if (left <= 0)
        return 0;

    left--;
    int fault_errno = configured_count("OPENFAIL_ERRNO");
    errno = fault_errno > 0 ? fault_errno : EACCES;
    return 1;
}

static int needs_mode(int flags)
{
    return (flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE;
}

int open(const char *pathname, int flags, ...)
{
    mode_t mode = 0;
    if (needs_mode(flags))
    {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    resolve_symbols();
    if (open_should_fail(pathname, flags))
        return -1;
    if (!real_open)
    {
        errno = ENOSYS;
        return -1;
    }
    return needs_mode(flags) ? real_open(pathname, flags, mode) : real_open(pathname, flags);
}

int open64(const char *pathname, int flags, ...)
{
    mode_t mode = 0;
    if (needs_mode(flags))
    {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    resolve_symbols();
    if (open_should_fail(pathname, flags))
        return -1;
    if (!real_open64)
    {
        errno = ENOSYS;
        return -1;
    }
    return needs_mode(flags) ? real_open64(pathname, flags, mode) : real_open64(pathname, flags);
}

int fdatasync(int fd)
{
    static int left = -1;
    char want[PATH_MAX];

    resolve_symbols();
    if (!real_fdatasync)
    {
        errno = ENOSYS;
        return -1;
    }
    if (read_target("/tmp/fsyncfail-target", want, sizeof want))
    {
        char link[32], target[PATH_MAX];
        snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
        ssize_t len = readlink(link, target, sizeof target - 1);
        if (len > 0)
        {
            target[len] = '\0';
            if (left < 0)
                left = configured_count("FSYNCFAIL_COUNT");
            if (strcmp(target, want) == 0 && left > 0)
            {
                left--;
                errno = EIO;
                return -1;
            }
        }
    }
    return real_fdatasync(fd);
}
