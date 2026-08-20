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
var guc_ring_capacity: c_int = 1024;

/// Compiled from the GUCs on every assign; read-only in the hook (E1).
var filter_cache = filter.Filter{};

pub fn init() void {
    pg.DefineCustomIntVariable("pg_logtap.level_min", "Minimum elevel to capture (10=DEBUG5 .. 22=PANIC).", null, &guc_level_min, 15, 10, 22, pg.PGC_SIGHUP, 0, null, assignLevel, null);
    pg.DefineCustomStringVariable("pg_logtap.pattern", "POSIX ERE; capture only matching messages (empty = all).", null, &guc_pattern, "", pg.PGC_SIGHUP, 0, null, assignPattern, null);
    pg.DefineCustomStringVariable("pg_logtap.pattern_exclude", "POSIX ERE; skip matching messages.", null, &guc_pattern_exclude, "", pg.PGC_SIGHUP, 0, null, assignPatternExclude, null);
    pg.DefineCustomBoolVariable("pg_logtap.field_query", "Capture the current query text with each event.", null, &guc_field_query, false, pg.PGC_SIGHUP, 0, null, null, null);
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
    filter_cache.include = compileOrWarn(newval, "pg_logtap.pattern");
}

fn assignPatternExclude(newval: [*c]const u8, extra: ?*anyopaque) callconv(.c) void {
    _ = extra;
    if (filter_cache.exclude) |*re| re.deinit();
    filter_cache.exclude = compileOrWarn(newval, "pg_logtap.pattern_exclude");
}

fn compileOrWarn(pattern: [*c]const u8, guc: [*:0]const u8) ?filter.Regex {
    if (pattern == null) return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(pattern)));
    if (span.len == 0) return null;
    return filter.Regex.compile(span) orelse {
        std.log.warn("invalid regex in {s}, ignoring", .{guc}); // no ereport inside GUC machinery
        return null;
    };
}

fn rebuildFilter() void {
    filter_cache.deinit();
    filter_cache.level_min = guc_level_min;
    filter_cache.include = compileOrWarn(guc_pattern, "pg_logtap.pattern");
    filter_cache.exclude = compileOrWarn(guc_pattern_exclude, "pg_logtap.pattern_exclude");
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

    copyStr(&entry.message, &entry, .message, d.message);
    copyStr(&entry.detail, &entry, .detail, d.detail);
    copyStr(&entry.hint, &entry, .hint, d.hint);
    copyStr(&entry.context, &entry, .context, d.context);
    copyStr(&entry.filename, &entry, .filename, d.filename);
    copyStr(&entry.funcname, &entry, .funcname, d.funcname);
    if (guc_field_query) copyStr(&entry.query, &entry, .query, pg.debug_query_string);

    lockRing();
    _ = ring.push(ring.Ring.init(state, entries), entry);
    unlockRing();
}

/// Copy a C string field into the entry, tracking truncation in its mask.
fn copyStr(dst: anytype, entry: *ring.ShmLogEntry, field: ring.TruncField, src: [*c]const u8) void {
    if (src == null) return;
    ring.setStr(dst, &entry.truncated_mask, field, std.mem.span(@as([*:0]const u8, @ptrCast(src))));
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

pub fn bumpExport(exported: u64, failed: u64, lost: u64) void {
    if (!ready) return;
    lockRing();
    state.exported += exported;
    state.export_failed += failed;
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

    var datums: [max_dump]pg.Datum = undefined;
    const ring_q = ring.Ring.init(state, entries);
    lockRing();
    const count = @min(ring.snapshot(ring_q).count, limit);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = ring.peek(ring_q, i) orelse break;
        var line_w: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer line_w.deinit();
        jsonl.writeEntry(&line_w.writer, &entry, resolveNames(&entry)) catch break;
        const line = line_w.written();
        datums[i] = @intFromPtr(pg.cstring_to_text_with_len(@ptrCast(line.ptr), @intCast(line.len)));
    }
    unlockRing();
    return @intFromPtr(pg.construct_array_builtin(&datums, @intCast(i), text_oid));
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
    return std.fmt.bufPrint(buf, "captured={d} dropped={d} exported={d} failed={d} lost={d} count={d} capacity={d}", .{
        snap.captured, snap.dropped, snap.exported, snap.export_failed, snap.export_lost, snap.count, snap.capacity,
    }) catch "stats overflow";
}

/// Consistent counter/gauge snapshot for /metrics.
pub fn snapshot() ring.Stats {
    if (!ready) return std.mem.zeroes(ring.Stats);
    lockRing();
    defer unlockRing();
    return ring.snapshot(ring.Ring.init(state, entries));
}
