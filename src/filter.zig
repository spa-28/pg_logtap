//! Capture filters: level threshold + POSIX regex include/exclude.
//! Pure module: libc only, no PostgreSQL imports — regexes are compiled once
//! per GUC assignment (PROBLEMS.md E1), never inside the log hook. The
//! compiled state lives behind an opaque box owned by src/c/regex_shim.c:
//! regex_t layout is libc- and arch-specific (glibc's even has bitfields,
//! opaque to translate-c), so the buffer is allocated in C against the
//! TARGET libc — the previous hardcoded 64-byte reservation in Zig (glibc
//! x86-64) was stack corruption in every backend wherever it didn't match.
//!
//! regexec has no timeout, and matches() runs in every logging backend.
//! Measured: plain EREs are linear on both glibc and musl ((a+)+b, (a|aa)+b,
//! (x+x+)+y at n=1000 → ≤3 ms); backreferences (\1) drop glibc off its fast
//! matcher to ~n^2.6 (measured 47/91/163 ms at n=100/130/160 → ~20 s at the
//! 1024-byte message-slot cap) — avoid \1 and friends in patterns.
const std = @import("std");

/// Allocated by src/c/regex_shim.c; size is the target libc's own.
pub const LtRegex = opaque {};

extern fn lt_regex_compile(pattern: [*:0]const u8) ?*LtRegex;
extern fn lt_regex_free(re: *LtRegex) void;
extern fn lt_regex_matches(re: *const LtRegex, s: [*:0]const u8) c_int;

pub const Regex = struct {
    re: *LtRegex,

    /// Returns null on invalid pattern (or OOM).
    pub fn compile(pattern: [:0]const u8) ?Regex {
        return .{ .re = lt_regex_compile(pattern.ptr) orelse return null };
    }

    pub fn deinit(self: *Regex) void {
        lt_regex_free(self.re);
    }

    /// Input must be NUL-terminated — our sources are C strings already.
    pub fn matches(self: *const Regex, s: [*:0]const u8) bool {
        return lt_regex_matches(self.re, s) != 0;
    }
};

pub const Filter = struct {
    level_min: i32 = 15, // LOG
    include: ?Regex = null,
    exclude: ?Regex = null,

    pub fn deinit(self: *Filter) void {
        if (self.include) |*re| re.deinit();
        if (self.exclude) |*re| re.deinit();
        self.include = null;
        self.exclude = null;
    }

    pub fn accepts(self: *const Filter, elevel: i32, message: [*:0]const u8) bool {
        if (elevel < self.level_min) return false;
        if (self.include) |*re| if (!re.matches(message)) return false;
        if (self.exclude) |*re| if (re.matches(message)) return false;
        return true;
    }
};

test "level threshold" {
    var flt = Filter{ .level_min = 19 }; // ERROR
    try std.testing.expect(!flt.accepts(15, "log"));
    try std.testing.expect(flt.accepts(19, "error"));
    try std.testing.expect(flt.accepts(21, "fatal"));
}

test "regex include/exclude" {
    var flt = Filter{};
    flt.include = Regex.compile("duplicate key.*") orelse return error.CompileFailed;
    defer flt.deinit();
    try std.testing.expect(flt.accepts(15, "duplicate key value violates"));
    try std.testing.expect(!flt.accepts(15, "relation not found"));
    try std.testing.expect(!flt.accepts(19, "other message")); // include regex misses
}

test "empty pattern compiles to always-match" {
    var flt = Filter{};
    flt.include = Regex.compile("") orelse return error.CompileFailed;
    defer flt.deinit();
    try std.testing.expect(flt.include != null);
}

test "invalid pattern rejected" {
    try std.testing.expect(Regex.compile("[unclosed") == null);
}
