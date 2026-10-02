/* fsyncfail: narrow filesystem fault injection for pg_logtap's e2e suite.
 *
 * LD_PRELOAD shim, no PostgreSQL headers:
 *
 * - fdatasync fails with EIO only for the fd whose /proc/self/fd link points
 *   at the path in /tmp/fsyncfail-target, for FSYNCFAIL_COUNT calls;
 * - open/open64 fail only an O_CREAT|O_EXCL attempt for the pathname in
 *   /tmp/openfail-target, for OPENFAIL_COUNT calls, with OPENFAIL_ERRNO;
 * - fchmod fails with EPERM for /tmp/chmodfail-target until it is removed;
 * - write on /tmp/writefail-target writes a 17-byte prefix once, then fails
 *   with ENOSPC until the target is removed (regular-file rollback test).
 *   Injected chmod/write faults are recorded in /tmp/fsyncfail.log.
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
#include <sys/stat.h>
#include <unistd.h>

static int (*real_fdatasync)(int);
static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_fchmod)(int, mode_t);
static ssize_t (*real_write)(int, const void *, size_t);

static void resolve_symbols(void)
{
    if (!real_fdatasync)
        real_fdatasync = dlsym(RTLD_NEXT, "fdatasync");
    if (!real_open)
        real_open = dlsym(RTLD_NEXT, "open");
    if (!real_open64)
        real_open64 = dlsym(RTLD_NEXT, "open64");
    if (!real_fchmod)
        real_fchmod = dlsym(RTLD_NEXT, "fchmod");
    if (!real_write)
        real_write = dlsym(RTLD_NEXT, "write");
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

static int fd_matches(int fd, const char *control)
{
    char want[PATH_MAX], link[32], target[PATH_MAX];
    if (!read_target(control, want, sizeof want))
        return 0;
    snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
    ssize_t len = readlink(link, target, sizeof target - 1);
    if (len <= 0)
        return 0;
    target[len] = '\0';
    return strcmp(target, want) == 0;
}

static void note_fault(const char *message)
{
    int fd = real_open("/tmp/fsyncfail.log", O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0)
    {
        if (real_write)
            (void)real_write(fd, message, strlen(message));
        close(fd);
    }
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

    resolve_symbols();
    if (!real_fdatasync)
    {
        errno = ENOSYS;
        return -1;
    }
    if (fd_matches(fd, "/tmp/fsyncfail-target"))
    {
        if (left < 0)
            left = configured_count("FSYNCFAIL_COUNT");
        if (left > 0)
        {
            left--;
            errno = EIO;
            return -1;
        }
    }
    return real_fdatasync(fd);
}

int fchmod(int fd, mode_t mode)
{
    resolve_symbols();
    if (!real_fchmod)
    {
        errno = ENOSYS;
        return -1;
    }
    if (fd_matches(fd, "/tmp/chmodfail-target"))
    {
        note_fault("fchmod EPERM\n");
        errno = EPERM;
        return -1;
    }
    return real_fchmod(fd, mode);
}

ssize_t write(int fd, const void *buf, size_t count)
{
    static int partial_written;
    static int enospc_noted;

    resolve_symbols();
    if (!real_write)
    {
        errno = ENOSYS;
        return -1;
    }
    if (count > 0 && fd_matches(fd, "/tmp/writefail-target"))
    {
        if (!partial_written)
        {
            ssize_t written = real_write(fd, buf, count < 17 ? count : 17);
            if (written > 0)
            {
                partial_written = 1;
                note_fault("write partial\n");
            }
            return written;
        }
        if (!enospc_noted)
        {
            enospc_noted = 1;
            note_fault("write ENOSPC\n");
        }
        errno = ENOSPC;
        return -1;
    }
    return real_write(fd, buf, count);
}
