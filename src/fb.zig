//! Fallback file: compressed durable on-disk queue, replayed on recovery.
//! When an http/tcp send fails and export_fallback_file is set, batches are
//! appended here and drained to the receiver once it answers — the RAM
//! backlog then only covers what parking cannot take.
//! Internal framing, one batch per member: [8-byte magic][u32 LE len][gzip]…
//! A crash mid-append leaves a torn tail member — detected by the short read,
//! truncated, appends resume at the member boundary. A crash mid-replay loses
//! only the in-memory offset: replay restarts from byte 0, so the receiver may
//! see duplicates — dedup by (host, seq), the http at-least-once contract.
//! Obeys the worker's abort disciplines (writeAll/compactAborted below).
const std = @import("std");

const pg = @import("pgzx").c;
const elog = @import("pgzx").elog;
const worker = @import("worker.zig");
const ring = @import("ring.zig");
const capture = @import("capture.zig");
const gzip = @import("gzip.zig");

/// libc file wrappers (see worker.zig's `c` for the socket half).
const c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(conn_fd: c_int) c_int;
    extern "c" fn fdatasync(fd: c_int) c_int;
    extern "c" fn fsync(fd: c_int) c_int;
    extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64; // SEEK_END=2 → file size
    extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
    extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
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
/// and gzip does not inflate its input beyond that +64K of slack.
const member_max = body_cap + ring.max_message + 65536;

const fb_magic = "PGLTFB01";
const fb_magic_len = 8;

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
/// Members skipped as unreadable (framing intact, gzip damaged) — folded into
/// `lost` by the flush cycle that read them.
pub var lost: u64 = 0;

var fb_path_buf: [4096]u8 = undefined;
var fb_path_len: usize = 0;

// --- GUCs -----------------------------------------------------------------------

var guc_file: [*c]u8 = null;
var guc_max_mb: c_int = 512;

/// The fallback GUC pair, called from worker.init (one registration site).
pub fn defineGucs() void {
    pg.DefineCustomStringVariable("pg_logtap.export_fallback_file", "Path; failed http/tcp batches are appended here as a compressed durable queue (fdatasynced once per flush cycle) and replayed automatically once the receiver answers. Relative resolves against the data directory. Empty = off. The resolved path must leave room for the .compact rewrite suffix (9 bytes under the 4096-byte path limit) or the value is rejected — the cap cannot work without it. See docs/delivery.md.", null, &guc_file, "", pg.PGC_SIGHUP, 0, checkFile, null, null);
    pg.DefineCustomIntVariable("pg_logtap.fallback_max_mb", "Size cap for the fallback queue file. When an append pushes the file past the cap it is compacted to the newest half (atomic rewrite), and the undelivered events dropped by that count into events_lost — the EventsLost alert is the signal that the outage outlasted the queue. 0 = unlimited (pre-0.3.0 behavior: an unattended outage fills the disk). A cap smaller than one member (~a hundred KB compressed) can only bound the file at member granularity.", null, &guc_max_mb, 512, 0, 1_048_576, pg.PGC_SIGHUP, 0, null, null, null);
}

/// The queue's path buffers are 4096 bytes and compaction rewrites through
/// "<path>.compact": a value that fits the queue but leaves no room for the
/// suffix parks events fine, yet the cap can never fire — compact cannot
/// even name its temp. Reject the value at SET (the call path guc.c uses for
/// both SET and ALTER SYSTEM; boot runs the default '' through here too, and
/// empty is always accepted). Relative paths measure against the data
/// directory, exactly as path() resolves them.
fn checkFile(newval: [*c][*c]u8, extra: [*c]?*anyopaque, source: c_uint) callconv(.c) bool {
    _ = extra;
    _ = source;
    const ptr = newval orelse return true;
    const raw_c = ptr.* orelse return true;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(raw_c)));
    if (raw.len == 0) return true;
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
        broken = false;
    }
    return fb_path_buf[0..fb_path_len];
}

/// Worker start: remove a crashed compaction's litter, then credit this
/// epoch's counters with whatever the file already holds (below).
pub fn boot(alloc: std.mem.Allocator) void {
    if (path() != null) {
        var tmp_buf: [4096]u8 = undefined;
        if (compactPath(&tmp_buf)) |p| _ = c.unlink(p);
    }
    creditBacklog(alloc);
}

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
    return file_fd;
}

/// fsync the parent of a path: makes a fresh directory entry durable. Best
/// effort — a failure costs durability of the creation, not correctness.
fn fsyncDirOf(path_str: []const u8) void {
    const dir_end = std.mem.findScalarLast(u8, path_str, '/') orelse return;
    var dir_buf: [4096]u8 = undefined;
    const dir = if (dir_end == 0) "/" else path_str[0..dir_end]; // "/x" → "/"
    if (dir.len >= dir_buf.len) return;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_buf[dir.len] = 0;
    const dir_fd = c.open(@ptrCast(&dir_buf), 0, @as(c_uint, 0)); // O_RDONLY
    if (dir_fd < 0) return;
    defer _ = c.close(dir_fd);
    _ = c.fsync(dir_fd);
}

fn fbSize(fd: c_int) ?u64 {
    const end = c.lseek(fd, 0, 2); // SEEK_END
    return if (end >= 0) @intCast(end) else null;
}

/// One pread; a regular file returns the full request unless EOF/EINTR-short.
fn fbPread(fd: c_int, buf: []u8, offset_v: u64) isize {
    return c.pread(fd, buf.ptr, buf.len, @intCast(offset_v));
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
pub fn append(alloc: std.mem.Allocator, body: []const u8, sync: bool) Outcome {
    if (broken) return .failed;
    const file_fd = fbOpen() orelse return .failed;
    defer _ = c.close(file_fd);
    const size = fbSize(file_fd) orelse return .failed;
    if (size == 0) {
        if (!worker.writeAll(file_fd, fb_magic, false)) {
            // Roll the fresh file back to empty. A short write can stop
            // mid-magic, and a 1..7-byte file is "foreign content" to the
            // next open — fallback disabled over a torn header. The file
            // holds no members yet, so the rollback costs nothing; the next
            // append writes the magic whole again.
            if (c.ftruncate(file_fd, 0) != 0) {
                broken = true;
                elog.Warning(@src(), "pg_logtap fallback append could not roll back a partial queue header (errno={d}), replay disabled: {s}", .{ std.c._errno().*, path() orelse "" });
            }
            return .failed;
        }
    } else {
        var magic: [fb_magic_len]u8 = undefined;
        if (size < fb_magic_len or fbPread(file_fd, &magic, 0) != fb_magic_len or !std.mem.eql(u8, &magic, fb_magic)) {
            broken = true;
            elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, fallback disabled: {s}", .{path() orelse ""});
            return .failed;
        }
    }
    const comp = gzip.compress(alloc, body) catch return .failed; // compression failed → RAM backlog retries
    defer alloc.free(comp);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(comp.len), .little);
    if (!worker.writeAll(file_fd, &len_buf, false) or !worker.writeAll(file_fd, comp, false)) {
        // Roll the partial member back. A torn [len][half-member] left in
        // place shifts the framing of every later append — the next member
        // lands mid-garbage and the whole tail reads as "gzip damaged"
        // instead of just this batch retrying from RAM.
        if (c.ftruncate(file_fd, @intCast(size)) != 0) {
            broken = true;
            elog.Warning(@src(), "pg_logtap fallback append could not roll back a partial member (errno={d}), replay disabled: {s}", .{ std.c._errno().*, path() orelse "" });
        }
        return .failed;
    }
    var durable = true;
    if (sync and !fbDatasync(file_fd)) durable = false;
    // Cap enforcement after the append: the member is on disk either way
    // (durability aside), and the compaction rewrite must never race a
    // lost one. A failed fdatasync above does not skip it either:
    // compaction is tmp+rename where every failure leaves the original
    // file untouched, so it can only enforce the cap — never worsen the
    // not-durable state or drop a member the failed sync left in place.
    // The fd and the post-append size are already in hand — the
    // cap check costs no syscall, and only a file past the cap pays for the
    // rewrite. A fresh file (size 0) also gained the framing magic with
    // this member.
    compact(alloc, file_fd, (if (size == 0) fb_magic_len else size) + 4 + comp.len);
    return if (durable) .appended else .not_durable;
}

/// fdatasync with an edge-triggered WARNING: false = the pages are written
/// but not durable (an OS crash loses them; postmaster death still does not).
fn fbDatasync(file_fd: c_int) bool {
    if (c.fdatasync(file_fd) == 0) {
        fb_sync_warned = false;
        return true;
    }
    if (!fb_sync_warned) {
        fb_sync_warned = true;
        elog.Warning(@src(), "pg_logtap fallback fdatasync failed (errno={d}): the queue's latest change is written but not durable", .{std.c._errno().*});
    }
    sync_failures += 1;
    return false;
}

/// Durability point for a cycle's deferred appends.
pub fn fsync() void {
    if (broken or path() == null) return;
    const file_fd = fbOpen() orelse return;
    defer _ = c.close(file_fd);
    _ = fbDatasync(file_fd);
}

/// One queued batch: decompressed NDJSON, the byte size at read time, and how
/// far offset advances past it. body borrows the reused inflate buffer —
/// valid until the next nextMember.
pub const Member = struct { body: []const u8, size: u64, advance: u64 };

// Reused inflate state: the 32K window and the ~100K+ decompressed member
// sit above glibc's mmap threshold — same story as the gzip pool.
var fb_dec: ?struct { window: []u8, body: std.Io.Writer.Allocating } = null;

/// Read the member at offset. null = nothing replayable right now (drained,
/// torn tail truncated away, unreadable member skipped, or the file is not
/// ours). Torn tail: crash mid-append left a short member — truncated so
/// appends resume at a member boundary.
pub fn nextMember(alloc: std.mem.Allocator) ?Member {
    if (broken) return null;
    const file_fd = fbOpen() orelse return null;
    defer _ = c.close(file_fd);
    const size = fbSize(file_fd) orelse return null;
    if (offset == 0) {
        if (size <= fb_magic_len) return null;
        var magic: [fb_magic_len]u8 = undefined;
        if (fbPread(file_fd, &magic, 0) != fb_magic_len or !std.mem.eql(u8, &magic, fb_magic)) {
            broken = true;
            elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, replay disabled: {s}", .{path() orelse ""});
            return null;
        }
        offset = fb_magic_len;
    }
    if (offset >= size) return null;
    var len_buf: [4]u8 = undefined;
    if (fbPread(file_fd, &len_buf, offset) != 4) return null;
    const mlen = std.mem.readInt(u32, &len_buf, .little);
    if (mlen == 0 or mlen > member_max) {
        broken = true;
        elog.Log(@src(), "pg_logtap fallback framing corrupt at offset {d}, replay disabled", .{offset});
        return null;
    }
    const comp = alloc.alloc(u8, mlen) catch return null;
    if (fbPread(file_fd, comp, offset + 4) != mlen) { // torn tail
        alloc.free(comp);
        // The truncation is what lets the next append land on a member edge;
        // if it fails the framing after offset is lost until a human
        // looks — replaying garbage is worse than stopping.
        if (c.ftruncate(file_fd, @intCast(offset)) != 0) {
            broken = true;
            elog.Warning(@src(), "pg_logtap fallback torn tail at offset {d} could not be truncated (errno={d}), replay disabled: {s}", .{ offset, std.c._errno().*, path() orelse "" });
        }
        return null;
    }
    defer alloc.free(comp);
    if (fb_dec == null) fb_dec = .{
        .window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return null,
        .body = .init(alloc),
    };
    const dec_state = &fb_dec.?;
    var src: std.Io.Reader = .fixed(comp);
    var dec = std.compress.flate.Decompress.init(&src, .gzip, dec_state.window);
    dec_state.body.writer.end = 0;
    _ = dec.reader.streamRemaining(&dec_state.body.writer) catch {
        const skip_at = offset; // framing is intact: skip past, count as loss
        offset += 4 + mlen;
        lost += 1;
        capture.noteWarn(.fallback_skipped);
        elog.Log(@src(), "pg_logtap fallback member at offset {d} unreadable, skipped", .{skip_at});
        return null;
    };
    // buildBody admits the event that crosses body_cap, so a member this
    // build writes is ≤ body_cap + one serialized event (≤ ring.max_message
    // + overhead); the +64K on top also admits members from 0.3.x binaries
    // (≤ ~371KB) read before an upgrade drains the queue. Compile-time max,
    // not the live GUC: queued members can outlive a restart that lowers
    // message_max. A byte bound, not a ratio: a wide repetitive body
    // legitimately inflates past 64:1 and a ratio bound would flag it
    // corrupt and lose it.
    if (dec_state.body.writer.end > member_max) { // inflated absurdly: corrupt, skip
        const skip_at = offset;
        offset += 4 + mlen;
        lost += 1;
        elog.Log(@src(), "pg_logtap fallback member at offset {d} inflated past sanity, skipped", .{skip_at});
        return null;
    }
    return .{ .body = dec_state.body.writer.buffer[0..dec_state.body.writer.end], .size = size, .advance = 4 + @as(u64, mlen) };
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
    var magic: [fb_magic_len]u8 = undefined;
    if (fbPread(file_fd, &magic, 0) != fb_magic_len or !std.mem.eql(u8, &magic, fb_magic)) return;
    if (c.ftruncate(file_fd, 0) == 0) {
        offset = 0;
        _ = fbDatasync(file_fd);
    }
}

/// The fallback file can outlive the shmem counters: a postmaster restart
/// zeroes queued/replayed/…, the disk queue does not. Credit this epoch's
/// queued with what the file already holds so backlog (queued − replayed)
/// stays a real number and replayed ≤ queued holds. One decompress pass at
/// worker start; offset is restored afterwards — the drain replays from the
/// top as before (at-least-once contract unchanged).
/// A worker restart (postmaster alive, counters intact) must credit nothing:
/// its predecessor already counted every append now in the file, and a
/// re-credit would inflate backlog (queued − replayed) forever — the file
/// draining does not repair a counter difference. Every append this epoch
/// bumped queued, so `file events −| queued` is exactly the uncounted part:
/// zero after a worker restart, the whole file after a postmaster restart.
fn creditBacklog(alloc: std.mem.Allocator) void {
    const saved_offset = offset;
    const saved_lost = lost;
    var lines: u64 = 0;
    while (true) {
        const before = offset;
        const member = nextMember(alloc) orelse {
            // null without advancing = drained, torn tail or foreign file;
            // null WITH advancing = unreadable member skipped — keep walking
            if (offset == before) break;
            continue;
        };
        lines += std.mem.countScalar(u8, member.body, '\n');
        offset += member.advance;
    }
    offset = saved_offset;
    lost = saved_lost;
    const due = lines -| capture.snapshot().queued;
    if (due > 0) capture.bumpExport(0, due, 0, 0, 0, 0);
}

/// Enforce fallback_max_mb (0 = unlimited): once the file outgrew the cap,
/// rewrite it keeping only the newest half of the cap — an unattended outage
/// then turns over cap/2 bytes per compaction instead of filling the disk.
/// Members below offset were already delivered (dropping them is free);
/// dropped undelivered members count into compacted AND lost: compacted
/// keeps queue_backlog = queued − replayed − compacted truthful (they left
/// the queue), lost records that they never arrived. Atomic (tmp + rename +
/// directory fsync); any failure leaves the file as it was — the next append
/// past the cap retries. Ceiling: a cap smaller than one member bounds the
/// file only at member granularity. Runs under the cycle's abort budget:
/// the member-count walk and the copy loop check worker.compactAborted()
/// between syscalls — the flush cycle's own budget mid-cycle, send_deadline
/// during shutdown — so neither ever waits out a cap/2 rewrite: the untouched
/// original simply retries on the next append past the cap.
fn compact(alloc: std.mem.Allocator, file_fd: c_int, size: u64) void {
    const cap_bytes: u64 = @as(u64, @intCast(@max(guc_max_mb, 0))) << 20;
    if (cap_bytes == 0 or size <= cap_bytes) return;
    const keep_bytes = cap_bytes / 2;

    // Walk whole members from the top; a member is droppable only if what
    // remains after it still holds the keep budget. Torn tail or framing we
    // misread stops the walk — nothing is dropped on a guess.
    var off: u64 = fb_magic_len;
    var lost_events: u64 = 0;
    while (off + 4 <= size) {
        if (worker.compactAborted()) return;
        var len_buf: [4]u8 = undefined;
        if (fbPread(file_fd, &len_buf, off) != 4) return;
        const mlen = std.mem.readInt(u32, &len_buf, .little);
        if (mlen == 0 or mlen > member_max) return;
        const end = off + 4 + mlen;
        if (end > size) break; // torn tail
        if (size - end < keep_bytes) break; // dropping would undercut the budget
        if (off >= offset) { // undelivered: count its events before dropping
            const comp = alloc.alloc(u8, mlen) catch return;
            defer alloc.free(comp);
            if (fbPread(file_fd, comp, off + 4) != mlen) return;
            if (fb_dec == null) fb_dec = .{
                .window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return,
                .body = .init(alloc),
            };
            const dec_state = &fb_dec.?;
            var src_reader: std.Io.Reader = .fixed(comp);
            var dec = std.compress.flate.Decompress.init(&src_reader, .gzip, dec_state.window);
            dec_state.body.writer.end = 0;
            // a member that will not inflate has no countable events; replay
            // counts it as one loss per member (nextMember's lost += 1)
            // — match that here or events_lost undercounts the compaction drop
            var readable = true;
            _ = dec.reader.streamRemaining(&dec_state.body.writer) catch {
                readable = false;
            };
            lost_events += if (readable) std.mem.countScalar(u8, dec_state.body.writer.buffer[0..dec_state.body.writer.end], '\n') else 1;
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
        if (c.unlink(tmp_path) != 0) return;
        tmp_fd = c.open(tmp_path, tmp_flags, @as(c_uint, 0o600));
        if (tmp_fd < 0) return;
    }
    var copied_ok = worker.writeAll(tmp_fd, fb_magic, false);
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
        const got = fbPread(file_fd, copy_buf[0..want], pos);
        if (got <= 0) { // 0 = EOF; -1 = read error — both abort the rewrite
            copied_ok = false;
            break;
        }
        copied_ok = worker.writeAll(tmp_fd, copy_buf[0..@intCast(got)], true);
        pos += @intCast(got);
    }
    if (copied_ok) copied_ok = c.fdatasync(tmp_fd) == 0;
    _ = c.close(tmp_fd);
    if (!copied_ok or c.rename(tmp_path, @ptrCast(fb_path_buf[0..fb_path_len :0].ptr)) != 0) {
        _ = c.unlink(tmp_path);
        return;
    }
    fsyncDirOf(fb_path_buf[0..fb_path_len]);
    offset = @max(fb_magic_len, offset -| dropped);
    if (lost_events > 0) capture.bumpExport(0, 0, 0, 0, lost_events, lost_events);
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
