//! Export background worker (one per cluster): drains the ring and pushes
//! JSON lines to http/tcp/file. Unsent events retry from a worker-local
//! backlog bounded by ring capacity (oldest dropped, counted in `lost`) —
//! or, with export_fallback_file set, from a compressed on-disk queue that
//! replays once the receiver answers (src/fb.zig).
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
const tls_mod = @import("tls.zig");
const fbq = @import("fb.zig");
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
    extern "c" fn fchmod(fd: c_int, mode: c_uint) c_int;
    extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64; // SEEK_END=2 → file size
    extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
    extern "c" fn inet_pton(family: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
    extern "c" fn fstat(fd: c_int, buf: *FileStat) c_int;
    extern "c" fn stat(path: [*:0]const u8, buf: *FileStat) c_int;
};

/// struct stat as glibc/musl build it on LP64 (kernel asm-generic layout,
/// 144 bytes on amd64/arm64): the full size so libc writes stay in bounds;
/// only dev/ino are read (the alias checks below). std dropped its linux
/// Stat wrapper in 0.16 (only statx remains — syscall plumbing for two
/// numbers).
pub const FileStat = extern struct {
    dev: i64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    pad0: u32 = 0,
    rdev: i64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atim: [16]u8 = @splat(0),
    mtim: [16]u8 = @splat(0),
    ctim: [16]u8 = @splat(0),
    unused: [24]u8 = @splat(0),
};
const net = std.c;

/// Message staging for ring drains (capture.messageMax() bytes, allocated
/// once at worker start, outside every lock).
var drain_msg: []u8 = &.{};

var guc_export_url: [*c]u8 = null;
var guc_cluster_name: [*c]u8 = null;
var guc_export_gzip: bool = false;
var guc_export_tls_ca: [*c]u8 = null;
var guc_export_tls_verify: bool = true;
var guc_export_tls_server_name: [*c]u8 = null;
var guc_export_http_extra_headers: [*c]u8 = null;
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

/// The fd of an in-flight socket send (http/tcp), -1 when none. A second
/// SIGTERM closes it: SO_SNDTIMEO/SO_RCVTIMEO cannot be shortened mid-syscall,
/// so a mute receiver otherwise pins the shutdown flush for a full
/// export_timeout_ms per send. close(2) wakes the blocked call (EBADF → the
/// ordinary failure path); it is async-signal-safe, and the transports clear
/// the slot before their own close, so a recycled fd number is never hit.
var send_conn_fd: c_int = -1;

/// The one sanctioned way an in-flight send socket goes away. The
/// double-SIGTERM handler closes it to punch blocking I/O; the sender's
/// defer must not then close the same number again after a recycle. Both
/// routes go through here so the slot and the fd always move together.
fn closeSendFd(fd: c_int) void {
    if (send_conn_fd == fd) send_conn_fd = -1;
    _ = c.close(fd);
}

/// Final-flush abort state: 0 outside a graceful-shutdown flush. The deadline
/// bounds the whole flush to ~1s of work plus one send timeout; sendAborted()
/// is checked between partial-write syscalls, which a per-syscall socket
/// timeout alone cannot bound (a dribbling receiver makes ONE send unbounded).
var send_deadline_us: i64 = 0;

/// The compaction's own bound. A normal flush cycle has a 1s budget
/// (cycle_deadline) that sendAborted() cannot see — send_deadline_us is set
/// only during shutdown — so without this a cap/2 rewrite could hold the
/// worker past the whole cycle, starving drainInto, /metrics and SIGHUP.
/// Set per flushAll; 0 = only the shutdown deadline applies (the final park
/// runs under sendAborted, as before).
var compact_deadline_us: i64 = 0;

/// Absolute budget of ONE send attempt: set at send() entry to
/// now + export_timeout_ms. export_timeout_ms alone bounds each socket
/// syscall, not the attempt — DNS stall + connect + write + a dribbling
/// status read could each take the full timeout. Armed at the stage
/// boundaries and loop iterations of the network senders: past it the send
/// fails (ordinary retry/fallback path), and the in-flight syscall the
/// arm happens to miss is bounded by the SO timeouts it just set to the
/// remaining budget. DNS itself stays outside (getaddrinfo has no timeout
/// knob; documented in the GUC table).
var net_deadline_us: i64 = 0;

/// Arm an EXPLICIT deadline's remainder on a socket — the per-syscall
/// re-arm inside writeAll. netArmDeadline below is the stage-boundary
/// version (the send attempt's global deadline).
fn armDeadlineFrom(fd: c_int, deadline: i64) bool {
    const remain_us = deadline - pg.GetCurrentTimestamp();
    if (remain_us < 1000) return failSend("send deadline", 0);
    const timeval = timevalMs(@divTrunc(remain_us, 1000));
    if (net.setsockopt(fd, 1, 20, &timeval, @sizeOf(Timeval)) != 0 // SOL_SOCKET, SO_RCVTIMEO
    or net.setsockopt(fd, 1, 21, &timeval, @sizeOf(Timeval)) != 0) { // SOL_SOCKET, SO_SNDTIMEO
        return failSend("setsockopt", std.c._errno().*);
    }
    return true;
}

/// Arm net_deadline_us on the send socket: false (with failSend reason)
/// when the budget is spent or the socket refuses the timeouts — callers
/// treat it exactly like the stage failing.
fn netArmDeadline(fd: c_int) bool {
    return armDeadlineFrom(fd, net_deadline_us);
}

fn sendAborted() bool {
    if (got_sigterm.read() >= 2) return true;
    return send_deadline_us != 0 and pg.GetCurrentTimestamp() > send_deadline_us;
}

/// The compaction aborts on either deadline: the cycle budget in a normal
/// flush, the shutdown budget during the final one.
pub fn compactAborted() bool {
    if (compact_deadline_us != 0 and pg.GetCurrentTimestamp() > compact_deadline_us) return true;
    return sendAborted();
}

pub fn init() void {
    pg.DefineCustomStringVariable("pg_logtap.export_url", "http://host:port[/path] | https://host:port[/path] | tcp://host:port | tcps://host:port | file:///path; empty = no export worker (restart applies). A file:// path equal to pg_logtap.export_fallback_file is rejected (the NDJSON sink and the queue framing cannot share a file).", null, &guc_export_url, "", pg.PGC_SIGHUP, 0, checkUrl, null, null);
    pg.DefineCustomStringVariable("pg_logtap.cluster_name", "Cluster label stamped into every event's cluster field. Empty = fall back to the server's cluster_name (postmaster GUC, restart-to-change; empty by default).", null, &guc_cluster_name, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomStringVariable("pg_logtap.export_tls_ca", "PEM file with the certificate authority (CA) to verify https:// and tcps:// receivers against — for a self-signed receiver, the receiver's own certificate. Empty = the system CA roots. A set file REPLACES the system roots. Applied on reload, from the next handshake.", null, &guc_export_tls_ca, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomBoolVariable("pg_logtap.export_tls_verify", "Verify the https:// and tcps:// receiver's certificate (chain and name). false disables both — development only: a man in the middle becomes possible and the logs are readable there.", null, &guc_export_tls_verify, true, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomStringVariable("pg_logtap.export_tls_server_name", "Certificate name to verify and SNI to send when it differs from the URL host (IP-literal URLs, a TLS-terminating load balancer in front of the receiver). Empty = the URL host.", null, &guc_export_tls_server_name, "", pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomStringVariable("pg_logtap.export_http_extra_headers", "Extra header line(s) appended to every http(s):// request after the fixed headers — e.g. 'Authorization: Bearer <token>' for VictoriaLogs. Separate lines with the two-character backslash-n sequence (ALTER SYSTEM rejects a real newline in the value); each line is CRLF-terminated on send. A raw carriage return or an empty line is rejected at SET (both would malform every request). Empty = none.", null, &guc_export_http_extra_headers, "", pg.PGC_SIGHUP, 0, checkHeader, null, null);
    pg.DefineCustomBoolVariable("pg_logtap.export_gzip", "Compress http:// export batches (Content-Encoding: gzip). Receiver must accept gzipped request bodies: Vector http_server, VictoriaLogs, Fluent Bit http and Logstash http inputs do; a plain custom endpoint may not.", null, &guc_export_gzip, false, pg.PGC_SIGHUP, 0, null, null, null);
    fbq.defineGucs();
    pg.DefineCustomIntVariable("pg_logtap.flush_interval", "Drain-and-flush interval in milliseconds.", null, &guc_flush_interval, 1000, 10, 3_600_000, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.export_timeout_ms", "connect/send/receive timeout in milliseconds on export sockets. A receiver that accepts the connection but never answers fails the send after this instead of hanging the worker; the batch then retries via the usual backlog/fallback path. Enforced as one absolute deadline per send attempt at the worker's stage boundaries, and every socket read inside a TLS handshake or session is re-armed to that deadline — a peer dribbling TLS fragments cannot stretch a stage past it. The residual multiple is on the write side only: a stage with several TLS writes can stretch to a small multiple when the peer stops reading, each write bounded by this.", null, &guc_export_timeout_ms, 5000, 100, 600_000, pg.PGC_SIGHUP, 0, null, null, null);
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
    // Drain-side message staging, sized to the slot's runtime width; without
    // it there is nowhere to pop a message into.
    drain_msg = alloc.alloc(u8, capture.messageMax()) catch pg.proc_exit(1);
    var pending: Backlog = .{};
    defer pending.deinit(alloc);
    var names = NameCache{};
    capture.setWorkerLatch(); // backends wake this worker on the first event
    syncMetricsListener();
    refreshSourceId();
    // Compaction-litter cleanup + backlog credit for a queue that outlived
    // the counters (src/fb.zig).
    fbq.boot(alloc);

    while (!got_sigterm.isSet()) {
        pg.ResetLatch(pg.MyLatch);
        if (got_sighup.isSet()) {
            got_sighup.clear();
            pg.ProcessConfigFile(pg.PGC_SIGHUP);
            syncMetricsListener();
            refreshSourceId();
            // A new URL (or a re-set threshold) must not inherit the
            // previous receiver's slow state: the stale flag would park the
            // new destination's batches until a quiet cycle re-probed it.
            // A still-slow receiver re-arms the flag on its next answer.
            receiver_slow = false;
        }
        // Absorb procsignal barriers (see handleUsr1). Errors here have no
        // better handler than the next cycle — the barrier itself doesn't
        // ereport.
        interrupts.CheckForInterrupts() catch {};
        flushAll(alloc, &pending, &names, false);
        // Return a storm-swollen backlog buffer: parking keeps the ArrayList
        // capacity, so a one-off million-event storm would otherwise pin GiB
        // of RSS for the worker's whole life (measured: 6.6GiB retained).
        if (pending.len() == 0 and pending.buf.capacity >= 2 * fbq.body_cap) {
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
/// contents and the RAM backlog. Bounded twice over: the whole flush gets
/// ~1s of work plus one send timeout (send_deadline_us, enforced between
/// syscalls by sendAborted), and a second SIGTERM closes the in-flight fd
/// outright. Whatever the flush cannot send live is parked to the fallback
/// file — parking is local-disk work, runs without a deadline, and loses
/// nothing that the RAM backlog would otherwise carry into the restart.
fn flushAll(alloc: std.mem.Allocator, pending: *Backlog, names: *NameCache, final: bool) void {
    if (guc_export_url == null or guc_export_url[0] == 0) return;
    const url = std.mem.span(@as([*:0]const u8, @ptrCast(guc_export_url)));
    const dest = dest_mod.parseUrl(url) orelse {
        warnUrlOnce(url);
        return;
    };
    warned_url = false; // re-arm: bad → fixed → bad warns again, like the file:// latches
    defer send_deadline_us = 0; // zero for normal cycles regardless
    defer compact_deadline_us = 0;
    if (final) send_deadline_us = pg.GetCurrentTimestamp() + 1_000_000 + @as(i64, guc_export_timeout_ms) * 1000;

    var sent: u64 = 0; // delivered by a live send
    var queued: u64 = 0; // appended to the fallback file (a lifecycle stage, not a durability claim — fb_sync_failures says which)
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
    // The compaction shares the cycle's budget: a cap/2 rewrite mid-cycle
    // that ignores it holds the worker past drainInto/metrics/SIGHUP until
    // the rewrite finishes (sendAborted() cannot bound it — no shutdown).
    if (!final) compact_deadline_us = cycle_deadline;
    var drained_total: usize = 0; // live inflow this flushAll call
    while (final or !got_sigterm.isSet()) {
        if (pg.GetCurrentTimestamp() > cycle_deadline) {
            if (!final) break;
            // Budget spent mid-shutdown: live sending is over (sendAborted
            // enforces it from here on regardless) — park what is left
            // instead of dropping it with the process.
            parkAll(alloc, pending, names, &queued, &lost);
            break;
        }
        drained_total += drainInto(alloc, pending);
        lost += trimBacklog(pending); // bounded RAM even when inflow outruns sending

        if (fbq.queued()) {
            // Queued events are older than anything live, so pending joins the
            // queue first — global seq order holds — and the file drains to the
            // receiver one member per iteration (the ring keeps draining through
            // a long catch-up). Parking live events on disk rather than RAM is
            // what makes catch-up lossless when the live rate exceeds the drain
            // rate; fbq.logDivert(true) fires only on a failed send, never on
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
                // At final the deadline is waived: parking is lossless and
                // the alternative is losing the backlog with the process.
                if (!final and pg.GetCurrentTimestamp() > cycle_deadline) break;
                drained_total += drainInto(alloc, pending);
                lost += trimBacklog(pending);
                const chunk = buildBody(bodyWriter(alloc), pending, names) orelse break;
                if (fbq.append(alloc, chunk.body, false) != .appended) { // disk full → RAM-backlog semantics for the rest (sync=false cannot be not_durable)
                    failed += 1;
                    break;
                }
                pending.dropFront(chunk.consumed);
                queued += chunk.consumed;
                appended = true;
            }
            if (appended) fbq.fsync();
            // Capture outranks replay: a member send to a slow receiver blocks
            // this loop for hundreds of milliseconds, and at high inflow the
            // ring fills and drops events at capture before the next drain.
            // While the receiver is slow AND this cycle saw any live inflow,
            // park-only: fsync and hand the loop back to drainInto; members
            // resume once inflow quiets or it recovers.
            if (receiver_slow and drained_total > 0) continue;
            const member = fbq.nextMember(alloc) orelse {
                lost += fbq.lost;
                fbq.lost = 0;
                failed += @intFromBool(pending.len() > 0); // append failed above
                break;
            };
            lost += fbq.lost;
            fbq.lost = 0;
            const gzipped = gzipPayload(alloc, dest, member.body, &gzip_buf);
            const m_sent_at = pg.GetCurrentTimestamp();
            if (send(dest, url, gzipped.payload, gzipped.enabled)) {
                // Drain-path round trip is the receiver liveness probe: a slow
                // answer re-arms the park (receiver_slow), a fast one clears
                // it — this also arms it after a restart into a slow receiver
                // where the live-send probe never ran.
                if (guc_export_slow_ms > 0) receiver_slow = pg.GetCurrentTimestamp() - m_sent_at >= @as(i64, guc_export_slow_ms) * 1000;
                fbq.logDivert(false);
                // counted queued at append time; this is its delivery
                replayed += std.mem.countScalar(u8, member.body, '\n');
                fbq.offset += member.advance;
                if (fbq.offset >= member.size) fbq.truncate(); // fully delivered → back to direct sends
                members += 1;
                if (members < 64) continue;
                break; // hand the loop back: counters, metrics, latch
            }
            fbq.logDivert(true); // receiver down: divert starts (transition-guarded)
            failed += 1;
            break; // retry the queue next cycle
        }

        if (pending.len() == 0) break;
        const chunk = buildBody(bodyWriter(alloc), pending, names) orelse break;
        if (receiver_slow and guc_export_slow_ms > 0 and fbq.append(alloc, chunk.body, true) != .failed) {
            // Slow-but-alive receiver (receiver_slow): park coming batches on
            // disk — left live, they pile up in the RAM backlog until trimmed.
            // Same as the failed-send divert below, minus failed: nothing
            // failed; the queue path owns catch-up from the next iteration.
            // A park that cannot append (no fallback file, disk full) falls
            // through to the live send below: that send is also the only
            // probe that clears receiver_slow — parking into nowhere while
            // the flag is set livelocks delivery forever.
            fbq.logDivert(true);
            pending.dropFront(chunk.consumed);
            queued += chunk.consumed;
            continue;
        }
        const gzipped = gzipPayload(alloc, dest, chunk.body, &gzip_buf);
        const sent_at = pg.GetCurrentTimestamp();
        if (send(dest, url, gzipped.payload, gzipped.enabled)) {
            fbq.logDivert(false);
            pending.dropFront(chunk.consumed);
            sent += chunk.consumed;
            // Liveness probe, both ways: an answer this slow cannot keep up
            // with capture; a fast one clears the park — the live path must
            // clear it too, or a slow answer with no fallback file set parks
            // every later batch with no way back.
            if (guc_export_slow_ms > 0) receiver_slow = pg.GetCurrentTimestamp() - sent_at >= @as(i64, guc_export_slow_ms) * 1000;
        } else if (final) {
            // Send failed during the shutdown flush: without this branch one
            // chunk parked and the rest of the RAM backlog died silently with
            // the process. Park everything — the file is local, the restart
            // replays it (at-least-once).
            failed += 1;
            parkAll(alloc, pending, names, &queued, &lost);
            break;
        } else if (fbq.append(alloc, chunk.body, true) != .failed) {
            fbq.logDivert(true);
            pending.dropFront(chunk.consumed);
            queued += chunk.consumed; // parked in the file (a failed fdatasync keeps the member — fbq.append); counted replayed on delivery
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

    capture.bumpExport(sent, queued, replayed, failed, lost, 0);
    // Every cycle, not on transitions: the worker-local originals die with
    // the process, and a stale shmem copy would otherwise outlive a restart
    // (e.g. fallback_broken=1 from a file the operator already fixed).
    capture.setWorkerGauges(dns_fail_streak, @intFromBool(fbq.broken), fbq.sync_failures);
    logTransitions(sent + replayed, failed, lost);
}

/// Park the whole remaining backlog to the fallback file; whatever cannot be
/// parked (no file, disk full, OOM) is counted lost — with the process about
/// to exit, RAM-backed events are otherwise silently dropped. Runs even after
/// a second SIGTERM: that demand is about network time (a 30s pinned recv),
/// while parking is local-disk work bounded by the RAM backlog bound itself.
fn parkAll(alloc: std.mem.Allocator, pending: *Backlog, names: *NameCache, queued: *u64, lost: *u64) void {
    var appended = false;
    while (pending.len() > 0) {
        const chunk = buildBody(bodyWriter(alloc), pending, names) orelse break;
        if (fbq.append(alloc, chunk.body, false) != .appended) break;
        pending.dropFront(chunk.consumed);
        queued.* += chunk.consumed;
        appended = true;
    }
    if (appended) fbq.fsync();
    lost.* += pending.len();
    pending.dropFront(pending.len());
}

/// pending → NDJSON body (one JSON line per event), built in a REUSED
/// buffer: a fresh ~100KB chunk body sits above glibc's mmap threshold, and
/// the per-chunk mmap/munmap + TLB shootdowns stall every core — measured as
/// ring drops under a 16-client storm. The slice is valid until the next call.
/// Stops at fbq.chunk_max events or fbq.body_cap bytes, whichever comes first, and
/// reports how many events it consumed — the caller drops exactly those.
/// null = nothing built (empty or formatting failed); the caller retries
/// next cycle.
const BodyChunk = struct { body: []const u8, consumed: usize };

// The NDJSON chunk body buffer (~100K), one for the process life — a fresh
// allocation per chunk crosses glibc's mmap threshold and pays an
// mmap/munmap per flush cycle (same story as the gzip pool).
var fb_body: ?std.Io.Writer.Allocating = null;

fn bodyWriter(alloc: std.mem.Allocator) *std.Io.Writer.Allocating {
    if (fb_body == null) fb_body = .init(alloc);
    return &fb_body.?;
}

fn buildBody(w: *std.Io.Writer.Allocating, pending: *Backlog, names: *NameCache) ?BodyChunk {
    w.writer.end = 0; // reset, keep capacity
    var consumed: usize = 0;
    var off = pending.head;
    while (consumed < @min(pending.len(), fbq.chunk_max)) {
        const ent: *const ring.ShmLogEntry = @ptrCast(@alignCast(pending.buf.items.ptr + off));
        const msg = pending.buf.items[off + @sizeOf(ring.ShmLogEntry) ..][0..ent.message_len];
        jsonl.writeEntry(&w.writer, ent, msg, names.lookup(ent)) catch return null;
        w.writer.writeByte('\n') catch return null;
        consumed += 1;
        if (w.writer.end >= fbq.body_cap) break;
        off = pending.nextOff(off);
    }
    if (consumed == 0) return null;
    return .{ .body = w.writer.buffer[0..w.writer.end], .consumed = consumed };
}

/// Ring → backlog. OOM counts the drained event as lost (the ring is already
/// drained). Round cap: the ring refilling as fast as it drains would keep
/// this loop running — 4096 events ≈ the old 64×64 batch — before sends,
/// /metrics and the latch get control back.
fn drainInto(alloc: std.mem.Allocator, pending: *Backlog) usize {
    var drained: usize = 0;
    var head: ring.ShmLogEntry = undefined;
    while (drained < 4096) {
        if (!capture.drainOne(&head, drain_msg)) return drained;
        pending.append(alloc, &head, drain_msg[0..head.message_len]) catch {
            capture.bumpExport(0, 0, 0, 0, 1, 0);
            return drained;
        };
        drained += 1;
    }
    return drained; // ring non-empty: the next flush cycle drains the rest
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

/// Front-consumable RAM backlog as a byte arena of [head][message] records,
/// 8-aligned so the head cast below is legal (c_allocator guarantees 16 for
/// any allocation this size). dropFront advances the byte head by walking
/// records (~80ns/step — a worst-case trim of 60k records is ~5ms); the dead
/// prefix is compacted inside append once it dominates. The old
/// shift-per-chunk copyForwards moved up to 27MB (8192 × 3.4KB) per 256-event
/// chunk and capped park throughput at ~14k events/s: below storm inflow, so
/// the trim fired continuously and lost events even with the fallback file on.
const Backlog = struct {
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0, // byte offset of the first live record
    count: usize = 0, // live records; len() must stay O(1) — loop conditions read it

    fn len(self: *const Backlog) usize {
        return self.count;
    }

    fn append(self: *Backlog, alloc: std.mem.Allocator, e: *const ring.ShmLogEntry, msg: []const u8) !void {
        if (self.head > 0 and self.head * 2 >= self.buf.items.len) {
            const rest = self.buf.items.len - self.head;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.head..]);
            self.buf.items.len = rest;
            self.head = 0;
        }
        const total = std.mem.alignForward(usize, @sizeOf(ring.ShmLogEntry) + msg.len, 8);
        const end = self.buf.items.len;
        try self.buf.resize(alloc, end + total);
        @memcpy(self.buf.items[end..][0..@sizeOf(ring.ShmLogEntry)], std.mem.asBytes(e));
        @memcpy(self.buf.items[end + @sizeOf(ring.ShmLogEntry) ..][0..msg.len], msg);
        self.count += 1;
    }

    /// Byte offset of the record after the one at `off`.
    fn nextOff(self: *const Backlog, off: usize) usize {
        const ent: *const ring.ShmLogEntry = @ptrCast(@alignCast(self.buf.items.ptr + off));
        return off + std.mem.alignForward(usize, @sizeOf(ring.ShmLogEntry) + ent.message_len, 8);
    }

    fn dropFront(self: *Backlog, n: usize) void {
        var dropped: usize = 0;
        while (dropped < n and self.count > 0) : (dropped += 1) {
            self.head = self.nextOff(self.head);
            self.count -= 1;
        }
    }

    fn deinit(self: *Backlog, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
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

/// Current pg_logtap.export_url value ("" while unset) — the fallback GUC's
/// SET check reads it for the aliasing rule below.
pub fn gucExportUrl() []const u8 {
    return gucSpan(guc_export_url);
}

/// True when a file:// export_url and the fallback GUC value resolve to the
/// same file — the NDJSON sink and the PGLTFB01 queue framing must not share
/// one (each corrupts the other's format; whichever opens second sees foreign
/// content). Rejected at SET of either GUC, so whichever lands second loses.
pub fn fileUrlAliasesFallback(url: []const u8, fb_raw: []const u8) bool {
    if (fb_raw.len == 0) return false;
    const dest_v = dest_mod.parseUrl(url) orelse return false;
    if (dest_v != .file) return false;
    if (fb_raw[0] == '/') return std.mem.eql(u8, fb_raw, dest_v.file);
    const dd_c = pg.DataDir orelse return false; // relative fallback → data dir, as fb.path resolves it
    const dd = std.mem.span(@as([*:0]const u8, @ptrCast(dd_c)));
    var buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dd, fb_raw }) catch return false;
    return std.mem.eql(u8, full, dest_v.file);
}

/// SET-time aliasing check for export_url (rule on fileUrlAliasesFallback):
/// guc.c runs this for SET and ALTER SYSTEM; boot runs '' through here too.
fn checkUrl(newval: [*c][*c]u8, extra: [*c]?*anyopaque, source: c_uint) callconv(.c) bool {
    _ = extra;
    _ = source;
    const ptr = newval orelse return true;
    const raw_c = ptr.* orelse return true;
    return !fileUrlAliasesFallback(std.mem.span(@as([*:0]const u8, @ptrCast(raw_c))), fbq.fileGucRaw());
}

/// Inode of an open fd (null when fstat fails).
fn fdStat(fd: c_int) ?FileStat {
    var sbuf: FileStat = undefined;
    if (c.fstat(fd, &sbuf) != 0) return null;
    return sbuf;
}

/// The SET-time rules above compare PATH STRINGS; the same file can be named
/// by different strings — a symlink or hardlink alias. The inode checks
/// below compare the filesystem object itself, at open time on both sides of
/// the pair: the file:// sink refuses the send (events ride the RAM backlog,
/// warned once), the queue latches broken exactly like any unusable queue.
/// Residual, by design: a path swapped between its check and the other
/// side's open (an active racing writer inside the data directory) can still
/// land both writers on one inode — same shape as the same-reload double-flip
/// residual; the foreign-content latch keeps it from silent corruption.
/// True when an open file:// sink fd is the same inode as the fallback queue
/// (the queue's own path stat'ed through symlinks — the sink follows them,
/// that shared inode is exactly the alias being caught).
fn fdAliasesFallback(fd: c_int) bool {
    const sink_st = fdStat(fd) orelse return false;
    return fbq.aliasesQueueInode(sink_st);
}

/// True when a just-opened queue fd is the same inode as the file the
/// file:// export_url names — fbOpen's mirror of fdAliasesFallback.
pub fn queueFdAliasesFileUrl(fd: c_int) bool {
    const dest_v = dest_mod.parseUrl(gucExportUrl()) orelse return false;
    if (dest_v != .file) return false;
    const qst = fdStat(fd) orelse return false;
    if (dest_v.file.len >= 4096) return false;
    var zbuf: [4096]u8 = undefined;
    const zpath = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{dest_v.file}, 0) catch return false;
    var ust: FileStat = undefined;
    if (c.stat(zpath, &ust) != 0) return false;
    return qst.dev == ust.dev and qst.ino == ust.ino;
}

// --- source identity (multi-host → one Vector): stamped into every event ------

// Owned copies behind jsonl.source_*: refreshSourceId re-runs on every
// SIGHUP, and a bare dupe leaked the previous allocation each reload.
var owned_host: ?[]u8 = null;
var owned_cluster: ?[]u8 = null;
var owned_pgdata: ?[]u8 = null;

fn setOwned(owned: *?[]u8, target: *[]const u8, val: []const u8) void {
    if (owned.*) |old| {
        if (std.mem.eql(u8, old, val)) {
            target.* = old; // unchanged value: keep the allocation
            return;
        }
        std.heap.c_allocator.free(old);
        owned.* = null;
    }
    const dup = std.heap.c_allocator.dupe(u8, val) catch {
        target.* = "";
        return;
    };
    owned.* = dup;
    target.* = dup;
}

/// hostname and pgdata never change; pg_logtap.cluster_name is SIGHUP-able,
/// hence the refresh on reload.
fn refreshSourceId() void {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0);
    if (c.gethostname(&buf, buf.len - 1) == 0) {
        setOwned(&owned_host, &jsonl.source_host, std.mem.sliceTo(&buf, 0));
    }
    // The override wins; otherwise reuse the server's cluster_name (which is
    // POSTMASTER — restart-to-change, hence this SIGHUP GUC). gucStrRaw borrows;
    // setOwned dupes each span before the next GetConfigOption call.
    var cluster = gucStrRaw("pg_logtap.cluster_name");
    if (cluster.len == 0) cluster = gucStrRaw("cluster_name");
    setOwned(&owned_cluster, &jsonl.source_cluster, cluster);
    const pgdata = gucStrRaw("data_directory");
    setOwned(&owned_pgdata, &jsonl.source_pgdata, pgdata);
}

/// A GUC's current value as a borrowed slice — valid until the next
/// GetConfigOption call; keepers dupe (setOwned does).
fn gucStrRaw(name: [:0]const u8) []const u8 {
    const val = pg.GetConfigOption(name.ptr, true, false);
    if (val == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(val)));
}

/// SET-time CR/LF check for export_http_extra_headers (discipline in export.zig,
/// unit-tested there): guc.c runs this for SET and ALTER SYSTEM, and boot
/// runs the default '' through here too (always accepted).
fn checkHeader(newval: [*c][*c]u8, extra: [*c]?*anyopaque, source: c_uint) callconv(.c) bool {
    _ = extra;
    _ = source;
    const ptr = newval orelse return true;
    const raw_c = ptr.* orelse return true;
    return dest_mod.headerValid(std.mem.span(@as([*:0]const u8, @ptrCast(raw_c))));
}

// --- oid → name cache (catalog lookups under one short transaction) -----------

const NameCache = struct {
    dbs: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .{},
    users: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .{},
    // A cluster has a handful of oids; a create/drop storm would grow the
    // maps forever, so past this bound they reset and re-fill lazily from
    // the catalog — the same path a fresh worker takes.
    const max_entries = 4096;

    fn lookup(self: *NameCache, e: *const ring.ShmLogEntry) jsonl.Names {
        if (!self.dbs.contains(e.db_oid) or !self.users.contains(e.role_oid)) self.fill(e);
        return .{
            .database = self.dbs.get(e.db_oid) orelse null,
            .user = self.users.get(e.role_oid) orelse null,
        };
    }

    fn fill(self: *NameCache, e: *const ring.ShmLogEntry) void {
        const alloc = std.heap.c_allocator;
        if (self.dbs.count() >= max_entries or self.users.count() >= max_entries) {
            inline for (.{ &self.dbs, &self.users }) |map| {
                var it = map.iterator();
                while (it.next()) |ent| {
                    if (ent.value_ptr.*) |name| alloc.free(name);
                }
                map.clearRetainingCapacity();
            }
        }
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
fn gzipPayload(alloc: std.mem.Allocator, dest: dest_mod.Dest, body: []const u8, out: *?[]u8) struct { payload: []const u8, enabled: bool } {
    if (!guc_export_gzip or dest != .http) return .{ .payload = body, .enabled = false };
    if (out.*) |old| alloc.free(old);
    out.* = gzip.compress(alloc, body) catch {
        out.* = null;
        return .{ .payload = body, .enabled = false };
    };
    return .{ .payload = out.*.?, .enabled = true };
}

fn send(dest: dest_mod.Dest, url: []const u8, body: []const u8, gzipped: bool) bool {
    _ = url;
    net_deadline_us = pg.GetCurrentTimestamp() + @as(i64, guc_export_timeout_ms) * 1000;
    return switch (dest) {
        .http => |h| sendHttp(h, body, gzipped),
        .tcp => |t| sendRaw(dialTcp(t.host, t.port), body, t),
        .file => |path| sendFile(path, body),
    };
}

/// A GUC string as a plain slice; null (unset) reads as empty.
fn gucSpan(v: [*c]u8) []const u8 {
    return if (v == null) "" else std.mem.span(@as([*:0]const u8, @ptrCast(v)));
}

/// Warned once per worker life: verify=off is the documented development
/// escape hatch, but the docs are not where an operator looks when a
/// misconfigured cluster quietly ships its logs unauthenticated.
var warned_tls_no_verify = false;

fn tlsOpts() tls_mod.Options {
    if (!guc_export_tls_verify and !warned_tls_no_verify) {
        warned_tls_no_verify = true;
        capture.noteWarn(.tls_no_verify);
        elog.Warning(@src(), "pg_logtap export_tls_verify=off: https/tcps certificate verification is DISABLED — a man in the middle can read the logs", .{});
    }
    return .{
        .ca_pem = gucSpan(guc_export_tls_ca),
        .server_name = gucSpan(guc_export_tls_server_name),
        .verify = guc_export_tls_verify,
    };
}

/// Fold tls.zig's detailed reason into the transition-log failure reason.
fn tlsFail() bool {
    fail_reason = std.fmt.bufPrint(&fail_reason_buf, "{s}", .{tls_mod.last_error}) catch "tls";
    return false;
}

/// Abort-aware body write over TLS: one tls chunk may drain several socket
/// writes (each bounded by SO_SNDTIMEO), so the shutdown/cycle budget is
/// checked between chunks instead of between syscalls.
fn tlsWriteBody(tls_conn: *tls_mod.Conn, head: []const u8, body: []const u8) bool {
    if (!tls_conn.write(head)) return tlsFail();
    var off: usize = 0;
    while (off < body.len) {
        if (sendAborted()) return failSend("tls abort", 0);
        if (!netArmDeadline(send_conn_fd)) return false; // send_conn_fd: only socket sends come here
        const want = @min(body.len - off, 64 * 1024);
        if (!tls_conn.write(body[off..][0..want])) return tlsFail();
        off += want;
    }
    return true;
}

fn sendHttp(h: anytype, body: []const u8, gzipped: bool) bool {
    // dialTcp has already set the specific reason (dns / connect errno=N);
    // a generic "dial errno=0" here would overwrite it and hide which stage
    // failed.
    const conn_fd = dialTcp(h.host, h.port) orelse return false;
    send_conn_fd = conn_fd;
    defer closeSendFd(conn_fd);
    // Arm the send budget post-dial: a wedged resolver can have spent most
    // of it before the socket existed (handshake/writes/status read then
    // run on what is left; dialAddr's own setsockopt gave connect the full
    // timeout — one in-flight syscall, as documented on netArmDeadline).
    if (!netArmDeadline(conn_fd)) return false;
    // Fixed headers (method line, Host, content type/encoding/length) run
    // ~110 bytes; 2048 leaves room for any realistic path, host and auth
    // header, and one that still does not fit fails the send with the
    // reason — not a torn header on the wire.
    var head_buf: [2048]u8 = undefined;
    var head = std.Io.Writer.fixed(&head_buf);
    head.print("POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/x-ndjson\r\n", .{ h.path, h.host, h.port }) catch return failSend("head build", 0);
    const extra_hdr = gucSpan(guc_export_http_extra_headers);
    if (extra_hdr.len > 0) dest_mod.writeHeaderLines(&head, extra_hdr) catch return failSend("head build", 0);
    if (gzipped) head.writeAll("Content-Encoding: gzip\r\n") catch return failSend("head build", 0);
    head.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return failSend("head build", 0);
    if (h.tls) return sendHttpTls(conn_fd, h, head.buffered(), body);
    if (!writeAll(conn_fd, head.buffered(), true, net_deadline_us)) return failSend("write head", std.c._errno().*);
    if (!writeAll(conn_fd, body, true, net_deadline_us)) return failSend("write body", std.c._errno().*);
    // Status line is enough: "HTTP/1.1 200 ..." — 2xx accepted, anything else retries.
    // TCP does not preserve write boundaries: the line may straddle recvs, and
    // a false failure here retries a body the receiver already accepted (a
    // contract-legal duplicate plus a spurious fallback divert). Loop to the
    // 12 bytes "HTTP/1.1 200" needs — RCVTIMEO bounds each recv (dialTcp), so
    // a receiver that stalls mid-line still fails with "status read".
    var status_buf: [32]u8 = undefined;
    var got: usize = 0;
    while (got < 12) {
        if (!netArmDeadline(conn_fd)) return false;
        const nread = recvSome(conn_fd, status_buf[got..]);
        if (nread == 0) return failSend("status read", std.c._errno().*);
        got += nread;
    }
    return status2xx(status_buf[0..got]);
}

fn status2xx(status: []const u8) bool {
    if (!std.mem.startsWith(u8, status, "HTTP/1.") or status[9] != '2') {
        return failSend("status code", @as(c_int, status[9]));
    }
    return true;
}

fn sendHttpTls(conn_fd: c_int, h: anytype, head: []const u8, body: []const u8) bool {
    const tls_conn = tls_mod.connect(conn_fd, h.host, tlsOpts(), net_deadline_us - pg.GetCurrentTimestamp()) orelse return tlsFail();
    if (!tlsWriteBody(tls_conn, head, body)) return false;
    // sendAborted between reads here: the plain path checks it inside
    // recvSome, but the TLS read goes through tls_mod's connection.
    var status_buf: [32]u8 = undefined;
    var got: usize = 0;
    while (got < 12) {
        if (sendAborted()) return failSend("tls abort", 0);
        if (!netArmDeadline(conn_fd)) return false;
        const nread = tls_conn.readSome(status_buf[got..]);
        if (nread == 0) {
            // Fold tls.zig's stage detail in — a bare "status read" hides
            // whether the peer reset, EOFed or the read timed out.
            fail_reason = std.fmt.bufPrint(&fail_reason_buf, "status read: {s}", .{tls_mod.last_error}) catch "status read";
            return false;
        }
        got += nread;
    }
    if (!status2xx(status_buf[0..got])) return false;
    // close_notify is best-effort; with the attempt budget spent, skipping it
    // beats paying up to two more socket waits after an already-successful
    // send — the fd close is the backstop, as on the failed-send path.
    if (pg.GetCurrentTimestamp() < net_deadline_us) tls_conn.end();
    return true;
}

fn sendRaw(fd_opt: ?c_int, body: []const u8, ep: dest_mod.Endpoint) bool {
    // As sendHttp: the dial path already recorded why it failed.
    const conn_fd = fd_opt orelse return false;
    send_conn_fd = conn_fd;
    defer closeSendFd(conn_fd);
    if (!netArmDeadline(conn_fd)) return false;
    if (ep.tls) {
        const tls_conn = tls_mod.connect(conn_fd, ep.host, tlsOpts(), net_deadline_us - pg.GetCurrentTimestamp()) orelse return tlsFail();
        if (!tlsWriteBody(tls_conn, "", body)) return false;
        if (pg.GetCurrentTimestamp() < net_deadline_us) tls_conn.end(); // best-effort close_notify, skipped when the budget is spent
        return true;
    }
    if (!writeAll(conn_fd, body, true, net_deadline_us)) return failSend("write body", std.c._errno().*);
    return true;
}

/// Warned-once latch for a file:// sink whose fdatasync failed and whose
/// rollback failed too — the batch is reported delivered (the lines are in
/// the page cache) while its durability is unknown. Same edge-triggered
/// shape as fb_sync_warned: a dying disk would otherwise bury the log.
var file_sync_warned = false;
var file_rollback_warned = false; // same shape: a torn write whose rollback failed
var sink_alias_warned = false; // same shape: a sink fd sharing the queue's inode

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
    // 0600 above applies at creation only — pull a pre-existing file (an
    // operator may have made it world-readable) down to it. Best-effort: a
    // chmod failing here means a filesystem that would fail the writes too.
    _ = c.fchmod(conn_fd, @as(c_uint, 0o600));
    const end_before = c.lseek(conn_fd, 0, 2); // SEEK_END: rollback point
    if (end_before < 0) return false;
    // Inode-level alias with the fallback queue (see fdAliasesFallback):
    // refuse before the first NDJSON byte lands in the queue's file.
    if (fdAliasesFallback(conn_fd)) {
        if (!sink_alias_warned) {
            sink_alias_warned = true;
            elog.Warning(@src(), "pg_logtap file:// sink and the fallback queue name one file (symlink/hardlink alias): sends to {s} refused, events stay in the RAM backlog", .{path});
        }
        return false;
    }
    if (!writeAll(conn_fd, body, false, null)) {
        // A partial write (ENOSPC mid-batch) leaves a torn line in the
        // sink's NDJSON stream forever; with O_APPEND a plain retry would
        // append the whole batch AGAIN after the torn prefix. Roll back to
        // the last full batch — the next cycle rewrites it whole. A failed
        // rollback is warned once and the sink is left as-is: ftruncate on a
        // regular file that just took the write only fails on a dying disk,
        // the damage is one torn line, and a broken-sink state machine buys
        // nothing the warning does not.
        if (c.ftruncate(conn_fd, @intCast(end_before)) == 0) {
            // Sync the rollback itself — the same resurrection window the
            // failed-sync rollback below closes: an unsynced truncate lets
            // an OS crash bring the torn tail back, and the retried batch
            // would append a whole copy after it. Best-effort; a sync that
            // fails too keeps the retry (at-least-once), the trade below.
            _ = c.fdatasync(conn_fd);
        } else if (!file_rollback_warned) {
            file_rollback_warned = true;
            elog.Warning(@src(), "pg_logtap file:// rollback of a torn write failed (errno={d}): a torn line stays in {s} and the next batch appends after it", .{ std.c._errno().*, path });
        }
        return false;
    }
    // Durable per batch: the page cache survives process death but not OS
    // death. One fdatasync per flush cycle is cheap next to the write itself.
    // A failed sync is NOT a failed write: the lines are in the file, and
    // reporting failure would make the caller append the whole batch again —
    // duplicate NDJSON. Try the rollback; if even that fails the disk cannot
    // take a clean retry either, so report delivered with the durability
    // caveat (better one maybe-lost batch than a guaranteed duplicate).
    if (c.fdatasync(conn_fd) != 0) {
        if (c.ftruncate(conn_fd, @intCast(end_before)) == 0) {
            // Sync the rollback itself: the failed sync may already have
            // pushed the batch's pages and size out, and an unsynced
            // truncate can resurrect them after an OS crash — the retried
            // batch parks on the fallback queue and would replay a second
            // copy after the resurrected one. A sync that fails too keeps
            // the retry (at-least-once), the same trade as below.
            _ = c.fdatasync(conn_fd);
            return false;
        }
        if (!file_sync_warned) {
            file_sync_warned = true;
            elog.Warning(@src(), "pg_logtap file:// fdatasync failed and rollback failed too (errno={d}): batch reported delivered but not durable: {s}", .{ std.c._errno().*, path });
        }
        return true;
    }
    // A clean batch clears the warned-once latches so the NEXT independent
    // failure is visible again (edge-triggered, re-armed by success).
    file_sync_warned = false;
    file_rollback_warned = false;
    sink_alias_warned = false;
    return true;
}

extern fn __res_init() c_int;

var dns_fail_streak: u32 = 0;

// The last address a dial actually reached, keyed by its host. When dns
// later fails in-process — the wedged-resolver state below, outliving every
// res_init re-arm on some cores — dialing this address keeps delivery alive.
// Container names keep their IP across docker stop/start, which is exactly
// the outage shape. The 60s TTL (dns_good_at_us) bounds the other failure
// shape: environments that REUSE IPs (k8s services) would otherwise keep
// shipping logs to whatever now owns the cached address. Ceiling: a name
// that moves to a new IP while dns also fails in-process stays unreachable
// until the resolver heals or the worker restarts; recreating the receiver
// recreates the stand, which restarts postgres too.
var dns_good_host: [255]u8 = undefined;
var dns_good_host_len: usize = 0;
// When dns_good_addr was cached (µs); 0 = never.
var dns_good_at_us: i64 = 0;
// sockaddr bytes as getaddrinfo made them. align(8) = sockaddr_storage grade:
// dialAddr's connect casts this to *sockaddr, and an odd .bss slot trips the
// alignment check (ReleaseSafe aborts the worker, taking the postmaster down).
var dns_good_addr: [128]u8 align(8) = undefined;
var dns_good_addr_len: u32 = 0;
var dns_good_family: c_int = 0;
// The port is part of the cache key, not just cargo: the sockaddr below
// carries it baked in, so a host whose URL port changed would otherwise be
// dialed on the OLD port for as long as the resolver outage lasts.
var dns_good_port: u16 = 0;

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
        // glibc's resolver can wedge in this process: a lookup interrupted at
        // the wrong internal moment (the latch's SIGUSR1s are dense exactly
        // while events flow) leaves later getaddrinfos failing fast with
        // EAI_AGAIN/EAI_NONAME while fresh processes resolve fine — and the
        // wedge RE-FORMS right after a successful delivery, because the
        // delivery's own transition event wakes the worker into the next
        // lookup 1ms later. Re-init every 10th consecutive failure so a
        // wedged episode gets repeated chances; harmless while the name is
        // really gone (res_init just re-parses resolv.conf). On some cores
        // the wedge outlives every re-init — the cached-address dial below
        // carries delivery through those.
        dns_fail_streak += 1;
        if (dns_fail_streak >= 10 and dns_fail_streak % 10 == 0) {
            if (__res_init() != 0)
                elog.Log(@src(), "pg_logtap resolver re-init failed, dns may stay wedged in this process", .{})
            else if (dns_fail_streak == 10)
                elog.Log(@src(), "pg_logtap resolver re-initialized after consecutive dns failures", .{});
        }
        if (dns_good_port == port and dns_good_host_len == host.len and std.mem.eql(u8, dns_good_host[0..host.len], host)) {
            // TTL, not forever: reused-IP environments would otherwise dial
            // whatever service now owns the cached address.
            if (pg.GetCurrentTimestamp() - dns_good_at_us <= 60_000_000) { // 60s in µs
                if (dialAddr(&dns_good_addr, dns_good_addr_len, dns_good_family)) |conn_fd| return conn_fd;
            }
        }
        // The code separates the failure classes: -2 NONAME (name genuinely
        // absent), -3 AGAIN (resolver timeout), -8 MEMORY; -1 SYSTEM parks
        // the real cause in errno — report that instead. The host goes into
        // the reason verbatim: a corrupted slice shows up as garbage here,
        // separating "the name is really gone" from in-process rot.
        const code: c_int = if (gai == -1) std.c._errno().* else gai;
        fail_reason = std.fmt.bufPrint(&fail_reason_buf, "dns errno={d} host='{s}' ({d} bytes)", .{ code, host[0..@min(host.len, 24)], host.len }) catch "dns";
        return null;
    }
    dns_fail_streak = 0;
    defer if (res) |r| net.freeaddrinfo(r);

    var addr_iter = res;
    while (addr_iter) |ai| : (addr_iter = ai.next) {
        if (dialAddr(ai.addr.?, ai.addrlen, ai.family)) |conn_fd| {
            if (host.len <= dns_good_host.len and ai.addrlen <= dns_good_addr.len) {
                @memcpy(dns_good_host[0..host.len], host);
                dns_good_host_len = host.len;
                @memcpy(dns_good_addr[0..ai.addrlen], @as([*]const u8, @ptrCast(ai.addr.?))[0..ai.addrlen]);
                dns_good_addr_len = ai.addrlen;
                dns_good_family = ai.family;
                dns_good_port = port;
                dns_good_at_us = pg.GetCurrentTimestamp();
            }
            return conn_fd;
        }
    }
    return null;
}

/// socket + connect for one resolved address, with the send timeouts from
/// export_timeout_ms applied before connect (see below). Returns the
/// connected fd or null after reporting the connect error via failSend.
fn dialAddr(addr: *const anyopaque, addrlen: u32, family: c_int) ?c_int {
    const conn_fd = c.socket(@intCast(family), 1, 0); // SOCK_STREAM, default protocol
    if (conn_fd < 0) return null;
    // A silent receiver (accepted connect, never answers; hung LB,
    // black-hole route) must not hang the single worker loop — with no
    // timeout, the status recv blocks forever: drain stops, the ring
    // overflows, /metrics and SIGHUP go unserved. Set before connect:
    // Linux honors SO_SNDTIMEO for connect(2) too. On expiry write/recv
    // return EAGAIN, which flows into the ordinary failSend →
    // retry/fallback path like any dead receiver.
    const timeval = timevalMs(guc_export_timeout_ms);
    if (net.setsockopt(conn_fd, 1, 20, &timeval, @sizeOf(Timeval)) != 0 // SOL_SOCKET, SO_RCVTIMEO
    or net.setsockopt(conn_fd, 1, 21, &timeval, @sizeOf(Timeval)) != 0) { // SOL_SOCKET, SO_SNDTIMEO
        // A socket the timeouts did not land on would block the single
        // worker loop forever — the exact hang they exist to prevent. Cancel
        // the attempt (the batch retries like any dead receiver) instead of
        // proceeding without the guarantee.
        const err = std.c._errno().*;
        _ = c.close(conn_fd);
        _ = failSend("setsockopt", err);
        return null;
    }
    if (net.connect(conn_fd, @ptrCast(@alignCast(addr)), addrlen) == 0) return conn_fd;
    const err = std.c._errno().*;
    _ = c.close(conn_fd);
    _ = failSend("connect", err);
    return null;
}

/// timeval(3type) for setsockopt: both fields c_long on linux x86-64/arm64.
const Timeval = extern struct { sec: i64, usec: i64 };

/// One timeval from whole milliseconds — the two socket-timeout sites.
fn timevalMs(ms: i64) Timeval {
    return .{ .sec = @divTrunc(ms, 1000), .usec = @mod(ms, 1000) * 1000 };
}
comptime {
    // Timeval above, the raw open(2) flag numbers and the page-size math all
    // assume LP64. The project ships amd64/arm64; rather than a silent
    // misbehaving 32-bit build, refuse it.
    if (@sizeOf(usize) != 8)
        @compileError("pg_logtap's worker assumes a 64-bit platform (timeval layout, raw O_ flags); not built or tested for 32-bit");
    // FileStat below is the asm-generic LP64 struct stat layout, not a
    // per-OS translation — the inode-alias checks would read garbage fields
    // anywhere but Linux.
    if (@import("builtin").os.tag != .linux)
        @compileError("pg_logtap's worker assumes Linux (raw syscall structs, O_ flag numbers); not built or tested elsewhere");
}

/// Remember why the last send failed; surfaces in the transition log line.
fn failSend(stage: []const u8, err: c_int) bool {
    fail_reason = std.fmt.bufPrint(&fail_reason_buf, "{s} errno={d}", .{ stage, err }) catch stage;
    return false;
}

var fail_reason_buf: [160]u8 = undefined; // wide enough for a tls.zig reason with its hint verbatim
var fail_reason: []const u8 = "";

/// Blocking full write over a socket or regular-file fd; fbq.zig's appends
/// and compaction go through here too.
pub fn writeAll(conn_fd: c_int, buf: []const u8, abortable: bool, deadline_us: ?i64) bool {
    var off: usize = 0;
    while (off < buf.len) {
        // The abort check runs between syscalls: SO_SNDTIMEO bounds ONE
        // write, so a dribbling receiver otherwise makes this loop unbounded
        // during the shutdown flush. A send attempt also passes its absolute
        // deadline — each partial write resets the socket's per-syscall wait,
        // so a receiver taking one byte per just-under-timeout interval could
        // stretch one body across many individually-bounded waits otherwise.
        // The deadline is an explicit argument, never the global: callers
        // outside a send attempt (compaction copy, metrics replies) are
        // abort-aware but must not measure against a stale one. Socket sends
        // only — a local file write (fallback queue, file:// destination) is
        // bounded by disk speed, and exactly those writes carry the parked
        // backlog through shutdown.
        if (abortable and (sendAborted() or (deadline_us != null and pg.GetCurrentTimestamp() >= deadline_us.?))) return false;
        // Re-arm to the REMAINDER before every write: the check above only
        // runs between syscalls, so a write started just inside the deadline
        // could otherwise block for one more full SO_SNDTIMEO past it.
        if (deadline_us != null and !armDeadlineFrom(conn_fd, deadline_us.?)) return false;
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
        if (sendAborted()) return 0;
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
    // An overlong address can never listen (listenOn rejects it), so it
    // compares as "": storing the GUC slice itself would leave a dangling
    // pointer after the next reload frees that memory.
    if (metrics_open_port == guc_metrics_port and std.mem.eql(u8, metrics_open_addr, if (addr.len > metrics_open_addr_buf.len) "" else addr)) return;
    metrics_open_port = guc_metrics_port;
    if (addr.len <= metrics_open_addr_buf.len) {
        @memcpy(metrics_open_addr_buf[0..addr.len], addr);
        metrics_open_addr = metrics_open_addr_buf[0..addr.len];
    } else metrics_open_addr = ""; // overlong: listenOn will reject it anyway
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
    var addr4 = std.mem.zeroes(net.sockaddr.in);
    addr4.family = 2; // AF_INET
    addr4.port = std.mem.nativeToBig(u16, port);
    var addr6 = std.mem.zeroes(net.sockaddr.in6);
    addr6.family = 10; // AF_INET6
    addr6.port = std.mem.nativeToBig(u16, port);
    var family: c_uint = undefined;
    var sock_addr: []const u8 = undefined;
    if (c.inet_pton(2, @ptrCast(&str_buf), &addr4.addr) == 1) { // AF_INET
        family = 2;
        sock_addr = std.mem.asBytes(&addr4);
    } else if (c.inet_pton(10, @ptrCast(&str_buf), &addr6.addr) == 1) { // AF_INET6
        family = 10;
        sock_addr = std.mem.asBytes(&addr6);
    } else return null;
    const listen_fd = c.socket(family, 1 | 2048, 0); // SOCK_STREAM|SOCK_NONBLOCK
    if (listen_fd < 0) return null;
    const one: c_int = 1;
    _ = net.setsockopt(listen_fd, 1, 2, &one, @sizeOf(c_int)); // SOL_SOCKET, SO_REUSEADDR
    if (net.bind(listen_fd, @ptrCast(@alignCast(sock_addr.ptr)), @intCast(sock_addr.len)) != 0 or net.listen(listen_fd, 8) != 0) {
        _ = c.close(listen_fd);
        return null;
    }
    return listen_fd;
}

/// Serve queued scrapes under a time budget, then return to the main loop.
/// Unbounded serving let a scraper that reconnects every iteration (or a
/// loopback client in a tight loop) starve the export cycle indefinitely —
/// the socket backlog keeps the rest for the next cycle.
fn scrapeAll() void {
    if (metrics_fd < 0) return;
    const budget_until = pg.GetCurrentTimestamp() + 250_000; // µs
    while (pg.GetCurrentTimestamp() <= budget_until) {
        const conn_fd = c.accept4(metrics_fd, null, null, 2048); // SOCK_NONBLOCK
        if (conn_fd < 0) return; // EAGAIN: backlog empty
        defer _ = c.close(conn_fd);
        serveOne(conn_fd);
    }
}

fn serveOne(conn_fd: c_int) void {
    // The scraper sends its request right after connect; wait briefly for it.
    // TCP does not preserve the sender's write boundaries: a GET straddling
    // recvs parses as a wrong path and answers 404, so read to the end of the
    // request line (writeResponse parses only that first line). The socket is
    // nonblocking (accept4 SOCK_NONBLOCK) — poll between recvs. 50ms: a
    // loopback scraper's line lands in the first poll, a legitimately laggy
    // client gets its inter-fragment gap covered (e2e-metrics drives a 20ms
    // one), and a client that connects and dribbles burns at most 50ms of
    // the cycle's 250ms scrape budget before its connection is dropped (the
    // budget, not this deadline, is the per-cycle cap on scraper overhead).
    var poll_fds = [1]net.pollfd{.{ .fd = conn_fd, .events = 1, .revents = 0 }}; // POLLIN
    const deadline = pg.GetCurrentTimestamp() + 50_000; // µs
    var req_buf: [512]u8 = undefined;
    var got: usize = 0;
    while (got < req_buf.len) {
        const left_ms: c_int = @intCast(@divTrunc(@max(0, deadline - pg.GetCurrentTimestamp()), 1000));
        if (net.poll(&poll_fds, 1, left_ms) <= 0) break;
        const nread = recvSome(conn_fd, req_buf[got..]);
        if (nread == 0) break;
        got += nread;
        if (std.mem.findScalar(u8, req_buf[0..got], '\n') != null) break; // line complete
    }
    if (got == 0) return;
    // metrics.body_cap + the status line/headers (metrics.writeResponse
    // renders the body into its own body_cap buffer, then copies it here).
    var resp_buf: [metrics.body_cap + 512]u8 = undefined;
    var resp_w = std.Io.Writer.fixed(&resp_buf);
    metrics.writeResponse(&resp_w, req_buf[0..got], capture.snapshot()) catch return;
    _ = writeAll(conn_fd, resp_w.buffered(), true, null);
}

// --- signals -------------------------------------------------------------------

fn handleTerm(sig: c_int) callconv(.c) void {
    _ = sig;
    // Counter, not flag: the first TERM asks for a graceful flush, a second
    // demands immediate exit (see send_conn_fd).
    const n = got_sigterm.read() + 1;
    got_sigterm.set(n);
    if (n >= 2 and send_conn_fd >= 0) closeSendFd(send_conn_fd);
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
