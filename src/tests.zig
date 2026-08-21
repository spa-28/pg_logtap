//! Unit-test root: imports only pure modules (no pgzx/pgsys) so the test
//! binary links standalone — PG symbols exist only inside postgres.
comptime {
    _ = @import("version.zig");
    _ = @import("ring.zig");
    _ = @import("filter.zig");
    _ = @import("jsonl.zig");
    _ = @import("export.zig");
    _ = @import("gzip.zig");
    _ = @import("metrics.zig");
}
