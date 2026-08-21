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
        const comp = try alloc.create(std.compress.flate.Compress);
        pool = .{ .window = window, .comp = comp };
    }
    pool.?.comp.* = try std.compress.flate.Compress.init(&out.writer, pool.?.window, .gzip, .level_1);
    try pool.?.comp.writer.writeAll(body);
    try pool.?.comp.finish();
    return alloc.dupe(u8, out.written());
}

/// Test hook: the worker keeps the pool for the process life; tests free it
/// so the leak detector sees a clean heap.
pub fn deinitPool(alloc: std.mem.Allocator) void {
    if (pool) |p| {
        alloc.free(p.window);
        alloc.destroy(p.comp);
        pool = null;
    }
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
