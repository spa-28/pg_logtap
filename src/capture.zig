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
/// Slot backing bytes: capacity × strideFor(state.message_max) of them. The
/// stride lives in ShmState (not in each process's GUC copy) so every forked
/// backend addresses the slots identically.
var entries_base: [*]u8 = undefined;
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
var guc_message_max: c_int = 1024;

/// Compiled from the GUCs on every assign; read-only in the hook (E1).
var filter_cache = filter.Filter{};
/// Compiled pg_logtap.redact_pattern; null unless the GUC is set.
var redactor: ?filter.Redactor = null;

/// Redaction scratch: the password-token cut writes one buffer, the regex
/// pass the other, so the hook never allocates. One byte over the message
/// width — the largest text field — so a full-length field still gets its
/// NUL terminator without losing a byte to it.
/// Sized at the BSS comptime maximum and sliced to message_max at use:
/// demand-zero under fork means only touched pages go resident (the
/// postmaster never touches them — the MyProc gate below exits first), and
/// the hook still never allocates, through any number of emergency restarts.
var redact_a: [ring.max_message + 1]u8 = undefined;
var redact_b: [ring.max_message + 1]u8 = undefined;
/// Hold for the layered message between copyMsg and ring.push: the layers
/// leave their result in redact_b, and the very next copyText (.detail)
/// overwrites it — the fixed fields were saved by setStr into the stack
/// entry, the variable-width message needs this buffer. Same BSS sizing.
var msg_hold: [ring.max_message]u8 = undefined;

/// Runtime message width — shmem's value, not the local GUC copy.
pub fn messageMax() usize {
    return if (ready) state.message_max else ring.default_message;
}

fn ringQ() ring.Ring {
    return ring.Ring.init(state, entries_base, ring.strideFor(state.message_max));
}

pub fn init() void {
    pg.DefineCustomIntVariable("pg_logtap.level_min", "Minimum elevel to capture (10=DEBUG5, 15=LOG, 19=WARNING, 21=ERROR, 23=PANIC). Filters export only — stderr/log_destination output is governed by the server's own log_min_messages.", null, &guc_level_min, 15, 10, 23, pg.PGC_SIGHUP, 0, null, assignLevel, null);
    pg.DefineCustomStringVariable("pg_logtap.pattern", "POSIX ERE; capture only matching messages (empty = all).", null, &guc_pattern, "", pg.PGC_SIGHUP, 0, null, assignPattern, null);
    pg.DefineCustomStringVariable("pg_logtap.pattern_exclude", "POSIX ERE; skip matching events — the pattern is matched against the event's whole text: message, detail, hint, context and the captured query (only when field_query is on). pattern_include still matches the message alone.", null, &guc_pattern_exclude, "", pg.PGC_SIGHUP, 0, null, assignPatternExclude, null);
    pg.DefineCustomStringVariable("pg_logtap.redact_pattern", "POSIX ERE; every match in message/detail/hint/context/query is replaced with <REDACTED> before the event leaves the server. Best-effort PII masking (a determined writer can evade any pattern) — the password token in logged statements is cut always, independently of this setting, and so are bind-parameter values (the DETAIL line log_parameter_max_length adds to statement lines). Avoid backreferences: they leave the libc fast matcher and can take seconds per message.", null, &guc_redact_pattern, "", pg.PGC_SIGHUP, 0, null, assignRedact, null);
    pg.DefineCustomBoolVariable("pg_logtap.field_query", "Capture the current query text with each event. SECURITY: queries can embed tokens and personal data beyond passwords (literals in INSERTs) — the standalone password token is cut always and redact_pattern masks its matches, but everything else ships as written; leave off unless the receiver is trusted. log_min_duration_statement puts query text into message regardless of this setting; pattern_exclude suppresses whole events at capture.", null, &guc_field_query, false, pg.PGC_SIGHUP, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.ring_capacity", "Ring buffer capacity in events; restart required.", null, &guc_ring_capacity, 1024, 128, @intCast(ring.max_capacity), pg.PGC_POSTMASTER, 0, null, null, null);
    pg.DefineCustomIntVariable("pg_logtap.message_max", "Width in bytes of each event's message field; longer messages are cut at a UTF-8 character boundary and named in truncated. Other fields stay 256 bytes. Shared memory cost is ring_capacity × (message_max + ~2.4 KB); restart required. Default keeps the slot byte-identical to 0.3.x (3.4 KB).", null, &guc_message_max, 1024, @intCast(ring.default_message), @intCast(ring.max_message), pg.PGC_POSTMASTER, 0, null, null, null);

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
    const span_len = if (newval == null) 0 else std.mem.span(@as([*:0]const u8, @ptrCast(newval))).len;
    redactor = compileOrWarn(filter.Redactor, newval, "pg_logtap.redact_pattern");
    // null also covers "pattern empty = layer off", which is not a failure
    setRedactPatternFailed(redactor == null and span_len > 0);
}

fn compileOrWarn(comptime T: type, pattern: [*c]const u8, guc: [*:0]const u8) ?T {
    if (pattern == null) return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(pattern)));
    if (span.len == 0) return null;
    var diag = filter.CompileDiag{};
    return T.compileDiag(span, &diag) orelse {
        std.log.warn("regex in {s} did not compile, ignoring: {s}", .{ guc, diag.text() }); // no ereport inside GUC machinery
        return null;
    };
}

fn rebuildFilter() void {
    filter_cache.deinit();
    filter_cache.level_min = guc_level_min;
    filter_cache.include = compileOrWarn(filter.Regex, guc_pattern, "pg_logtap.pattern");
    filter_cache.exclude = compileOrWarn(filter.Regex, guc_pattern_exclude, "pg_logtap.pattern_exclude");
    if (redactor) |*r| r.deinit();
    const span_len = if (guc_redact_pattern == null) 0 else std.mem.span(@as([*:0]const u8, @ptrCast(guc_redact_pattern))).len;
    redactor = compileOrWarn(filter.Redactor, guc_redact_pattern, "pg_logtap.redact_pattern");
    setRedactPatternFailed(redactor == null and span_len > 0);
}

// --- shared memory -----------------------------------------------------------

fn shmemRequestHook() callconv(.c) void {
    const cap: usize = @intCast(guc_ring_capacity);
    pg.RequestAddinShmemSpace(@sizeOf(ring.ShmState) + @as(usize, ring.strideFor(@intCast(guc_message_max))) * cap);
}

fn shmemStartupHook() callconv(.c) void {
    // PG18: the tranche counter lives in shared memory; allocating it anywhere
    // before shmem exists (request hook, _PG_init) segfaults.
    tranche_id = pg.LWLockNewTrancheId();
    pg.LWLockRegisterTranche(tranche_id, state_name);
    var found = false;
    state = @ptrCast(@alignCast(pg.ShmemInitStruct(state_name, @sizeOf(ring.ShmState), &found) orelse return));
    const cap: usize = @intCast(guc_ring_capacity);
    const stride = ring.strideFor(@intCast(guc_message_max));
    const eptr = pg.ShmemInitStruct(entries_name, @as(usize, stride) * cap, &found);
    entries_base = @ptrCast(eptr orelse return);
    if (!found) {
        state.* = std.mem.zeroes(ring.ShmState);
        state.capacity = @intCast(cap);
        state.message_max = @intCast(guc_message_max);
        // Seed seq from the wall clock (µs since 2000-01-01): each second of
        // uptime advances the seed by 1e6 but consumes <1e6 values unless the
        // capture rate exceeds 1M events/s, so seq never repeats on a host
        // across restarts — receivers may dedup on (host, seq) long-term.
        state.seq_next = @intCast(pg.GetCurrentTimestamp());
        @memset(entries_base[0 .. @as(usize, stride) * cap], 0);
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
    // Re-entrancy guard first and total: prev_hook may be an extension that
    // logs from inside its hook (audit hooks do), and forwarding — or
    // capturing — the nested line re-enters hook → elog → hook without
    // bound. The nested line still reaches the server log (elog prints it
    // regardless); it is only exempt from hook processing.
    if (in_hook) return;
    in_hook = true;
    defer in_hook = false;
    if (prev_hook) |p| p(edata);
    if (!ready) return;
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
    // pattern_exclude sees every text field the event would carry — the
    // query only when it is actually captured (field_query), matching what
    // ships: no excluding on text that never leaves the process.
    const filter_extra = [_]?[*:0]const u8{
        @as(?[*:0]const u8, @ptrCast(d.detail)),
        @as(?[*:0]const u8, @ptrCast(d.hint)),
        @as(?[*:0]const u8, @ptrCast(d.context)),
        if (guc_field_query) @as(?[*:0]const u8, @ptrCast(pg.debug_query_string)) else null,
    };
    if (!filter_cache.accepts(d.elevel, msg, &filter_extra)) return;

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
    // lines, simple AND extended protocol — see filter.stmtLine) carries the
    // raw SQL, passwords included; the token cut is gated on that marker so
    // an ordinary message mentioning the word is untouched.
    const msg_span = std.mem.span(@as([*:0]const u8, @ptrCast(d.message)));
    const stmt_line = filter.stmtLine(msg_span);
    const msg_bytes = copyMsg(&entry, d.message, stmt_line);
    // Bind values (log_parameter_max_length) ride DETAIL on statement lines —
    // the secret sits there, not in the placeholder SQL the token cut sees.
    copyText(&entry.detail, &entry, .detail, d.detail, false, stmt_line);
    copyText(&entry.hint, &entry, .hint, d.hint, false, false);
    copyText(&entry.context, &entry, .context, d.context, false, false);
    copyStr(&entry.filename, &entry, .filename, d.filename);
    copyStr(&entry.funcname, &entry, .funcname, d.funcname);
    if (guc_field_query) copyText(&entry.query, &entry, .query, pg.debug_query_string, true, false);

    lockRing();
    const was_empty = state.count == 0;
    _ = ring.push(ringQ(), entry, msg_bytes);
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

/// Run text through the redaction layers: the `password` token cut (pw —
/// query field always, statement-embedded message lines) or the bind-value
/// mask (bind_params — DETAIL on statement lines; the two never coexist on
/// one field) into one scratch buffer, then the redact_pattern regex over
/// the result into the other. Layers that cannot change the text copy
/// nothing.
fn maskThroughLayers(text: []const u8, pw: bool, bind_params: bool) filter.Masked {
    var out = filter.Masked{ .text = text, .clipped = false };
    if (pw) out = filter.redactPassword(redact_a[0 .. messageMax() + 1], out.text);
    if (bind_params) out = filter.redactParamValues(redact_a[0 .. messageMax() + 1], out.text);
    if (redactor) |*red| out = red.apply(redact_b[0 .. messageMax() + 1], out.text);
    return out;
}

/// Copy a C string field through the redaction layers into its fixed slot.
/// A layer that had to clip sets the field's redacted bit itself: setStr
/// cannot, because the clipped result fits the slot — and the cause is the
/// clip, not the slot.
fn copyText(dst: anytype, entry: *ring.ShmLogEntry, field: ring.TruncField, src: [*c]const u8, pw: bool, bind_params: bool) void {
    if (src == null) return;
    const masked = maskThroughLayers(std.mem.span(@as([*:0]const u8, @ptrCast(src))), pw, bind_params);
    ring.setStr(dst, &entry.truncated_mask, field, masked.text);
    if (masked.clipped) entry.redacted_mask |= @as(u16, 1) << @intCast(@intFromEnum(field));
}

/// The message variant of copyText: same layers (bind values never ride the
/// message — the Parameters line is DETAIL-only), but the result lands in
/// msg_hold via setMsg (the slot's message region is variable-width) and the
/// copied slice is returned for ring.push — it must
/// survive until push, and the layers' own buffer (redact_b) does not: the
/// next copyText overwrites it.
fn copyMsg(entry: *ring.ShmLogEntry, src: [*c]const u8, pw: bool) []const u8 {
    const masked = maskThroughLayers(std.mem.span(@as([*:0]const u8, @ptrCast(src))), pw, false);
    const held = ring.setMsg(&entry.message_len, &entry.truncated_mask, masked.text, msg_hold[0..messageMax()]);
    if (masked.clipped) entry.redacted_mask |= @as(u16, 1) << @intCast(@intFromEnum(ring.TruncField.message));
    return held;
}

// --- worker side ---------------------------------------------------------------

/// Pop one event: head into head_out, message bytes into msg_out (worker-
/// owned, message_max-sized). One lock round per event — the same bytes move
/// as the old 64-event batch under one hold, with the worst single hold 64×
/// shorter, which is what a logging backend stuck behind the lock feels.
pub fn drainOne(head_out: *ring.ShmLogEntry, msg_out: []u8) bool {
    if (!ready) return false;
    lockRing();
    defer unlockRing();
    return ring.pop(ringQ(), head_out, msg_out);
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

/// Worker-owned gauges, republished every flush cycle: the worker-local
/// originals (dns_fail_streak, fb_broken) die with the process, so a restart
/// must overwrite possibly-stale copies here within one cycle.
pub fn setWorkerGauges(dns_fail: u32, fb_broken: u8) void {
    if (!ready) return;
    lockRing();
    state.dns_fail_streak = dns_fail;
    state.fallback_broken = fb_broken;
    unlockRing();
}

/// Redaction compile health. Set from the GUC assign hook (SIGHUP runs in
/// whichever backend reloads) and the startup rebuild: a pattern that does
/// not compile leaves that layer OFF (fail-open) — the gauge is the signal.
/// The postmaster also runs assign hooks on its own SIGHUP reload, and it
/// has no PGPROC: waiting on a contended LWLock there PANICs the whole
/// cluster. Skip in that process — every backend runs the same assign on
/// its own reload a moment later, so the gauge still converges.
pub fn setRedactPatternFailed(on: bool) void {
    if (!ready) return;
    if (pg.MyProc == null) return;
    lockRing();
    state.redact_pattern_failed = @intFromBool(on);
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
    // The copy buffers themselves are palloc'd BEFORE the lock for the same
    // reason (elogs while the lock is still unheld); the query context owns
    // them. The message area is capped at 64MiB total: at the message_max
    // ceiling a full 1024-row dump would ask palloc for ~1GiB.
    const mmax: usize = state.message_max;
    const mb_cap: u32 = @intCast(@divTrunc(64 * 1024 * 1024, mmax));
    const eff_limit: u32 = @min(limit, mb_cap);
    const copies: []ring.ShmLogEntry = (@as([*]ring.ShmLogEntry, @ptrCast(@alignCast(pg.palloc(@sizeOf(ring.ShmLogEntry) * eff_limit)))))[0..eff_limit];
    const msg_area: []u8 = @as([*]u8, @ptrCast(pg.palloc(mmax * eff_limit)))[0 .. mmax * eff_limit];
    lockRing();
    const count = @min(ring.snapshot(ringQ()).count, eff_limit);
    var taken: u32 = 0;
    while (taken < count) : (taken += 1) {
        if (!ring.peek(ringQ(), taken, &copies[taken], msg_area[taken * mmax ..][0..mmax])) break;
    }
    unlockRing();

    var datums: [max_dump]pg.Datum = undefined;
    var out_rows: u32 = 0;
    while (out_rows < taken) : (out_rows += 1) {
        const ent = &copies[out_rows];
        var line_w: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer line_w.deinit();
        jsonl.writeEntry(&line_w.writer, ent, msg_area[out_rows * mmax ..][0..ent.message_len], resolveNames(ent)) catch break;
        const line = line_w.written();
        datums[out_rows] = @intFromPtr(pg.cstring_to_text_with_len(@ptrCast(line.ptr), @intCast(line.len)));
    }
    return @intFromPtr(pg.construct_array_builtin(&datums, @intCast(out_rows), text_oid));
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
    return std.fmt.bufPrint(buf, "events_captured={d} events_dropped={d} events_sent={d} events_queued={d} events_replayed={d} send_cycles_failed={d} events_lost={d} ring_events={d} ring_capacity={d} dns_fail_streak={d} fallback_broken={d} redact_pattern_failed={d}", .{
        snap.captured, snap.dropped, snap.sent, snap.queued, snap.replayed, snap.send_failed, snap.export_lost, snap.count, snap.capacity, snap.dns_fail_streak, snap.fallback_broken, snap.redact_pattern_failed,
    }) catch "stats overflow";
}

/// Same counters as JSON with the full column names of pg_logtap_delivery
/// (plus the derived queue_backlog / delivered).
pub fn statsJson(buf: []u8) ?[]const u8 {
    if (!ready) return "{\"events_captured\":0}"; // shmem not up: zero row
    const snap = snapshot();
    return std.fmt.bufPrint(buf, "{{\"events_captured\":{d},\"events_dropped\":{d},\"events_sent\":{d},\"events_queued\":{d},\"events_replayed\":{d},\"queue_backlog\":{d},\"delivered\":{d},\"events_lost\":{d},\"send_cycles_failed\":{d},\"ring_events\":{d},\"ring_capacity\":{d},\"dns_fail_streak\":{d},\"fallback_broken\":{d},\"redact_pattern_failed\":{d}}}", .{
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
        snap.dns_fail_streak,
        snap.fallback_broken,
        snap.redact_pattern_failed,
    }) catch "{\"events_captured\":0}";
}

/// Consistent counter/gauge snapshot for /metrics.
pub fn snapshot() ring.Stats {
    if (!ready) return std.mem.zeroes(ring.Stats);
    lockRing();
    defer unlockRing();
    return ring.snapshot(ringQ());
}
