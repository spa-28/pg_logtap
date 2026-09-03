//! Prometheus text endpoint for the export worker (plan §M4): /metrics,
//! /healthz. Pure module — the worker does the socket IO.
const std = @import("std");

const ring = @import("ring.zig");

/// Response body ceiling: sized with every counter rendered at its u64
/// widest (20 digits) — the "metrics body fits" test below pins that, and a
/// new metric that breaks it must raise this. Callers serving the response
/// need body_cap + 512 for the status line and headers on top.
pub const body_cap = 4096;

/// Full HTTP/1.1 response for one scraped request line ("GET /metrics HTTP/1.1").
pub fn writeResponse(w: *std.Io.Writer, request_line: []const u8, snap: ring.Stats) !void {
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse "";
    const path = parts.next() orelse "";

    var body_buf: [body_cap]u8 = undefined;
    var body_w = std.Io.Writer.fixed(&body_buf);
    var is_ok = true;
    if (!std.mem.eql(u8, method, "GET")) {
        is_ok = false;
        try body_w.writeAll("method not allowed\n");
    } else if (std.mem.eql(u8, path, "/healthz")) {
        try body_w.writeAll("ok\n");
    } else if (std.mem.eql(u8, path, "/metrics")) {
        try writeBody(&body_w, snap);
    } else {
        is_ok = false;
        try body_w.writeAll("not found\n");
    }

    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        @as(u32, if (is_ok) 200 else 404),
        if (is_ok) "OK" else "Not Found",
        body_w.buffered().len,
    });
    try w.writeAll(body_w.buffered());
}

/// Exposition format 0.0.4; counters end in _total by convention.
fn writeBody(w: *std.Io.Writer, snap: ring.Stats) !void {
    try w.print(
        \\# HELP pg_logtap_events_captured_total Log events captured into the ring.
        \\# TYPE pg_logtap_events_captured_total counter
        \\pg_logtap_events_captured_total {d}
        \\# HELP pg_logtap_events_dropped_total Events dropped because the ring was full.
        \\# TYPE pg_logtap_events_dropped_total counter
        \\pg_logtap_events_dropped_total {d}
        \\# HELP pg_logtap_events_sent_total Events delivered by a live send to the export URL.
        \\# TYPE pg_logtap_events_sent_total counter
        \\pg_logtap_events_sent_total {d}
        \\# HELP pg_logtap_events_queued_total Events durably appended to the fallback file. Stuck in the queue right now = events_queued - events_replayed - events_compacted.
        \\# TYPE pg_logtap_events_queued_total counter
        \\pg_logtap_events_queued_total {d}
        \\# HELP pg_logtap_events_replayed_total Events delivered out of the fallback file after the receiver recovered.
        \\# TYPE pg_logtap_events_replayed_total counter
        \\pg_logtap_events_replayed_total {d}
        \\# HELP pg_logtap_events_compacted_total Events dropped by the fallback-file cap trim while not yet delivered (also counted in events_lost) — the outage outlasted the queue.
        \\# TYPE pg_logtap_events_compacted_total counter
        \\pg_logtap_events_compacted_total {d}
        \\# HELP pg_logtap_send_cycles_failed_total Failed send attempts — one per flush cycle whose send failed, NOT events. The events are safe (fallback queue / backlog); this is the receiver-down signal.
        \\# TYPE pg_logtap_send_cycles_failed_total counter
        \\pg_logtap_send_cycles_failed_total {d}
        \\# HELP pg_logtap_events_lost_total Events permanently lost: RAM backlog overflow with no fallback file, the fallback_max_mb cap trimming undelivered members (also in events_compacted), or an unreadable fallback member skipped.
        \\# TYPE pg_logtap_events_lost_total counter
        \\pg_logtap_events_lost_total {d}
        \\# HELP pg_logtap_ring_events Events currently waiting in the ring.
        \\# TYPE pg_logtap_ring_events gauge
        \\pg_logtap_ring_events {d}
        \\# HELP pg_logtap_ring_capacity Ring capacity in events.
        \\# TYPE pg_logtap_ring_capacity gauge
        \\pg_logtap_ring_capacity {d}
        \\# HELP pg_logtap_dns_fail_streak Consecutive failed getaddrinfo lookups for the export receiver host; reset by any success. Delivery continues via the last-known-good address while it stays valid.
        \\# TYPE pg_logtap_dns_fail_streak gauge
        \\pg_logtap_dns_fail_streak {d}
        \\# HELP pg_logtap_fallback_broken 1 = the fallback queue file is foreign or corrupt and is neither appended to nor replayed: durability degraded to the RAM backlog bound until the GUC points at a different path or the worker restarts.
        \\# TYPE pg_logtap_fallback_broken gauge
        \\pg_logtap_fallback_broken {d}
        \\# HELP pg_logtap_fb_sync_failures Failed fdatasync calls on the fallback queue, cumulative. Events of such a cycle are in the file but not durable (lost on OS crash, not on postmaster death); the log WARNING is once per failure streak, this counter is not — a growing value is a dying disk.
        \\# TYPE pg_logtap_fb_sync_failures counter
        \\pg_logtap_fb_sync_failures {d}
        \\# HELP pg_logtap_redact_pattern_failed 1 = pg_logtap.redact_pattern did not compile and that redaction layer is OFF (fail-open). The compile error text is in the server log.
        \\# TYPE pg_logtap_redact_pattern_failed gauge
        \\pg_logtap_redact_pattern_failed {d}
        \\
    , .{
        snap.captured,         snap.dropped,               snap.sent,
        snap.queued,           snap.replayed,              snap.compacted,
        snap.send_failed,      snap.export_lost,           snap.count,
        snap.capacity,         snap.dns_fail_streak,       snap.fallback_broken,
        snap.fb_sync_failures, snap.redact_pattern_failed,
    });
}

test "metrics response" {
    var snap = std.mem.zeroes(ring.Stats);
    snap.captured = 7;
    snap.capacity = 1024;
    snap.dns_fail_streak = 12;
    snap.fallback_broken = 1;
    snap.fb_sync_failures = 3;
    snap.redact_pattern_failed = 1;
    var wbuf: [4096]u8 = undefined;
    var resp_w = std.Io.Writer.fixed(&wbuf);
    try writeResponse(&resp_w, "GET /metrics HTTP/1.1", snap);
    const got = resp_w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_events_captured_total 7\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_ring_capacity 1024\n") != null);
    // health gauges render with their values and stay inside the body buffer
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_dns_fail_streak 12\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_fallback_broken 1\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_fb_sync_failures 3\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_redact_pattern_failed 1\n") != null);
    // Content-Length must match the body that actually follows it.
    const hdr_end = std.mem.find(u8, got, "\r\n\r\n").? + 4;
    const cl_idx = std.mem.find(u8, got, "Content-Length: ").? + "Content-Length: ".len;
    const len_end = std.mem.findScalarPos(u8, got, cl_idx, '\r').?;
    try std.testing.expectEqual(hdr_end + try std.fmt.parseInt(usize, got[cl_idx..len_end], 10), got.len);
}

test "metrics body fits with every counter at u64 width" {
    // The structural T11 case: counters can legitimately be 20 digits after
    // a long uptime at high rates. Every field at its type's widest must
    // still render whole into body_cap — and the full response (status line
    // + headers + body) into the worker's body_cap + 512 serve buffer.
    var snap = std.mem.zeroes(ring.Stats);
    snap.captured = 12345678901234567890;
    snap.dropped = 12345678901234567890;
    snap.sent = 12345678901234567890;
    snap.queued = 12345678901234567890;
    snap.replayed = 12345678901234567890;
    snap.compacted = 12345678901234567890;
    snap.send_failed = 12345678901234567890;
    snap.export_lost = 12345678901234567890;
    snap.dns_fail_streak = 4294967295;
    snap.fallback_broken = 255;
    snap.redact_pattern_failed = 255;
    snap.count = 4294967295;
    snap.capacity = 4294967295;
    var wbuf: [body_cap + 512]u8 = undefined;
    var resp_w = std.Io.Writer.fixed(&wbuf);
    try writeResponse(&resp_w, "GET /metrics HTTP/1.1", snap);
    const got = resp_w.buffered();
    // No metric line may be missing (a body overflow would truncate the tail
    // — and today fails the write outright): first, middle and last.
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_events_captured_total 12345678901234567890\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_events_compacted_total 12345678901234567890\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_redact_pattern_failed 255\n") != null);
    // Content-Length must match the body that actually follows it.
    const hdr_end = std.mem.find(u8, got, "\r\n\r\n").? + 4;
    const cl_idx = std.mem.find(u8, got, "Content-Length: ").? + "Content-Length: ".len;
    const len_end = std.mem.findScalarPos(u8, got, cl_idx, '\r').?;
    try std.testing.expectEqual(hdr_end + try std.fmt.parseInt(usize, got[cl_idx..len_end], 10), got.len);
}

test "healthz and unknown path" {
    const snap = std.mem.zeroes(ring.Stats);
    var wbuf: [4096]u8 = undefined;
    var resp_w = std.Io.Writer.fixed(&wbuf);
    try writeResponse(&resp_w, "GET /healthz HTTP/1.1", snap);
    try std.testing.expect(std.mem.find(u8, resp_w.buffered(), "\r\n\r\nok\n") != null);
    var w404 = std.Io.Writer.fixed(&wbuf);
    try writeResponse(&w404, "GET /nope HTTP/1.1", snap);
    try std.testing.expect(std.mem.startsWith(u8, w404.buffered(), "HTTP/1.1 404 Not Found"));
}
