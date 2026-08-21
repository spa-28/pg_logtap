//! Export background worker (one per cluster): drains the ring and pushes
//! JSON lines to http/tcp/file. Unsent events retry from a worker-local
//! backlog bounded by ring capacity (oldest dropped, counted in `lost`).
//! IO is plain blocking libc — the right shape for a bgworker loop.
const std = @import("std");

const pg = @import("pgzx").c;
const bgworker = @import("pgzx").bgworker;
const interrupts = @import("pgzx").intr;
const elog = @import("pgzx").elog;
const ring = @import("ring.zig");
const jsonl = @import("jsonl.zig");
const capture = @import("capture.zig");
const dest_mod = @import("export.zig");
const gzip = @import("gzip.zig");
const metrics = @import("metrics.zig");

/// libc socket/open wrappers: stable, boring, no std.Io plumbing.
const c = struct {
    extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
    extern "c" fn close(conn_fd: c_int) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn accept4(conn_fd: c_int, addr: ?*anyopaque, len: ?*u32, flags: c_int) c_int;
    extern "c" fn gethostname(name: [*]u8, len: usize) c_int;
};
const net = std.c;

const chunk_max = 256; // events per request / file write
const drain_batch = 64; // popped per lock round; stack-sized

var guc_export_url: [*c]u8 = null;
var guc_export_gzip: bool = false;
var guc_flush_interval: c_int = 1000;
var guc_metrics_port: c_int = 0;

var got_sigterm = interrupts.Signal.new(0);
var got_sighup = interrupts.Signal.new(0);

pub fn init() void {
    pg.DefineCustomStringVariable("pg_logtap.export_url", "http://host:port[/path] | tcp://host:port | file:///path; empty = no export worker (restart applies).", null, &guc_export_url, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomBoolVariable("pg_logtap.export_gzip", "Compress http:// export batches (Content-Encoding: gzip). Receiver must accept gzipped request bodies: Vector http_server, VictoriaLogs, Fluent Bit http and Logstash http inputs do; a plain custom endpoint may not.", null, &guc_export_gzip, false, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.flush_interval", "Drain-and-flush interval in milliseconds.", null, &guc_flush_interval, 1000, 10, 3_600_000, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.metrics_port", "TCP port for Prometheus /metrics and /healthz; 0 = off. Applied on reload.", null, &guc_metrics_port, 0, 0, 65535, pg.PGC_SIGHUP, 0, null, null, null);
    // Registered unconditionally: custom-variable values from postgresql.conf
    // are not visible yet in _PG_init, so we cannot decide here. With an empty
    // URL the worker just sleeps on its latch (no drain, no export).
    bgworker.register("pg_logtap exporter", "pg_logtap", "pg_logtap_worker", .{
        .flags = pg.BGWORKER_SHMEM_ACCESS | pg.BGWORKER_BACKEND_DATABASE_CONNECTION,
        .start_time = pg.BgWorkerStart_RecoveryFinished,
        .restart_time = 1,
    });
}

pub fn workerMain() void {
    // port.h renames pqsignal to pqsignal_be for the backend build (PG18+).
    if (comptime pg.PG_VERSION_NUM >= 180000) {
        pg.pqsignal_be(@intFromEnum(std.posix.SIG.TERM), handleTerm);
        pg.pqsignal_be(@intFromEnum(std.posix.SIG.HUP), handleHup);
    } else {
        _ = pg.pqsignal(@intFromEnum(std.posix.SIG.TERM), handleTerm);
        _ = pg.pqsignal(@intFromEnum(std.posix.SIG.HUP), handleHup);
    }
    // Catalog access for database/user name resolution.
    pg.BackgroundWorkerInitializeConnection("postgres", null, 0);
    pg.BackgroundWorkerUnblockSignals();

    const alloc = std.heap.c_allocator;
    var pending: std.ArrayList(ring.ShmLogEntry) = .empty;
    defer pending.deinit(alloc);
    var names = NameCache{};
    syncMetricsListener();
    refreshSourceId();

    while (!got_sigterm.isSet()) {
        pg.ResetLatch(pg.MyLatch);
        if (got_sighup.isSet()) {
            got_sighup.clear();
            pg.ProcessConfigFile(pg.PGC_SIGHUP);
            syncMetricsListener();
            refreshSourceId();
        }
        flushAll(alloc, &pending, &names);
        scrapeAll();
        _ = pg.WaitLatch(pg.MyLatch, pg.WL_LATCH_SET | pg.WL_TIMEOUT | pg.WL_EXIT_ON_PM_DEATH, @intCast(guc_flush_interval), 0);
    }
    flushAll(alloc, &pending, &names); // graceful shutdown: hand off what we can
    pg.proc_exit(0);
}

/// One cycle: interleave ring drains with chunk pushes. A slow POST no longer
/// lets the ring fill up mid-cycle — the backlog absorbs the burst instead.
fn flushAll(alloc: std.mem.Allocator, pending: *std.ArrayList(ring.ShmLogEntry), names: *NameCache) void {
    if (guc_export_url == null or guc_export_url[0] == 0) return;
    const url = std.mem.span(@as([*:0]const u8, @ptrCast(guc_export_url)));
    const dest = dest_mod.parseUrl(url) orelse {
        warnUrlOnce(url);
        return;
    };

    var exported: u64 = 0;
    var failed: u64 = 0;
    var lost: u64 = 0;
    var gzip_buf: ?[]u8 = null; // reused across chunks, freed on cycle exit
    defer if (gzip_buf) |z| alloc.free(z);
    while (!got_sigterm.isSet()) {
        drainInto(alloc, pending);
        lost += trimBacklog(pending); // bounded RAM even when inflow outruns sending
        if (pending.items.len == 0) break;
        const count = @min(pending.items.len, chunk_max);
        var body_w: std.Io.Writer.Allocating = .init(alloc);
        defer body_w.deinit();
        for (pending.items[0..count]) |*e| {
            jsonl.writeEntry(&body_w.writer, e, names.lookup(e)) catch break;
            body_w.writer.writeByte('\n') catch break;
        }
        if (gzip_buf) |z| { // previous chunk's compressed body
            alloc.free(z);
            gzip_buf = null;
        }
        const gz = gzipPayload(alloc, dest, body_w.written(), &gzip_buf);
        if (send(dest, url, gz.payload, gz.on)) {
            dropFront(pending, count);
            exported += count;
        } else {
            failed += 1; // counts failed flush CYCLES, not events (A8: no double counting)
            break; // retry the backlog next cycle
        }
    }

    capture.bumpExport(exported, failed, lost);
    logTransitions(exported, failed, lost);
}

/// Ring → backlog. OOM counts the drained events as lost (ring is already drained).
fn drainInto(alloc: std.mem.Allocator, pending: *std.ArrayList(ring.ShmLogEntry)) void {
    var batch: [drain_batch]ring.ShmLogEntry = undefined;
    while (true) {
        const count = capture.drainBatch(&batch);
        if (count == 0) return;
        pending.appendSlice(alloc, batch[0..count]) catch {
            capture.bumpExport(0, 0, count);
            return;
        };
    }
}

/// Backlog bound: keep the newest ring_capacity events, return what fell off.
fn trimBacklog(pending: *std.ArrayList(ring.ShmLogEntry)) u64 {
    if (pending.items.len <= capture.capacity()) return 0;
    const lost: u64 = pending.items.len - capture.capacity();
    dropFront(pending, lost);
    return lost;
}

fn dropFront(list: *std.ArrayList(ring.ShmLogEntry), count: usize) void {
    const rest = list.items.len - count;
    std.mem.copyForwards(ring.ShmLogEntry, list.items[0..rest], list.items[count..]);
    list.items.len = rest;
}

// --- failures in the server log: on transition only, not every cycle ----------

var was_failing = false;

fn logTransitions(exported: u64, failed: u64, lost: u64) void {
    if (failed > 0 and !was_failing) {
        elog.Log(@src(), "pg_logtap export failing ({s}), events buffered (pending retry)", .{fail_reason});
    } else if (failed == 0 and was_failing) {
        elog.Log(@src(), "pg_logtap export recovered, exported={d} lost_total_logged={d}", .{ exported, lost });
    }
    was_failing = failed > 0;
    if (lost > 0) elog.Log(@src(), "pg_logtap backlog overflow: {d} events lost", .{lost});
}

var warned_url: bool = false;

fn warnUrlOnce(url: []const u8) void {
    if (warned_url) return;
    warned_url = true;
    elog.Log(@src(), "pg_logtap.export_url unparseable, export disabled until fixed: {s}", .{url});
}

// --- source identity (multi-host → one Vector): stamped into every event ------

/// hostname and pgdata never change; cluster_name is SIGHUP-able, hence the
/// refresh on reload. ponytail: leaks ~50 bytes per reload — reloads are rare.
fn refreshSourceId() void {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0);
    if (c.gethostname(&buf, buf.len - 1) == 0) {
        jsonl.source_host = std.heap.c_allocator.dupe(u8, std.mem.sliceTo(&buf, 0)) catch "";
    }
    jsonl.source_cluster = gucStr("cluster_name");
    jsonl.source_pgdata = gucStr("data_directory");
}

fn gucStr(name: [:0]const u8) []const u8 {
    const val = pg.GetConfigOption(name.ptr, true, false);
    if (val == null) return "";
    return std.heap.c_allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(val)))) catch "";
}

// --- oid → name cache (catalog lookups under one short transaction) -----------

const NameCache = struct {
    dbs: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .{},
    users: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .{},
    // Entries are never evicted: a cluster has a handful of oids. ponytail:
    // unbounded on oid churn (db create/drop storm) — add eviction if that bites.

    fn lookup(self: *NameCache, e: *const ring.ShmLogEntry) jsonl.Names {
        if (!self.dbs.contains(e.db_oid) or !self.users.contains(e.role_oid)) self.fill(e);
        return .{
            .database = self.dbs.get(e.db_oid) orelse null,
            .user = self.users.get(e.role_oid) orelse null,
        };
    }

    fn fill(self: *NameCache, e: *const ring.ShmLogEntry) void {
        const alloc = std.heap.c_allocator;
        pg.SetCurrentStatementStartTimestamp();
        pg.StartTransactionCommand();
        defer pg.CommitTransactionCommand();
        if (!self.dbs.contains(e.db_oid)) {
            const name = pg.get_database_name(@intCast(e.db_oid));
            const val: ?[]const u8 = if (name != null) alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name)))) catch null else null;
            self.dbs.put(alloc, e.db_oid, val) catch {};
        }
        if (!self.users.contains(e.role_oid)) {
            const name = pg.GetUserNameFromId(@intCast(e.role_oid), true);
            const val: ?[]const u8 = if (name != null) alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name)))) catch null else null;
            self.users.put(alloc, e.role_oid, val) catch {};
        }
    }
};

// --- senders -------------------------------------------------------------------

/// gzip the batch for the http destination when export_gzip is on; plain
/// bytes otherwise. OOM falls back to plain — compression is an
/// optimization, not a guarantee.
fn gzipPayload(alloc: std.mem.Allocator, dest: dest_mod.Dest, body: []const u8, out: *?[]u8) struct { payload: []const u8, on: bool } {
    if (!guc_export_gzip or dest != .http) return .{ .payload = body, .on = false };
    out.* = gzip.compress(alloc, body) catch return .{ .payload = body, .on = false };
    return .{ .payload = out.*.?, .on = true };
}

fn send(dest: dest_mod.Dest, url: []const u8, body: []const u8, gz: bool) bool {
    _ = url;
    return switch (dest) {
        .http => |h| sendHttp(h, body, gz),
        .tcp => |t| sendRaw(dialTcp(t.host, t.port), body),
        .file => |path| sendFile(path, body),
    };
}

fn sendHttp(h: anytype, body: []const u8, gz: bool) bool {
    const conn_fd = dialTcp(h.host, h.port) orelse return failSend("dial", 0);
    defer _ = c.close(conn_fd);
    var head_buf: [512]u8 = undefined;
    var head = std.Io.Writer.fixed(&head_buf);
    head.print("POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/x-ndjson\r\n", .{ h.path, h.host, h.port }) catch return failSend("head build", 0);
    if (gz) head.writeAll("Content-Encoding: gzip\r\n") catch return failSend("head build", 0);
    head.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return failSend("head build", 0);
    if (!writeAll(conn_fd, head.buffered())) return failSend("write head", std.c._errno().*);
    if (!writeAll(conn_fd, body)) return failSend("write body", std.c._errno().*);
    // Status line is enough: "HTTP/1.1 200 ..." — 2xx accepted, anything else retries.
    var status_buf: [32]u8 = undefined;
    const got = recvSome(conn_fd, &status_buf);
    if (got < 12) return failSend("status read", std.c._errno().*);
    if (!std.mem.startsWith(u8, status_buf[0..got], "HTTP/1.") or status_buf[9] != '2') {
        return failSend("status code", @as(c_int, status_buf[9]));
    }
    return true;
}

fn sendRaw(fd_opt: ?c_int, body: []const u8) bool {
    const conn_fd = fd_opt orelse return failSend("dial", 0);
    defer _ = c.close(conn_fd);
    if (!writeAll(conn_fd, body)) return failSend("write body", std.c._errno().*);
    return true;
}

fn sendFile(path: []const u8, body: []const u8) bool {
    if (path.len >= 4096) return false;
    var pbuf: [4096]u8 = undefined;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    // O_WRONLY|O_CREAT|O_APPEND (Linux), 0600: export file must not be world-readable (C2).
    const conn_fd = c.open(@ptrCast(&pbuf), 1 | 64 | 512, @as(c_uint, 0o600));
    if (conn_fd < 0) return false;
    defer _ = c.close(conn_fd);
    return writeAll(conn_fd, body);
}

/// getaddrinfo + first connectable address; hostnames and IPv4 literals.
fn dialTcp(host: []const u8, port: u16) ?c_int {
    if (host.len >= 256) {
        _ = failSend("host too long", 0);
        return null;
    }
    var host_buf: [256]u8 = undefined;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{port}, 0) catch return null;

    var hints = std.mem.zeroes(net.addrinfo);
    hints.family = 0; // AF_UNSPEC: IPv4 or IPv6
    hints.socktype = 1; // SOCK_STREAM
    var res: ?*net.addrinfo = null;
    if (@intFromEnum(net.getaddrinfo(@ptrCast(&host_buf), port_str.ptr, &hints, &res)) != 0) {
        _ = failSend("dns", 0);
        return null;
    }
    defer if (res) |r| net.freeaddrinfo(r);

    var it = res;
    while (it) |ai| : (it = ai.next) {
        const conn_fd = c.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
        if (conn_fd < 0) continue;
        if (net.connect(conn_fd, ai.addr.?, ai.addrlen) == 0) return conn_fd;
        const err = std.c._errno().*;
        _ = c.close(conn_fd);
        _ = failSend("connect", err);
    }
    return null;
}

/// Remember why the last send failed; surfaces in the transition log line.
fn failSend(stage: []const u8, err: c_int) bool {
    fail_reason = std.fmt.bufPrint(&fail_reason_buf, "{s} errno={d}", .{ stage, err }) catch stage;
    return false;
}

var fail_reason_buf: [64]u8 = undefined;
var fail_reason: []const u8 = "";

fn writeAll(conn_fd: c_int, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        // write(2): works for both sockets and regular files (send does not).
        const count = net.write(conn_fd, buf.ptr + off, buf.len - off);
        if (count > 0) {
            off += @intCast(count);
        } else if (count == -1 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) {
            continue; // EINTR is legal here even with SA_RESTART handlers
        } else return false;
    }
    return true;
}

fn recvSome(conn_fd: c_int, buf: []u8) usize {
    const count = net.recv(conn_fd, buf.ptr, buf.len, 0);
    return if (count > 0) @intCast(count) else 0;
}

// --- Prometheus /metrics (M4): scrapes served from the worker loop, no threads --

var metrics_fd: c_int = -1;
var metrics_port_open: c_int = -1; // port the socket currently reflects

/// (Re)open the listening socket when the configured port changed (SIGHUP).
fn syncMetricsListener() void {
    if (metrics_port_open == guc_metrics_port) return;
    metrics_port_open = guc_metrics_port;
    if (metrics_fd >= 0) {
        _ = c.close(metrics_fd);
        metrics_fd = -1;
    }
    if (guc_metrics_port <= 0) return;
    metrics_fd = listenOn(@intCast(guc_metrics_port)) orelse {
        elog.Log(@src(), "pg_logtap.metrics_port {d} failed to listen, metrics disabled", .{guc_metrics_port});
        return;
    };
    elog.Log(@src(), "pg_logtap metrics serving /metrics and /healthz on port {d}", .{guc_metrics_port});
}

fn listenOn(port: u16) ?c_int {
    const listen_fd = c.socket(2, 1 | 2048, 0); // AF_INET, SOCK_STREAM|SOCK_NONBLOCK
    if (listen_fd < 0) return null;
    const one: c_int = 1;
    _ = net.setsockopt(listen_fd, 1, 2, &one, @sizeOf(c_int)); // SOL_SOCKET, SO_REUSEADDR
    var addr = std.mem.zeroes(net.sockaddr.in);
    addr.family = 2; // AF_INET
    addr.port = std.mem.nativeToBig(u16, port);
    if (net.bind(listen_fd, @ptrCast(&addr), @sizeOf(net.sockaddr.in)) != 0 or net.listen(listen_fd, 8) != 0) {
        _ = c.close(listen_fd);
        return null;
    }
    return listen_fd;
}

/// Serve every queued scrape, then return to the main loop.
fn scrapeAll() void {
    if (metrics_fd < 0) return;
    while (true) {
        const conn_fd = c.accept4(metrics_fd, null, null, 2048); // SOCK_NONBLOCK
        if (conn_fd < 0) return; // EAGAIN: backlog empty
        defer _ = c.close(conn_fd);
        serveOne(conn_fd);
    }
}

fn serveOne(conn_fd: c_int) void {
    // The scraper sends its request right after connect; wait briefly for it.
    var poll_fds = [1]net.pollfd{.{ .fd = conn_fd, .events = 1, .revents = 0 }}; // POLLIN
    if (net.poll(&poll_fds, 1, 100) <= 0) return;
    var req_buf: [512]u8 = undefined;
    const got = recvSome(conn_fd, &req_buf);
    if (got == 0) return;
    var resp_buf: [4096]u8 = undefined;
    var resp_w = std.Io.Writer.fixed(&resp_buf);
    metrics.writeResponse(&resp_w, req_buf[0..got], capture.snapshot()) catch return;
    _ = writeAll(conn_fd, resp_w.buffered());
}

// --- signals -------------------------------------------------------------------

fn handleTerm(sig: c_int) callconv(.c) void {
    _ = sig;
    got_sigterm.set(1);
    if (pg.MyLatch != null) pg.SetLatch(pg.MyLatch);
}

fn handleHup(sig: c_int) callconv(.c) void {
    _ = sig;
    got_sighup.set(1);
    if (pg.MyLatch != null) pg.SetLatch(pg.MyLatch);
}
