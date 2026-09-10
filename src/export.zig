//! Export destination URL (pure, unit-tested). Formats:
//!   http://host:port[/path]   plain HTTP POST — Vector on localhost
//!   https://host:port[/path]  HTTP POST over TLS (see export_tls_* GUCs)
//!   tcp://host:port           raw JSON lines
//!   tcps://host:port          JSON lines over TLS
//!   file:///abs/path          append (0600)
//! IPv6 literal hosts are not supported (bracket parsing); hostname or IPv4 only.
const std = @import("std");

pub const Endpoint = struct { host: []const u8, port: u16, tls: bool = false };
pub const Http = struct { host: []const u8, port: u16, path: []const u8, tls: bool = false };

pub const Dest = union(enum) {
    http: Http,
    tcp: Endpoint,
    file: []const u8,
};

/// SET-time discipline for export_http_extra_headers: reject only what the
/// sender cannot fix — an empty line (it would end the header section before
/// the fixed headers) and a raw CR/LF byte. Lines are separated by the
/// two-character "\n" sequence: a config-file GUC value cannot carry a real
/// newline at all (ALTER SYSTEM rejects one outright), so the escape is the
/// only multi-line form there is. A line must be "Name: value", and the name
/// must be one the sender does not own — the framing/identity names (Host,
/// Content-Length, …) are rejected case-insensitively: a config-supplied
/// second copy makes a request with conflicting HTTP semantics.
pub fn headerValid(val: []const u8) bool {
    var rest = val;
    while (rest.len > 0) {
        const eol = std.mem.indexOf(u8, rest, "\\n") orelse rest.len;
        const line = rest[0..eol];
        if (std.mem.indexOfAny(u8, line, "\r\n") != null) return false; // raw CR/LF byte
        if (line.len == 0) return false; // empty line ends the header section early
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false; // "Name: value" — no colon is not a header
        const name = line[0..colon];
        // The sender owns these names: they carry the request's framing and
        // identity, and a second one from config makes a request with
        // conflicting semantics (two Content-Lengths is smuggling-shaped).
        // Application headers (Authorization, X-*) stay allowed.
        for ([_][]const u8{ "host", "content-length", "transfer-encoding", "connection", "content-encoding", "te", "upgrade", "proxy-connection" }) |owned| {
            if (std.ascii.eqlIgnoreCase(name, owned)) return false;
        }
        if (eol == rest.len) return true;
        rest = rest[eol + 2 ..];
    }
    return true;
}

/// Wire form of the configured extra headers: one CRLF-terminated line per
/// "\n"-separated line of the value, so the fixed headers that follow always
/// start on a fresh line — a plain 'Authorization: Bearer t' needs no
/// ceremony, and the missing final CRLF is supplied.
pub fn writeHeaderLines(w: anytype, val: []const u8) !void {
    var rest = val;
    while (rest.len > 0) {
        const eol = std.mem.indexOf(u8, rest, "\\n") orelse rest.len;
        try w.writeAll(rest[0..eol]);
        try w.writeAll("\r\n");
        if (eol == rest.len) return;
        rest = rest[eol + 2 ..];
    }
}

pub fn parseUrl(url: []const u8) ?Dest {
    if (std.mem.startsWith(u8, url, "http://")) return parseHttp(url["http://".len..], false);
    if (std.mem.startsWith(u8, url, "https://")) return parseHttp(url["https://".len..], true);
    if (std.mem.startsWith(u8, url, "tcp://")) {
        const endpoint = parseEndpoint(url["tcp://".len..]) orelse return null;
        return .{ .tcp = endpoint };
    }
    if (std.mem.startsWith(u8, url, "tcps://")) {
        var endpoint = parseEndpoint(url["tcps://".len..]) orelse return null;
        endpoint.tls = true;
        return .{ .tcp = endpoint };
    }
    if (std.mem.startsWith(u8, url, "file://")) {
        var path = url["file://".len..];
        if (std.mem.startsWith(u8, path, "localhost")) path = path["localhost".len..];
        if (path.len == 0 or path[0] != '/') return null;
        return .{ .file = path };
    }
    return null;
}

/// The host and path of a network scheme ride the HTTP request line verbatim
/// (or into getaddrinfo/dial for tcp), so a control byte or a space could
/// split or smuggle the request — reject such a value at parse, where it
/// fails SET loudly instead of corrupting every send. file:// paths are
/// local filenames and keep spaces.
fn cleanAscii(s: []const u8) bool {
    for (s) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

fn parseHttp(rest: []const u8, tls: bool) ?Dest {
    if (!cleanAscii(rest)) return null;
    const slash = std.mem.findScalar(u8, rest, '/');
    const hostport = if (slash) |i| rest[0..i] else rest;
    const path = if (slash) |i| rest[i..] else "/";
    const endpoint = parseEndpoint(hostport) orelse return null;
    return .{ .http = .{ .host = endpoint.host, .port = endpoint.port, .path = path, .tls = tls } };
}

fn parseEndpoint(hostport: []const u8) ?Endpoint {
    if (!cleanAscii(hostport)) return null;
    const colon = std.mem.findScalarLast(u8, hostport, ':') orelse return null;
    const host = hostport[0..colon];
    if (host.len == 0 or std.mem.findScalar(u8, host, ':') != null) return null; // IPv6 / garbage
    const port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return null;
    return .{ .host = host, .port = port };
}

test "parse http" {
    const dest_v = parseUrl("http://v:8686/events").?;
    try std.testing.expectEqualStrings("v", dest_v.http.host);
    try std.testing.expectEqual(@as(u16, 8686), dest_v.http.port);
    try std.testing.expectEqualStrings("/events", dest_v.http.path);
    try std.testing.expectEqual(false, dest_v.http.tls);
}

test "parse http no path, default port explicit" {
    const dest_v = parseUrl("http://127.0.0.1:80").?;
    try std.testing.expectEqualStrings("/", dest_v.http.path);
    try std.testing.expectEqualStrings("127.0.0.1", dest_v.http.host);
}

test "parse https and tcps" {
    const dest_v = parseUrl("https://logs.example.com:443/insert/jsonline").?;
    try std.testing.expectEqual(true, dest_v.http.tls);
    try std.testing.expectEqualStrings("logs.example.com", dest_v.http.host);
    const tcp_v = parseUrl("tcps://fluent:24224").?;
    try std.testing.expectEqual(true, tcp_v.tcp.tls);
    try std.testing.expectEqual(@as(u16, 24224), tcp_v.tcp.port);
    try std.testing.expectEqual(false, parseUrl("tcp://fluent:24224").?.tcp.tls);
}

test "parse tcp and file" {
    try std.testing.expectEqual(@as(u16, 9999), parseUrl("tcp://h:9999").?.tcp.port);
    try std.testing.expectEqualStrings("/var/log/tap.jsonl", parseUrl("file:///var/log/tap.jsonl").?.file);
    try std.testing.expectEqualStrings("/x", parseUrl("file://localhost/x").?.file);
}

test "reject garbage" {
    try std.testing.expect(parseUrl("gopher://v:8686") == null); // unknown scheme
    try std.testing.expect(parseUrl("tcp://v") == null); // no port
    try std.testing.expect(parseUrl("file://relative") == null);
    try std.testing.expect(parseUrl("http://:80/x") == null);
    try std.testing.expect(parseUrl("") == null);
}

test "reject control bytes and spaces in network schemes" {
    try std.testing.expect(parseUrl("http://v:8686/insert\r\nX-Evil: 1") == null); // request-line split
    try std.testing.expect(parseUrl("http://v:8686/a\x00b") == null);
    try std.testing.expect(parseUrl("http://v:8686/a b") == null); // space in the path
    try std.testing.expect(parseUrl("http://ba d:8686/") == null); // space in the host
    try std.testing.expect(parseUrl("tcp://h:9999\n") == null);
    // file:// paths are local filenames: a space stays legal there.
    try std.testing.expectEqualStrings("/tmp/my logs.jsonl", parseUrl("file:///tmp/my logs.jsonl").?.file);
}

test "export_http_extra_headers CR/LF discipline" {
    try std.testing.expect(headerValid("")); // boot default
    try std.testing.expect(headerValid("Authorization: Bearer t")); // the plain form
    try std.testing.expect(headerValid("X-Tenant: a\\nAuthorization: Bearer t")); // two lines, the \n escape
    try std.testing.expect(headerValid("X-Tenant: a\\nAuthorization: Bearer t\\n")); // trailing separator
    try std.testing.expect(!headerValid("\\nAuthorization: Bearer t")); // empty first line
    try std.testing.expect(!headerValid("X-A: 1\\n\\nX-B: 2")); // empty middle line
    try std.testing.expect(!headerValid("X-A: 1\r\nX-B: 2")); // raw CR/LF bytes — ALTER SYSTEM
    try std.testing.expect(!headerValid("X-A: 1\nX-B: 2")); // cannot deliver one anyway,
    try std.testing.expect(!headerValid("X-A: 1\r")); // reject them regardless
}

test "export_http_extra_headers protocol-owned names rejected" {
    try std.testing.expect(!headerValid("Host: evil.example"));
    try std.testing.expect(!headerValid("host: evil.example")); // case-insensitive
    try std.testing.expect(!headerValid("Content-Length: 5"));
    try std.testing.expect(!headerValid("content-length: 5"));
    try std.testing.expect(!headerValid("Transfer-Encoding: chunked"));
    try std.testing.expect(!headerValid("Connection: keep-alive"));
    try std.testing.expect(!headerValid("Content-Encoding: gzip"));
    try std.testing.expect(!headerValid("TE: trailers"));
    try std.testing.expect(!headerValid("Upgrade: h2c"));
    try std.testing.expect(!headerValid("Proxy-Connection: keep-alive"));
    try std.testing.expect(!headerValid("X-A: 1\\nHost: evil.example")); // anywhere in the list
    // "Hostname" is not "Host": a prefix collision must not reject an
    // unowned (if odd) name, and an application header stays allowed.
    try std.testing.expect(headerValid("Hostname: x"));
    try std.testing.expect(headerValid("Authorization: Bearer t"));
    // No colon = not a header line at all.
    try std.testing.expect(!headerValid("not-a-header"));
}

test "export_http_extra_headers wire form" {
    var buf: [128]u8 = undefined;
    var writer1 = std.Io.Writer.fixed(&buf);
    try writeHeaderLines(&writer1, "Authorization: Bearer t");
    try std.testing.expectEqualStrings("Authorization: Bearer t\r\n", writer1.buffered());
    var writer2 = std.Io.Writer.fixed(&buf);
    try writeHeaderLines(&writer2, "X-Tenant: a\\nAuthorization: Bearer t");
    try std.testing.expectEqualStrings("X-Tenant: a\r\nAuthorization: Bearer t\r\n", writer2.buffered());
}
