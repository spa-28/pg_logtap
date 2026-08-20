//! Shared-memory ring buffer: layout + pure operations.
//! No PostgreSQL imports here — unit-testable standalone; capture.zig owns
//! the LWLock discipline (lock around every push/pop/snapshot call).
const std = @import("std");

pub const msg_len = 1024;
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

/// Bits of ShmLogEntry.truncated_mask: which fields were cut on copy.
pub const TruncField = enum(u4) { message, detail, hint, context, query, filename, funcname, backend_type, app, client_host };

/// One captured log event. Fixed layout: lives in shared memory as-is.
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
    message: FixedStr(msg_len),
    detail: FixedStr(aux_len),
    hint: FixedStr(aux_len),
    context: FixedStr(aux_len),
    filename: FixedStr(aux_len),
    funcname: FixedStr(aux_len),
    query: FixedStr(aux_len),
    truncated_mask: u16 = 0,
};

/// Control block; entries array is a separate shmem chunk (keeps this small
/// enough to zero on the stack in tests).
pub const ShmState = extern struct {
    /// pg.LWLock, padded to LWLOCK_PADDED_SIZE (64). Initialized by capture.zig.
    lock: [64]u8 align(8) = [_]u8{0} ** 64,
    magic: u32 = 0,
    capacity: u32 = 0,
    write_pos: u32 = 0,
    read_pos: u32 = 0,
    count: u32 = 0,
    seq_next: u64 = 0,
    captured: u64 = 0,
    dropped: u64 = 0,
    exported: u64 = 0,
    export_failed: u64 = 0,
    export_lost: u64 = 0,
};

/// Ring handle: control block + backing store, capacity == entries.len.
pub const Ring = struct {
    state: *ShmState,
    entries: []ShmLogEntry,

    pub fn init(state: *ShmState, entries: []ShmLogEntry) Ring {
        return .{ .state = state, .entries = entries };
    }
};

pub const Stats = struct {
    captured: u64,
    dropped: u64,
    exported: u64,
    export_failed: u64,
    export_lost: u64,
    count: u32,
    capacity: u32,
    seq_next: u64,
};

/// Append an event. Caller holds the lock. On overflow the NEW event is
/// dropped and `dropped` counted (consumer keeps its place; seq stays gapless
/// for dedup downstream). Returns false when dropped.
pub fn push(ring: Ring, e: ShmLogEntry) bool {
    if (ring.state.count >= ring.state.capacity or ring.state.capacity == 0) {
        ring.state.dropped += 1;
        return false;
    }
    var entry = e;
    entry.seq = ring.state.seq_next;
    ring.state.seq_next += 1;
    ring.entries[ring.state.write_pos] = entry;
    ring.state.write_pos = (ring.state.write_pos + 1) % ring.state.capacity;
    ring.state.count += 1;
    ring.state.captured += 1;
    return true;
}

/// Take the oldest unconsumed event (M2: the bgworker drain side).
/// Caller holds the lock.
pub fn pop(ring: Ring) ?ShmLogEntry {
    if (ring.state.count == 0) return null;
    const entry = ring.entries[ring.state.read_pos];
    ring.state.read_pos = (ring.state.read_pos + 1) % ring.state.capacity;
    ring.state.count -= 1;
    return entry;
}

/// Non-destructive read of the i-th pending event (dump side; the M3 worker
/// will use pop instead). Caller holds the lock.
pub fn peek(ring: Ring, i: u32) ?ShmLogEntry {
    if (i >= ring.state.count) return null;
    const idx = (ring.state.read_pos + i) % ring.state.capacity;
    return ring.entries[idx];
}

/// Caller holds the lock.
pub fn snapshot(ring: Ring) Stats {
    return .{
        .captured = ring.state.captured,
        .dropped = ring.state.dropped,
        .exported = ring.state.exported,
        .export_failed = ring.state.export_failed,
        .export_lost = ring.state.export_lost,
        .count = ring.state.count,
        .capacity = ring.state.capacity,
        .seq_next = ring.state.seq_next,
    };
}

/// Copy `src` into a FixedStr, cutting back to a UTF-8 character boundary
/// when it does not fit; sets the field's bit in `mask` when truncated.
pub fn setStr(dst: anytype, mask: *u16, field: TruncField, src: []const u8) void {
    const cap = dst.bytes.len;
    var n = @min(src.len, cap);
    const truncated = src.len > n;
    // Continuation bytes are 0b10xxxxxx; step back onto a lead byte.
    if (truncated) {
        while (n > 0 and (src[n] & 0xC0) == 0x80) n -= 1;
    }
    @memcpy(dst.bytes[0..n], src[0..n]);
    dst.len = @intCast(n);
    if (truncated) mask.* |= @as(u16, 1) << @intCast(@intFromEnum(field));
}

test "push/pop/overflow with seq gapless" {
    const alloc = std.testing.allocator;
    var state = std.mem.zeroes(ShmState);
    state.capacity = 2;
    const entries = try alloc.alloc(ShmLogEntry, 2);
    defer alloc.free(entries);
    const ring_q = Ring.init(&state, entries);

    var event_v = std.mem.zeroes(ShmLogEntry);
    event_v.elevel = 19;

    try std.testing.expect(push(ring_q, event_v)); // seq 0
    try std.testing.expect(push(ring_q, event_v)); // seq 1
    try std.testing.expect(!push(ring_q, event_v)); // full -> dropped
    _ = pop(ring_q).?;
    try std.testing.expect(push(ring_q, event_v)); // seq 2

    const snap_v = snapshot(ring_q);
    try std.testing.expectEqual(@as(u64, 3), snap_v.captured);
    try std.testing.expectEqual(@as(u64, 1), snap_v.dropped);
    try std.testing.expectEqual(@as(u32, 2), snap_v.count);
    try std.testing.expectEqual(@as(u64, 3), snap_v.seq_next);
    try std.testing.expectEqual(@as(u64, 1), pop(ring_q).?.seq); // 0 was popped above
    try std.testing.expectEqual(@as(u64, 2), pop(ring_q).?.seq); // gapless despite drop
    try std.testing.expect(pop(ring_q) == null);
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
