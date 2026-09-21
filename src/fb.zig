//! Fallback file: compressed durable on-disk queue, replayed on recovery.
//! When an export send fails (any transport — http(s), tcp(s), file) and
//! export_fallback_file is set, batches are appended here and drained to the
//! receiver once it answers — the RAM backlog then only covers what parking
//! cannot take.
//! Internal framing, one batch per member: v1 [magic][u32 len][gzip],
//! v2 [magic][u32 len][u32 event count][gzip].
//! A crash mid-append leaves a torn tail member — detected by the short read,
//! truncated, appends resume at the member boundary. A crash mid-replay loses
//! only the in-memory offset: replay restarts from byte 0, so the receiver may
//! see duplicates — dedup by (host, seq), the http at-least-once contract.
//! Obeys the worker's abort disciplines (writeAll/compactAborted below).
const std = @import("std");

const pg = @import("pgzx").c;
const elog = @import("pgzx").elog;
const worker = @import("worker.zig");
const jsonl = @import("jsonl.zig");
const capture = @import("capture.zig");
const gzip = @import("gzip.zig");

/// libc file wrappers (see worker.zig's `c` for the socket half).
const c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(conn_fd: c_int) c_int;
    extern "c" fn fdatasync(fd: c_int) c_int;
    extern "c" fn fsync(fd: c_int) c_int;
    extern "c" fn fchmod(fd: c_int, mode: c_uint) c_int;
    extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64; // SEEK_END=2 → file size
    extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
    extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
    extern "c" fn fstat(fd: c_int, buf: *worker.FileStat) c_int;
    extern "c" fn stat(path: [*:0]const u8, buf: *worker.FileStat) c_int;
};

/// Events per request body / queue member. 1024 measured 40% SLOWER under a
/// debug storm: the transient body/member buffers cross glibc's mmap threshold
/// and every flush cycle munmaps ~1MB — TLB shootdown IPIs tax every core,
/// postgres backends included. 256 keeps allocations on the malloc heap and 4x
/// more fdatasyncs cost less than that.
pub const chunk_max = 256;
/// Byte target per request body / queue member (buildBody admits the event
/// that crosses it): at message_max=1MB a full 256-event chunk would be ~67MB
/// — past proxy body limits and the flush cycle's time budget. buildBody stops
/// at whichever bound, events or bytes, comes first.
pub const body_cap = 4 << 20;

/// Framing sanity bound, shared by the compressed-size check (nextMember,
/// compact) and the inflated-output check below it: a member this build (or
/// 0.3.x, ≤ ~371KB) writes can never exceed body_cap + one serialized event,
/// and gzip does not inflate its input beyond that +64K of slack. The
/// serialized-event term is jsonl's worst case, not the raw message width:
/// JSON escaping turns a control byte into six (`\u00XX`), so at
/// message_max = 1 MiB one event serializes to ~6 MiB — a raw-width bound
/// here let the queue write members its own replay buffer could not hold.
const member_max = body_cap + jsonl.worst_serialized_entry + 65536;

const fb_magic_v1 = "PGLTFB01";
const fb_magic_v2 = "PGLTFB02";
const fb_magic_len = 8;

const FrameFormat = enum {
    legacy,
    counted,

    fn magic(format: FrameFormat) []const u8 {
        return switch (format) {
            .legacy => fb_magic_v1,
            .counted => fb_magic_v2,
        };
    }

    fn headerLen(format: FrameFormat) u64 {
        return switch (format) {
            .legacy => 4,
            .counted => 8,
        };
    }
};

/// Linux O_NOFOLLOW (0o400000) as a raw flag value: std.os.linux.O is a
/// packed bool struct, unusable with the extern open. Every open of the
/// queue path (and the compaction temp) passes it — anything able to write
/// the data directory must not aim the queue at another file.
const fb_no_follow: c_int = 0o400000;

/// Consumed prefix of the queue (magic + members), worker-local. 0 also means
/// "magic not verified yet". Read and advanced by the worker's drain loop.
pub var offset: u64 = 0;
/// Foreign or corrupt framing — never append to or replay such a file; the
/// RAM backlog takes over until the GUC is repointed or the server restarts.
pub var broken = false;
/// Cumulative failed fdatasync calls on the fallback queue — the counter
/// behind the shmem gauge (the WARNING below is edge-triggered on purpose).
/// Cumulative means historical, not a current-state claim: a non-zero value
/// does not say the queue NOW holds undurable data — the next successful
/// sync (or a landing compaction, fdatasynced before its rename) makes it
/// durable while the counter stays. Alert on growth, not level.
pub var sync_failures: u64 = 0;
/// Warned-once latch for a failing fdatasync: a dying disk fails every cycle
/// and a per-cycle WARNING would bury the server log, but one silent failure
/// streak means queued events nobody knows are not durable. Cleared by the
/// first success, so a flapping disk is heard each time it starts failing.
var fb_sync_warned = false;
/// Events in unreadable v2 members — folded into `lost` by the flush cycle
/// that read them. A corrupt v1 member has no trustworthy count and breaks the
/// queue instead of inventing one.
pub var lost: u64 = 0;
/// Same skipped-v2 events, removed from the physical queue without replay.
/// Kept separate from `compacted`, whose public contract is cap trimming.
pub var discarded: u64 = 0;

var queue_dev: i64 = 0;
var queue_ino: u64 = 0;
var queue_identity_valid = false;

var fb_path_buf: [4096]u8 = undefined;
var fb_path_len: usize = 0;

// --- GUCs -----------------------------------------------------------------------

var guc_file: [*c]u8 = null;
var guc_max_mb: c_int = 512;

/// The fallback GUC pair, called from worker.init (one registration site).
pub fn defineGucs() void {
    pg.DefineCustomStringVariable("pg_logtap.export_fallback_file", "Path; failed export batches (any transport — http(s), tcp(s), file) are appended here as a compressed durable queue (fdatasynced once per flush cycle) and replayed automatically once the receiver answers. Relative resolves against the data directory. Empty = off. The resolved path must leave room for the .compact rewrite suffix (9 bytes under the 4096-byte path limit) or the value is rejected — the cap cannot work without it; a path equal to a file:// pg_logtap.export_url is rejected too (the NDJSON sink and the queue framing cannot share a file). See docs/delivery.md.", null, &guc_file, "", pg.PGC_SIGHUP, 0, checkFile, null, null);
    pg.DefineCustomIntVariable("pg_logtap.fallback_max_mb", "Size cap for the fallback queue file. When an append pushes the file past the cap it is compacted to the newest half (atomic rewrite), and the undelivered events dropped by that count into events_lost — the EventsLost alert is the signal that the outage outlasted the queue. 0 = unlimited (pre-0.3.0 behavior: an unattended outage fills the disk). A cap smaller than one member (~a hundred KB compressed) can only bound the file at member granularity.", null, &guc_max_mb, 512, 0, 1_048_576, pg.PGC_SIGHUP, 0, null, null, null);
}

/// Current pg_logtap.export_fallback_file value ("" while unset) — the
/// export_url SET check reads it for the aliasing rule.
pub fn fileGucRaw() []const u8 {
    if (guc_file == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(guc_file)));
}

/// The queue's path buffers are 4096 bytes and compaction rewrites through
/// "<path>.compact": a value that fits the queue but leaves no room for the
/// suffix parks events fine, yet the cap can never fire — compact cannot
/// even name its temp. Reject the value at ALTER SYSTEM (a session SET is
/// refused before any value check — PGC_SIGHUP); boot runs the default ''
/// through here too, and empty is always accepted. Relative paths measure
/// against the data
/// directory, exactly as path() resolves them. A path aliasing a file://
/// export_url is rejected the same way (rule on worker.fileUrlAliasesFallback).
fn checkFile(newval: [*c][*c]u8, extra: [*c]?*anyopaque, source: c_uint) callconv(.c) bool {
    _ = extra;
    _ = source;
    const ptr = newval orelse return true;
    const raw_c = ptr.* orelse return true;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(raw_c)));
    if (raw.len == 0) return true;
    if (worker.fileUrlAliasesFallback(worker.gucExportUrl(), raw)) return false;
    var resolved: []const u8 = raw;
    var tmp: [4096]u8 = undefined;
    if (raw[0] != '/') {
        const dd_c = pg.DataDir orelse return true;
        const dd = std.mem.span(@as([*:0]const u8, @ptrCast(dd_c)));
        resolved = std.fmt.bufPrint(&tmp, "{s}/{s}", .{ dd, raw }) catch return false;
    }
    // +8 ".compact" +1 NUL must fit the same 4096-byte path buffers
    return resolved.len + 9 <= 4096;
}

/// Resolve the GUC (relative → data directory, the log_directory convention;
/// the queue belongs with the data). Repointing the GUC orphans the old queue
/// (its events stay on disk for a manual drain) and resets consumer state.
/// "<fallback>.compact" — compact's rewrite target. A crash between its
/// creation and the rename leaves it behind (up to cap/2 of litter nothing
/// ever reads); boot() unlinks it at start.
fn compactPath(tmp_buf: *[4096]u8) ?[*:0]const u8 {
    if (fb_path_len + 8 + 1 > tmp_buf.len) return null;
    @memcpy(tmp_buf[0..fb_path_len], fb_path_buf[0..fb_path_len]);
    @memcpy(tmp_buf[fb_path_len..][0..8], ".compact");
    tmp_buf[fb_path_len + 8] = 0;
    return @ptrCast(tmp_buf);
}

fn path() ?[]const u8 {
    if (guc_file == null) return null;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(guc_file)));
    if (raw.len == 0 or raw.len + 1 > fb_path_buf.len) return null;
    var tmp: [4096]u8 = undefined;
    const full = blk: {
        if (raw[0] == '/') break :blk raw;
        if (pg.DataDir == null) return null;
        const dd = std.mem.span(@as([*:0]const u8, @ptrCast(pg.DataDir)));
        break :blk std.fmt.bufPrint(&tmp, "{s}/{s}", .{ dd, raw }) catch return null;
    };
    if (full.len != fb_path_len or !std.mem.eql(u8, fb_path_buf[0..fb_path_len], full)) {
        fb_path_len = full.len;
        @memcpy(fb_path_buf[0..full.len], full);
        fb_path_buf[full.len] = 0;
        offset = 0;
        queue_identity_valid = false;
        broken = false;
    }
    return fb_path_buf[0..fb_path_len];
}

/// Worker start: remove a crashed compaction's litter, restore the cursor a
/// previous worker published in shmem, then credit any uncounted suffix.
pub fn boot(alloc: std.mem.Allocator) void {
    if (path() == null) return;
    var tmp_buf: [4096]u8 = undefined;
    if (compactPath(&tmp_buf)) |p| _ = c.unlink(p);
    if (fbOpen()) |file_fd| {
        defer _ = c.close(file_fd);
        if (fbSize(file_fd)) |size| {
            if (queue_identity_valid)
                offset = capture.fallbackOffset(queue_dev, queue_ino, size);
        }
    }
    creditBacklog(alloc);
}

/// True when the given inode is the file the queue path names (through
/// symlinks — the file:// sink follows them when it opens, so that shared
/// inode is exactly the alias worker.sendFile catches with this).
pub fn aliasesQueueInode(st: worker.FileStat) bool {
    if (path() == null) return false;
    var qst: worker.FileStat = undefined;
    if (c.stat(@ptrCast(fb_path_buf[0..fb_path_len :0].ptr), &qst) != 0) return false;
    return st.dev == qst.dev and st.ino == qst.ino;
}

/// Warned-once latch for a pre-existing queue whose permissions could not
/// be pulled down to 0600 — the compressed log stream stays readable by
/// whoever the operator's mode left in. Same edge-triggered shape as
/// dir_sync_warned: a successful tighten re-arms it.
var perm_warned = false;

fn fbOpen() ?c_int {
    if (path() == null) return null;
    // O_RDWR|O_CREAT|O_APPEND (Linux: 2|64|1024) — reads go through pread,
    // immune to the append position. 0600: not world-readable (C2).
    // Create via O_EXCL|O_CREAT (Linux: 128|64) first: its success is the
    // only reliable "the file just came into existence" signal — the moment
    // to fsync the directory, so the creation itself (not just the data,
    // which fdatasync covers) survives a power loss. O_EXCL|O_CREAT also
    // never follows a symlink (POSIX), so the create branch needs no
    // O_NOFOLLOW of its own.
    var file_fd = c.open(@ptrCast(fb_path_buf[0..fb_path_len :0].ptr), 2 | 64 | 1024 | 128, @as(c_uint, 0o600));
    if (file_fd >= 0) {
        fsyncDirOf(fb_path_buf[0..fb_path_len]);
    } else if (std.c._errno().* == @intFromEnum(std.c.E.EXIST)) { // the usual case
        // fb_no_follow: the queue lives in the data directory, and anything
        // able to write there must not aim the queue at another file — the
        // rule compact already enforces for its temp. ELOOP (the path IS
        // a symlink) just fails the open: the caller parks in RAM instead.
        file_fd = c.open(@ptrCast(fb_path_buf[0..fb_path_len :0].ptr), 2 | 64 | 1024 | fb_no_follow, @as(c_uint, 0o600));
        // The mode argument only covers creation; a pre-existing queue may
        // sit wider (operator-made 0644). Best-effort tighten — see sendFile;
        // a tighten that fails leaves the queue readable and says so, once
        // per streak.
        if (file_fd >= 0) {
            if (c.fchmod(file_fd, @as(c_uint, 0o600)) == 0) {
                perm_warned = false;
            } else if (!perm_warned) {
                perm_warned = true;
                elog.Warning(@src(), "pg_logtap fallback queue permissions could not be tightened to 0600 (errno={d}): local users may read the compressed log stream in {s}", .{ std.c._errno().*, path() orelse "" });
            }
        }
    }
    // Any other errno (EACCES, EROFS, ENOTDIR, …) fails as is — a retrying
    // open would only mask the real reason. An unopenable queue is as
    // unusable as a foreign one: mark it broken so the fallback_broken gauge
    // says so, and say it once — broken stops the re-opens; repointing
    // the GUC or a restart re-checks, the same recovery as a foreign file.
    if (file_fd < 0) {
        broken = true;
        capture.noteWarn(.fallback_open);
        elog.Warning(@src(), "pg_logtap fallback queue cannot be opened (errno={d}), fallback disabled: {s}", .{ std.c._errno().*, path() orelse "" });
        return null;
    }
    // A hardlink at the queue path (O_NOFOLLOW passes those) can name the
    // same inode the file:// sink writes — the queue's side of the inode
    // alias check; same latch and warning shape as the unopenable queue.
    if (worker.queueFdAliasesFileUrl(file_fd)) {
        _ = c.close(file_fd);
        broken = true;
        capture.noteWarn(.fallback_open);
        elog.Warning(@src(), "pg_logtap fallback queue and the file:// export_url name one file (symlink/hardlink alias): fallback disabled: {s}", .{path() orelse ""});
        return null;
    }
    var file_stat: worker.FileStat = undefined;
    if (c.fstat(file_fd, &file_stat) != 0) {
        _ = c.close(file_fd);
        broken = true;
        capture.noteWarn(.fallback_open);
        elog.Warning(@src(), "pg_logtap fallback queue identity could not be read (errno={d}), fallback disabled: {s}", .{ std.c._errno().*, path() orelse "" });
        return null;
    }
    if (queue_identity_valid and (queue_dev != file_stat.dev or queue_ino != file_stat.ino)) offset = 0;
    queue_dev = file_stat.dev;
    queue_ino = file_stat.ino;
    queue_identity_valid = true;
    return file_fd;
}

/// fsync the parent of a path: makes a fresh directory entry durable. Best
/// effort — a failure costs durability of the CREATION only: the queue's data
/// is still fdatasynced, and until the kernel writes the directory back an
/// OS crash may drop the queue's name (the events degrade to what a RAM-only
/// worker would have lost, never worse). A failure is warned once — a
/// directory fsync that fails is a dying-disk signal, the same class as
/// fb_sync_failures — but no broken-mark: the queue still beats RAM.
var dir_sync_warned = false;

fn fsyncDirOf(path_str: []const u8) void {
    const dir_end = std.mem.findScalarLast(u8, path_str, '/') orelse return;
    var dir_buf: [4096]u8 = undefined;
    const dir = if (dir_end == 0) "/" else path_str[0..dir_end]; // "/x" → "/"
    if (dir.len >= dir_buf.len) return;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_buf[dir.len] = 0;
    const dir_fd = c.open(@ptrCast(&dir_buf), 0, @as(c_uint, 0)); // O_RDONLY
    const synced = dir_fd >= 0 and blk: {
        defer _ = c.close(dir_fd);
        break :blk c.fsync(dir_fd) == 0;
    };
    if (synced) {
        // Edge-triggered like every warn latch here: a clean creation
        // re-arms it, so an independent later failure warns again.
        dir_sync_warned = false;
    } else if (!dir_sync_warned) {
        dir_sync_warned = true;
        elog.Warning(@src(), "pg_logtap fallback queue directory fsync failed: the creation is not durable until the kernel writes the directory back (an OS crash may drop the queue's name): {s}", .{path_str});
    }
}

fn fbSize(fd: c_int) ?u64 {
    const end = c.lseek(fd, 0, 2); // SEEK_END
    return if (end >= 0) @intCast(end) else null;
}

const ReadResult = enum { full, eof, err };

/// Exact fill: loops until the buffer is complete. A single pread can return
/// a partial count — a signal after some bytes moved (this worker's SIGUSR1
/// latch pokes are dense exactly while events flow), which is not EOF;
/// callers once read that as a torn tail and truncated members the queue
/// had fully written.
fn fbPread(fd: c_int, buf: []u8, offset_v: u64) ReadResult {
    var got: usize = 0;
    while (got < buf.len) {
        const nread = c.pread(fd, buf.ptr + got, buf.len - got, @intCast(offset_v + got));
        if (nread == 0) return .eof;
        if (nread > 0) {
            got += @intCast(nread);
        } else if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) {
            return .err;
        }
    }
    return .full;
}

fn readFormat(file_fd: c_int) ?FrameFormat {
    var magic: [fb_magic_len]u8 = undefined;
    if (fbPread(file_fd, &magic, 0) != .full) return null;
    if (std.mem.eql(u8, &magic, fb_magic_v1)) return .legacy;
    if (std.mem.eql(u8, &magic, fb_magic_v2)) return .counted;
    return null;
}

const FrameHeader = struct {
    compressed_len: u32,
    event_count: ?u32,
    len: u64,
};

const HeaderResult = union(enum) {
    full: FrameHeader,
    torn,
    err,
    corrupt,
};

fn readFrameHeader(file_fd: c_int, format: FrameFormat, at: u64, size: u64) HeaderResult {
    const header_len = format.headerLen();
    if (size -| at < header_len) return .torn;
    var buf: [8]u8 = undefined;
    switch (fbPread(file_fd, buf[0..@intCast(header_len)], at)) {
        .full => {},
        .eof => return .torn,
        .err => return .err,
    }
    const compressed_len = std.mem.readInt(u32, buf[0..4], .little);
    if (compressed_len == 0 or compressed_len > member_max) return .corrupt;
    const event_count: ?u32 = if (format == .counted) std.mem.readInt(u32, buf[4..8], .little) else null;
    return .{ .full = .{ .compressed_len = compressed_len, .event_count = event_count, .len = header_len } };
}

fn storedEventCount(event_count: ?u32) ?u32 {
    const count = event_count orelse return null;
    return if (count > 0 and count <= chunk_max) count else null;
}

/// A short frame header/body after a valid magic is ours and is safe to cut.
/// Sync the repair so an OS crash cannot resurrect the torn bytes behind a
/// later append.
fn repairTail(file_fd: c_int, at: u64) bool {
    if (c.ftruncate(file_fd, @intCast(at)) == 0) {
        _ = fbDatasync(file_fd, false);
        return true;
    }
    broken = true;
    elog.Warning(@src(), "pg_logtap fallback torn tail at offset {d} could not be truncated (errno={d}), replay disabled: {s}", .{ at, std.c._errno().*, path() orelse "" });
    return false;
}

/// True while the fallback file holds undelivered events — flushAll then
/// routes everything through it to keep global order.
pub fn queued() bool {
    // path() FIRST: while broken, short-circuiting on it would never
    // re-resolve the GUC, and the reset inside path() (path-string change)
    // is the one way a broken queue recovers without a restart.
    if (path() == null) return false;
    if (broken) return false;
    const file_fd = fbOpen() orelse return false;
    defer _ = c.close(file_fd);
    const size = fbSize(file_fd) orelse return false;
    return if (offset == 0) size > fb_magic_len else size > offset;
}

pub fn cursor() ?capture.FallbackCursor {
    if (!queue_identity_valid) return null;
    return .{ .dev = queue_dev, .ino = queue_ino, .offset = offset };
}

/// Outcome of appending one batch. `failed` = nothing of it is in the file
/// (a partial write is rolled back; the events stay in the caller's RAM
/// backlog and the append may be retried). `appended` = in the file and
/// fdatasynced. `not_durable` = in the file, fdatasync failed — the member
/// STAYS (dropping it would be another write that can also fail) and must
/// never be appended again: the caller drops the batch from RAM on anything
/// but `failed`. Page cache survives postmaster death; an OS crash loses an
/// unsynced tail (fbDatasync warns once).
pub const Outcome = enum { failed, appended, not_durable };

/// Append one batch as a framed gzip member. `sync` fdatasyncs this member;
/// false defers to one fsync() per flush cycle — per-member syncs on a
/// WAL-shared disk stall the worker past the ring's drain window (measured:
/// 5k dropped in a 16-client storm). Success = the events left pg_logtap
/// (page cache survives postmaster death; an OS crash loses the unsynced tail).
pub fn append(alloc: std.mem.Allocator, body: []const u8, events: usize, sync: bool) Outcome {
    if (broken or events == 0 or events > chunk_max) return .failed;
    const file_fd = fbOpen() orelse return .failed;
    defer _ = c.close(file_fd);
    const size = fbSize(file_fd) orelse return .failed;
    const format: FrameFormat = if (size == 0) .counted else readFormat(file_fd) orelse {
        broken = true;
        elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, fallback disabled: {s}", .{path() orelse ""});
        return .failed;
    };
    if (size == 0) {
        if (!worker.writeAll(file_fd, format.magic(), false, null)) {
            // Roll the fresh file back to empty. A short write can stop
            // mid-magic, and a 1..7-byte file is "foreign content" to the
            // next open — fallback disabled over a torn header. The file
            // holds no members yet, so the rollback costs nothing; the next
            // append writes the magic whole again.
            if (c.ftruncate(file_fd, 0) == 0) {
                // Sync the rollback: an unsynced truncate lets an OS crash
                // resurrect the torn header — the next open then reads
                // foreign content and disables the queue for nothing. A
                // failed sync only re-opens that window (counted like any
                // other durability point); the repair re-runs at the next
                // open's foreign-content check.
                _ = fbDatasync(file_fd, false);
            } else {
                broken = true;
                elog.Warning(@src(), "pg_logtap fallback append could not roll back a partial queue header (errno={d}), replay disabled: {s}", .{ std.c._errno().*, path() orelse "" });
            }
            return .failed;
        }
    }
    const comp = gzip.compress(alloc, body) catch return .failed; // compression failed → RAM backlog retries
    defer alloc.free(comp);
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(comp.len), .little);
    if (format == .counted) std.mem.writeInt(u32, header[4..8], @intCast(events), .little);
    const header_len: usize = @intCast(format.headerLen());
    if (!worker.writeAll(file_fd, header[0..header_len], false, null) or !worker.writeAll(file_fd, comp, false, null)) {
        // Roll the partial member back. A torn header/body left in place
        // shifts the framing of every later append — the next member lands
        // mid-garbage instead of just this batch retrying from RAM.
        if (c.ftruncate(file_fd, @intCast(size)) == 0) {
            // Sync the rollback, same window as the magic rollback above:
            // an unsynced truncate can resurrect the torn member after an OS
            // crash, and an append would then land behind it.
            _ = fbDatasync(file_fd, false);
        } else {
            broken = true;
            elog.Warning(@src(), "pg_logtap fallback append could not roll back a partial member (errno={d}), replay disabled: {s}", .{ std.c._errno().*, path() orelse "" });
        }
        return .failed;
    }
    var durable = true;
    if (sync and !fbDatasync(file_fd, false)) durable = false;
    // Cap enforcement after the append: the member is on disk either way
    // (durability aside), and the compaction rewrite must never race a
    // lost one. A failed fdatasync above does not skip it either:
    // compaction is tmp+rename where every failure leaves the original
    // file untouched, so it can only enforce the cap — never worsen the
    // not-durable state or drop a member the failed sync left in place.
    compact(alloc, file_fd, (if (size == 0) fb_magic_len else size) + format.headerLen() + comp.len, format);
    return if (durable) .appended else .not_durable;
}

/// fdatasync with an edge-triggered WARNING: false = the pages are written
/// but not durable (an OS crash loses them; postmaster death still does not).
/// `compaction` marks the rewrite temp's sync point — a landed compaction is
/// one of the queue's documented durability points, so its failure belongs in
/// fb_sync_failures too; only the message differs (the rewrite is abandoned
/// and the original queue stands).
fn fbDatasync(file_fd: c_int, compaction: bool) bool {
    if (c.fdatasync(file_fd) == 0) {
        fb_sync_warned = false;
        return true;
    }
    if (!fb_sync_warned) {
        fb_sync_warned = true;
        if (compaction) {
            elog.Warning(@src(), "pg_logtap fallback compaction fdatasync failed (errno={d}): rewrite abandoned, the original queue stands — the disk cannot make the queue durable", .{std.c._errno().*});
        } else {
            elog.Warning(@src(), "pg_logtap fallback fdatasync failed (errno={d}): the queue's latest change is written but not durable", .{std.c._errno().*});
        }
    }
    sync_failures += 1;
    return false;
}

/// Durability point for a cycle's deferred appends. Liveness ceiling, part of
/// the contract: a sync that failed (or a deferred one never followed by a
/// later append) is NOT retried on a timer — the next append, truncate or
/// landing compaction provides the next sync point; until one does, the
/// member sits in the documented OS-crash window that fb_sync_failures names.
pub fn fsync() void {
    if (broken or path() == null) return;
    const file_fd = fbOpen() orelse return;
    defer _ = c.close(file_fd);
    _ = fbDatasync(file_fd, false);
}

/// One queued batch: decompressed NDJSON, event count, the byte size at read
/// time, and how far offset advances past it. body borrows the reused inflate
/// buffer — valid until the next nextMember.
pub const Member = struct { body: []const u8, events: u32, size: u64, advance: u64 };

pub const Skipped = struct { events: u32, final: bool };

pub const Next = union(enum) {
    none,
    member: Member,
    skipped: Skipped,
};

// Reused inflate state: the 32K window and the ≤ member_max decompressed
// member sit above glibc's mmap threshold — same story as the gzip pool.
// The body buffer is FIXED at member_max, not an allocating writer: the
// framing check bounds only the COMPRESSED length, and a small member can
// inflate without limit (a decompression bomb) — the buffer itself is the
// ceiling, and one that crosses it fails the write and is skipped below
// exactly like a gzip-damaged one. ~5MB, allocated once on first replay.
var fb_dec: ?struct { window: []u8, body_buf: []u8 } = null;

fn unreadableMember(format: FrameFormat, at: u64, size: u64, advance: u64, event_count: ?u32) Next {
    if (format == .legacy) {
        // v1 stores no count outside gzip. Skipping it as one event makes both
        // events_lost and queue_backlog lie; stop and require operator action.
        broken = true;
        elog.Warning(@src(), "pg_logtap legacy fallback member at offset {d} is unreadable and its event count is unknown, replay disabled: {s}", .{ at, path() orelse "" });
        return .none;
    }
    const events = storedEventCount(event_count) orelse {
        broken = true;
        elog.Warning(@src(), "pg_logtap fallback member at offset {d} is unreadable and its stored event_count={d} is outside 1..{d}, replay disabled: {s}", .{ at, event_count.?, chunk_max, path() orelse "" });
        return .none;
    };
    offset += advance;
    lost += events;
    discarded += events;
    capture.noteWarn(.fallback_skipped);
    elog.Log(@src(), "pg_logtap fallback member at offset {d} unreadable (gzip damaged or inflates past the {d}-byte bound), {d} events skipped", .{ at, member_max, events });
    return .{ .skipped = .{ .events = events, .final = offset >= size } };
}

/// Read the member at offset. An explicit skipped result lets the drain remove
/// a final corrupt v2 frame without making the boot-time credit scan delete
/// valid members it has only inspected. Torn tails are repaired at the current
/// member boundary so later appends cannot land behind stale framing bytes.
pub fn nextMember(alloc: std.mem.Allocator) Next {
    if (broken) return .none;
    const file_fd = fbOpen() orelse return .none;
    defer _ = c.close(file_fd);
    const size = fbSize(file_fd) orelse return .none;
    if (offset == 0) {
        if (size <= fb_magic_len) return .none;
        if (readFormat(file_fd) == null) {
            broken = true;
            elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, replay disabled: {s}", .{path() orelse ""});
            return .none;
        }
        offset = fb_magic_len;
    }
    if (offset >= size) return .none;
    const format = readFormat(file_fd) orelse {
        broken = true;
        elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, replay disabled: {s}", .{path() orelse ""});
        return .none;
    };
    const header = switch (readFrameHeader(file_fd, format, offset, size)) {
        .full => |h| h,
        .torn => {
            _ = repairTail(file_fd, offset);
            return .none;
        },
        .err => return .none,
        .corrupt => {
            broken = true;
            elog.Log(@src(), "pg_logtap fallback framing corrupt at offset {d}, replay disabled", .{offset});
            return .none;
        },
    };
    const advance = header.len + @as(u64, header.compressed_len);
    if (size -| offset < advance) {
        _ = repairTail(file_fd, offset);
        return .none;
    }
    const comp = alloc.alloc(u8, header.compressed_len) catch return .none;
    const body_read = fbPread(file_fd, comp, offset + header.len);
    if (body_read == .err) {
        // An I/O error says nothing about the framing — leave the member in
        // place and retry next cycle; truncating here would destroy fully
        // valid members on a transient disk fault.
        alloc.free(comp);
        return .none;
    }
    if (body_read == .eof) {
        alloc.free(comp);
        _ = repairTail(file_fd, offset);
        return .none;
    }
    defer alloc.free(comp);
    if (fb_dec == null) fb_dec = .{
        .window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return .none,
        .body_buf = alloc.alloc(u8, member_max) catch return .none,
    };
    const dec_state = &fb_dec.?;
    var src: std.Io.Reader = .fixed(comp);
    var dec = std.compress.flate.Decompress.init(&src, .gzip, dec_state.window);
    var body: std.Io.Writer = std.Io.Writer.fixed(dec_state.body_buf);
    _ = dec.reader.streamRemaining(&body) catch return unreadableMember(format, offset, size, advance, header.event_count);
    const events: u32 = @intCast(std.mem.countScalar(u8, body.buffered(), '\n'));
    if (events == 0)
        return unreadableMember(format, offset, size, advance, header.event_count);
    if (format == .counted and events != header.event_count.?)
        elog.Warning(@src(), "pg_logtap fallback member at offset {d} stores event_count={d} but contains {d} readable NDJSON lines; replaying and accounting the readable payload", .{ offset, header.event_count.?, events });
    // member_max itself: buildBody admits the event that crosses body_cap,
    // so a member this build writes is ≤ body_cap + one serialized event
    // (jsonl.worst_serialized_entry — 6× the raw widths, see its comment);
    // the +64K on top also admits members from 0.3.x binaries read before an
    // upgrade drains the queue. A byte bound, not a ratio: a wide repetitive
    // body legitimately inflates past 64:1 and a ratio bound would lose it.
    return .{ .member = .{ .body = body.buffered(), .events = events, .size = size, .advance = advance } };
}

/// Queue fully delivered: zero it (the next append re-creates the magic) and
/// return to direct sends. Opened through fbOpen — one open discipline,
/// O_NOFOLLOW included — and the magic is re-verified before the destructive
/// call: a rename swapping some other file into the path between the drain's
/// read and here must not have that file zeroed; without our magic it is not
/// ours, leave it. The fdatasync makes the removal a durability point:
/// ftruncate only edits the inode, and without a sync a crash right after a
/// full drain can resurrect members the receiver already has — the documented
/// at-least-once duplicates, but the window stays open exactly when the
/// outage ends and nothing parks again to sync it shut. Best effort one way:
/// a failed sync (counted in sync_failures) only re-opens that duplicate
/// window; the events are already delivered.
pub fn truncate() void {
    if (broken) return;
    const file_fd = fbOpen() orelse return;
    defer _ = c.close(file_fd);
    if (readFormat(file_fd) == null) return;
    // The next queue generation reuses this inode. Fail closed to replay from
    // byte zero if the worker exits before publishing that generation's cursor.
    capture.invalidateFallbackCursor();
    if (c.ftruncate(file_fd, 0) == 0) {
        offset = 0;
        _ = fbDatasync(file_fd, false);
    }
}

/// Credit queue events that are not represented by the current derived
/// backlog. A postmaster restart has no saved cursor or counters, so the full
/// file is credited. A soft worker restart resumes at the shmem cursor and
/// normally credits zero; if the old worker died after an append but before
/// publishing its cycle counters, only that uncounted suffix is credited.
fn creditBacklog(alloc: std.mem.Allocator) void {
    const saved_offset = offset;
    const saved_lost = lost;
    const saved_discarded = discarded;
    var events: u64 = 0;
    while (true) switch (nextMember(alloc)) {
        .none => break,
        .member => |member| {
            events += member.events;
            offset += member.advance;
        },
        // Count a corrupt v2 frame in queued for this fresh shmem epoch too;
        // the real drain later folds its exact count into lost + discarded.
        .skipped => |skip| events += skip.events,
    };
    offset = saved_offset;
    lost = saved_lost;
    discarded = saved_discarded;
    const snap = capture.snapshot();
    const backlog = snap.queued -| snap.replayed -| snap.compacted -| snap.queue_discarded;
    const due = events -| backlog;
    if (due > 0) capture.bumpExport(0, due, 0, 0, 0, 0, 0);
}

fn countFrameEvents(alloc: std.mem.Allocator, file_fd: c_int, format: FrameFormat, off: u64, header: FrameHeader) ?u64 {
    const stored: ?u64 = if (storedEventCount(header.event_count)) |events| events else null;
    const comp = alloc.alloc(u8, header.compressed_len) catch return stored;
    defer alloc.free(comp);
    if (fbPread(file_fd, comp, off + header.len) != .full) return stored;
    if (fb_dec == null) fb_dec = .{
        .window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return stored,
        .body_buf = alloc.alloc(u8, member_max) catch return stored,
    };
    const dec_state = &fb_dec.?;
    var src_reader: std.Io.Reader = .fixed(comp);
    var dec = std.compress.flate.Decompress.init(&src_reader, .gzip, dec_state.window);
    var body: std.Io.Writer = std.Io.Writer.fixed(dec_state.body_buf);
    _ = dec.reader.streamRemaining(&body) catch return stored;
    const events: u64 = std.mem.countScalar(u8, body.buffered(), '\n');
    if (events == 0) return stored;
    if (format == .counted and events != header.event_count.?)
        elog.Warning(@src(), "pg_logtap fallback member at offset {d} stores event_count={d} but contains {d} readable NDJSON lines; compaction accounts the readable payload", .{ off, header.event_count.?, events });
    return events;
}

/// Enforce fallback_max_mb (0 = unlimited): once the file outgrew the cap,
/// rewrite it keeping only the newest half of the cap — an unattended outage
/// then turns over cap/2 bytes per compaction instead of filling the disk.
/// Members below offset were already delivered (dropping them is free);
/// dropped undelivered members count into compacted AND lost: compacted
/// removes them from queue_backlog, lost records that they never arrived.
/// Atomic (tmp + rename +
/// directory fsync); any failure leaves the file as it was — the next append
/// past the cap retries. Ceiling: a cap smaller than one member bounds the
/// file only at member granularity. Runs under the cycle's abort budget:
/// the member-count walk and the copy loop check worker.compactAborted()
/// between syscalls — the flush cycle's own budget mid-cycle, send_deadline
/// during shutdown — so neither ever waits out a cap/2 rewrite: the untouched
/// original simply retries on the next append past the cap.
fn compact(alloc: std.mem.Allocator, file_fd: c_int, size: u64, format: FrameFormat) void {
    const cap_bytes: u64 = @as(u64, @intCast(@max(guc_max_mb, 0))) << 20;
    if (cap_bytes == 0 or size <= cap_bytes) return;
    const keep_bytes = cap_bytes / 2;

    // Walk whole members from the top; a member is droppable only if what
    // remains after it still holds the keep budget. Torn tail or framing we
    // misread stops the walk — nothing is dropped on a guess.
    var off: u64 = fb_magic_len;
    var lost_events: u64 = 0;
    while (off < size) {
        if (worker.compactAborted()) return;
        const header = switch (readFrameHeader(file_fd, format, off, size)) {
            .full => |h| h,
            .torn => break,
            .err, .corrupt => return,
        };
        const end = off + header.len + header.compressed_len;
        if (end > size) break; // torn tail
        if (size - end < keep_bytes) break; // dropping would undercut the budget
        if (off >= offset) { // undelivered: count its events before dropping
            // A readable gzip payload is authoritative: its CRC passed and its
            // NDJSON line count survives a damaged v2 count word. If v2 itself
            // is unreadable, the stored count remains the exact fallback; v1
            // has no such metadata and must abort rather than invent a loss.
            lost_events += countFrameEvents(alloc, file_fd, format, off, header) orelse return;
        }
        off = end;
    }
    const dropped = off - fb_magic_len;
    if (dropped == 0) return; // first member alone exceeds the budget

    // Rewrite: magic + [off, size) copied verbatim (gzip members are
    // self-contained; no recompression).
    var tmp_buf: [4096]u8 = undefined;
    const tmp_path = compactPath(&tmp_buf) orelse return;
    // The temp must be exclusively ours: a predictable name opened with
    // O_TRUNC follows a symlink planted in a writable directory (truncating
    // its target, and the rename would then put that symlink in the queue's
    // place). O_EXCL|O_NOFOLLOW refuse both; the EEXIST case is our own
    // litter from a crashed compaction — unlink it (never a symlink's
    // target) and retry once. Anything still in the way aborts quietly:
    // the original queue stands, the cap retries on the next append.
    const tmp_flags = 2 | 64 | 128 | fb_no_follow; // O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW
    var tmp_fd = c.open(tmp_path, tmp_flags, @as(c_uint, 0o600));
    if (tmp_fd < 0) {
        const open_errno = std.c._errno().*;
        if (open_errno != @intFromEnum(std.c.E.EXIST)) return;
        if (c.unlink(tmp_path) != 0) return;
        tmp_fd = c.open(tmp_path, tmp_flags, @as(c_uint, 0o600));
        if (tmp_fd < 0) return;
    }
    var copied_ok = worker.writeAll(tmp_fd, format.magic(), false, null);
    var pos: u64 = off;
    var copy_buf: [64 * 1024]u8 = undefined;
    while (copied_ok and pos < size) {
        // Abortable unlike the parked-backlog writes: the members are durable
        // in the original, so an aborted rewrite is a wasted tmp, not a loss.
        if (worker.compactAborted()) { // mid-cycle: hand the worker back, retry later
            copied_ok = false;
            break;
        }
        const want: usize = @intCast(@min(@as(u64, copy_buf.len), size - pos));
        if (fbPread(file_fd, copy_buf[0..want], pos) != .full) { // EOF/read error — abort the rewrite
            copied_ok = false;
            break;
        }
        copied_ok = worker.writeAll(tmp_fd, copy_buf[0..want], true, null);
        pos += want;
    }
    if (copied_ok) copied_ok = fbDatasync(tmp_fd, true);
    var tmp_st: worker.FileStat = undefined;
    if (copied_ok and c.fstat(tmp_fd, &tmp_st) != 0) copied_ok = false;
    _ = c.close(tmp_fd);
    if (!copied_ok or c.rename(tmp_path, @ptrCast(fb_path_buf[0..fb_path_len :0].ptr)) != 0) {
        _ = c.unlink(tmp_path);
        return;
    }
    fsyncDirOf(fb_path_buf[0..fb_path_len]);
    queue_dev = tmp_st.dev;
    queue_ino = tmp_st.ino;
    queue_identity_valid = true;
    offset = @max(fb_magic_len, offset -| dropped);
    if (lost_events > 0) capture.bumpExport(0, 0, 0, 0, lost_events, lost_events, 0);
    elog.Log(@src(), "pg_logtap fallback file compacted to the newest {d} of {d} bytes; {d} undelivered events counted lost (outage outlasted the queue cap)", .{ size - off, size, lost_events });
}

/// Fallback on/off transitions only — same discipline as export failures.
var was_fallback = false;

pub fn logDivert(active: bool) void {
    if (active == was_fallback) return;
    was_fallback = active;
    if (active) {
        elog.Log(@src(), "pg_logtap export diverting batches to fallback file (receiver failing)", .{});
        // The transition guard above makes this once per divert, not once
        // per append: an unattended outage with no cap parks events until
        // the disk is full, and that deserves an operator-visible line.
        if (guc_max_mb == 0) {
            capture.noteWarn(.fallback_unbounded);
            elog.Warning(@src(), "pg_logtap fallback queue is unbounded (fallback_max_mb=0): a long outage grows it until the disk is full; set fallback_max_mb to bound it", .{});
        }
    } else {
        elog.Log(@src(), "pg_logtap fallback closed, receiver delivery resumed", .{});
    }
}
