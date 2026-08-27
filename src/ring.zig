//! Shared-memory ring buffer: layout + pure operations.
//! No PostgreSQL imports here — unit-testable standalone; capture.zig owns
//! the LWLock discipline (lock around every push/pop/snapshot call).
const std = @import("std");

/// Default and ceiling of pg_logtap.message_max (PGC_POSTMASTER): the width
/// in bytes of the variable-size message region of every slot.
pub const default_message = 1024;
pub const max_message = 1_048_576;
pub const aux_len = 256;
/// GUC hard ceiling for ring_capacity (PGC_POSTMASTER).
pub const max_capacity = 8192;
/// ShmState.magic once the segment is initialized by the startup hook.
pub const ready_magic: u32 = 0x70677461; // "pgta"

/// Fixed-size, NUL-free string field. `len` counts valid UTF-8 bytes.
pub fn FixedStr(comptime cap: usize) type {
    return extern struct {
        len: u32 = 0,
        bytes: [cap]u8 = [_]u8{0} ** cap,
    };
}

/// Bits of ShmLogEntry.truncated_mask / redacted_mask: which fields were cut
/// on copy. The two masks carry different causes for the same cut and stay
/// independent: truncated = the text did not fit its slot, redacted = a
/// redaction layer clipped at its scratch size.
pub const TruncField = enum(u4) { message, detail, hint, context, query, filename, funcname, backend_type, app, client_host };

/// One captured log event: the fixed head of a ring slot. The message — the
/// one variable-width field (pg_logtap.message_max) — is not part of the
/// struct: its bytes start at @sizeOf(ShmLogEntry) inside the slot,
/// message_len of them; the slot stride comes from ShmState.message_max.
pub const ShmLogEntry = extern struct {
    seq: u64 = 0,
    timestamp_us: i64 = 0, // PostgreSQL TimestampTz (µs since 2000-01-01)
    elevel: i32 = 0,
    sqlerrcode: i32 = 0,
    lineno: i32 = 0,
    pid: i32 = 0,
    db_oid: u32 = 0,
    role_oid: u32 = 0,
    backend_type: FixedStr(aux_len), // GetBackendTypeDesc() at capture; enum values differ across PG versions
    app: FixedStr(aux_len), // session application_name (%a); "" for no-client processes
    client_host: FixedStr(aux_len), // MyProcPort->remote_host (%h); "" for unix sockets
    /// Message bytes at the head's end in the slot, this many of them.
    message_len: u32 = 0,
    detail: FixedStr(aux_len),
    hint: FixedStr(aux_len),
    context: FixedStr(aux_len),
    filename: FixedStr(aux_len),
    funcname: FixedStr(aux_len),
    query: FixedStr(aux_len),
    truncated_mask: u16 = 0,
    /// Set by the redaction layers (capture.copyText), not by setStr: same
    /// cut as truncated_mask, different cause — see TruncField above.
    redacted_mask: u16 = 0,
};

/// Control block; the slots live in a separate shmem chunk (keeps this small
/// enough to zero on the stack in tests).
pub const ShmState = extern struct {
    /// pg.LWLock, padded to LWLOCK_PADDED_SIZE (64). Initialized by capture.zig.
    lock: [64]u8 align(8) = [_]u8{0} ** 64,
    magic: u32 = 0,
    capacity: u32 = 0,
    /// Slot stride input: stride = strideFor(message_max). Written once at
    /// shmem init; every process derives addressing from here rather than
    /// from its own GUC copy, so the two can never disagree.
    message_max: u32 = 0,
    write_pos: u32 = 0,
    read_pos: u32 = 0,
    count: u32 = 0,
    /// The export worker's latch, published at worker start (0 = not yet).
    /// Backends SetLatch it when the ring goes empty → non-empty, so a burst
    /// is drained immediately instead of after a full flush_interval of sleep.
    worker_latch: usize = 0,
    seq_next: u64 = 0,
    captured: u64 = 0,
    dropped: u64 = 0,
    sent: u64 = 0,
    queued: u64 = 0,
    replayed: u64 = 0,
    send_failed: u64 = 0,
    export_lost: u64 = 0,
    /// Consecutive failed getaddrinfo lookups in the export worker; 0 after
    /// any success. The originals are worker-local — these copies are what
    /// stats/metrics/alerts see.
    dns_fail_streak: u32 = 0,
    /// 1 = the fallback file is foreign/corrupt and neither appended to nor
    /// replayed: durability is silently degraded to the RAM backlog bound.
    fallback_broken: u8 = 0,
    /// 1 = pg_logtap.redact_pattern did not compile; that redaction layer is
    /// OFF (fail-open) until the pattern is fixed.
    redact_pattern_failed: u8 = 0,
};

/// Byte stride of one slot: head + message region, rounded up so every slot
/// head is 8-aligned. Shared-memory chunks are MAXALIGN(8) — the same
/// guarantee the old `[*]ShmLogEntry` array cast relied on.
pub fn strideFor(message_max: u32) u32 {
    return @intCast(std.mem.alignForward(usize, @sizeOf(ShmLogEntry) + message_max, 8));
}

/// Ring handle: control block + backing bytes (capacity × stride of them).
pub const Ring = struct {
    state: *ShmState,
    base: [*]u8,
    stride: u32,

    pub fn init(state: *ShmState, base: [*]u8, stride: u32) Ring {
        return .{ .state = state, .base = base, .stride = stride };
    }

    fn slotHead(r: Ring, i: u32) *ShmLogEntry {
        return @ptrCast(@alignCast(r.base + @as(usize, i) * r.stride));
    }

    fn slotMsg(r: Ring, i: u32) []u8 {
        const off = @as(usize, i) * r.stride + @sizeOf(ShmLogEntry);
        return (r.base + off)[0..r.state.message_max];
    }
};

pub const Stats = struct {
    captured: u64,
    dropped: u64,
    sent: u64,
    queued: u64,
    replayed: u64,
    send_failed: u64,
    export_lost: u64,
    dns_fail_streak: u32,
    fallback_broken: u8,
    redact_pattern_failed: u8,
    count: u32,
    capacity: u32,
    seq_next: u64,
};

/// Append an event: head + message bytes. Caller holds the lock. On overflow
/// the NEW event is dropped and `dropped` counted (consumer keeps its place;
/// seq stays gapless for dedup downstream). Returns false when dropped.
/// The message is clipped defensively at the slot bound — capture owns the
/// truncated mask and has already clipped; this is the memcpy's trust
/// boundary, and a bounds panic here would take down a logging backend.
pub fn push(r: Ring, e: ShmLogEntry, msg: []const u8) bool {
    if (r.state.count >= r.state.capacity or r.state.capacity == 0) {
        r.state.dropped += 1;
        return false;
    }
    var entry = e;
    entry.seq = r.state.seq_next;
    r.state.seq_next += 1;
    const c = clipUtf8(msg, r.state.message_max);
    entry.message_len = @intCast(c.len);
    r.slotHead(r.state.write_pos).* = entry;
    if (c.len > 0) @memcpy(r.slotMsg(r.state.write_pos)[0..c.len], msg[0..c.len]);
    r.state.write_pos = (r.state.write_pos + 1) % r.state.capacity;
    r.state.count += 1;
    r.state.captured += 1;
    return true;
}

/// Take the oldest unconsumed event: head into *head_out, message bytes into
/// msg_out (caller-owned, message_max-sized). Caller holds the lock.
/// Out-params rather than a returned slice: a slice into the slot would
/// dangle the moment the lock drops and the slot is reused.
pub fn pop(r: Ring, head_out: *ShmLogEntry, msg_out: []u8) bool {
    if (r.state.count == 0) return false;
    const slot = r.slotHead(r.state.read_pos);
    head_out.* = slot.*;
    const n = @min(slot.message_len, msg_out.len);
    if (n > 0) @memcpy(msg_out[0..n], r.slotMsg(r.state.read_pos)[0..n]);
    r.state.read_pos = (r.state.read_pos + 1) % r.state.capacity;
    r.state.count -= 1;
    return true;
}

/// Non-destructive read of the i-th pending event (dump side), same
/// head/msg_out shape as pop. Caller holds the lock.
pub fn peek(r: Ring, i: u32, head_out: *ShmLogEntry, msg_out: []u8) bool {
    if (i >= r.state.count) return false;
    const idx = (r.state.read_pos + i) % r.state.capacity;
    const slot = r.slotHead(idx);
    head_out.* = slot.*;
    const n = @min(slot.message_len, msg_out.len);
    if (n > 0) @memcpy(msg_out[0..n], r.slotMsg(idx)[0..n]);
    return true;
}

/// Caller holds the lock.
pub fn snapshot(r: Ring) Stats {
    return .{
        .captured = r.state.captured,
        .dropped = r.state.dropped,
        .sent = r.state.sent,
        .queued = r.state.queued,
        .replayed = r.state.replayed,
        .send_failed = r.state.send_failed,
        .export_lost = r.state.export_lost,
        .dns_fail_streak = r.state.dns_fail_streak,
        .fallback_broken = r.state.fallback_broken,
        .redact_pattern_failed = r.state.redact_pattern_failed,
        .count = r.state.count,
        .capacity = r.state.capacity,
        .seq_next = r.state.seq_next,
    };
}

/// Clip `src` to `cap` bytes, backing off to a UTF-8 character boundary.
pub fn clipUtf8(src: []const u8, cap: usize) struct { len: usize, truncated: bool } {
    var n = @min(src.len, cap);
    const truncated = src.len > n;
    // Continuation bytes are 0b10xxxxxx; step back onto a lead byte.
    if (truncated) {
        while (n > 0 and (src[n] & 0xC0) == 0x80) n -= 1;
    }
    return .{ .len = n, .truncated = truncated };
}

/// Copy `src` into a FixedStr field, setting the field's truncation bit when
/// clipped.
pub fn setStr(dst: anytype, mask: *u16, field: TruncField, src: []const u8) void {
    const c = clipUtf8(src, dst.bytes.len);
    @memcpy(dst.bytes[0..c.len], src[0..c.len]);
    dst.len = @intCast(c.len);
    if (c.truncated) mask.* |= @as(u16, 1) << @intCast(@intFromEnum(field));
}

/// The message counterpart of setStr for the variable-width field: clip into
/// `dst` (the capture-side hold buffer, or a test buffer), set message_len
/// and the truncated bit, and return the copied slice.
pub fn setMsg(len_out: *u32, mask: *u16, src: []const u8, dst: []u8) []const u8 {
    const c = clipUtf8(src, dst.len);
    @memcpy(dst[0..c.len], src[0..c.len]);
    len_out.* = @intCast(c.len);
    if (c.truncated) mask.* |= @as(u16, 1) << @intCast(@intFromEnum(TruncField.message));
    return dst[0..c.len];
}

test "head layout: default config keeps the 0.3.x shmem request" {
    // The message region moved out of the struct into the slot tail; with
    // message_max at its default the slot stride is byte-identical to the
    // pre-0.4 fixed slot (3416), so a default-config cluster requests the
    // same shared memory and the documented sizing keeps holding.
    try std.testing.expectEqual(@as(usize, 2392), @sizeOf(ShmLogEntry));
    try std.testing.expectEqual(@as(usize, 2384), @offsetOf(ShmLogEntry, "truncated_mask"));
    try std.testing.expectEqual(@as(usize, 2386), @offsetOf(ShmLogEntry, "redacted_mask"));
    try std.testing.expectEqual(@as(u32, 3416), strideFor(default_message));
    // every stride keeps every slot head 8-aligned
    try std.testing.expectEqual(@as(u32, 0), strideFor(max_message) % 8);
}

test "push/pop/overflow with seq gapless" {
    const alloc = std.testing.allocator;
    var state = std.mem.zeroes(ShmState);
    state.capacity = 2;
    state.message_max = 16;
    const stride = strideFor(16);
    const bytes = try alloc.alloc(u8, stride * 2);
    defer alloc.free(bytes);
    const ring_q = Ring.init(&state, bytes.ptr, stride);

    var event_v = std.mem.zeroes(ShmLogEntry);
    event_v.elevel = 19;
    var head: ShmLogEntry = undefined;
    var msg: [64]u8 = undefined;

    try std.testing.expect(push(ring_q, event_v, "one")); // seq 0
    try std.testing.expect(push(ring_q, event_v, "two")); // seq 1
    try std.testing.expect(!push(ring_q, event_v, "dropped")); // full -> dropped
    try std.testing.expect(pop(ring_q, &head, &msg));
    try std.testing.expectEqualStrings("one", msg[0..head.message_len]);
    try std.testing.expect(push(ring_q, event_v, "three")); // seq 2

    const snap_v = snapshot(ring_q);
    try std.testing.expectEqual(@as(u64, 3), snap_v.captured);
    try std.testing.expectEqual(@as(u64, 1), snap_v.dropped);
    try std.testing.expectEqual(@as(u32, 2), snap_v.count);
    try std.testing.expectEqual(@as(u64, 3), snap_v.seq_next);
    try std.testing.expect(pop(ring_q, &head, &msg)); // seq 1, "two"
    try std.testing.expectEqual(@as(u64, 1), head.seq);
    try std.testing.expectEqualStrings("two", msg[0..head.message_len]);
    try std.testing.expect(pop(ring_q, &head, &msg)); // seq 2, gapless despite drop
    try std.testing.expectEqual(@as(u64, 2), head.seq);
    try std.testing.expectEqualStrings("three", msg[0..head.message_len]);
    try std.testing.expect(!pop(ring_q, &head, &msg));
}

test "message clip at the slot bound" {
    // Exact fit truncates nothing; one byte over clips (and flags); a
    // multi-byte character straddling the bound backs off to its start.
    var len_v: u32 = 0;
    var mask: u16 = 0;
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("abc", setMsg(&len_v, &mask, "abc", buf[0..3]));
    try std.testing.expectEqual(@as(u32, 3), len_v);
    try std.testing.expectEqual(@as(u16, 0), mask);

    try std.testing.expectEqualStrings("abc", setMsg(&len_v, &mask, "abcd", buf[0..3]));
    try std.testing.expectEqual(@as(u32, 3), len_v);
    try std.testing.expectEqual(@as(u16, 1), mask); // the message bit

    var mask2: u16 = 0;
    try std.testing.expectEqualStrings("€€", setMsg(&len_v, &mask2, "€€€", buf[0..8])); // 3 bytes/char: the 3rd straddles
    try std.testing.expectEqual(@as(u32, 6), len_v);
    try std.testing.expectEqual(@as(u16, 1), mask2);
}

test "push clips defensively at message_max" {
    const alloc = std.testing.allocator;
    var state = std.mem.zeroes(ShmState);
    state.capacity = 2;
    state.message_max = 4;
    const stride = strideFor(4);
    const bytes = try alloc.alloc(u8, stride * 2);
    defer alloc.free(bytes);
    const ring_q = Ring.init(&state, bytes.ptr, stride);

    try std.testing.expect(push(ring_q, std.mem.zeroes(ShmLogEntry), "0123456789"));
    var head: ShmLogEntry = undefined;
    var msg: [64]u8 = undefined;
    try std.testing.expect(pop(ring_q, &head, &msg));
    try std.testing.expectEqual(@as(u32, 4), head.message_len);
    try std.testing.expectEqual(@as(u16, 0), head.truncated_mask); // capture's bit to set, not push's
}

test "utf8 truncation backs off to char boundary" {
    var field_v: FixedStr(12) = .{};
    var mask: u16 = 0;
    // 2-byte cyrillic "аб" = 4 bytes; 12 bytes holds 6 chars; 7th straddles.
    const src = "абвгдеж" ++ "0123456789";
    setStr(&field_v, &mask, .message, src);
    try std.testing.expectEqual(@as(u32, 12), field_v.len); // exactly 6 cyrillic chars
    try std.testing.expect(std.unicode.utf8ValidateSlice(field_v.bytes[0..field_v.len]));
    try std.testing.expectEqual(@as(u16, 1), mask);

    var short: FixedStr(64) = .{};
    var mask2: u16 = 0;
    setStr(&short, &mask2, .detail, "fits");
    try std.testing.expectEqualStrings("fits", short.bytes[0..short.len]);
    try std.testing.expectEqual(@as(u16, 0), mask2);
}
