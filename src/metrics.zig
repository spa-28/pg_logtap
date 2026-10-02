//! Prometheus text endpoint for the export worker (plan §M4): /metrics,
//! /healthz, /livez, /readyz. Pure module — the worker does the socket IO.
const std = @import("std");

const ring = @import("ring.zig");

/// Response body ceiling: sized with every counter rendered at its u64
/// widest (20 digits) — the "metrics body fits" test below pins that, and a
/// new metric that breaks it must raise this. Callers serving the response
/// need body_cap + 512 for the status line and headers on top.
pub const body_cap = 8192;

/// Full HTTP/1.1 response for one scraped request line ("GET /metrics HTTP/1.1").
pub fn writeResponse(w: *std.Io.Writer, request_line: []const u8, snap: ring.Stats, ready: bool) !void {
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse "";
    const path = parts.next() orelse "";

    var body_buf: [body_cap]u8 = undefined;
    var body_w = std.Io.Writer.fixed(&body_buf);
    var status: u32 = 200;
    var reason: []const u8 = "OK";
    if (!std.mem.eql(u8, method, "GET")) {
        status = 405;
        reason = "Method Not Allowed";
        try body_w.writeAll("method not allowed\n");
    } else if (std.mem.eql(u8, path, "/healthz") or std.mem.eql(u8, path, "/livez")) {
        try body_w.writeAll("ok\n");
    } else if (std.mem.eql(u8, path, "/readyz")) {
        if (ready) {
            try body_w.writeAll("ok\n");
        } else {
            status = 503;
            reason = "Service Unavailable";
            try body_w.writeAll("not ready\n");
        }
    } else if (std.mem.eql(u8, path, "/metrics")) {
        try writeBody(&body_w, snap);
    } else {
        status = 404;
        reason = "Not Found";
        try body_w.writeAll("not found\n");
    }

    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        status,
        reason,
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
        \\# HELP pg_logtap_events_queued_total Events appended to the fallback file — a lifecycle stage, not a durability claim (fb_sync_failures names the cycles that are not durable). queue_backlog subtracts replayed, cap-trimmed, and unreadable skipped events.
        \\# TYPE pg_logtap_events_queued_total counter
        \\pg_logtap_events_queued_total {d}
        \\# HELP pg_logtap_events_replayed_total Events delivered out of the fallback file after the receiver recovered.
        \\# TYPE pg_logtap_events_replayed_total counter
        \\pg_logtap_events_replayed_total {d}
        \\# HELP pg_logtap_events_compacted_total Events dropped by the fallback-file cap trim while not yet delivered (also counted in events_lost) — the outage outlasted the queue.
        \\# TYPE pg_logtap_events_compacted_total counter
        \\pg_logtap_events_compacted_total {d}
        \\# HELP pg_logtap_queue_backlog Events remaining in the fallback queue after replay, cap trim, and unreadable counted skips; not ring/RAM events, bytes, or a durability guarantee.
        \\# TYPE pg_logtap_queue_backlog gauge
        \\pg_logtap_queue_backlog {d}
        \\# HELP pg_logtap_send_cycles_failed_total Failed send attempts — one per flush cycle whose send failed, NOT events. The events are safe (fallback queue / backlog); this is the receiver-down signal.
        \\# TYPE pg_logtap_send_cycles_failed_total counter
        \\pg_logtap_send_cycles_failed_total {d}
        \\# HELP pg_logtap_events_lost_total Events permanently lost: RAM backlog overflow with no fallback file, the fallback_max_mb cap trimming undelivered members (also in events_compacted), or an unreadable counted fallback member skipped by its stored fallback count; readable payloads use their NDJSON line count.
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
        \\# HELP pg_logtap_fallback_broken 1 = the fallback queue file is foreign or corrupt and is neither appended to nor replayed: durability degraded to the RAM backlog bound until repaired and securely rechecked by SIGHUP.
        \\# TYPE pg_logtap_fallback_broken gauge
        \\pg_logtap_fallback_broken {d}
        \\# HELP pg_logtap_fb_sync_failures Failed fdatasync calls on the fallback queue, cumulative. Events of such a cycle are in the file but not durable (lost on OS crash, not on postmaster death); the log WARNING is once per failure streak, this counter is not — a growing value is a dying disk. Non-zero is history, not current state: the next successful sync (or a compaction, whose rewrite is fdatasynced before the rename) makes the queue durable again while the counter stays — alert on its growth, not its level.
        \\# TYPE pg_logtap_fb_sync_failures counter
        \\pg_logtap_fb_sync_failures {d}
        \\# HELP pg_logtap_redact_pattern_failed 1 = pg_logtap.redact_pattern unexpectedly failed assign-time compilation; the previous compiled redactor remains active, if one existed. The compile error text is in the server log.
        \\# TYPE pg_logtap_redact_pattern_failed gauge
        \\pg_logtap_redact_pattern_failed {d}
        \\# HELP pg_logtap_warn_tls_no_verify The verify=off WARNING fired (once per worker life): https/tcps export is shipping unauthenticated.
        \\# TYPE pg_logtap_warn_tls_no_verify counter
        \\pg_logtap_warn_tls_no_verify {d}
        \\# HELP pg_logtap_warn_fallback_open The fallback queue could not be opened; fallback_broken also goes 1.
        \\# TYPE pg_logtap_warn_fallback_open counter
        \\pg_logtap_warn_fallback_open {d}
        \\# HELP pg_logtap_warn_fallback_skipped Unreadable counted fallback member observations during boot/reload scans and replay; only replay accounts their events in events_lost.
        \\# TYPE pg_logtap_warn_fallback_skipped counter
        \\pg_logtap_warn_fallback_skipped {d}
        \\# HELP pg_logtap_warn_fallback_unbounded Diverts into an unbounded (fallback_max_mb=0) fallback queue — once per divert, not per append.
        \\# TYPE pg_logtap_warn_fallback_unbounded counter
        \\pg_logtap_warn_fallback_unbounded {d}
        \\
    , .{
        snap.captured,                snap.dropped,            snap.sent,
        snap.queued,                  snap.replayed,           snap.compacted,
        snap.queueBacklog(),          snap.send_failed,        snap.export_lost,
        snap.count,                   snap.capacity,           snap.dns_fail_streak,
        snap.fallback_broken,         snap.fb_sync_failures,   snap.redact_pattern_failed,
        snap.warn_tls_no_verify,      snap.warn_fallback_open, snap.warn_fallback_skipped,
        snap.warn_fallback_unbounded,
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
    snap.warn_tls_no_verify = 1;
    snap.warn_fallback_skipped = 4;
    var wbuf: [body_cap + 512]u8 = undefined;
    var resp_w = std.Io.Writer.fixed(&wbuf);
    try writeResponse(&resp_w, "GET /metrics HTTP/1.1", snap, false);
    const got = resp_w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_events_captured_total 7\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_ring_capacity 1024\n") != null);
    // health gauges render with their values and stay inside the body buffer
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_dns_fail_streak 12\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_fallback_broken 1\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_fb_sync_failures 3\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_redact_pattern_failed 1\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "# HELP pg_logtap_redact_pattern_failed 1 = pg_logtap.redact_pattern unexpectedly failed assign-time compilation; the previous compiled redactor remains active, if one existed.") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_warn_tls_no_verify 1\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "pg_logtap_warn_fallback_skipped 4\n") != null);
    try expectResponseLength(got);
}

test "metrics body fits with every counter at u64 width" {
    // The structural T11 case: counters can legitimately be 20 digits after
    // a long uptime at high rates. Every field at its type's widest must
    // still render whole into body_cap — and the full response (status line
    // + headers + body) into the worker's body_cap + 512 serve buffer.
    var snap = std.mem.zeroes(ring.Stats);
    inline for (@typeInfo(ring.Stats).@"struct".fields) |field| {
        @field(snap, field.name) = std.math.maxInt(field.type);
    }
    var wbuf: [body_cap + 512]u8 = undefined;
    // All lifecycle counters widest, then the derived gauge itself widest.
    for (0..2) |pass| {
        if (pass == 1) {
            snap.replayed = 0;
            snap.compacted = 0;
            snap.queue_discarded = 0;
        }
        var resp_w = std.Io.Writer.fixed(&wbuf);
        try writeResponse(&resp_w, "GET /metrics HTTP/1.1", snap, false);
        const got = resp_w.buffered();
        try std.testing.expect(std.mem.find(u8, got, "pg_logtap_events_captured_total 18446744073709551615\n") != null);
        try std.testing.expect(std.mem.find(u8, got, "pg_logtap_fb_sync_failures 18446744073709551615\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, got, "pg_logtap_warn_fallback_unbounded 18446744073709551615\n"));
        try std.testing.expectEqual(@as(usize, 19), std.mem.count(u8, got, "# TYPE pg_logtap_"));
        const backlog_line = if (pass == 0) "pg_logtap_queue_backlog 0\n" else "pg_logtap_queue_backlog 18446744073709551615\n";
        try std.testing.expect(std.mem.find(u8, got, backlog_line) != null);
        try expectResponseLength(got);
    }
}

test "queue backlog includes replay trim and unreadable counted skips with saturation" {
    const Case = struct { queued: u64, replayed: u64, compacted: u64, discarded: u64, backlog: u64 };
    const max = std.math.maxInt(u64);
    const cases = [_]Case{
        .{ .queued = 70, .replayed = 3, .compacted = 5, .discarded = 56, .backlog = 6 },
        .{ .queued = 10, .replayed = 0, .compacted = 0, .discarded = 0, .backlog = 10 },
        .{ .queued = 0, .replayed = max, .compacted = max, .discarded = max, .backlog = 0 },
        .{ .queued = 10, .replayed = 11, .compacted = 0, .discarded = 0, .backlog = 0 },
        .{ .queued = 10, .replayed = 4, .compacted = 7, .discarded = 0, .backlog = 0 },
        .{ .queued = 10, .replayed = 4, .compacted = 2, .discarded = 5, .backlog = 0 },
        .{ .queued = max, .replayed = max - 1, .compacted = 0, .discarded = 0, .backlog = 1 },
        .{ .queued = max, .replayed = 0, .compacted = 0, .discarded = 0, .backlog = max },
    };
    for (cases) |case| {
        var snap = std.mem.zeroes(ring.Stats);
        snap.queued = case.queued;
        snap.replayed = case.replayed;
        snap.compacted = case.compacted;
        snap.queue_discarded = case.discarded;
        snap.count = 999; // Ring and unrelated loss are not fallback backlog.
        snap.export_lost = max;
        var wbuf: [body_cap + 512]u8 = undefined;
        var resp_w = std.Io.Writer.fixed(&wbuf);
        try writeResponse(&resp_w, "GET /metrics HTTP/1.1", snap, false);
        var line_buf: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "# TYPE pg_logtap_queue_backlog gauge\npg_logtap_queue_backlog {d}\n", .{case.backlog});
        try std.testing.expect(std.mem.find(u8, resp_w.buffered(), line) != null);
        try expectResponseLength(resp_w.buffered());
    }
}

test "liveness readiness and rejected routes" {
    var snap = std.mem.zeroes(ring.Stats);
    snap.queued = 70; // Backlog and broken fallback must not override readiness.
    snap.fallback_broken = 1;
    const Case = struct { request: []const u8, ready: bool, status: []const u8, body: []const u8 };
    const cases = [_]Case{
        .{ .request = "GET /healthz HTTP/1.1", .ready = false, .status = "200 OK", .body = "ok\n" },
        .{ .request = "GET /healthz HTTP/1.1", .ready = true, .status = "200 OK", .body = "ok\n" },
        .{ .request = "GET /livez HTTP/1.1", .ready = false, .status = "200 OK", .body = "ok\n" },
        .{ .request = "GET /livez HTTP/1.1", .ready = true, .status = "200 OK", .body = "ok\n" },
        .{ .request = "GET /readyz HTTP/1.1", .ready = false, .status = "503 Service Unavailable", .body = "not ready\n" },
        .{ .request = "GET /readyz HTTP/1.1", .ready = true, .status = "200 OK", .body = "ok\n" },
        .{ .request = "GET /nope HTTP/1.1", .ready = true, .status = "404 Not Found", .body = "not found\n" },
        .{ .request = "GET /readyz?probe HTTP/1.1", .ready = true, .status = "404 Not Found", .body = "not found\n" },
        .{ .request = "GET", .ready = true, .status = "404 Not Found", .body = "not found\n" },
        .{ .request = "", .ready = true, .status = "405 Method Not Allowed", .body = "method not allowed\n" },
        .{ .request = "POST /metrics HTTP/1.1", .ready = true, .status = "405 Method Not Allowed", .body = "method not allowed\n" },
        .{ .request = "POST /healthz HTTP/1.1", .ready = true, .status = "405 Method Not Allowed", .body = "method not allowed\n" },
        .{ .request = "POST /livez HTTP/1.1", .ready = false, .status = "405 Method Not Allowed", .body = "method not allowed\n" },
        .{ .request = "HEAD /readyz HTTP/1.1", .ready = true, .status = "405 Method Not Allowed", .body = "method not allowed\n" },
    };
    for (cases) |case| {
        var wbuf: [body_cap + 512]u8 = undefined;
        var resp_w = std.Io.Writer.fixed(&wbuf);
        try writeResponse(&resp_w, case.request, snap, case.ready);
        const got = resp_w.buffered();
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 "));
        try std.testing.expect(std.mem.startsWith(u8, got["HTTP/1.1 ".len..], case.status));
        const body = got[std.mem.find(u8, got, "\r\n\r\n").? + 4 ..];
        try std.testing.expectEqualStrings(case.body, body);
        try expectResponseLength(got);
        var short_buf: [1]u8 = undefined;
        var short_w = std.Io.Writer.fixed(&short_buf);
        try std.testing.expectError(error.WriteFailed, writeResponse(&short_w, case.request, snap, case.ready));
    }
}

fn expectResponseLength(got: []const u8) !void {
    const hdr_end = std.mem.find(u8, got, "\r\n\r\n").? + 4;
    const cl_idx = std.mem.find(u8, got, "Content-Length: ").? + "Content-Length: ".len;
    const len_end = std.mem.findScalarPos(u8, got, cl_idx, '\r').?;
    const body_len = try std.fmt.parseInt(usize, got[cl_idx..len_end], 10);
    try std.testing.expectEqual(hdr_end + body_len, got.len);
    try std.testing.expect(body_len <= body_cap);
    try std.testing.expect(got.len <= body_cap + 512);
}
