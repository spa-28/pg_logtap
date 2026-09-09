//! TLS transport for https:// and tcps:// export: std.crypto.tls.Client
//! (TLS 1.2/1.3) over the ALREADY-DIALED socket fd — dialTcp owns DNS,
//! connect and the initial SO_SNDTIMEO/SO_RCVTIMEO budgets; this owns the
//! handshake and the encrypted read/write, with every socket READ re-armed
//! to the attempt's absolute deadline (DeadlineReader below), so the
//! unbounded std handshake loop cannot outlive the send budget. One
//! handshake per send, matching the transports' connect-per-batch shape.
//! Deliberately pgzx-free: failures surface through `last_error`, which the
//! worker folds into its usual failSend transition log — no logging here, so
//! the file stays linkable in pure unit-test builds.
const std = @import("std");

const tls = std.crypto.tls;

const alloc = std.heap.c_allocator;

/// Threaded Io in single-threaded mode = plain blocking syscalls on the
/// calling thread (EINTR retried inside netReadPosix — postgres latch pokes
/// are safe), no threads ever spawned. The worker's own IO shape.
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn now() std.Io.Timestamp {
    return std.Io.Timestamp.now(io(), .real);
}

/// All four TLS/socket buffers at the max ciphertext record size (16645):
/// socket read + write (ciphertext), app read + write (cleartext staging) —
/// the minimum the client asserts for its socket-facing buffers.
const buf_len = tls.max_ciphertext_record_len;

pub const Options = struct {
    /// PEM file with the receiver's CA (the receiver's own certificate for a
    /// self-signed one). Empty = system CA roots. A custom file REPLACES the
    /// system roots — the receiver's chain is known, that is the point.
    ca_pem: []const u8 = "",
    /// Certificate name to verify and SNI to send when it differs from the
    /// URL host (IP-literal URLs, TLS-terminating load balancers).
    /// Empty = the URL host.
    server_name: []const u8 = "",
    /// false disables both chain and name verification — development only.
    verify: bool = true,
};

pub const Conn = struct {
    deadline_reader: DeadlineReader,
    stream_writer: std.Io.net.Stream.Writer,
    client: tls.Client,
    entropy: [tls.Client.Options.entropy_len]u8,
    socket_read_buf: [buf_len]u8 = undefined,
    socket_write_buf: [buf_len]u8 = undefined,
    app_read_buf: [buf_len]u8 = undefined,
    app_write_buf: [buf_len]u8 = undefined,

    /// Encrypt and send. false = failure (reason in last_error). The caller
    /// chunks large bodies with its own abort checks between calls — each
    /// call may drain several socket writes, each already bounded by
    /// SO_SNDTIMEO.
    pub fn write(c: *Conn, bytes: []const u8) bool {
        c.client.writer.writeAll(bytes) catch |e| {
            fail("tls write: {s}", .{@errorName(e)});
            return false;
        };
        c.client.writer.flush() catch |e| {
            fail("tls flush: {s}", .{@errorName(e)});
            return false;
        };
        // The TLS layer's flush only moves ciphertext INTO the socket
        // Writer's buffer — draining that buffer into the fd is the owner's
        // job (std.http.Client flushes it at request completion; without
        // this the body sits unsent, the receiver waits, and the status read
        // runs out its SO_RCVTIMEO).
        c.stream_writer.interface.flush() catch |e| {
            fail("tls send: {s}", .{@errorName(e)});
            return false;
        };
        return true;
    }

    /// Decrypted bytes into buf — as many as available, at least 1 on
    /// success (0 = failure or clean EOF; reason in last_error for both).
    pub fn readSome(c: *Conn, buf: []u8) usize {
        const nread = c.client.reader.readSliceShort(buf) catch |e| {
            fail("tls read: {s}", .{@errorName(e)});
            return 0;
        };
        // Name the clean EOF, or the caller reports whatever failure the
        // PREVIOUS attempt left in last_error ("stable until the next one").
        if (nread == 0) fail("tls eof: the receiver closed the session", .{});
        return nread;
    }

    /// Best-effort close_notify so the receiver can tell a finished session
    /// from a truncated one. After a failed send it is skipped — the fd
    /// close is the backstop there, same as the plain transports.
    pub fn end(c: *Conn) void {
        c.client.end() catch {};
        c.stream_writer.interface.flush() catch {}; // drain the close_notify record too
    }
};

/// One connection at a time by design: the export worker is a single thread,
/// so the ~66 KB of buffers is a worker-local static — zero allocation in the
/// send path. The client's interfaces point into this storage; it must not
/// move while a Conn is live (it never does — one static).
var conn_storage: Conn = undefined;

/// Socket reader that makes the TLS handshake share ONE absolute deadline
/// instead of handing every internal read a full socket timeout. The std
/// handshake loop (`fragment: while (true)`) has no bound on the number of
/// reads it will do, so a peer dribbling one record fragment per
/// just-under-timeout interval could otherwise pin the worker inside
/// `tls.Client.init` forever — each individual recv succeeds, SO_RCVTIMEO
/// never fires. Shape is std.Io.net.Stream.Reader's (readVec is the syscall
/// site; stream is its buffered wrapper) with the deadline arm prepended.
const DeadlineReader = struct {
    io_ctx: std.Io,
    interface: std.Io.Reader,
    sock_fd: c_int,
    /// Absolute end of the send attempt, std realtime clock, µs.
    deadline_us: i64,
    err: ?std.Io.net.Stream.Reader.Error = null,

    /// Re-arm SO_RCVTIMEO to the remaining budget; false (reason in
    /// last_error) when it is spent. Same raw-flag style as worker.zig's
    /// netArmDeadline — the two sites say the same thing about the same
    /// socket option.
    fn arm(self: *DeadlineReader) bool {
        // nanoseconds is i96 in the Timestamp struct; realtime fits i64 for
        // any date representable in export_timeout_ms arithmetic.
        const now_us: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io_ctx, .real).nanoseconds, 1000));
        const remain_us = self.deadline_us - now_us;
        if (remain_us < 1000) {
            fail("tls budget: the attempt outlived export_timeout_ms", .{});
            return false;
        }
        const sock_tv = std.posix.timeval{ .sec = @divTrunc(remain_us, 1_000_000), .usec = @mod(remain_us, 1_000_000) };
        std.posix.setsockopt(self.sock_fd, 1, 20, std.mem.asBytes(&sock_tv)) catch |e| { // SOL_SOCKET, SO_RCVTIMEO
            fail("tls setsockopt SO_RCVTIMEO: {s}", .{@errorName(e)});
            return false;
        };
        return true;
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const nread = try readVec(io_r, &data);
        io_w.advance(nread);
        return nread;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *DeadlineReader = @alignCast(@fieldParentPtr("interface", io_r));
        if (!self.arm()) return error.ReadFailed;
        var iovecs_buffer: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const nread = self.io_ctx.vtable.netRead(self.io_ctx.userdata, self.sock_fd, dest) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (nread == 0) return error.EndOfStream;
        if (nread > data_size) {
            io_r.end += nread - data_size;
            return data_size;
        }
        return nread;
    }
};

var ca_bundle: std.crypto.Certificate.Bundle = .empty;
var ca_lock: std.Io.RwLock = .init;

/// Last failure (or clean-eof note), set by connect/write/read. Stable
/// until the next one.
/// 160: fits an error name plus the misconfiguration hint below verbatim.
pub var last_error_buf: [160]u8 = undefined;
pub var last_error: []const u8 = "";

fn fail(comptime fmt: []const u8, args: anytype) void {
    last_error = std.fmt.bufPrint(&last_error_buf, fmt, args) catch "tls";
}

/// Load export_tls_ca into the bundle for THIS handshake — every time, not
/// on path change: the file's content can change under an unchanged path
/// (rotation), and a stale bundle turns every handshake into a mystery
/// failure. A PEM parse per send (~ms on a KB-scale file, one send per
/// flush cycle) is cheaper than any stat-based invalidation. An empty path
/// clears the bundle too — empty means SYSTEM roots, not "whatever the
/// previous value loaded" — and the TLS client's own incremental rescan of
/// the system roots then fills it.
/// Two operator mistakes fail HERE, with the path in the reason, instead of
/// later as an opaque chain error: a wrong/unreadable path, and a file that
/// parses but holds no certificates (created empty, or the wrong file).
fn bundleReady(ca_path: []const u8) bool {
    ca_bundle.deinit(alloc);
    ca_bundle = .empty;
    if (ca_path.len == 0) return true;
    if (ca_path.len > 4096) {
        fail("tls ca path too long ({d} bytes)", .{ca_path.len});
        return false;
    }
    // Tail of the path, so a long data-directory-relative path still names
    // the file in the 160-byte reason.
    const tail = ca_path[ca_path.len - @min(ca_path.len, 64) ..];
    ca_bundle.addCertsFromFilePathAbsolute(alloc, io(), now(), ca_path) catch |e| {
        fail("tls ca file: {s}: {s}", .{ @errorName(e), tail });
        return false;
    };
    if (ca_bundle.map.count() == 0) {
        fail("tls ca file holds no certificates: {s}", .{tail});
        return false;
    }
    return true;
}

/// Handshake over a connected fd. `remaining_us` is what is left of the
/// send attempt's absolute budget (worker's net_deadline_us clock); every
/// socket read inside the handshake — and every record read of the session
/// after it — is re-armed to that deadline, so a dribbling peer cannot
/// stretch the stage past it. null = failure, reason in last_error.
/// The caller owns the fd (worker's send_conn_fd / closeSendFd discipline —
/// a second SIGTERM close(2) punches the blocked handshake read the same way
/// it punches a plain one).
pub fn connect(fd: c_int, url_host: []const u8, opts: Options, remaining_us: i64) ?*Conn {
    const c = &conn_storage;
    const io_ref = io();
    // The address field is unused by the read/write paths (dialTcp already
    // connected the fd); it just needs a valid value.
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = .{ .ip4 = .unspecified(0) } } };
    const now_us: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io_ref, .real).nanoseconds, 1000));
    c.deadline_reader = .{
        .io_ctx = io_ref,
        .interface = .{
            .vtable = &.{ .stream = DeadlineReader.streamImpl, .readVec = DeadlineReader.readVec },
            .buffer = &c.socket_read_buf,
            .seek = 0,
            .end = 0,
        },
        .sock_fd = fd,
        .deadline_us = now_us + remaining_us,
    };
    c.stream_writer = stream.writer(io_ref, &c.socket_write_buf);
    io_ref.random(&c.entropy);
    var client_opts: tls.Client.Options = .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = &c.app_read_buf,
        .write_buffer = &c.app_write_buf,
        .entropy = &c.entropy,
        .realtime_now = now(),
        // Same call as std.http.Client makes: truncation of the response is
        // detected by the HTTP layer, not the TLS close_notify.
        .allow_truncation_attacks = true,
    };
    if (opts.verify) {
        if (!bundleReady(opts.ca_pem)) return null;
        const host = if (opts.server_name.len > 0) opts.server_name else url_host;
        client_opts.host = .{ .explicit = host };
        client_opts.ca = .{ .bundle = .{ .gpa = alloc, .io = io_ref, .lock = &ca_lock, .bundle = &ca_bundle } };
    }
    c.client = tls.Client.init(&c.deadline_reader.interface, &c.stream_writer.interface, client_opts) catch |e| {
        // The error name alone is a riddle for the three misconfigurations
        // that dominate real setups; append the GUC that fixes each. String
        // compares (not a switch) so an error outside this set still formats.
        const name = @errorName(e);
        const hint: []const u8 = if (std.mem.eql(u8, name, "CertificateHostMismatch"))
            " — name mismatch: set export_tls_server_name (IP-literal URLs always need it)"
        else if (std.mem.eql(u8, name, "CertificateIssuerNotFound"))
            " — unknown CA: set export_tls_ca to the receiver's CA"
        else if (std.mem.eql(u8, name, "TlsCertificateNotVerified"))
            " — chain rejected: check the export_tls_ca file"
        else if (std.mem.eql(u8, name, "TlsDecodeError") or std.mem.eql(u8, name, "TlsUnexpectedMessage") or std.mem.eql(u8, name, "TlsBadLength") or std.mem.eql(u8, name, "Unexpected"))
            " — the receiver may not be speaking TLS on this port"
        else
            "";
        fail("tls handshake: {s}{s}", .{ name, hint });
        return null;
    };
    return c;
}
