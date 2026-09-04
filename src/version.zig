//! Pure logic: no pgzx/pgsys imports — unit-testable without a PostgreSQL binary.
const std = @import("std");

pub const version = "0.4.4";

test "version constant" {
    try std.testing.expectEqualStrings("0.4.4", version);
}
