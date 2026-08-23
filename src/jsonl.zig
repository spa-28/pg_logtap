//! Captured event → one JSON line (the single wire format, plan §4.3).
//! Pure module: no PostgreSQL imports; names that require catalog lookups
//! are resolved by the caller and passed in.
const std = @import("std");

const ring = @import("ring.zig");

/// PG epoch: 2000-01-01T00:00:00Z in Unix µs.
const pg_epoch_unix_us: i64 = 946_684_800 * 1_000_000;

/// Catalog-resolved names; null → JSON null.
pub const Names = struct {
    database: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

/// Source identity stamped on every event, so a central Vector receiving
/// many clusters can tell senders apart. Filled by the worker; empty → null.
pub var source_host: []const u8 = "";
pub var source_cluster: []const u8 = "";
pub var source_pgdata: []const u8 = "";

pub fn writeEntry(w: *std.Io.Writer, e: *const ring.ShmLogEntry, names: Names) !void {
    try w.print("{{\"seq\":{d},\"timestamp\":\"", .{e.seq});
    try writeTimestamp(w, e.timestamp_us);
    try w.writeAll("\"");
    try w.print(",\"level\":\"{s}\",\"message\":", .{levelName(e.elevel)});
    try jsonStr(w, fixed(&e.message));
    try w.print(",\"detail\":", .{});
    try optJsonStr(w, fixed(&e.detail));
    try w.print(",\"hint\":", .{});
    try optJsonStr(w, fixed(&e.hint));
    try w.print(",\"context\":", .{});
    try optJsonStr(w, fixed(&e.context));
    try w.print(",\"sqlerrcode\":\"{s}\",\"filename\":", .{sqlState(e.sqlerrcode)});
    try optJsonStr(w, fixed(&e.filename));
    try w.print(",\"lineno\":{d},\"funcname\":", .{e.lineno});
    try optJsonStr(w, fixed(&e.funcname));
    try w.print(",\"database\":", .{});
    try optJsonStr(w, names.database);
    try w.print(",\"user\":", .{});
    try optJsonStr(w, names.user);
    try w.print(",\"app\":", .{});
    try optJsonStr(w, fixed(&e.app));
    try w.print(",\"client_host\":", .{});
    try optJsonStr(w, fixed(&e.client_host));
    try w.print(",\"host\":", .{});
    try optJsonStr(w, source_host);
    try w.print(",\"cluster\":", .{});
    try optJsonStr(w, source_cluster);
    try w.print(",\"pgdata\":", .{});
    try optJsonStr(w, source_pgdata);
    try w.print(",\"pid\":{d},\"backend_type\":", .{e.pid});
    try optJsonStr(w, fixed(&e.backend_type));
    try w.print(",\"query\":", .{});
    try optJsonStr(w, fixed(&e.query));
    try w.writeAll(",\"truncated\":[");
    var first = true;
    inline for (std.meta.fields(ring.TruncField)) |f| {
        if (e.truncated_mask & (@as(u16, 1) << @intCast(f.value)) != 0) {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\"", .{f.name});
        }
    }
    try w.writeAll("]}");
}

fn fixed(fs: anytype) []const u8 {
    return fs.bytes[0..fs.len];
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try jsonChars(w, s);
    try w.writeByte('"');
}

/// JSON string body, UTF-8-sanitized. Log fields can carry raw invalid bytes —
/// SQL_ASCII databases, COPY/encoding errors quoting the offending bytes — and
/// JSON strings must be valid UTF-8 or the receiving parser (Vector's
/// serde_json, VictoriaLogs) rejects the line. Invalid bytes become U+FFFD;
/// valid input (the overwhelmingly common case) is one validate + one pass.
fn jsonChars(w: *std.Io.Writer, s: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(s))
        return std.json.Stringify.encodeJsonStringChars(s, .{}, w);
    var run: usize = 0; // start of the current valid run
    var i: usize = 0;
    while (i < s.len) {
        if (validSeqAt(s, i)) |len| {
            i += len;
        } else {
            try std.json.Stringify.encodeJsonStringChars(s[run..i], .{}, w);
            try w.writeAll("\u{FFFD}");
            i += 1;
            run = i;
        }
    }
    return std.json.Stringify.encodeJsonStringChars(s[run..], .{}, w);
}

/// Length of the valid UTF-8 sequence at s[i], or null for an invalid byte
/// (bad lead byte, truncated/overlong/surrogate sequence).
fn validSeqAt(s: []const u8, i: usize) ?u3 {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + len > s.len) return null;
    return if (std.unicode.utf8Decode(s[i..][0..len])) |_| len else |_| null;
}

/// Absent (null) or empty string → JSON null (copyStr skips null sources).
fn optJsonStr(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s == null or s.?.len == 0) {
        try w.writeAll("null");
    } else {
        try jsonStr(w, s.?);
    }
}

/// TimestampTz (µs since PG epoch) → RFC3339 UTC with microseconds.
pub fn writeTimestamp(w: *std.Io.Writer, ts_us: i64) !void {
    const unix_us = ts_us + pg_epoch_unix_us;
    const secs = @divFloor(unix_us, 1_000_000);
    const micros: u32 = @intCast(@mod(unix_us, 1_000_000));
    const days = @divFloor(secs, 86_400);
    const day_secs: u32 = @intCast(@mod(secs, 86_400));
    const civil = civilFromDays(days);
    const year: u32 = @intCast(@max(civil.year, 0)); // {d:0>4} prints '+' for signed
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z", .{
        year,            civil.month,            civil.day,
        day_secs / 3600, (day_secs % 3600) / 60, day_secs % 60,
        micros,
    });
}

/// Howard Hinnant's civil_from_days; valid for the whole TimestampTz range.
fn civilFromDays(z_in: i64) struct { year: i64, month: u32, day: u32 } {
    const z = z_in + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    const year_full = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day_num = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month_num = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (month_num <= 2) year_full + 1 else year_full, .month = @intCast(month_num), .day = @intCast(day_num) };
}

/// ErrorData.sqlerrcode is the MAKE_SQL_STATE-packed form (char j in bits 6j),
/// not the numeric SQLSTATE; unpack to the canonical 5-char string "22012".
fn sqlState(code: i32) [5]u8 {
    const bits: u32 = @bitCast(code);
    var out: [5]u8 = undefined;
    for (&out, 0..) |*ch, j| ch.* = @intCast('0' + ((bits >> (6 * @as(u5, @intCast(j)))) & 0x3F));
    return out;
}

/// elevel constants are stable across PG15-18 (utils/elog.h).
pub fn levelName(elevel: i32) []const u8 {
    return switch (elevel) {
        10 => "DEBUG5",
        11 => "DEBUG4",
        12 => "DEBUG3",
        13 => "DEBUG2",
        14 => "DEBUG1",
        15 => "LOG",
        16 => "LOG_SERVER_ONLY",
        17 => "INFO",
        18 => "NOTICE",
        19 => "WARNING",
        20 => "WARNING_CLIENT_ONLY",
        21 => "ERROR",
        22 => "FATAL",
        23 => "PANIC",
        else => "UNKNOWN",
    };
}

test "invalid utf-8 bytes sanitize to U+FFFD, line stays valid JSON" {
    // The live case: a COPY/encoding error quotes the offending raw bytes
    // into DETAIL ("invalid byte sequence ... : 0x80" with the byte itself).
    var entry = std.mem.zeroes(ring.ShmLogEntry);
    entry.seq = 1;
    entry.elevel = 19;
    // 0x80 (stray continuation), \xC3\x28 (broken 2-byte), 'a\xED\xA0\x80z'
    // (surrogate pair) — all invalid; valid ASCII and a valid 2-byte 'é'
    // around them must pass through untouched.
    ring.setStr(&entry.message, &entry.truncated_mask, .message, "a\x80b\xC3\x28 \xC3\xA9 \xED\xA0\x80");

    var line_w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_w.deinit();
    try writeEntry(&line_w.writer, &entry, .{});
    const line = line_w.written();

    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(std.mem.indexOf(u8, line, "\u{FFFD}") != null);
    // valid sequences survive: é (U+00E9) not replaced
    try std.testing.expect(std.mem.indexOf(u8, line, "\xC3\xA9") != null);
    // structural sanity: control chars would be escaped by encodeJsonStringChars
    try std.testing.expect(std.mem.indexOf(u8, line, "\n") == null);
}

test "control characters in message escape correctly" {
    var entry = std.mem.zeroes(ring.ShmLogEntry);
    entry.seq = 2;
    entry.elevel = 19;
    ring.setStr(&entry.message, &entry.truncated_mask, .message, "tab\tquote\"nl\n\x00");

    var line_w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_w.deinit();
    try writeEntry(&line_w.writer, &entry, .{});
    const line = line_w.written();

    // still one line: no raw \n or \0 anywhere, quotes escaped
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0) == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\\\"") != null);
    try std.testing.expect(try std.json.validate(std.testing.allocator, line));
}

test "timestamp formatting" {
    var tbuf: [40]u8 = undefined;
    var fixed_w = std.Io.Writer.fixed(&tbuf);
    // 845s after PG epoch → 2000-01-01T00:14:05.000001Z
    try writeTimestamp(&fixed_w, 845_000_001);
    try std.testing.expectEqualStrings("2000-01-01T00:14:05.000001Z", fixed_w.buffered());
}

test "timestamp across leap day" {
    var tbuf: [40]u8 = undefined;
    var fixed_w = std.Io.Writer.fixed(&tbuf);
    // unix 2024-02-29T12:00:00Z = 1709208000s → PG ts = unix - 946684800s
    try writeTimestamp(&fixed_w, (1709208000 - 946684800) * 1_000_000);
    try std.testing.expectEqualStrings("2024-02-29T12:00:00.000000Z", fixed_w.buffered());
}

test "sqlstate unpacking" {
    // Real capture of SELECT 1/0: ErrorData.sqlerrcode = MAKE_SQL_STATE("22012").
    try std.testing.expectEqualStrings("22012", &sqlState(33816706));
    try std.testing.expectEqualStrings("23505", &sqlState(83906754));
    try std.testing.expectEqualStrings("00000", &sqlState(0));
}

test "full entry json" {
    var entry = std.mem.zeroes(ring.ShmLogEntry);
    entry.seq = 184;
    entry.timestamp_us = 845_000_001;
    entry.elevel = 21;
    entry.sqlerrcode = 83906754; // MAKE_SQL_STATE packing of "23505"
    entry.lineno = 671;
    entry.pid = 12345;
    entry.db_oid = 16384;
    entry.role_oid = 10;
    ring.setStr(&entry.message, &entry.truncated_mask, .message, "duplicate key \"x\"");
    ring.setStr(&entry.filename, &entry.truncated_mask, .filename, "nbtinsert.c");
    ring.setStr(&entry.funcname, &entry.truncated_mask, .funcname, "_bt_check_unique");
    ring.setStr(&entry.backend_type, &entry.truncated_mask, .backend_type, "client backend");
    ring.setStr(&entry.app, &entry.truncated_mask, .app, "pgbench");
    ring.setStr(&entry.client_host, &entry.truncated_mask, .client_host, "10.0.0.7");

    var line_w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line_w.deinit();
    source_host = "pg1.example";
    source_cluster = "prod-main";
    defer {
        source_host = "";
        source_cluster = "";
    }
    try writeEntry(&line_w.writer, &entry, .{ .database = "mydb", .user = "app" });
    const got = line_w.written();

    try std.testing.expect(std.mem.find(u8, got, "\"host\":\"pg1.example\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"cluster\":\"prod-main\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"pgdata\":null") != null); // unset → null
    try std.testing.expect(std.mem.find(u8, got, "\"level\":\"ERROR\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"sqlerrcode\":\"23505\"") != null); // unpacked from packed form
    try std.testing.expect(std.mem.find(u8, got, "\\\"x\\\"") != null); // escaped quotes
    try std.testing.expect(std.mem.find(u8, got, "\"database\":\"mydb\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"detail\":null") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"backend_type\":\"client backend\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"app\":\"pgbench\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"client_host\":\"10.0.0.7\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"truncated\":[]") != null);
    // The whole line must be valid JSON — Vector rejects it otherwise.
    try std.testing.expect(try std.json.validate(std.testing.allocator, got));
}
