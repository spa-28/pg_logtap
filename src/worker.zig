//! Export background worker (one per cluster): drains the ring and pushes
//! JSON lines to http/tcp/file. Unsent events retry from a worker-local
//! backlog bounded by ring capacity (oldest dropped, counted in `lost`) —
//! or, with export_fallback_file set, from a compressed on-disk queue that
//! replays once the receiver answers (fb* helpers below).
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
    extern "c" fn fdatasync(fd: c_int) c_int;
    extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64; // SEEK_END=2 → file size
    extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
    extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
    extern "c" fn inet_pton(family: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
};
const net = std.c;

const chunk_max = 256; // events per request / queue member. 1024 measured
// 40% SLOWER under a debug storm: the transient body/member buffers cross
// glibc's mmap threshold and every flush cycle munmaps ~1MB — TLB shootdown
// IPIs tax every core, postgres backends included. 256 keeps allocations on
// the malloc heap and 4x more fdatasyncs cost less than that.
const drain_batch = 64; // popped per lock round; stack-sized

var guc_export_url: [*c]u8 = null;
var guc_cluster_name: [*c]u8 = null;
var guc_export_gzip: bool = false;
var guc_export_fallback_file: [*c]u8 = null;
var guc_flush_interval: c_int = 1000;
var guc_export_timeout_ms: c_int = 5000;
var guc_export_slow_ms: c_int = 250;
var guc_export_backlog_max: c_int = 65_536;
/// Receiver liveness probe: set when a live send answered but took at least
/// export_slow_ms — such a receiver cannot keep up (256 events per slow
/// round trip), so live batches park on the fallback file instead of piling
/// up in the RAM backlog and being trimmed. Cleared by a fast send on the
/// drain path once the receiver recovers.
var receiver_slow = false;
var guc_metrics_port: c_int = 0;
var guc_metrics_addr: [*c]u8 = null;

var got_sigterm = interrupts.Signal.new(0);
var got_sighup = interrupts.Signal.new(0);

pub fn init() void {
    pg.DefineCustomStringVariable("pg_logtap.export_url", "http://host:port[/path] | tcp://host:port | file:///path; empty = no export worker (restart applies).", null, &guc_export_url, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomStringVariable("pg_logtap.cluster_name", "Cluster label stamped into every event's cluster field. Empty = fall back to the server's cluster_name (postmaster GUC, restart-to-change; empty by default).", null, &guc_cluster_name, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomBoolVariable("pg_logtap.export_gzip", "Compress http:// export batches (Content-Encoding: gzip). Receiver must accept gzipped request bodies: Vector http_server, VictoriaLogs, Fluent Bit http and Logstash http inputs do; a plain custom endpoint may not.", null, &guc_export_gzip, false, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomStringVariable("pg_logtap.export_fallback_file", "Path; failed http/tcp batches are appended here as a compressed durable queue (fdatasynced once per flush cycle) and replayed automatically once the receiver answers. Relative resolves against the data directory. Empty = off. See docs/delivery.md.", null, &guc_export_fallback_file, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.flush_interval", "Drain-and-flush interval in milliseconds.", null, &guc_flush_interval, 1000, 10, 3_600_000, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.export_timeout_ms", "connect/send/receive timeout in milliseconds on export sockets. A receiver that accepts the connection but never answers fails the send after this instead of hanging the worker; the batch then retries via the usual backlog/fallback path.", null, &guc_export_timeout_ms, 5000, 100, 600_000, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.export_slow_ms", "A live send that answers but takes at least this many milliseconds means the receiver cannot keep up with capture; while it stays this slow, live batches park on the export_fallback_file (RAM backlog would trim them) until a fast send on the drain path clears the flag. 0 = off (slow receivers lose events per the RAM bound, as before 0.2.1).", null, &guc_export_slow_ms, 250, 0, 600_000, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.export_backlog_max", "Events the RAM backlog may hold before the oldest are trimmed (lost). Absorbs throughput spikes while batches park on the fallback file; sustained parking matches capture, so trimming at this depth means real capacity shortfall, not noise. Ceiling cost ≈ depth × ring slot size (~3.4KB) of RAM, touched only when parking falls behind; released once the backlog drains. Values below the ring capacity are clamped up to it.", null, &guc_export_backlog_max, 65_536, 8192, 16_777_216, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.metrics_port", "TCP port for Prometheus /metrics and /healthz; 0 = off. Applied on reload.", null, &guc_metrics_port, 0, 0, 65535, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomStringVariable("pg_logtap.metrics_addr", "Bind address for the /metrics and /healthz listener, as an IP literal (v4 or v6). Loopback by default — the counters name the host, cluster and data directory, so keep them off the network unless something scrapes them; 0.0.0.0 exposes to every interface.", null, &guc_metrics_addr, "127.0.0.1", pg.PGC_SIGHUP, 0, null, null, null);
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
        pg.pqsignal_be(@intFromEnum(std.posix.SIG.USR1), handleUsr1);
    } else {
        _ = pg.pqsignal(@intFromEnum(std.posix.SIG.TERM), handleTerm);
        _ = pg.pqsignal(@intFromEnum(std.posix.SIG.HUP), handleHup);
        _ = pg.pqsignal(@intFromEnum(std.posix.SIG.USR1), handleUsr1);
    }
    // Catalog access for database/user name resolution.
    pg.BackgroundWorkerInitializeConnection("postgres", null, 0);
    pg.BackgroundWorkerUnblockSignals();

    const alloc = std.heap.c_allocator;
    var pending: Backlog = .{};
    defer pending.deinit(alloc);
    var names = NameCache{};
    capture.setWorkerLatch(); // backends wake this worker on the first event
    syncMetricsListener();
    refreshSourceId();
    fbCreditBacklog(alloc);

    while (!got_sigterm.isSet()) {
        pg.ResetLatch(pg.MyLatch);
        if (got_sighup.isSet()) {
            got_sighup.clear();
            pg.ProcessConfigFile(pg.PGC_SIGHUP);
            syncMetricsListener();
            refreshSourceId();
        }
        // Absorb procsignal barriers (see handleUsr1). Errors here have no
        // better handler than the next cycle — the barrier itself doesn't
        // ereport.
        interrupts.CheckForInterrupts() catch {};
        flushAll(alloc, &pending, &names, false);
        // Return a storm-swollen backlog buffer: parking keeps the ArrayList
        // capacity, so a one-off million-event storm would otherwise pin GiB
        // of RSS for the worker's whole life (measured: 6.6GiB retained).
        if (pending.len() == 0 and pending.list.capacity > 4096) {
            pending.deinit(alloc);
            pending = .{};
        }
        scrapeAll();
        _ = pg.WaitLatch(pg.MyLatch, pg.WL_LATCH_SET | pg.WL_TIMEOUT | pg.WL_EXIT_ON_PM_DEATH, @intCast(guc_flush_interval), 0);
    }
    flushAll(alloc, &pending, &names, true); // graceful shutdown: hand off what we can
    // Exit code 1, not 0: the postmaster treats a zero exit of a static
    // bgworker as "work done, never restart" (rw_terminate), so anything
    // except a postmaster-ordered stop — a stray SIGTERM from an operator,
    // a supervisor — would silently disable export until the next cluster
    // restart. Code 1 is the expected bgworker failure code: restart after
    // bgw_restart_time (1 s), no cluster crash (only death by signal does
    // that). During a real shutdown the postmaster is exiting itself and
    // does not respawn.
    pg.proc_exit(1);
}

/// One cycle: interleave ring drains with chunk pushes. A slow POST no longer
/// lets the ring fill up mid-cycle — the backlog absorbs the burst instead.
/// While the fallback file holds undelivered events it IS the backlog: live
/// events append to it and it drains to the receiver in order.
/// `final` (worker SIGTERM) ignores got_sigterm: the main loop already exited
/// on it, so without this the "graceful shutdown: hand off what we can" call
/// skipped its loop entirely and every clean stop silently dropped the ring
/// contents and the RAM backlog. Still bounded: the 1s cycle deadline plus one
/// send timeout (~export_timeout_ms worst case) with a dead receiver.
fn flushAll(alloc: std.mem.Allocator, pending: *Backlog, names: *NameCache, final: bool) void {
    if (guc_export_url == null or guc_export_url[0] == 0) return;
    const url = std.mem.span(@as([*:0]const u8, @ptrCast(guc_export_url)));
    const dest = dest_mod.parseUrl(url) orelse {
        warnUrlOnce(url);
        return;
    };

    var sent: u64 = 0; // delivered by a live send
    var queued: u64 = 0; // durably appended to the fallback file
    var replayed: u64 = 0; // delivered out of the fallback file
    var failed: u64 = 0;
    var lost: u64 = 0;
    var members: usize = 0; // members sent this cycle — bounded so a long
    // catch-up still returns: counters bump, /metrics gets scraped, the latch
    // honors SIGHUP/TERM. 64 members ≈ 16k events per flush_interval.
    var gzip_buf: ?[]u8 = null; // reused across chunks, freed on cycle exit
    defer if (gzip_buf) |z| alloc.free(z);
    // Bound one flushAll call to ~1s of wall clock. The direct-send branch
    // has no members cap (only the fallback branch does), so a receiver that
    // answers slower than the capture rate keeps this loop running for the
    // whole outage: counters bump, /metrics and SIGHUP handling only happen
    // between flushAll calls — all three froze mid-storm while trims piled
    // up in a local and flushed minutes late. The next cycle resumes 100ms
    // later; a fast receiver still drains a full backlog in one call.
    const cycle_deadline = pg.GetCurrentTimestamp() + 1_000_000; // µs
    var drained_total: usize = 0; // live inflow this flushAll call
    while (final or !got_sigterm.isSet()) {
        if (pg.GetCurrentTimestamp() > cycle_deadline) break;
        drained_total += drainInto(alloc, pending);
        lost += trimBacklog(pending); // bounded RAM even when inflow outruns sending

        if (fbQueued()) {
            // Queued events are older than anything live, so pending joins the
            // queue first — global seq order holds — and the file drains to the
            // receiver one member per iteration (the ring keeps draining through
            // a long catch-up). Parking live events on disk rather than RAM is
            // what makes catch-up lossless when the live rate exceeds the drain
            // rate; logFallback(true) fires only on a failed send, never on
            // these appends — a transition line per append would feed itself
            // back through the hook into the queue, forever.
            var appended = false;
            while (pending.len() > 0) {
                // The park loop obeys the outer loop's disciplines PER CHUNK:
                // under a sustained storm pending never empties, and without
                // these one flushAll call runs for the whole storm — counters,
                // /metrics and SIGHUP freeze, the ring starves (3.7M events
                // dropped at capture in a 7-min 15k/s storm) and the RAM
                // backlog grows GiB-scale because trimBacklog never runs.
                if (pg.GetCurrentTimestamp() > cycle_deadline) break;
                drained_total += drainInto(alloc, pending);
                lost += trimBacklog(pending);
                const count = @min(pending.len(), chunk_max);
                const body = buildBody(bodyWriter(alloc), pending.live()[0..count], names) orelse break;
                if (!fbAppend(alloc, body, false)) { // disk full → RAM-backlog semantics for the rest
                    failed += 1;
                    break;
                }
                pending.dropFront(count);
                queued += count;
                appended = true;
            }
            if (appended) fbFsync();
            // Capture outranks replay: a member send to a slow receiver blocks
            // this loop for hundreds of milliseconds, and at high inflow the
            // ring fills and drops events at capture before the next drain.
            // While the receiver is slow AND this cycle saw any live inflow,
            // park-only: fsync and hand the loop back to drainInto; members
            // resume once inflow quiets or it recovers.
            if (receiver_slow and drained_total > 0) continue;
            const m = fbNextMember(alloc) orelse {
                lost += fb_lost;
                fb_lost = 0;
                failed += @intFromBool(pending.len() > 0); // append failed above
                break;
            };
            lost += fb_lost;
            fb_lost = 0;
            const gz = gzipPayload(alloc, dest, m.body, &gzip_buf);
            const m_sent_at = pg.GetCurrentTimestamp();
            if (send(dest, url, gz.payload, gz.on)) {
                // Drain-path round trip is the receiver liveness probe: a slow
                // answer re-arms the park (receiver_slow), a fast one clears
                // it — this also arms it after a restart into a slow receiver
                // where the live-send probe never ran.
                if (guc_export_slow_ms > 0) receiver_slow = pg.GetCurrentTimestamp() - m_sent_at >= @as(i64, guc_export_slow_ms) * 1000;
                logFallback(false);
                // counted queued at append time; this is its delivery
                replayed += std.mem.countScalar(u8, m.body, '\n');
                fb_offset += m.advance;
                if (fb_offset >= m.size) fbTruncate(); // fully delivered → back to direct sends
                members += 1;
                if (members < 64) continue;
                break; // hand the loop back: counters, metrics, latch
            }
            logFallback(true); // receiver down: divert starts (transition-guarded)
            failed += 1;
            break; // retry the queue next cycle
        }

        if (pending.len() == 0) break;
        const count = @min(pending.len(), chunk_max);
        const body = buildBody(bodyWriter(alloc), pending.live()[0..count], names) orelse break;
        if (receiver_slow and guc_export_slow_ms > 0) {
            // Slow-but-alive receiver (receiver_slow): park coming batches on
            // disk — left live, they pile up in the RAM backlog until trimmed.
            // Same as the failed-send divert below, minus failed: nothing
            // failed; the queue path owns catch-up from the next iteration.
            if (!fbAppend(alloc, body, true)) {
                failed += 1; // disk full → RAM-backlog semantics for the rest
                break;
            }
            logFallback(true);
            pending.dropFront(count);
            queued += count;
            continue;
        }
        const gz = gzipPayload(alloc, dest, body, &gzip_buf);
        const sent_at = pg.GetCurrentTimestamp();
        if (send(dest, url, gz.payload, gz.on)) {
            logFallback(false);
            pending.dropFront(count);
            sent += count;
            // Liveness probe: an answer this slow cannot keep up with capture.
            if (guc_export_slow_ms > 0 and pg.GetCurrentTimestamp() - sent_at >= @as(i64, guc_export_slow_ms) * 1000) receiver_slow = true;
        } else if (fbAppend(alloc, body, true)) {
            logFallback(true);
            pending.dropFront(count);
            queued += count; // durably parked: counted replayed on delivery
            failed += 1; // the send DID fail — without this a diverting storm
            // reports send_cycles_failed=0 (the receiver-down signal) while
            // actively losing events
            break; // return to the main loop: flush counters, serve /metrics
            // and the latch; the queue path (the file is non-empty now) owns
            // catch-up from the next cycle — without the break one flushAll
            // call loops for the whole outage with stats frozen mid-loss
        } else {
            failed += 1; // counts failed flush CYCLES, not events
            break; // retry the backlog next cycle
        }
    }

    capture.bumpExport(sent, queued, replayed, failed, lost);
    logTransitions(sent + replayed, failed, lost);
}

/// pending slice → NDJSON body (one JSON line per event), built in a REUSED
/// buffer: a fresh ~100KB chunk body sits above glibc's mmap threshold, and
/// the per-chunk mmap/munmap + TLB shootdowns stall every core — measured as
/// ring drops under a 16-client storm. The slice is valid until the next call.
/// null = formatting failed (OOM); the caller retries the chunk next cycle.
fn buildBody(w: *std.Io.Writer.Allocating, entries: []const ring.ShmLogEntry, names: *NameCache) ?[]const u8 {
    w.writer.end = 0; // reset, keep capacity
    for (entries) |*e| {
        jsonl.writeEntry(&w.writer, e, names.lookup(e)) catch return null;
        w.writer.writeByte('\n') catch return null;
    }
    return w.writer.buffer[0..w.writer.end];
}

/// Ring → backlog. OOM counts the drained events as lost (ring is already drained).
fn drainInto(alloc: std.mem.Allocator, pending: *Backlog) usize {
    var drained: usize = 0;
    var batch: [drain_batch]ring.ShmLogEntry = undefined;
    while (true) {
        const count = capture.drainBatch(&batch);
        if (count == 0) return drained;
        pending.append(alloc, batch[0..count]) catch {
            capture.bumpExport(0, 0, 0, 0, count);
            return drained;
        };
        drained += count;
    }
}

/// Backlog bound: keep the newest export_backlog_max events, return what fell
/// off. The bound only matters when parking sustains a real deficit — spikes
/// (fsync, scheduler contention) must fit inside it, or events that would park
/// a second later get trimmed; ring_capacity (~0.5s of storm inflow) was that
/// tight, so trim fired in bursts while sustained parking matched inflow.
fn trimBacklog(pending: *Backlog) u64 {
    const cap: usize = @max(guc_export_backlog_max, capture.capacity());
    if (pending.len() <= cap) return 0;
    const lost: u64 = pending.len() - cap;
    pending.dropFront(lost);
    return lost;
}

/// Front-consumable RAM backlog: appended at the tail (ring drains), consumed
/// from the head (chunk parks / sends). dropFront is O(1) — a head index, with
/// the dead prefix compacted inside append once it dominates. The old
/// shift-per-chunk copyForwards moved up to 27MB (8192 × 3.4KB) per 256-event
/// chunk and capped park throughput at ~14k events/s: below storm inflow, so
/// the trim fired continuously and lost events even with the fallback file on.
const Backlog = struct {
    list: std.ArrayList(ring.ShmLogEntry) = .empty,
    head: usize = 0,

    fn len(self: *const Backlog) usize {
        return self.list.items.len - self.head;
    }

    fn live(self: *const Backlog) []ring.ShmLogEntry {
        return self.list.items[self.head..];
    }

    fn append(self: *Backlog, alloc: std.mem.Allocator, items: []const ring.ShmLogEntry) !void {
        if (self.head > 0 and self.head * 2 >= self.list.items.len) {
            const rest = self.list.items.len - self.head;
            std.mem.copyForwards(ring.ShmLogEntry, self.list.items[0..rest], self.list.items[self.head..]);
            self.list.items.len = rest;
            self.head = 0;
        }
        try self.list.appendSlice(alloc, items);
    }

    fn dropFront(self: *Backlog, count: usize) void {
        self.head = @min(self.head + count, self.list.items.len);
    }

    fn deinit(self: *Backlog, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }
};

// --- failures in the server log: on transition only, not every cycle ----------

var was_failing = false;

fn logTransitions(delivered: u64, failed: u64, lost: u64) void {
    if (failed > 0 and !was_failing) {
        elog.Log(@src(), "pg_logtap export failing ({s}), events buffered (pending retry)", .{fail_reason});
    } else if (failed == 0 and was_failing) {
        elog.Log(@src(), "pg_logtap export recovered, delivered={d} lost_total_logged={d}", .{ delivered, lost });
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

/// hostname and pgdata never change; pg_logtap.cluster_name is SIGHUP-able,
/// hence the refresh on reload. ponytail: leaks ~50 bytes per reload — reloads
/// are rare.
fn refreshSourceId() void {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0);
    if (c.gethostname(&buf, buf.len - 1) == 0) {
        jsonl.source_host = std.heap.c_allocator.dupe(u8, std.mem.sliceTo(&buf, 0)) catch "";
    }
    // The override wins; otherwise reuse the server's cluster_name (which is
    // POSTMASTER — restart-to-change, hence this SIGHUP GUC).
    jsonl.source_cluster = gucStr("pg_logtap.cluster_name");
    if (jsonl.source_cluster.len == 0) jsonl.source_cluster = gucStr("cluster_name");
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
/// optimization, not a guarantee. Frees the previous cached payload itself;
/// the caller frees the last one (flushAll's defer).
fn gzipPayload(alloc: std.mem.Allocator, dest: dest_mod.Dest, body: []const u8, out: *?[]u8) struct { payload: []const u8, on: bool } {
    if (!guc_export_gzip or dest != .http) return .{ .payload = body, .on = false };
    if (out.*) |old| alloc.free(old);
    out.* = gzip.compress(alloc, body) catch {
        out.* = null;
        return .{ .payload = body, .on = false };
    };
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

// --- fallback file: compressed durable queue, replayed on recovery ------------
//
// Internal framing, one batch per member: [8-byte magic][u32 LE len][gzip]…
// A crash mid-append leaves a torn tail member — detected by the short read,
// truncated, appends resume at the member boundary. A crash mid-replay loses
// only the in-memory offset: replay restarts from byte 0, so the receiver may
// see duplicates — dedup by (host, seq), the http at-least-once contract.

const fb_magic = "PGLTFB01";
const fb_magic_len = 8;

/// Consumed prefix of the queue (magic + members), worker-local. 0 also means
/// "magic not verified yet".
var fb_offset: u64 = 0;
/// Foreign or corrupt framing — never append to or replay such a file; the
/// RAM backlog takes over until the GUC is repointed or the server restarts.
var fb_broken = false;
/// Members skipped as unreadable (framing intact, gzip damaged) — folded into
/// `lost` by the flush cycle that read them.
var fb_lost: u64 = 0;

var fb_path_buf: [4096]u8 = undefined;
var fb_path_len: usize = 0;

/// Resolve the GUC (relative → data directory, the log_directory convention;
/// the queue belongs with the data). Repointing the GUC orphans the old queue
/// (its events stay on disk for a manual drain) and resets consumer state.
fn fallbackPath() ?[]const u8 {
    if (guc_export_fallback_file == null) return null;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(guc_export_fallback_file)));
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
        fb_offset = 0;
        fb_broken = false;
    }
    return fb_path_buf[0..fb_path_len];
}

fn fbOpen() ?c_int {
    if (fallbackPath() == null) return null;
    // O_RDWR|O_CREAT|O_APPEND (Linux: 2|64|1024) — reads go through pread,
    // immune to the append position. 0600: not world-readable (C2).
    const fd = c.open(@ptrCast(fb_path_buf[0..fb_path_len :0].ptr), 2 | 64 | 1024, @as(c_uint, 0o600));
    return if (fd >= 0) fd else null;
}

fn fbSize(fd: c_int) ?u64 {
    const end = c.lseek(fd, 0, 2); // SEEK_END
    return if (end >= 0) @intCast(end) else null;
}

/// One pread; a regular file returns the full request unless EOF/EINTR-short.
fn fbPread(fd: c_int, buf: []u8, offset: u64) isize {
    return c.pread(fd, buf.ptr, buf.len, @intCast(offset));
}

/// True while the fallback file holds undelivered events — flushAll then
/// routes everything through it to keep global order.
fn fbQueued() bool {
    if (fb_broken or fallbackPath() == null) return false;
    const fd = fbOpen() orelse return false;
    defer _ = c.close(fd);
    const size = fbSize(fd) orelse return false;
    return if (fb_offset == 0) size > fb_magic_len else size > fb_offset;
}

/// Append one batch as a framed gzip member. `sync` fdatasyncs this member;
/// false defers to one fbFsync() per flush cycle — per-member syncs on a
/// WAL-shared disk stall the worker past the ring's drain window (measured:
/// 5k dropped in a 16-client storm). Success = the events left pg_logtap
/// (page cache survives postmaster death; an OS crash loses the unsynced tail).
fn fbAppend(alloc: std.mem.Allocator, body: []const u8, sync: bool) bool {
    if (fb_broken) return false;
    const fd = fbOpen() orelse return false;
    defer _ = c.close(fd);
    const size = fbSize(fd) orelse return false;
    if (size == 0) {
        if (!writeAll(fd, fb_magic)) return false;
    } else {
        var magic: [fb_magic_len]u8 = undefined;
        if (size < fb_magic_len or fbPread(fd, &magic, 0) != fb_magic_len or !std.mem.eql(u8, &magic, fb_magic)) {
            fb_broken = true;
            elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, fallback disabled: {s}", .{fallbackPath() orelse ""});
            return false;
        }
    }
    const gz = gzip.compress(alloc, body) catch return false; // compression failed → RAM backlog retries
    defer alloc.free(gz);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(gz.len), .little);
    if (!writeAll(fd, &len_buf) or !writeAll(fd, gz)) return false;
    return !sync or c.fdatasync(fd) == 0;
}

/// Durability point for a cycle's deferred appends.
fn fbFsync() void {
    if (fb_broken or fallbackPath() == null) return;
    const fd = fbOpen() orelse return;
    defer _ = c.close(fd);
    _ = c.fdatasync(fd);
}

/// One queued batch: decompressed NDJSON, the byte size at read time, and how
/// far fb_offset advances past it. body borrows the reused inflate buffer —
/// valid until the next fbNextMember.
const FbMember = struct { body: []const u8, size: u64, advance: u64 };

// Reused inflate state: the 32K window and the ~100K+ decompressed member
// sit above glibc's mmap threshold — same story as the gzip pool.
var fb_dec: ?struct { window: []u8, body: std.Io.Writer.Allocating } = null;

// Ditto for the NDJSON chunk body (~100K): one for the process life, or every
// flush cycle pays an mmap/munmap.
var fb_body: ?std.Io.Writer.Allocating = null;

fn bodyWriter(alloc: std.mem.Allocator) *std.Io.Writer.Allocating {
    if (fb_body == null) fb_body = .init(alloc);
    return &fb_body.?;
}

/// Read the member at fb_offset. null = nothing replayable right now (drained,
/// torn tail truncated away, unreadable member skipped, or the file is not
/// ours). Torn tail: crash mid-append left a short member — truncated so
/// appends resume at a member boundary.
fn fbNextMember(alloc: std.mem.Allocator) ?FbMember {
    if (fb_broken) return null;
    const fd = fbOpen() orelse return null;
    defer _ = c.close(fd);
    const size = fbSize(fd) orelse return null;
    if (fb_offset == 0) {
        if (size <= fb_magic_len) return null;
        var magic: [fb_magic_len]u8 = undefined;
        if (fbPread(fd, &magic, 0) != fb_magic_len or !std.mem.eql(u8, &magic, fb_magic)) {
            fb_broken = true;
            elog.Log(@src(), "pg_logtap fallback file is not a pg_logtap queue, replay disabled: {s}", .{fallbackPath() orelse ""});
            return null;
        }
        fb_offset = fb_magic_len;
    }
    if (fb_offset >= size) return null;
    var len_buf: [4]u8 = undefined;
    if (fbPread(fd, &len_buf, fb_offset) != 4) return null;
    const mlen = std.mem.readInt(u32, &len_buf, .little);
    if (mlen == 0 or mlen > 512 * 1024 * 1024) {
        fb_broken = true;
        elog.Log(@src(), "pg_logtap fallback framing corrupt at offset {d}, replay disabled", .{fb_offset});
        return null;
    }
    const gz = alloc.alloc(u8, mlen) catch return null;
    if (fbPread(fd, gz, fb_offset + 4) != mlen) { // torn tail
        alloc.free(gz);
        _ = c.ftruncate(fd, @intCast(fb_offset));
        return null;
    }
    defer alloc.free(gz);
    if (fb_dec == null) fb_dec = .{
        .window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return null,
        .body = .init(alloc),
    };
    const d = &fb_dec.?;
    var src: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&src, .gzip, d.window);
    d.body.writer.end = 0;
    _ = dec.reader.streamRemaining(&d.body.writer) catch {
        const at = fb_offset; // framing is intact: skip past, count as loss
        fb_offset += 4 + mlen;
        fb_lost += 1;
        elog.Log(@src(), "pg_logtap fallback member at offset {d} unreadable, skipped", .{at});
        return null;
    };
    if (d.body.writer.end > mlen * 64 + 65536) { // inflated absurdly: corrupt, skip
        const at = fb_offset;
        fb_offset += 4 + mlen;
        fb_lost += 1;
        elog.Log(@src(), "pg_logtap fallback member at offset {d} inflated past sanity, skipped", .{at});
        return null;
    }
    return .{ .body = d.body.writer.buffer[0..d.body.writer.end], .size = size, .advance = 4 + @as(u64, mlen) };
}

/// Queue fully delivered: zero it (the next append re-creates the magic) and
/// return to direct sends.
fn fbTruncate() void {
    const fd = c.open(@ptrCast(fb_path_buf[0..fb_path_len :0].ptr), 1, @as(c_uint, 0o600)); // O_WRONLY
    if (fd < 0) return;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, 0) == 0) fb_offset = 0;
}

/// The fallback file can outlive the shmem counters: a postmaster restart
/// zeroes queued/replayed/…, the disk queue does not. Credit this epoch's
/// queued with what the file already holds so backlog (queued − replayed)
/// stays a real number and replayed ≤ queued holds. One decompress pass at
/// worker start; fb_offset is restored afterwards — the drain replays from
/// the top as before (at-least-once contract unchanged).
/// A worker restart (postmaster alive, counters intact) must credit nothing:
/// its predecessor already counted every append now in the file, and a
/// re-credit would inflate backlog (queued − replayed) forever — the file
/// draining does not repair a counter difference. Every append this epoch
/// bumped queued, so `file events −| queued` is exactly the uncounted part:
/// zero after a worker restart, the whole file after a postmaster restart.
fn fbCreditBacklog(alloc: std.mem.Allocator) void {
    const saved_offset = fb_offset;
    const saved_lost = fb_lost;
    var lines: u64 = 0;
    while (true) {
        const before = fb_offset;
        const m = fbNextMember(alloc) orelse {
            // null without advancing = drained, torn tail or foreign file;
            // null WITH advancing = unreadable member skipped — keep walking
            if (fb_offset == before) break;
            continue;
        };
        lines += std.mem.countScalar(u8, m.body, '\n');
        fb_offset += m.advance;
    }
    fb_offset = saved_offset;
    fb_lost = saved_lost;
    const due = lines -| capture.snapshot().queued;
    if (due > 0) capture.bumpExport(0, due, 0, 0, 0);
}

/// Fallback on/off transitions only — same discipline as export failures.
var was_fallback = false;

fn logFallback(active: bool) void {
    if (active == was_fallback) return;
    was_fallback = active;
    if (active) {
        elog.Log(@src(), "pg_logtap export diverting batches to fallback file (receiver failing)", .{});
    } else {
        elog.Log(@src(), "pg_logtap fallback closed, receiver delivery resumed", .{});
    }
}

fn sendHttp(h: anytype, body: []const u8, gz: bool) bool {
    // dialTcp has already set the specific reason (dns / connect errno=N);
    // a generic "dial errno=0" here would overwrite it and hide which stage
    // failed.
    const conn_fd = dialTcp(h.host, h.port) orelse return false;
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
    // As sendHttp: the dial path already recorded why it failed.
    const conn_fd = fd_opt orelse return false;
    defer _ = c.close(conn_fd);
    if (!writeAll(conn_fd, body)) return failSend("write body", std.c._errno().*);
    return true;
}

fn sendFile(path: []const u8, body: []const u8) bool {
    if (path.len >= 4096) return false;
    var pbuf: [4096]u8 = undefined;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    // O_WRONLY|O_CREAT|O_APPEND (Linux: 1|64|1024 — 512 is O_TRUNC, which
    // silently keeps only the last batch), 0600: not world-readable (C2).
    const conn_fd = c.open(@ptrCast(&pbuf), 1 | 64 | 1024, @as(c_uint, 0o600));
    if (conn_fd < 0) return false;
    defer _ = c.close(conn_fd);
    if (!writeAll(conn_fd, body)) return false;
    // Durable per batch: the page cache survives process death but not OS
    // death. One fdatasync per flush cycle is cheap next to the write itself.
    return c.fdatasync(conn_fd) == 0;
}

extern fn __res_init() c_int;

var dns_fail_streak: u32 = 0;

/// getaddrinfo + first connectable address; hostnames and IPv4 literals.
/// getaddrinfo is blocking with NO timeout knob — export_timeout_ms bounds
/// only connect/send/recv (set below). A wedged resolver stalls the worker
/// for the resolver's own timeouts (resolv.conf: ~5s × attempts × servers);
/// the failure mode is the same as a dead receiver (ring absorbs, then
/// events_lost), never a permanent hang. IP literals skip resolution.
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
    hints.socktype = 1; // SOCK_STREAM
    var res: ?*net.addrinfo = null;
    // AF_UNSPEC makes glibc query A and AAAA on one resolver socket. Docker's
    // embedded DNS has no AAAA for container names and can fail that half
    // instantly — glibc then reports EAI_AGAIN (-3) for the whole lookup,
    // persistently, while other processes in the same netns resolve fine.
    // EAI_AGAIN is the transient class, so retry with the A family alone
    // before believing it.
    var gai: c_int = 0;
    inline for (.{ 0, 2 }) |fam| { // AF_UNSPEC, then AF_INET
        hints.family = fam;
        gai = @intFromEnum(net.getaddrinfo(@ptrCast(&host_buf), port_str.ptr, &hints, &res));
        if (gai != -3) break;
    }
    if (gai != 0) {
        // The code separates the failure classes: -2 NONAME (name genuinely
        // absent), -3 AGAIN (resolver timeout), -8 MEMORY; -1 SYSTEM parks
        // the real cause in errno — report that instead. The host goes into
        // the reason verbatim: a corrupted slice shows up as garbage here,
        // separating "the name is really gone" from in-process rot.
        const code: c_int = if (gai == -1) std.c._errno().* else gai;
        fail_reason = std.fmt.bufPrint(&fail_reason_buf, "dns errno={d} host='{s}' ({d} bytes)", .{ code, host[0..@min(host.len, 24)], host.len }) catch "dns";
        // glibc's resolver can wedge permanently in this process: a lookup
        // interrupted at the wrong internal moment (the latch's SIGUSR1s are
        // dense exactly while events flow) leaves every later getaddrinfo
        // failing fast with EAI_AGAIN/EAI_NONAME, fresh processes resolve
        // fine. res_init() re-parses resolv.conf and clears the state —
        // harmless while the name is really gone, curative when it wedged.
        dns_fail_streak += 1;
        if (dns_fail_streak == 20) {
            _ = __res_init();
            elog.Log(@src(), "pg_logtap resolver re-initialized after {d} consecutive dns failures", .{dns_fail_streak});
        }
        return null;
    }
    dns_fail_streak = 0;
    defer if (res) |r| net.freeaddrinfo(r);

    var it = res;
    while (it) |ai| : (it = ai.next) {
        const conn_fd = c.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
        if (conn_fd < 0) continue;
        // A silent receiver (accepted connect, never answers; hung LB,
        // black-hole route) must not hang the single worker loop — with no
        // timeout, the status recv blocks forever: drain stops, the ring
        // overflows, /metrics and SIGHUP go unserved. Set before connect:
        // Linux honors SO_SNDTIMEO for connect(2) too. On expiry write/recv
        // return EAGAIN, which flows into the ordinary failSend →
        // retry/fallback path like any dead receiver.
        const tv = Timeval{
            .sec = @intCast(@divTrunc(guc_export_timeout_ms, 1000)),
            .usec = @intCast(@mod(guc_export_timeout_ms, 1000) * 1000),
        };
        _ = net.setsockopt(conn_fd, 1, 20, &tv, @sizeOf(Timeval)); // SOL_SOCKET, SO_RCVTIMEO
        _ = net.setsockopt(conn_fd, 1, 21, &tv, @sizeOf(Timeval)); // SOL_SOCKET, SO_SNDTIMEO
        if (net.connect(conn_fd, ai.addr.?, ai.addrlen) == 0) return conn_fd;
        const err = std.c._errno().*;
        _ = c.close(conn_fd);
        _ = failSend("connect", err);
    }
    return null;
}

/// timeval(3type) for setsockopt: both fields c_long on linux x86-64/arm64.
const Timeval = extern struct { sec: i64, usec: i64 };

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
    while (true) {
        const count = net.recv(conn_fd, buf.ptr, buf.len, 0);
        if (count > 0) return @intCast(count);
        // A signal (SIGUSR1 latch poke, SIGHUP) arriving mid-read is not a
        // receiver fault — retry like writeAll does, or every reload aborts
        // a healthy in-flight request ("status read errno=4").
        if (count == -1 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        return 0; // real fault: EAGAIN (timeout) flows into failSend
    }
}

// --- Prometheus /metrics (M4): scrapes served from the worker loop, no threads --

var metrics_fd: c_int = -1;
var metrics_open_port: c_int = -1; // port the socket currently reflects
var metrics_open_addr_buf: [64]u8 = undefined; // …and the address it reflects
var metrics_open_addr: []const u8 = "";

/// (Re)open the listening socket when port or address changed (SIGHUP).
fn syncMetricsListener() void {
    const addr = if (guc_metrics_addr == null) "" else std.mem.span(@as([*:0]const u8, @ptrCast(guc_metrics_addr)));
    if (metrics_open_port == guc_metrics_port and std.mem.eql(u8, metrics_open_addr, addr)) return;
    metrics_open_port = guc_metrics_port;
    if (addr.len <= metrics_open_addr_buf.len) {
        @memcpy(metrics_open_addr_buf[0..addr.len], addr);
        metrics_open_addr = metrics_open_addr_buf[0..addr.len];
    } else metrics_open_addr = addr; // overlong: listenOn will reject it anyway
    if (metrics_fd >= 0) {
        _ = c.close(metrics_fd);
        metrics_fd = -1;
    }
    if (guc_metrics_port <= 0) return;
    metrics_fd = listenOn(addr, @intCast(guc_metrics_port)) orelse {
        elog.Log(@src(), "pg_logtap.metrics_port {d} on \"{s}\" failed to listen, metrics disabled", .{ guc_metrics_port, addr });
        return;
    };
    elog.Log(@src(), "pg_logtap metrics serving /metrics and /healthz on {s}:{d}", .{ addr, guc_metrics_port });
}

fn listenOn(addr_str: []const u8, port: u16) ?c_int {
    if (addr_str.len >= 64) return null;
    var str_buf: [64]u8 = undefined;
    @memcpy(str_buf[0..addr_str.len], addr_str);
    str_buf[addr_str.len] = 0;
    // inet_pton, not DNS: a bind address is an IP literal or a config error —
    // a name would silently bind to whatever it resolved to at open time.
    var v4 = std.mem.zeroes(net.sockaddr.in);
    v4.family = 2; // AF_INET
    v4.port = std.mem.nativeToBig(u16, port);
    var v6 = std.mem.zeroes(net.sockaddr.in6);
    v6.family = 10; // AF_INET6
    v6.port = std.mem.nativeToBig(u16, port);
    var family: c_uint = undefined;
    var sa: []const u8 = undefined;
    if (c.inet_pton(2, @ptrCast(&str_buf), &v4.addr) == 1) { // AF_INET
        family = 2;
        sa = std.mem.asBytes(&v4);
    } else if (c.inet_pton(10, @ptrCast(&str_buf), &v6.addr) == 1) { // AF_INET6
        family = 10;
        sa = std.mem.asBytes(&v6);
    } else return null;
    const listen_fd = c.socket(family, 1 | 2048, 0); // SOCK_STREAM|SOCK_NONBLOCK
    if (listen_fd < 0) return null;
    const one: c_int = 1;
    _ = net.setsockopt(listen_fd, 1, 2, &one, @sizeOf(c_int)); // SOL_SOCKET, SO_REUSEADDR
    if (net.bind(listen_fd, @ptrCast(@alignCast(sa.ptr)), @intCast(sa.len)) != 0 or net.listen(listen_fd, 8) != 0) {
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

/// procsignal (SIGUSR1) carries cross-backend events; the one that matters
/// here is the barrier: DROP DATABASE waits until every backend holding a
/// ProcSignal slot absorbs it, and this worker connects to a database, so it
/// holds a slot. Without this handler (plus CheckForInterrupts in the main
/// loop) it never absorbs — DROP DATABASE hangs forever on any cluster with
/// pg_logtap loaded, worker idle the whole time. The barrier flag is set
/// unconditionally: absorbing an already-absorbed generation is a no-op, and
/// the other procsignal reasons (notify, parallel message) don't apply to a
/// worker with no client.
fn handleUsr1(sig: c_int) callconv(.c) void {
    _ = sig;
    interrupts.Pending.ProcSignalBarrier.set(1);
    interrupts.Pending.Interrupt.set(1);
    if (pg.MyLatch != null) pg.SetLatch(pg.MyLatch);
}
