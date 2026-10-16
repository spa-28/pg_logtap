//! Transport gzip for the HTTP exporter (Content-Encoding: gzip). Pure
//! memory: a finished batch is compressed right before send — never on the
//! capture path, never in shared memory. Receiver must decompress request
//! bodies (Vector http_server, VictoriaLogs insert endpoints, Fluent Bit
//! http input, Logstash http input all do; a naive custom endpoint may not).
const std = @import("std");

/// The compressor state is ~256K (struct + window) — above glibc's mmap
/// threshold, so per-call create/destroy costs an mmap/munmap + TLB
/// shootdown on every core (measured as ring drops under a 16-client
/// storm). The worker is single-threaded: keep one for the process life.
var pool: ?struct { window: []u8, comp: *std.compress.flate.Compress } = null;

/// gzip the batch, returning an owned slice. level_1: log text compresses
/// 10-20x even at the cheapest setting, and keeps the worker's CPU low.
pub fn compress(alloc: std.mem.Allocator, body: []const u8) error{ OutOfMemory, WriteFailed }![]u8 {
    // Compress.init asserts an output capacity > 8; .init starts empty.
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    defer out.deinit();
    if (pool == null) {
        const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
        errdefer alloc.free(window);
        const comp = try alloc.create(std.compress.flate.Compress);
        pool = .{ .window = window, .comp = comp };
    }
    pool.?.comp.* = try std.compress.flate.Compress.init(&out.writer, pool.?.window, .gzip, .level_1);
    try pool.?.comp.writer.writeAll(body);
    try pool.?.comp.finish();
    return alloc.dupe(u8, out.written());
}

/// Zig's inflater parses the footer but does not verify it. Check the actual
/// bounded output before trusting any readable lines or event counts.
pub fn validTrailer(body: []const u8, crc: u32, count: u32) bool {
    return std.hash.Crc32.hash(body) == crc and @as(u32, @truncate(body.len)) == count;
}

/// Fixed inflate buffers, retained by the worker after first successful use.
pub const DecoderBuffers = struct {
    window: []u8,
    body_buf: []u8,

    pub fn init(alloc: std.mem.Allocator, body_limit: usize) !DecoderBuffers {
        const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
        errdefer alloc.free(window);
        return .{
            .window = window,
            .body_buf = try alloc.alloc(u8, body_limit),
        };
    }

    pub fn deinit(self: DecoderBuffers, alloc: std.mem.Allocator) void {
        alloc.free(self.body_buf);
        alloc.free(self.window);
    }
};

/// Test hook: the worker keeps the pool for the process life; tests free it
/// so the leak detector sees a clean heap.
pub fn deinitPool(alloc: std.mem.Allocator) void {
    if (pool) |p| {
        alloc.free(p.window);
        alloc.destroy(p.comp);
        pool = null;
    }
}

test "compress frees window when pool creation runs out of memory" {
    try std.testing.expect(pool == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const alloc = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, compress(alloc, "retry"));
    try std.testing.expect(pool == null);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

    failing.fail_index = std.math.maxInt(usize);
    const compressed = try compress(alloc, "retry");
    alloc.free(compressed);
    deinitPool(alloc);
    try std.testing.expect(pool == null);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "DecoderBuffers frees window when body allocation fails and retries" {
    // The arena lets the RED run reclaim an otherwise unreachable window;
    // FailingAllocator's byte counters still expose the ownership leak.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 1 });
    const alloc = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, DecoderBuffers.init(alloc, 4096));
    try std.testing.expectEqual(@as(usize, std.compress.flate.max_window_len), failing.allocated_bytes);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

    failing.fail_index = std.math.maxInt(usize);
    const buffers = try DecoderBuffers.init(alloc, 4096);
    try std.testing.expectEqual(@as(usize, 4096), buffers.body_buf.len);
    buffers.deinit(alloc);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "gzip trailer rejects CRC and ISIZE faults even when inflation succeeds" {
    const alloc = std.testing.allocator;
    defer deinitPool(alloc);
    const plain = "{\"message\":\"verified\"}\n";
    const compressed = try compress(alloc, plain);
    defer alloc.free(compressed);
    const buffers = try DecoderBuffers.init(alloc, plain.len + 64);
    defer buffers.deinit(alloc);

    for ([_]usize{ 0, 8, 4 }) |footer_offset| {
        // Both faults start from the same valid member, never from each other.
        if (footer_offset != 0) compressed[compressed.len - footer_offset] ^= 1;
        defer if (footer_offset != 0) {
            compressed[compressed.len - footer_offset] ^= 1;
        };
        var src: std.Io.Reader = .fixed(compressed);
        var dec = std.compress.flate.Decompress.init(&src, .gzip, buffers.window);
        var body = std.Io.Writer.fixed(buffers.body_buf);
        _ = try dec.reader.streamRemaining(&body);
        try std.testing.expectEqualStrings(plain, body.buffered());
        const footer = dec.container_metadata.gzip;
        try std.testing.expectEqual(footer_offset == 0, validTrailer(body.buffered(), footer.crc, footer.count));
    }
    try std.testing.expect(validTrailer("", 0, 0));
    try std.testing.expect(!validTrailer(plain, std.hash.Crc32.hash(plain), 0));
}

test "gzip roundtrip" {
    const alloc = std.testing.allocator;
    defer deinitPool(alloc);
    const body = "pg_logtap gzip roundtrip line\n" ** 200; // ~6K compressible text

    const packed_body = try compress(alloc, body);
    defer alloc.free(packed_body);
    try std.testing.expect(packed_body.len < body.len / 4); // actually compresses

    var src: std.Io.Reader = .fixed(packed_body);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var dec = std.compress.flate.Decompress.init(&src, .gzip, window);
    // .limited hits StreamTooLong when the output fills it exactly; pad and
    // let expectEqualStrings assert the real size.
    const plain = try dec.reader.allocRemaining(alloc, .limited(body.len + 64));
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(body, plain);
}
