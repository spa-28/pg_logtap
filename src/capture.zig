//! emit_log_hook capture into the shared-memory ring. All PostgreSQL
//! interop lives here; ring.zig/filter.zig stay pure and unit-tested.
const std = @import("std");

const pg = @import("pgzx").c;
const ring = @import("ring.zig");
const filter = @import("filter.zig");
const jsonl = @import("jsonl.zig");
const args = @import("pgzx").fmgr.args;

const state_name = "pg_logtap";
const entries_name = "pg_logtap:entries";

var state: *ring.ShmState = undefined;
var entries: []ring.ShmLogEntry = undefined;
/// Set by the shmem startup hook in the postmaster; inherited by fork.
var ready = false;
var tranche_id: c_int = 0;

/// Previous hook, called first (PROBLEMS.md B1: never swallow other hooks).
var prev_hook: pg.emit_log_hook_type = null;
/// Reentrancy guard: our own ereport inside the hook must not loop.
var in_hook = false;

// GUC-backed process-local values (reloaded per-backend on SIGHUP).
var guc_level_min: c_int = 15; // LOG
var guc_pattern: [*c]u8 = null;
var guc_pattern_exclude: [*c]u8 = null;
var guc_field_query: bool = false;
var guc_redact_pattern: [*c]u8 = null;
var guc_ring_capacity: c_int = 1024;

/// Compiled from the GUCs on every assign; read-only in the hook (E1).
var filter_cache = filter.Filter{};
/// Compiled pg_logtap.redact_pattern; null unless the GUC is set.
var redactor: ?filter.Redactor = null;

/// Redaction scratch: the password-token cut writes one buffer, the regex
/// pass the other, so the hook never allocates. One byte over the message
/// slot — the largest text field — so a full-length field still gets its
/// NUL terminator without losing a byte to it.
var redact_a: [ring.msg_len + 1]u8 = undefined;
var redact_b: [ring.msg_len + 1]u8 = undefined;

pub fn init() void {
    pg.DefineCustomIntVariable("pg_logtap.level_min", "Minimum elevel to capture (10=DEBUG5, 15=LOG, 19=WARNING, 21=ERROR, 23=PANIC). Filters export only — stderr/log_destination output is governed by the server's own log_min_messages.", null, &guc_level_min, 15, 10, 23, pg.PGC_SIGHUP, 0, null, assignLevel, null);
    pg.DefineCustomStringVariable("pg_logtap.pattern", "POSIX ERE; capture only matching messages (empty = all).", null, &guc_pattern, "", pg.PGC_SIGHUP, 0, null, assignPattern, null);
    pg.DefineCustomStringVariable("pg_logtap.pattern_exclude", "POSIX ERE; skip matching messages.", null, &guc_pattern_exclude, "", pg.PGC_SIGHUP, 0, null, assignPatternExclude, null);
    pg.DefineCustomStringVariable("pg_logtap.redact_pattern", "POSIX ERE; every match in message/detail/hint/context/query is replaced with <REDACTED> before the event leaves the server. Best-effort PII masking (a determined writer can evade any pattern) — the password token in logged statements is cut always, independently of this setting. Avoid backreferences: they leave the libc fast matcher and can take seconds per message.", null, &guc_redact_pattern, "", pg.PGC_SIGHUP, 0, null, assignRedact, null);
    pg.DefineCustomBoolVariable("pg_logtap.field_query", "Capture the current query text with each event. SECURITY: queries can embed tokens and personal data beyond passwords (literals in INSERTs) — the standalone password token is cut always and redact_pattern masks its matches, but everything else ships as written; leave off unless the receiver is trusted. log_min_duration_statement puts query text into message regardless of this setting; pattern_exclude suppresses whole events at capture.", null, &guc_field_query, false, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.ring_capacity", "Ring buffer capacity in events; restart required.", null, &guc_ring_capacity, 1024, 128, @intCast(ring.max_capacity), pg.PGC_POSTMASTER, 0, null, null, null);

    pg.shmem_request_hook = shmemRequestHook;
    pg.shmem_startup_hook = shmemStartupHook;
    prev_hook = pg.emit_log_hook;
    pg.emit_log_hook = emitLogHook;
    rebuildFilter();
}

fn assignLevel(newval: c_int, extra: ?*anyopaque) callconv(.c) void {
    _ = extra;
    guc_level_min = newval;
    filter_cache.level_min = newval;
}

fn assignPattern(newval: [*c]const u8, extra: ?*anyopaque) callconv(.c) void {
    _ = extra;
    if (filter_cache.include) |*re| re.deinit();
    filter_cache.include = compileOrWarn(filter.Regex, newval, "pg_logtap.pattern");
}

fn assignPatternExclude(newval: [*c]const u8, extra: ?*anyopaque) callconv(.c) void {
    _ = extra;
    if (filter_cache.exclude) |*re| re.deinit();
    filter_cache.exclude = compileOrWarn(filter.Regex, newval, "pg_logtap.pattern_exclude");
}

fn assignRedact(newval: [*c]const u8, extra: ?*anyopaque) callconv(.c) void {
    _ = extra;
    if (redactor) |*r| r.deinit();
    redactor = compileOrWarn(filter.Redactor, newval, "pg_logtap.redact_pattern");
}

fn compileOrWarn(comptime T: type, pattern: [*c]const u8, guc: [*:0]const u8) ?T {
    if (pattern == null) return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(pattern)));
    if (span.len == 0) return null;
    return T.compile(span) orelse {
        std.log.warn("invalid regex in {s}, ignoring", .{guc}); // no ereport inside GUC machinery
        return null;
    };
}

fn rebuildFilter() void {
    filter_cache.deinit();
    filter_cache.level_min = guc_level_min;
    filter_cache.include = compileOrWarn(filter.Regex, guc_pattern, "pg_logtap.pattern");
    filter_cache.exclude = compileOrWarn(filter.Regex, guc_pattern_exclude, "pg_logtap.pattern_exclude");
    if (redactor) |*r| r.deinit();
    redactor = compileOrWarn(filter.Redactor, guc_redact_pattern, "pg_logtap.redact_pattern");
}

// --- shared memory -----------------------------------------------------------

fn shmemRequestHook() callconv(.c) void {
    const cap: usize = @intCast(guc_ring_capacity);
    pg.RequestAddinShmemSpace(@sizeOf(ring.ShmState) + @sizeOf(ring.ShmLogEntry) * cap);
}

fn shmemStartupHook() callconv(.c) void {
    // PG18: the tranche counter lives in shared memory; allocating it anywhere
    // before shmem exists (request hook, _PG_init) segfaults.
    tranche_id = pg.LWLockNewTrancheId();
    pg.LWLockRegisterTranche(tranche_id, state_name);
    var found = false;
    state = @ptrCast(@alignCast(pg.ShmemInitStruct(state_name, @sizeOf(ring.ShmState), &found) orelse return));
    const cap: usize = @intCast(guc_ring_capacity);
    const eptr = pg.ShmemInitStruct(entries_name, @sizeOf(ring.ShmLogEntry) * cap, &found);
    const ebuf: [*]ring.ShmLogEntry = @ptrCast(@alignCast(eptr orelse return));
    entries = ebuf[0..cap];
    if (!found) {
        state.* = std.mem.zeroes(ring.ShmState);
        state.capacity = @intCast(cap);
        // Seed seq from the wall clock (µs since 2000-01-01): each second of
        // uptime advances the seed by 1e6 but consumes <1e6 values unless the
        // capture rate exceeds 1M events/s, so seq never repeats on a host
        // across restarts — receivers may dedup on (host, seq) long-term.
        state.seq_next = @intCast(pg.GetCurrentTimestamp());
        @memset(entries, std.mem.zeroes(ring.ShmLogEntry));
    }
    pg.LWLockInitialize(@ptrCast(&state.lock), tranche_id);
    // Fence + magic last: backends treat the segment as usable once magic matches.
    state.magic = ring.ready_magic;
    ready = true;
}

fn lockRing() void {
    _ = pg.LWLockAcquire(@ptrCast(&state.lock), pg.LW_EXCLUSIVE);
}

fn unlockRing() void {
    pg.LWLockRelease(@ptrCast(&state.lock));
}

// --- the hook ----------------------------------------------------------------

fn emitLogHook(edata: [*c]pg.ErrorData) callconv(.c) void {
    if (prev_hook) |p| p(edata);
    if (!ready or in_hook) return;
    // The postmaster runs this hook for its own lines too — and during an
    // emergency restart it logs from inside PGSharedMemoryCreate, after the
    // old segment is already unmapped: `state` dangles there and even a read
    // SEGVs (gdb: emitLogHook ← PGSharedMemoryCreate). PGPROC-less callers
    // are exactly that process — skip them; their lines still reach stderr.
    if (pg.MyProc == null) return;
    if (edata == null) return;
    const d = edata.*;
    if (d.message == null) return;
    const msg: [*:0]const u8 = @ptrCast(d.message);
    if (!filter_cache.accepts(d.elevel, msg)) return;

    in_hook = true;
    defer in_hook = false;

    var entry = std.mem.zeroes(ring.ShmLogEntry);
    entry.timestamp_us = pg.GetCurrentTimestamp();
    entry.elevel = d.elevel;
    entry.sqlerrcode = d.sqlerrcode;
    entry.lineno = d.lineno;
    entry.pid = pg.MyProcPid;
    entry.db_oid = @intCast(pg.MyDatabaseId);
    if (pg.MyProc != null) entry.role_oid = pg.MyProc.*.roleId;
    copyStr(&entry.backend_type, &entry, .backend_type, pg.GetBackendTypeDesc(pg.MyBackendType));
    // Session context (%a/%h of log_line_prefix): read in the hooking backend
    // itself — GUC and Port are process-local, no locking needed. MyProcPort is
    // ?*Port in PG18 bindings and [*c]Port in <=17 — normalize before field access.
    if (pg.application_name != null) copyStr(&entry.app, &entry, .app, pg.application_name);
    const port: ?*pg.Port = @ptrCast(pg.MyProcPort);
    if (port) |p| copyStr(&entry.client_host, &entry, .client_host, p.remote_host);

    // Statement-embedded text (log_statement / log_min_duration_statement
    // lines) carries the raw SQL, passwords included; the token cut is gated
    // on that marker so an ordinary message mentioning the word is untouched.
    const msg_span = std.mem.span(@as([*:0]const u8, @ptrCast(d.message)));
    const stmt_line = std.mem.indexOf(u8, msg_span, "statement: ") != null;
    copyText(&entry.message, &entry, .message, d.message, stmt_line);
    copyText(&entry.detail, &entry, .detail, d.detail, false);
    copyText(&entry.hint, &entry, .hint, d.hint, false);
    copyText(&entry.context, &entry, .context, d.context, false);
    copyStr(&entry.filename, &entry, .filename, d.filename);
    copyStr(&entry.funcname, &entry, .funcname, d.funcname);
    if (guc_field_query) copyText(&entry.query, &entry, .query, pg.debug_query_string, true);

    lockRing();
    const was_empty = state.count == 0;
    _ = ring.push(ring.Ring.init(state, entries), entry);
    unlockRing();
    // Wake the worker the moment the ring goes non-empty: a connection burst
    // at debug1 (~85k events/s from 16 pgbench connects) fills the whole ring
    // in one 100ms sleep otherwise. SetLatch on the worker's shmem latch is
    // the standard inter-process poke in PostgreSQL.
    if (was_empty and state.worker_latch != 0) pg.SetLatch(@ptrFromInt(state.worker_latch));
}

/// Copy a C string field into the entry, tracking truncation in its mask.
fn copyStr(dst: anytype, entry: *ring.ShmLogEntry, field: ring.TruncField, src: [*c]const u8) void {
    if (src == null) return;
    ring.setStr(dst, &entry.truncated_mask, field, std.mem.span(@as([*:0]const u8, @ptrCast(src))));
}

/// Copy a C string field through the redaction layers: the `password` token
/// cut (pw — query field always, statement-embedded message lines) into one
/// scratch buffer, then the redact_pattern regex over the result into the
/// other. Layers that cannot change the text copy nothing. A layer that had
/// to clip sets the field's truncated bit itself: setStr cannot, because the
/// clipped result fits the slot.
fn copyText(dst: anytype, entry: *ring.ShmLogEntry, field: ring.TruncField, src: [*c]const u8, pw: bool) void {
    if (src == null) return;
    var text: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(src)));
    var clipped = false;
    if (pw) {
        const m = filter.redactPassword(&redact_a, text);
        text = m.text;
        clipped = m.clipped;
    }
    if (redactor) |*r| {
        const m = r.apply(&redact_b, text);
        text = m.text;
        clipped = clipped or m.clipped;
    }
    ring.setStr(dst, &entry.truncated_mask, field, text);
    if (clipped) entry.truncated_mask |= @as(u16, 1) << @intCast(@intFromEnum(field));
}

// --- worker side ---------------------------------------------------------------

/// Pop up to batch.len events (allocation-free under the lock).
pub fn drainBatch(batch: []ring.ShmLogEntry) usize {
    if (!ready) return 0;
    const ring_q = ring.Ring.init(state, entries);
    lockRing();
    defer unlockRing();
    var taken: usize = 0;
    while (taken < batch.len) : (taken += 1) {
        batch[taken] = ring.pop(ring_q) orelse break;
    }
    return taken;
}

pub fn capacity() u32 {
    return if (ready) state.capacity else 0;
}

/// The worker publishes its latch so backends can wake it on the first
/// pushed event (see hookLog). Re-published on every worker (re)start.
pub fn setWorkerLatch() void {
    if (!ready) return;
    lockRing();
    state.worker_latch = @intFromPtr(pg.MyLatch);
    unlockRing();
}

/// Lifecycle counters — one event is counted exactly once per stage it
/// passes through: sent (live send), queued (fallback-file append),
/// replayed (queue member delivered after recovery). Stuck in the queue
/// right now = queued - replayed. failed counts CYCLES, not events.
pub fn bumpExport(sent: u64, queued: u64, replayed: u64, failed: u64, lost: u64) void {
    if (!ready) return;
    lockRing();
    state.sent += sent;
    state.queued += queued;
    state.replayed += replayed;
    state.send_failed += failed;
    state.export_lost += lost;
    unlockRing();
}

// --- dump --------------------------------------------------------------------

const text_oid: pg.Oid = 25; // TEXTOID
const max_dump = 1024;

/// SQL: pg_logtap_dump(limit) → text[] of JSON lines, non-destructive.
pub fn dumpDatum(fcinfo: pg.FunctionCallInfo) pg.Datum {
    const limit: u32 = @intCast(if (args.Arg(i32, 0).read(fcinfo)) |v| @min(@max(v, 1), max_dump) else |_| 100);
    if (!ready) {
        var none: pg.Datum = undefined;
        return @intFromPtr(pg.construct_array_builtin(&none, 0, text_oid));
    }

    // Under the lock: only the struct copy out of shmem. Everything that can
    // elog (palloc, catalog lookups) runs below, outside — an elog between
    // acquire/release longjmps past LWLockRelease, and every logging backend
    // then blocks on the held lock: an OOM in dump would hang the cluster.
    // The copy buffer itself is palloc'd BEFORE the lock for the same reason
    // (elogs while the lock is still unheld); the query context owns it.
    const copies: []ring.ShmLogEntry = (@as([*]ring.ShmLogEntry, @ptrCast(@alignCast(pg.palloc(@sizeOf(ring.ShmLogEntry) * limit)))))[0..limit];
    const ring_q = ring.Ring.init(state, entries);
    lockRing();
    const count = @min(ring.snapshot(ring_q).count, limit);
    var taken: u32 = 0;
    while (taken < count) : (taken += 1) {
        copies[taken] = ring.peek(ring_q, taken) orelse break;
    }
    unlockRing();

    var datums: [max_dump]pg.Datum = undefined;
    var n: u32 = 0;
    while (n < taken) : (n += 1) {
        var line_w: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer line_w.deinit();
        jsonl.writeEntry(&line_w.writer, &copies[n], resolveNames(&copies[n])) catch break;
        const line = line_w.written();
        datums[n] = @intFromPtr(pg.cstring_to_text_with_len(@ptrCast(line.ptr), @intCast(line.len)));
    }
    return @intFromPtr(pg.construct_array_builtin(&datums, @intCast(n), text_oid));
}

/// Catalog lookups run in the caller's memory context — palloc'd results are
/// freed when the query context resets; no manual cleanup (the PG way).
fn resolveNames(entry: *const ring.ShmLogEntry) jsonl.Names {
    const db = pg.get_database_name(entry.db_oid);
    const usr = pg.GetUserNameFromId(entry.role_oid, true);
    return .{
        .database = if (db != null) std.mem.span(@as([*:0]const u8, @ptrCast(db))) else null,
        .user = if (usr != null) std.mem.span(@as([*:0]const u8, @ptrCast(usr))) else null,
    };
}

// --- stats -------------------------------------------------------------------

pub fn statsText(buf: []u8) ?[]const u8 {
    if (!ready) return "shmem not initialized (shared_preload_libraries?)";
    const snap = snapshot();
    // Same names and order as the pg_logtap_delivery view columns.
    return std.fmt.bufPrint(buf, "events_captured={d} events_dropped={d} events_sent={d} events_queued={d} events_replayed={d} send_cycles_failed={d} events_lost={d} ring_events={d} ring_capacity={d}", .{
        snap.captured, snap.dropped, snap.sent, snap.queued, snap.replayed, snap.send_failed, snap.export_lost, snap.count, snap.capacity,
    }) catch "stats overflow";
}

/// Same counters as JSON with the full column names of pg_logtap_delivery
/// (plus the derived queue_backlog / delivered).
pub fn statsJson(buf: []u8) ?[]const u8 {
    if (!ready) return "{\"events_captured\":0}"; // shmem not up: zero row
    const snap = snapshot();
    return std.fmt.bufPrint(buf, "{{\"events_captured\":{d},\"events_dropped\":{d},\"events_sent\":{d},\"events_queued\":{d},\"events_replayed\":{d},\"queue_backlog\":{d},\"delivered\":{d},\"events_lost\":{d},\"send_cycles_failed\":{d},\"ring_events\":{d},\"ring_capacity\":{d}}}", .{
        snap.captured,
        snap.dropped,
        snap.sent,
        snap.queued,
        snap.replayed,
        snap.queued -| snap.replayed,
        snap.sent +| snap.replayed,
        snap.export_lost,
        snap.send_failed,
        snap.count,
        snap.capacity,
    }) catch "{\"events_captured\":0}";
}

/// Consistent counter/gauge snapshot for /metrics.
pub fn snapshot() ring.Stats {
    if (!ready) return std.mem.zeroes(ring.Stats);
    lockRing();
    defer unlockRing();
    return ring.snapshot(ring.Ring.init(state, entries));
}
