//! pg_logtap: PostgreSQL log tap → ring buffer → JSON export.
//! M1: capture via emit_log_hook (capture.zig); pure logic in ring/filter.
//! M3: export worker (worker.zig).
const pg = @import("pgzx").c;
const fmgr = @import("pgzx").fmgr;
const elog = @import("pgzx").elog;
const capture = @import("capture.zig");
const worker = @import("worker.zig");

pub const version = @import("version.zig").version;

comptime {
    fmgr.PG_MODULE_MAGIC();
    fmgr.PG_FUNCTION_INFO_V1("pg_logtap_version");
    fmgr.PG_FUNCTION_INFO_V1("pg_logtap_stats");
    fmgr.PG_FUNCTION_INFO_V1("pg_logtap_stats_json");
    fmgr.PG_FUNCTION_INFO_V1("pg_logtap_dump");
    fmgr.PG_FUNCTION_INFO_V1("pg_logtap_worker");
}

export fn pg_logtap_version(fcinfo: pg.FunctionCallInfo) pg.Datum {
    _ = fcinfo;
    const txt = pg.cstring_to_text(version);
    return @intFromPtr(txt);
}

export fn pg_logtap_stats(fcinfo: pg.FunctionCallInfo) pg.Datum {
    _ = fcinfo;
    // statsText prints into zbuf (leaving one zero byte as NUL terminator).
    var zbuf: [384]u8 = [_]u8{0} ** 384;
    _ = capture.statsText(zbuf[0 .. zbuf.len - 1]);
    return @intFromPtr(pg.cstring_to_text(@ptrCast(&zbuf)));
}

export fn pg_logtap_stats_json(fcinfo: pg.FunctionCallInfo) pg.Datum {
    _ = fcinfo;
    var zbuf: [384]u8 = [_]u8{0} ** 384;
    _ = capture.statsJson(zbuf[0 .. zbuf.len - 1]);
    return @intFromPtr(pg.cstring_to_text(@ptrCast(&zbuf)));
}

export fn pg_logtap_dump(fcinfo: pg.FunctionCallInfo) pg.Datum {
    return capture.dumpDatum(fcinfo);
}

export fn pg_logtap_worker(fcinfo: pg.FunctionCallInfo) pg.Datum {
    _ = fcinfo;
    worker.workerMain();
    return 0;
}

export fn _PG_init() void { // zlinter-disable-current-line function_naming - имя фиксировано PostgreSQL
    elog.Log(@src(), "pg_logtap " ++ version ++ " loaded", .{});
    capture.init();
    worker.init();
}
