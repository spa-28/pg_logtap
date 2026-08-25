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
extern fn lt_regex_compile_sub(pattern: [*:0]const u8) ?*LtRegex;
/// s must be NUL-terminated at its end (our sources are C strings); reports
/// the first match as byte offsets from s.
extern fn lt_regex_find(re: *const LtRegex, s: [*]const u8, notbol: c_int, start: *usize, end: *usize) c_int;

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
    var flt = Filter{ .level_min = 19 }; // WARNING
    try std.testing.expect(!flt.accepts(15, "log"));
    try std.testing.expect(flt.accepts(19, "warning"));
    try std.testing.expect(flt.accepts(21, "error"));
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

// --- redaction ----------------------------------------------------------------
//
// Two layers, mirroring the ecosystem: core PostgreSQL masks nothing (a
// cleartext PASSWORD in a logged statement reaches stderr verbatim); pgaudit
// hardcodes an always-on cut after the `password` token for role/user-mapping
// statements, and collectors (pganalyze & friends) apply user regexes on
// their side. We have no parse tree in emit_log_hook — only text — so the
// token scan is gated by the caller (query field: always; message: only
// statement-embedded text) and the regex layer is opt-in via GUC.

pub const redacted = "<REDACTED>";

/// Copy clipped to dst, always NUL-terminating the result (scratch output
/// feeds the next regex pass, and regexec reads to the terminator). A clip
/// cuts back to a UTF-8 character boundary and reports itself — setStr
/// cannot know: the clipped result fits the slot, so it sees no truncation.
fn put(dst: []u8, s: []const u8, clipped: *bool) usize {
    if (dst.len == 0) return 0;
    var n = @min(dst.len - 1, s.len);
    if (s.len > n) {
        clipped.* = true;
        while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1; // step back onto a lead byte
    }
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
    return n;
}

fn isIdentChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Case-insensitive search for a standalone ASCII word (word = surrounded by
/// non-identifier bytes). Returns its offset.
fn findWord(hay: []const u8, word: []const u8) ?usize {
    if (word.len == 0 or hay.len < word.len) return null;
    var i: usize = 0;
    while (i + word.len <= hay.len) : (i += 1) {
        if (i > 0 and isIdentChar(hay[i - 1])) continue;
        for (word, 0..) |w, j| {
            if (std.ascii.toLower(hay[i + j]) != w) break;
            if (j + 1 == word.len) {
                if (i + word.len == hay.len or !isIdentChar(hay[i + word.len])) return i;
            }
        }
    }
    return null;
}

/// Result of a redaction pass: the masked text (a slice of src when the pass
/// changed nothing) and whether it had to clip at the scratch size.
pub const Masked = struct { text: []const u8, clipped: bool };

/// Everything from the end of a standalone `password` token on is dropped and
/// replaced (pgaudit semantics). Returns src untouched when no token is
/// present — the common case costs one scan, no copy.
pub fn redactPassword(dst: []u8, src: []const u8) Masked {
    const pos = findWord(src, "password") orelse return .{ .text = src, .clipped = false };
    var clipped = false;
    var w = put(dst, src[0 .. pos + "password".len], &clipped);
    w += put(dst[w..], " " ++ redacted, &clipped);
    return .{ .text = dst[0..w], .clipped = clipped };
}

/// Whole-match regex redaction: every match of the pattern becomes
/// <REDACTED>. Same libc caveats as Regex (see the header note on
/// backreferences).
pub const Redactor = struct {
    re: *LtRegex,

    pub fn compile(pattern: [:0]const u8) ?Redactor {
        return .{ .re = lt_regex_compile_sub(pattern.ptr) orelse return null };
    }

    pub fn deinit(self: *Redactor) void {
        lt_regex_free(self.re);
    }

    /// src must be NUL-terminated at src.len.
    pub fn apply(self: *const Redactor, dst: []u8, src: []const u8) Masked {
        var clipped = false;
        var w: usize = 0;
        var r: usize = 0;
        var bol = true;
        while (r < src.len) {
            var ms: usize = 0;
            var me: usize = 0;
            // notbol on resumed scans: '^' must anchor at the true string
            // start, not at the resume point (REG_NOTBOL is POSIX).
            if (lt_regex_find(self.re, src.ptr + r, @intFromBool(!bol), &ms, &me) != 0) break;
            bol = false;
            const s = r + ms;
            const e = r + me;
            w += put(dst[w..], src[r..s], &clipped);
            w += put(dst[w..], redacted, &clipped);
            if (e == s) { // zero-length match: emit one char and step past it
                if (s >= src.len) break;
                const cl: usize = if (src[s] >= 0xF0) 4 else if (src[s] >= 0xE0) 3 else if (src[s] >= 0xC0) 2 else 1;
                w += put(dst[w..], src[s .. s + @min(cl, src.len - s)], &clipped);
                r = s + @min(cl, src.len - s);
            } else r = e;
        }
        w += put(dst[w..], src[r..], &clipped);
        return .{ .text = dst[0..w], .clipped = clipped };
    }
};

test "password token cut" {
    var buf: [128]u8 = undefined;
    const q = "CREATE ROLE app PASSWORD 'SECRET-abc123'";
    const out = redactPassword(&buf, q);
    try std.testing.expectEqualStrings("CREATE ROLE app PASSWORD <REDACTED>", out.text);
    try std.testing.expect(!out.clipped);
    try std.testing.expectEqualStrings("create role x password <REDACTED>", redactPassword(&buf, "create role x password 's'").text);
    try std.testing.expectEqualStrings("alter role a password <REDACTED>", redactPassword(&buf, "alter role a password's'").text);
    // no token / word-boundary misses: returned untouched
    const clean = "select * from password_audit";
    try std.testing.expect(redactPassword(&buf, clean).text.ptr == clean.ptr);
    const up = "user_passwords table";
    try std.testing.expect(redactPassword(&buf, up).text.ptr == up.ptr);
    try std.testing.expectEqualStrings("select 1", redactPassword(&buf, "select 1").text);
}

test "redactor regex replace" {
    var r = Redactor.compile("SECRET-[a-z0-9-]+") orelse return error.CompileFailed;
    defer r.deinit();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "token=<REDACTED> then=<REDACTED> end",
        r.apply(&buf, "token=SECRET-abc123 then=SECRET-xyz end").text,
    );
    const miss = r.apply(&buf, "nothing here");
    try std.testing.expectEqualStrings("nothing here", miss.text);
    try std.testing.expect(!miss.clipped);
}

test "redactor anchors and zero-length matches" {
    var r = Redactor.compile("^a") orelse return error.CompileFailed;
    defer r.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("<REDACTED>bc", r.apply(&buf, "abc").text);
    // 'a' mid-string is not at the string start once scanning resumes
    var r2 = Redactor.compile("^b") orelse return error.CompileFailed;
    defer r2.deinit();
    try std.testing.expectEqualStrings("ab", r2.apply(&buf, "ab").text);

    var r3 = Redactor.compile("x*") orelse return error.CompileFailed; // matches empty everywhere
    defer r3.deinit();
    // sed semantics (s/x*/R/g): empty match → marker, one char verbatim, step
    // past. The contract under test is termination.
    try std.testing.expectEqualStrings("<REDACTED>a<REDACTED>b<REDACTED>c", r3.apply(&buf, "abc").text);
}

test "clip cuts at a UTF-8 boundary and reports itself" {
    // multibyte run longer than the scratch: the cut must land between
    // characters and flag clipping (setStr cannot — the result fits the slot)
    var buf: [33]u8 = undefined;
    const src = "abc" ++ "é" ** 40; // 3 + 80 bytes
    var r = Redactor.compile("nomatch") orelse return error.CompileFailed;
    defer r.deinit();
    const m = r.apply(&buf, src);
    try std.testing.expect(m.clipped);
    try std.testing.expect(m.text.len <= 32);
    try std.testing.expect(m.text[0] == 'a');
    try std.testing.expect(std.unicode.utf8ValidateSlice(m.text));
    // the byte after the text is the NUL the regex pass relies on
    try std.testing.expect(buf[m.text.len] == 0);
}

test "invalid redactor pattern rejected" {
    try std.testing.expect(Redactor.compile("[unclosed") == null);
}

// --- fuzz ---------------------------------------------------------------------
//
// Random inputs through both redaction layers. Invariants the capture path
// depends on: the pass terminates (bounded by dst), never writes past
// dst.len-1, NUL-terminates its output (the next layer regexecs to that
// terminator), and on valid-UTF-8 input the password cut — whose cut points
// surround an ASCII token, and whose clip backs off to a lead byte — keeps
// the text on character boundaries. The regex layer is byte-oriented: a
// match may split a multibyte character, so its output is NOT promised to
// be valid UTF-8 — the jsonl sanitizer owns that (see its fuzz test).

test "fuzz: redactPassword over random valid UTF-8" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    // token variants and boundary misses share the pool with plain text
    const pieces = [_][]const u8{
        "a",        "Z",        "0",        "_",              " ",              "\t",  "\"",
        "\\",
        "é",
        "δ",
        "€",
        "ж",
        "password", "Password", "PASSWORD", "password_audit", "user_passwords", "'s'", "--",
    };
    var src: [600]u8 = undefined;
    var dst: [65]u8 = undefined; // smaller than some inputs: exercise the clip
    for (0..512) |_| {
        var n: usize = 0;
        while (n + 24 < src.len) {
            const p = pieces[rand.intRangeLessThan(usize, 0, pieces.len)];
            if (n + p.len > src.len) break;
            @memcpy(src[n..][0..p.len], p);
            n += p.len;
        }
        const input = src[0..n];
        const m = redactPassword(&dst, input);
        if (m.text.ptr == dst[0..].ptr) { // masked: lives in dst
            try std.testing.expect(m.text.len < dst.len);
            try std.testing.expect(dst[m.text.len] == 0);
            try std.testing.expect(std.unicode.utf8ValidateSlice(m.text));
            if (!m.clipped) try std.testing.expect(std.mem.endsWith(u8, m.text, " " ++ redacted));
        } else { // no token: returned untouched
            try std.testing.expect(m.text.ptr == input.ptr);
            try std.testing.expect(!m.clipped);
        }
    }
}

test "fuzz: Redactor.apply over random bytes" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    const patterns = [_][:0]const u8{ "x*", "(|a)", ".*", "[a-z]+", "^", "é", "password" };
    var src: [600]u8 = undefined;
    var dst: [512]u8 = undefined;
    for (0..512) |_| {
        const pat = patterns[rand.intRangeLessThan(usize, 0, patterns.len)];
        var r = Redactor.compile(pat) orelse return error.CompileFailed;
        defer r.deinit();
        const n = rand.intRangeLessThan(usize, 0, src.len);
        for (src[0..n]) |*b| b.* = rand.intRangeAtMost(u8, 1, 255); // C string: no NUL
        src[n] = 0; // apply's contract: regexec reads to the terminator
        const m = r.apply(&dst, src[0..n]);
        // apply always rewrites into dst (the tail copy); output stays inside
        // the buffer and NUL-terminated for the next pass
        try std.testing.expect(m.text.ptr == dst[0..].ptr);
        try std.testing.expect(m.text.len < dst.len);
        try std.testing.expect(dst[m.text.len] == 0);
    }
}
