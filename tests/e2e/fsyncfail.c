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
 *   With /tmp/writefail-offsets, fail only the listed EOF offsets once each,
 *   before writing; later appends pass through (final pending retry test).
 *   Injected chmod/write faults are recorded in /tmp/fsyncfail.log.
 * - fsync on /tmp/dirsyncobserve-target records a directory sync attempt;
 * - pread/pread64 on /tmp/preadobserve-target record frame/payload offsets;
 * - pread EIO on /tmp/preadfail-target follows the finite offset list in
 *   /tmp/preadfail-offsets (repeat an offset to fail it more than once);
 * - /tmp/payloadfail-target + /tmp/payloadfail-offsets arms ENOMEM only on
 *   the allocation immediately after the matching 4/8-byte frame header,
 *   and only if malloc's size equals that header's compressed payload length.
 * - fdatasync on /tmp/datasyncobserve-target records successful data syncs.
 *   These observers pass through unchanged and use the same log.
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
static int (*real_fsync)(int);
static ssize_t (*real_pread)(int, void *, size_t, off_t);
static ssize_t (*real_pread64)(int, void *, size_t, off64_t);
static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_fchmod)(int, mode_t);
static ssize_t (*real_write)(int, const void *, size_t);

static void resolve_symbols(void)
{
    if (!real_fdatasync)
        real_fdatasync = dlsym(RTLD_NEXT, "fdatasync");
    if (!real_fsync)
        real_fsync = dlsym(RTLD_NEXT, "fsync");
    if (!real_pread)
        real_pread = dlsym(RTLD_NEXT, "pread");
    if (!real_pread64)
        real_pread64 = dlsym(RTLD_NEXT, "pread64");
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
    int result = real_fdatasync(fd);
    int saved_errno = errno;
    if (result == 0 && fd_matches(fd, "/tmp/datasyncobserve-target"))
        note_fault("fdatasync OK\n");
    errno = saved_errno;
    return result;
}

int fsync(int fd)
{
    resolve_symbols();
    if (!real_fsync)
    {
        errno = ENOSYS;
        return -1;
    }
    int saved_errno = errno;
    struct stat st;
    if (fd_matches(fd, "/tmp/dirsyncobserve-target") &&
        fstat(fd, &st) == 0 && S_ISDIR(st.st_mode))
        note_fault("fsync directory\n");
    errno = saved_errno;
    return real_fsync(fd);
}

static void observe_pread(int fd, size_t count, long long offset)
{
    int saved_errno = errno;
    if (offset >= 8 && fd_matches(fd, "/tmp/preadobserve-target"))
    {
        char message[96];
        snprintf(message, sizeof message, "pread %lld %zu\n", offset, count);
        note_fault(message);
    }
    errno = saved_errno;
}

struct read_fault {
    char target[PATH_MAX];
    char offsets[512];
    size_t next;
};

/* A changed target/list re-arms; otherwise the finite budget stays spent.
 * Parsing and logging use fixed buffers, never the allocator under test. */
static int scheduled_read_fault(struct read_fault *fault, int fd, long long offset,
                                const char *target_control, const char *offset_control)
{
    char target[PATH_MAX], offsets[512];
    if (!fd_matches(fd, target_control) ||
        !read_target(target_control, target, sizeof target) ||
        !read_target(offset_control, offsets, sizeof offsets))
        return 0;
    if (strcmp(fault->target, target) != 0 || strcmp(fault->offsets, offsets) != 0)
    {
        strcpy(fault->target, target);
        strcpy(fault->offsets, offsets);
        fault->next = 0;
    }
    char *end;
    const char *at = fault->offsets + fault->next;
    long long want = strtoll(at, &end, 10);
    if (end == at || want < 0 || want != offset)
        return 0;
    fault->next = (size_t)(end - fault->offsets);
    return 1;
}

static int pread_should_fail(int fd, size_t count, long long offset)
{
    static struct read_fault fault;
    int saved_errno = errno;
    if (scheduled_read_fault(&fault, fd, offset, "/tmp/preadfail-target", "/tmp/preadfail-offsets"))
    {
        char message[96];
        snprintf(message, sizeof message, "pread EIO %lld %zu\n", offset, count);
        note_fault(message);
        errno = EIO;
        return 1;
    }
    errno = saved_errno;
    return 0;
}

/* LD_PRELOAD reserves this TLS at startup; accessing the malloc guard must
 * not allocate a dynamic TLS block and recurse into malloc. */
static _Thread_local size_t payload_alloc_size __attribute__((tls_model("initial-exec")));
static _Thread_local char payload_alloc_note[96] __attribute__((tls_model("initial-exec")));

static void arm_payload_fault(int fd, const void *buf, size_t count, long long offset, ssize_t result)
{
    static struct read_fault fault;
    int saved_errno = errno;
    payload_alloc_size = 0;
    if (offset >= 8 && (count == 4 || count == 8) && result == (ssize_t)count &&
        scheduled_read_fault(&fault, fd, offset, "/tmp/payloadfail-target", "/tmp/payloadfail-offsets"))
    {
        const unsigned char *header = buf;
        size_t size = (size_t)header[0] | (size_t)header[1] << 8 |
                      (size_t)header[2] << 16 | (size_t)header[3] << 24;
        snprintf(payload_alloc_note, sizeof payload_alloc_note,
                 "malloc ENOMEM header %lld payload %zu\n", offset, size);
        payload_alloc_size = size;
    }
    errno = saved_errno;
}

/* The test images use glibc. Its direct entry point avoids dlsym/malloc
 * bootstrap recursion. No global Nth-allocation fault and no logging while
 * armed: even a non-matching next allocation disarms this header's fault. */
extern void *__libc_malloc(size_t);
void *malloc(size_t size)
{
    size_t armed = payload_alloc_size;
    payload_alloc_size = 0;
    if (armed != 0 && size == armed)
    {
        note_fault(payload_alloc_note);
        errno = ENOMEM;
        return NULL;
    }
    return __libc_malloc(size);
}

ssize_t pread(int fd, void *buf, size_t count, off_t offset)
{
    resolve_symbols();
    if (!real_pread)
    {
        errno = ENOSYS;
        return -1;
    }
    observe_pread(fd, count, (long long)offset);
    if (pread_should_fail(fd, count, (long long)offset))
        return -1;
    ssize_t result = real_pread(fd, buf, count, offset);
    arm_payload_fault(fd, buf, count, (long long)offset, result);
    return result;
}

ssize_t pread64(int fd, void *buf, size_t count, off64_t offset)
{
    resolve_symbols();
    if (!real_pread64)
    {
        errno = ENOSYS;
        return -1;
    }
    observe_pread(fd, count, (long long)offset);
    if (pread_should_fail(fd, count, (long long)offset))
        return -1;
    ssize_t result = real_pread64(fd, buf, count, offset);
    arm_payload_fault(fd, buf, count, (long long)offset, result);
    return result;
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
        static struct read_fault fault;
        char offsets[512];
        if (read_target("/tmp/writefail-offsets", offsets, sizeof offsets))
        {
            if (scheduled_read_fault(&fault, fd, (long long)lseek(fd, 0, SEEK_END),
                                     "/tmp/writefail-target", "/tmp/writefail-offsets"))
            {
                note_fault("write ENOSPC once\n");
                errno = ENOSPC;
                return -1;
            }
            return real_write(fd, buf, count);
        }
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
