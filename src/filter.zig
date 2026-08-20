//! Capture filters: level threshold + POSIX regex include/exclude.
//! Pure module: libc only, no PostgreSQL imports — regexes are compiled once
//! per GUC assignment (PROBLEMS.md E1), never inside the log hook.
const std = @import("std");

/// glibc regex_t is 64 bytes on x86-64/aarch64; opaque reservation.
const regex_t_size = 64;
const reg_extended: c_int = 1;
const reg_nosub: c_int = 8;

extern fn regcomp(preg: *anyopaque, pattern: [*:0]const u8, cflags: c_int) c_int;
extern fn regexec(preg: *const anyopaque, string: [*:0]const u8, nmatch: usize, pmatch: ?*anyopaque, eflags: c_int) c_int;
extern fn regfree(preg: *anyopaque) void;

pub const Regex = struct {
    buf: [regex_t_size]u8 align(8) = [_]u8{0} ** regex_t_size,
    compiled: bool = false,

    /// Returns null on invalid pattern.
    pub fn compile(pattern: [:0]const u8) ?Regex {
        var self = Regex{};
        if (regcomp(&self.buf, pattern.ptr, reg_extended | reg_nosub) != 0) return null;
        self.compiled = true;
        return self;
    }

    pub fn deinit(self: *Regex) void {
        if (self.compiled) regfree(&self.buf);
        self.compiled = false;
    }

    /// Input must be NUL-terminated — our sources are C strings already.
    pub fn matches(self: *const Regex, s: [*:0]const u8) bool {
        if (!self.compiled) return true;
        return regexec(&self.buf, s, 0, null, 0) == 0;
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
