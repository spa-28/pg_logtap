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

extern fn lt_regex_compile(pattern: [*:0]const u8, errbuf: [*c]u8, errlen: usize) ?*LtRegex;
extern fn lt_regex_free(re: *LtRegex) void;
extern fn lt_regex_matches(re: *const LtRegex, s: [*:0]const u8) c_int;
extern fn lt_regex_compile_sub(pattern: [*:0]const u8, errbuf: [*c]u8, errlen: usize) ?*LtRegex;
/// s must be NUL-terminated at its end (our sources are C strings); reports
/// the first match as byte offsets from s.
extern fn lt_regex_find(re: *const LtRegex, s: [*]const u8, notbol: c_int, start: *usize, end: *usize) c_int;

/// regerror's text for a failed compile: the operator sees why the pattern
/// was rejected ("Unmatched [") instead of a generic "invalid regex" that
/// misdiagnoses e.g. REG_ESPACE as a syntax error.
pub const CompileDiag = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const CompileDiag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Shared compile-with-diag: on failure the shim filled buf with regerror's
/// NUL-terminated text, which is copied into the caller's diag if it wants it.
fn compileInto(comptime f: anytype, pattern: [:0]const u8, diag: ?*CompileDiag) ?*LtRegex {
    var buf: [128]u8 = undefined;
    const re = f(pattern.ptr, &buf, buf.len) orelse {
        if (diag) |d| {
            d.len = std.mem.findScalar(u8, &buf, 0) orelse buf.len;
            @memcpy(d.buf[0..d.len], buf[0..d.len]);
        }
        return null;
    };
    return re;
}

pub const Regex = struct {
    regex: *LtRegex,

    /// Returns null on invalid pattern (or OOM).
    pub fn compile(pattern: [:0]const u8) ?Regex {
        return compileDiag(pattern, null);
    }

    pub fn compileDiag(pattern: [:0]const u8, diag: ?*CompileDiag) ?Regex {
        return .{ .regex = compileInto(lt_regex_compile, pattern, diag) orelse return null };
    }

    pub fn deinit(self: *Regex) void {
        lt_regex_free(self.regex);
    }

    /// Input must be NUL-terminated — our sources are C strings already.
    pub fn matches(self: *const Regex, s: [*:0]const u8) bool {
        return lt_regex_matches(self.regex, s) != 0;
    }
};

pub const Filter = struct {
    level_min: i32 = 15, // LOG
    include: ?Regex = null,
    exclude: ?Regex = null,

    pub fn deinit(self: *Filter) void {
        if (self.include) |*inc| inc.deinit();
        if (self.exclude) |*exc| exc.deinit();
        self.include = null;
        self.exclude = null;
    }

    pub fn accepts(self: *const Filter, elevel: i32, message: [*:0]const u8) bool {
        if (elevel < self.level_min) return false;
        if (self.include) |*inc| if (!inc.matches(message)) return false;
        if (self.exclude) |*exc| if (exc.matches(message)) return false;
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

test "compile failure reports regerror's text" {
    // The point is the operator-facing message: "invalid regex" hides a
    // REG_ESPACE (memory) behind what reads like a syntax problem. Both
    // libcs' texts for an unmatched bracket mention the bracket itself.
    var diag = CompileDiag{};
    try std.testing.expect(Regex.compileDiag("[unclosed", &diag) == null);
    try std.testing.expect(diag.len > 0);
    try std.testing.expect(std.mem.findScalar(u8, diag.text(), '[') != null);
    var diag2 = CompileDiag{};
    try std.testing.expect(Redactor.compileDiag("a(", &diag2) == null);
    try std.testing.expect(diag2.len > 0);
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

/// True when the message line is statement-embedded SQL: the simple-protocol
/// `statement: ` marker, or an extended-protocol phase line — postgres.c logs
/// `parse <name>: <sql>`, `bind <name>...`, `execute <name>: <sql>` WITHOUT
/// the "statement: " marker, each optionally behind a `duration: N ms  `
/// prefix (log_min_duration_statement). The password cut is gated on this:
/// an ordinary message merely mentioning a word stays verbatim.
pub fn stmtLine(msg: []const u8) bool {
    if (std.mem.find(u8, msg, "statement: ") != null) return true;
    var rest = msg;
    if (std.mem.startsWith(u8, rest, "duration: ")) {
        rest = rest["duration: ".len..];
        var i: usize = 0;
        while (i < rest.len and (std.ascii.isDigit(rest[i]) or rest[i] == '.')) : (i += 1) {}
        if (!std.mem.startsWith(u8, rest[i..], " ms  ")) return false;
        rest = rest[i + " ms  ".len ..];
    }
    return std.mem.startsWith(u8, rest, "parse ") or
        std.mem.startsWith(u8, rest, "bind ") or
        std.mem.startsWith(u8, rest, "execute ");
}

test "statement-embedded SQL markers, simple and extended protocol" {
    // simple protocol
    try std.testing.expect(stmtLine("statement: SELECT 1"));
    try std.testing.expect(stmtLine("duration: 3.2 ms  statement: SELECT 1"));
    // extended protocol (JDBC/psycopg/pgbench -M extended): phase lines
    // carry the raw SQL without the "statement: " marker
    try std.testing.expect(stmtLine("parse stmt_1: SELECT $1"));
    try std.testing.expect(stmtLine("bind sd_1 to stmt_1"));
    try std.testing.expect(stmtLine("execute S_1: SELECT $1"));
    try std.testing.expect(stmtLine("duration: 1.2 ms  execute S_1: SELECT $1"));
    try std.testing.expect(stmtLine("duration: 0.4 ms  parse sd_1: ALTER ROLE a PASSWORD 'x'"));
    // ordinary lines that merely contain the words: verbatim
    try std.testing.expect(!stmtLine("executor slow today"));
    try std.testing.expect(!stmtLine("parser recovered"));
    try std.testing.expect(!stmtLine("duration of the outage: parse errors"));
    try std.testing.expect(!stmtLine("parsed the config"));
    // a message literally starting with a phase verb is treated as a
    // statement line: the gate errs toward cutting (over-redaction), and the
    // cut itself still needs a standalone password token to change anything
    try std.testing.expect(stmtLine("bind variable count"));
}

/// Everything from the end of a standalone `password` token on is dropped and
/// replaced (pgaudit semantics). Returns src untouched when no token is
/// present — the common case costs one scan, no copy.
pub fn redactPassword(dst: []u8, src: []const u8) Masked {
    const pos = findWord(src, "password") orelse return .{ .text = src, .clipped = false };
    var clipped = false;
    var out_len = put(dst, src[0 .. pos + "password".len], &clipped);
    out_len += put(dst[out_len..], " " ++ redacted, &clipped);
    return .{ .text = dst[0..out_len], .clipped = clipped };
}

/// Bind-parameter values ride in DETAIL as `Parameters: $1 = '...'` (put
/// there by log_parameter_max_length — capital P, the exact errdetail shape
/// in exec_bind_message/exec_execute_message) — the statement text carries
/// only the $N placeholders, so the password token cut cannot see the secret.
/// On that one line shape every single-quoted value ('' inside is an escaped
/// quote, not the end) becomes <REDACTED>; pgaudit parity — it does not log
/// parameter values at all. Any other detail returns src untouched: text we
/// do not recognize is not ours to rewrite. The values stay in the server's
/// own log; only the export is masked.
pub fn redactParamValues(dst: []u8, src: []const u8) Masked {
    const pfx = "Parameters: ";
    if (!std.mem.startsWith(u8, src, pfx)) return .{ .text = src, .clipped = false };
    var clipped = false;
    var out_len = put(dst, src[0..pfx.len], &clipped);
    var i = pfx.len;
    while (i < src.len) {
        if (src[i] != '\'') { // between values: `$1 = `, `, ` — verbatim
            var end = i;
            while (end < src.len and src[end] != '\'') end += 1;
            out_len += put(dst[out_len..], src[i..end], &clipped);
            i = end;
            continue;
        }
        // quoted value: a lone ' ends it, '' is an escaped quote inside it
        var end = i + 1;
        while (end < src.len) {
            if (src[end] != '\'') {
                end += 1;
            } else if (end + 1 < src.len and src[end + 1] == '\'') {
                end += 2;
            } else break;
        }
        out_len += put(dst[out_len..], redacted, &clipped);
        i = if (end < src.len) end + 1 else src.len; // unterminated tail: masked, done
    }
    return .{ .text = dst[0..out_len], .clipped = clipped };
}

/// Whole-match regex redaction: every match of the pattern becomes
/// <REDACTED>. Same libc caveats as Regex (see the header note on
/// backreferences).
pub const Redactor = struct {
    regex: *LtRegex,

    pub fn compile(pattern: [:0]const u8) ?Redactor {
        return compileDiag(pattern, null);
    }

    pub fn compileDiag(pattern: [:0]const u8, diag: ?*CompileDiag) ?Redactor {
        return .{ .regex = compileInto(lt_regex_compile_sub, pattern, diag) orelse return null };
    }

    pub fn deinit(self: *Redactor) void {
        lt_regex_free(self.regex);
    }

    /// src must be NUL-terminated at src.len.
    pub fn apply(self: *const Redactor, dst: []u8, src: []const u8) Masked {
        var clipped = false;
        var out_len: usize = 0;
        var read_pos: usize = 0;
        var bol = true;
        while (read_pos < src.len) {
            var rel_start: usize = 0;
            var rel_end: usize = 0;
            // notbol on resumed scans: '^' must anchor at the true string
            // start, not at the resume point (REG_NOTBOL is POSIX).
            if (lt_regex_find(self.regex, src.ptr + read_pos, @intFromBool(!bol), &rel_start, &rel_end) != 0) break;
            bol = false;
            const match_start = read_pos + rel_start;
            const match_stop = read_pos + rel_end;
            out_len += put(dst[out_len..], src[read_pos..match_start], &clipped);
            out_len += put(dst[out_len..], redacted, &clipped);
            if (match_stop == match_start) { // zero-length match: emit one char and step past it
                if (match_start >= src.len) break;
                const char_len: usize = if (src[match_start] >= 0xF0) 4 else if (src[match_start] >= 0xE0) 3 else if (src[match_start] >= 0xC0) 2 else 1;
                out_len += put(dst[out_len..], src[match_start .. match_start + @min(char_len, src.len - match_start)], &clipped);
                read_pos = match_start + @min(char_len, src.len - match_start);
            } else read_pos = match_stop;
        }
        out_len += put(dst[out_len..], src[read_pos..], &clipped);
        return .{ .text = dst[0..out_len], .clipped = clipped };
    }
};

test "password token cut" {
    var buf: [128]u8 = undefined;
    const query = "CREATE ROLE app PASSWORD 'SECRET-abc123'";
    const out = redactPassword(&buf, query);
    try std.testing.expectEqualStrings("CREATE ROLE app PASSWORD <REDACTED>", out.text);
    try std.testing.expect(!out.clipped);
    try std.testing.expectEqualStrings("create role x password <REDACTED>", redactPassword(&buf, "create role x password 's'").text);
    try std.testing.expectEqualStrings("alter role a password <REDACTED>", redactPassword(&buf, "alter role a password's'").text);
    // no token / word-boundary misses: returned untouched
    const clean = "select * from password_audit";
    try std.testing.expect(redactPassword(&buf, clean).text.ptr == clean.ptr);
    const underscored = "user_passwords table";
    try std.testing.expect(redactPassword(&buf, underscored).text.ptr == underscored.ptr);
    try std.testing.expectEqualStrings("select 1", redactPassword(&buf, "select 1").text);
}

test "bind-parameter values masked on the Parameters line" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Parameters: $1 = <REDACTED>, $2 = <REDACTED>",
        redactParamValues(&buf, "Parameters: $1 = 'hunter2', $2 = '42'").text,
    );
    // '' inside a value is an escaped quote, not the terminator
    try std.testing.expectEqualStrings(
        "Parameters: $1 = <REDACTED>",
        redactParamValues(&buf, "Parameters: $1 = 'o''brien''s'").text,
    );
    // empty value still masked; unterminated tail (length-capped log) too
    try std.testing.expectEqualStrings("Parameters: $1 = <REDACTED>", redactParamValues(&buf, "Parameters: $1 = ''").text);
    try std.testing.expectEqualStrings("Parameters: $1 = <REDACTED>", redactParamValues(&buf, "Parameters: $1 = 'trunc").text);
    // a value containing the word password rides the same mask
    try std.testing.expectEqualStrings("Parameters: $1 = <REDACTED>", redactParamValues(&buf, "Parameters: $1 = 'password x'").text);
    // the gate is the exact errdetail shape: lowercase or any other detail is
    // not ours to rewrite
    const foreign = "parameters: $1 = 'x' and other detail text";
    try std.testing.expect(redactParamValues(&buf, foreign).text.ptr == foreign.ptr);
    try std.testing.expect(!redactParamValues(&buf, foreign).clipped);
    // a mask run longer than the scratch clips at a UTF-8 boundary and reports
    var small: [26]u8 = undefined;
    const clipped = redactParamValues(&small, "Parameters: $1 = 'aaaaéééééééé'");
    try std.testing.expect(clipped.clipped);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped.text));
}

test "redactor regex replace" {
    var red = Redactor.compile("SECRET-[a-z0-9-]+") orelse return error.CompileFailed;
    defer red.deinit();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "token=<REDACTED> then=<REDACTED> end",
        red.apply(&buf, "token=SECRET-abc123 then=SECRET-xyz end").text,
    );
    const miss = red.apply(&buf, "nothing here");
    try std.testing.expectEqualStrings("nothing here", miss.text);
    try std.testing.expect(!miss.clipped);
}

test "redactor anchors and zero-length matches" {
    var red = Redactor.compile("^a") orelse return error.CompileFailed;
    defer red.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("<REDACTED>bc", red.apply(&buf, "abc").text);
    // 'a' mid-string is not at the string start once scanning resumes
    var red2 = Redactor.compile("^b") orelse return error.CompileFailed;
    defer red2.deinit();
    try std.testing.expectEqualStrings("ab", red2.apply(&buf, "ab").text);

    var red3 = Redactor.compile("x*") orelse return error.CompileFailed; // matches empty everywhere
    defer red3.deinit();
    // sed semantics (s/x*/R/g): empty match → marker, one char verbatim, step
    // past. The contract under test is termination.
    try std.testing.expectEqualStrings("<REDACTED>a<REDACTED>b<REDACTED>c", red3.apply(&buf, "abc").text);
}

test "clip cuts at a UTF-8 boundary and reports itself" {
    // multibyte run longer than the scratch: the cut must land between
    // characters and flag clipping (setStr cannot — the result fits the slot)
    var buf: [33]u8 = undefined;
    const src = "abc" ++ "é" ** 40; // 3 + 80 bytes
    var red = Redactor.compile("nomatch") orelse return error.CompileFailed;
    defer red.deinit();
    const masked = red.apply(&buf, src);
    try std.testing.expect(masked.clipped);
    try std.testing.expect(masked.text.len <= 32);
    try std.testing.expect(masked.text[0] == 'a');
    try std.testing.expect(std.unicode.utf8ValidateSlice(masked.text));
    // the byte after the text is the NUL the regex pass relies on
    try std.testing.expect(buf[masked.text.len] == 0);
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
        var total: usize = 0;
        while (total + 24 < src.len) {
            const piece = pieces[rand.intRangeLessThan(usize, 0, pieces.len)];
            if (total + piece.len > src.len) break;
            @memcpy(src[total..][0..piece.len], piece);
            total += piece.len;
        }
        const input = src[0..total];
        const masked = redactPassword(&dst, input);
        if (masked.text.ptr == dst[0..].ptr) { // masked: lives in dst
            try std.testing.expect(masked.text.len < dst.len);
            try std.testing.expect(dst[masked.text.len] == 0);
            try std.testing.expect(std.unicode.utf8ValidateSlice(masked.text));
            if (!masked.clipped) try std.testing.expect(std.mem.endsWith(u8, masked.text, " " ++ redacted));
        } else { // no token: returned untouched
            try std.testing.expect(masked.text.ptr == input.ptr);
            try std.testing.expect(!masked.clipped);
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
        var red = Redactor.compile(pat) orelse return error.CompileFailed;
        defer red.deinit();
        const body_len = rand.intRangeLessThan(usize, 0, src.len);
        for (src[0..body_len]) |*b| b.* = rand.intRangeAtMost(u8, 1, 255); // C string: no NUL
        src[body_len] = 0; // apply's contract: regexec reads to the terminator
        const masked = red.apply(&dst, src[0..body_len]);
        // apply always rewrites into dst (the tail copy); output stays inside
        // the buffer and NUL-terminated for the next pass
        try std.testing.expect(masked.text.ptr == dst[0..].ptr);
        try std.testing.expect(masked.text.len < dst.len);
        try std.testing.expect(dst[masked.text.len] == 0);
    }
}
