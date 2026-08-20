//! Pure logic: no pgzx/pgsys imports — unit-testable without a PostgreSQL binary.
const std = @import("std");

pub const version = "0.1.0";

test "version constant" {
    try std.testing.expectEqualStrings("0.1.0", version);
}
