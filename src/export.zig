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

fn parseHttp(rest: []const u8, tls: bool) ?Dest {
    const slash = std.mem.findScalar(u8, rest, '/');
    const hostport = if (slash) |i| rest[0..i] else rest;
    const path = if (slash) |i| rest[i..] else "/";
    const endpoint = parseEndpoint(hostport) orelse return null;
    return .{ .http = .{ .host = endpoint.host, .port = endpoint.port, .path = path, .tls = tls } };
}

fn parseEndpoint(hostport: []const u8) ?Endpoint {
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
