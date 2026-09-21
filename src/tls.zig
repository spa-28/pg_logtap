//! TLS transport for https:// and tcps:// export: std.crypto.tls.Client
//! (TLS 1.2/1.3) over the ALREADY-DIALED socket fd — dialTcp owns DNS,
//! connect and the initial SO_SNDTIMEO/SO_RCVTIMEO budgets; this owns the
//! handshake and the encrypted read/write, with every socket read AND
//! write re-armed to the attempt's absolute deadline (DeadlineReader /
//! DeadlineWriter below), so the unbounded std handshake loop and a
//! read-dribbling or write-stalling peer cannot outlive the send budget.
//! One handshake per send, matching the transports' connect-per-batch shape.
//! Deliberately pgzx-free: failures surface through `last_error`, which the
//! worker folds into its usual failSend transition log — no logging here, so
//! the file stays linkable in pure unit-test builds.
const std = @import("std");

const tls = std.crypto.tls;

const alloc = std.heap.c_allocator;

/// Threaded Io in single-threaded mode supplies clocks, entropy and the TLS
/// client's surrounding Io contract; the socket adapters below issue Linux
/// readv/sendmsg themselves so every EINTR retry can re-arm the absolute
/// deadline. No threads are spawned.
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn realNow() std.Io.Timestamp {
    return std.Io.Timestamp.now(io(), .real);
}

fn monotonicNowUs(io_ctx: std.Io) i64 {
    const timestamp = std.Io.Timestamp.now(io_ctx, .awake);
    return @intCast(@divTrunc(timestamp.nanoseconds, 1000));
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
    deadline_writer: DeadlineWriter,
    client: tls.Client,
    entropy: [tls.Client.Options.entropy_len]u8,
    socket_read_buf: [buf_len]u8 = undefined,
    socket_write_buf: [buf_len]u8 = undefined,
    app_read_buf: [buf_len]u8 = undefined,
    app_write_buf: [buf_len]u8 = undefined,

    /// Encrypt and send. false = failure (reason in last_error). The caller
    /// chunks large bodies with its own abort checks between calls; inside a
    /// call every socket write is one armed sendmsg — the DeadlineWriter
    /// re-arms SO_SNDTIMEO to the attempt's remaining budget before each.
    pub fn write(c: *Conn, bytes: []const u8) bool {
        clearFailure();
        c.client.writer.writeAll(bytes) catch |e| {
            failIfEmpty("tls write: {s}", .{@errorName(e)});
            return false;
        };
        c.client.writer.flush() catch |e| {
            failIfEmpty("tls flush: {s}", .{@errorName(e)});
            return false;
        };
        // The TLS layer's flush only moves ciphertext INTO the socket
        // Writer's buffer — draining that buffer into the fd is the owner's
        // job (std.http.Client flushes it at request completion; without
        // this the body sits unsent, the receiver waits, and the status read
        // runs out its SO_RCVTIMEO). Each drain inside is one armed sendmsg.
        c.deadline_writer.interface.flush() catch |e| {
            failIfEmpty("tls send: {s}", .{@errorName(e)});
            return false;
        };
        return true;
    }

    /// Decrypted bytes into buf — as many as available, at least 1 on
    /// success (0 = failure or clean EOF; reason in last_error for both).
    pub fn readSome(c: *Conn, buf: []u8) usize {
        clearFailure();
        const nread = c.client.reader.readSliceShort(buf) catch |e| {
            failIfEmpty("tls read: {s}", .{@errorName(e)});
            return 0;
        };
        if (nread == 0) fail("tls eof: the receiver closed the session", .{});
        return nread;
    }

    /// Best-effort close_notify so the receiver can tell a finished session
    /// from a truncated one. After a failed send it is skipped — the fd
    /// close is the backstop there, same as the plain transports.
    pub fn end(c: *Conn) void {
        c.client.end() catch {};
        c.deadline_writer.interface.flush() catch {}; // drain the close_notify record too — armed like every write
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
    /// Absolute end of the send attempt, monotonic awake clock, µs.
    deadline_us: i64,
    err: ?std.Io.net.Stream.Reader.Error = null,

    /// Re-arm SO_RCVTIMEO to the remaining budget; false (reason in
    /// last_error) when it is spent. Same raw-flag style as worker.zig's
    /// netArmDeadline — the two sites say the same thing about the same
    /// socket option.
    fn arm(self: *DeadlineReader) bool {
        const remain_us = self.deadline_us - monotonicNowUs(self.io_ctx);
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
        var slices: [8][]u8 = undefined;
        const slice_n, const data_size = try io_r.writableVector(&slices, data);
        const dest = slices[0..slice_n];
        std.debug.assert(dest[0].len > 0);

        var iovecs: [8]std.posix.iovec = undefined;
        var iovecs_len: usize = 0;
        for (dest) |buf| {
            if (buf.len == 0) continue;
            iovecs[iovecs_len] = .{ .base = buf.ptr, .len = buf.len };
            iovecs_len += 1;
        }
        const nread = while (true) {
            // readv itself must expose EINTR here: std.Io.Threaded.netRead
            // retries internally and would reuse the stale relative timeout.
            if (!self.arm()) return error.ReadFailed;
            const result = std.os.linux.readv(self.sock_fd, &iovecs, iovecs_len);
            switch (std.os.linux.errno(result)) {
                .SUCCESS => break @as(usize, @intCast(result)),
                .INTR => continue,
                else => |err| {
                    self.err = switch (err) {
                        .INVAL, .FAULT => std.Io.Threaded.errnoBug(err),
                        .AGAIN, .TIMEDOUT => error.Timeout,
                        // A second SIGTERM deliberately closes this fd to punch
                        // a blocked TLS syscall out of the shutdown path.
                        .BADF, .NOTCONN, .PIPE => error.SocketUnconnected,
                        .NOBUFS, .NOMEM => error.SystemResources,
                        .CONNRESET => error.ConnectionResetByPeer,
                        .NETDOWN => error.NetworkDown,
                        else => std.posix.unexpectedErrno(err),
                    };
                    fail("tls read syscall errno={d}: {s}", .{ @intFromEnum(err), @errorName(self.err.?) });
                    return error.ReadFailed;
                },
            }
        };
        if (nread == 0) return error.EndOfStream;
        if (nread > data_size) {
            io_r.end += nread - data_size;
            return data_size;
        }
        return nread;
    }
};

/// Socket writer giving the WRITE side the same absolute-deadline discipline
/// the reader has. A drain is one sendmsg(MSG_NOSIGNAL) to the fd, and every
/// syscall attempt is preceded by an SO_SNDTIMEO re-arm: without it EINTR can
/// restart the old relative wait, and a 64 KB body's several TLS records can
/// stretch one chunk past the whole budget. net.Stream.Writer's vector/splat
/// shape is retained; defaultFlush drains through drain, so every flush path —
/// body, handshake records and close_notify — is armed per attempt.
const DeadlineWriter = struct {
    io_ctx: std.Io,
    interface: std.Io.Writer,
    sock_fd: c_int,
    /// Same absolute end as the reader's — one budget per send attempt.
    deadline_us: i64,
    err: ?std.Io.net.Stream.Writer.Error = null,

    /// Re-arm SO_SNDTIMEO to the remaining budget; false (reason in
    /// last_error) when it is spent. Mirrors DeadlineReader.arm — same
    /// clock, same socket, the other direction.
    fn arm(self: *DeadlineWriter) bool {
        const remain_us = self.deadline_us - monotonicNowUs(self.io_ctx);
        if (remain_us < 1000) {
            fail("tls budget: the attempt outlived export_timeout_ms", .{});
            return false;
        }
        const sock_tv = std.posix.timeval{ .sec = @divTrunc(remain_us, 1_000_000), .usec = @mod(remain_us, 1_000_000) };
        std.posix.setsockopt(self.sock_fd, 1, 21, std.mem.asBytes(&sock_tv)) catch |e| { // SOL_SOCKET, SO_SNDTIMEO
            fail("tls setsockopt SO_SNDTIMEO: {s}", .{@errorName(e)});
            return false;
        };
        return true;
    }

    fn init(io_ctx: std.Io, buffer: []u8, sock_fd: c_int, deadline_us: i64) DeadlineWriter {
        return .{
            .io_ctx = io_ctx,
            .interface = .{
                .vtable = &.{ .drain = drain, .sendFile = sendFile },
                .buffer = buffer,
            },
            .sock_fd = sock_fd,
            .deadline_us = deadline_us,
        };
    }

    fn addIovec(iovecs: []std.posix.iovec_const, len: *usize, bytes: []const u8) void {
        // Linux checks the address before the length, so omit empty vectors.
        if (bytes.len == 0 or len.* == iovecs.len) return;
        iovecs[len.*] = .{ .base = bytes.ptr, .len = bytes.len };
        len.* += 1;
    }

    /// net.Stream.Writer's vector/splat shape, with the Linux syscall local so
    /// EINTR returns to the deadline arm before sendmsg is attempted again.
    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DeadlineWriter = @alignCast(@fieldParentPtr("interface", io_w));
        var iovecs: [8]std.posix.iovec_const = undefined;
        var msg: std.os.linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iovecs,
            .iovlen = 0,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        addIovec(&iovecs, &msg.iovlen, io_w.buffered());
        for (data[0 .. data.len - 1]) |bytes| addIovec(&iovecs, &msg.iovlen, bytes);
        const pattern = data[data.len - 1];

        var splat_buffer: [64]u8 = undefined;
        if (msg.iovlen < iovecs.len) switch (splat) {
            0 => {},
            1 => addIovec(&iovecs, &msg.iovlen, pattern),
            else => switch (pattern.len) {
                0 => {},
                1 => {
                    const memset_len = @min(splat_buffer.len, splat);
                    @memset(splat_buffer[0..memset_len], pattern[0]);
                    addIovec(&iovecs, &msg.iovlen, splat_buffer[0..memset_len]);
                    var remaining = splat - memset_len;
                    while (remaining > splat_buffer.len and msg.iovlen < iovecs.len) {
                        addIovec(&iovecs, &msg.iovlen, &splat_buffer);
                        remaining -= splat_buffer.len;
                    }
                    addIovec(&iovecs, &msg.iovlen, splat_buffer[0..@min(remaining, splat_buffer.len)]);
                },
                else => for (0..@min(splat, iovecs.len - msg.iovlen)) |_| {
                    addIovec(&iovecs, &msg.iovlen, pattern);
                },
            },
        };

        const written = while (true) {
            if (!self.arm()) return error.WriteFailed;
            const result = std.os.linux.sendmsg(self.sock_fd, &msg, std.os.linux.MSG.NOSIGNAL);
            switch (std.os.linux.errno(result)) {
                .SUCCESS => break @as(usize, @intCast(result)),
                .INTR => continue,
                else => |err| {
                    self.err = switch (err) {
                        .ACCES, .DESTADDRREQ, .FAULT, .INVAL, .ISCONN, .MSGSIZE, .NOTSOCK, .OPNOTSUPP => std.Io.Threaded.errnoBug(err),
                        // Stream.Writer has no Timeout member; last_error below
                        // carries the expected SO_SNDTIMEO/EAGAIN distinction.
                        .AGAIN => error.Unexpected,
                        .BADF, .PIPE, .NOTCONN => error.SocketUnconnected,
                        .ALREADY => error.FastOpenAlreadyInProgress,
                        .CONNRESET => error.ConnectionResetByPeer,
                        .NOBUFS, .NOMEM => error.SystemResources,
                        .AFNOSUPPORT => error.AddressFamilyUnsupported,
                        .HOSTUNREACH => error.HostUnreachable,
                        .NETUNREACH => error.NetworkUnreachable,
                        .NETDOWN => error.NetworkDown,
                        else => std.posix.unexpectedErrno(err),
                    };
                    fail("tls write syscall errno={d}: {s}", .{ @intFromEnum(err), @errorName(self.err.?) });
                    return error.WriteFailed;
                },
            }
        };
        return io_w.consume(written);
    }

    fn sendFile(io_w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        _ = io_w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented; // same as net.Stream.Writer's — TLS sends no files
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

fn clearFailure() void {
    last_error = "";
}

fn failIfEmpty(comptime fmt: []const u8, args: anytype) void {
    if (last_error.len == 0) fail(fmt, args);
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
    // The worker is single-threaded so the mutation cannot race a live
    // handshake today, but the TLS client DOES take this lock shared while
    // verifying (Client.zig's ca.lock.lockShared) — replacing the bundle
    // under the same lock makes the ownership contract hold by construction
    // instead of by the call graph.
    ca_lock.lockUncancelable(io());
    defer ca_lock.unlock(io());
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
    ca_bundle.addCertsFromFilePathAbsolute(alloc, io(), realNow(), ca_path) catch |e| {
        fail("tls ca file: {s}: {s}", .{ @errorName(e), tail });
        return false;
    };
    if (ca_bundle.map.count() == 0) {
        fail("tls ca file holds no certificates: {s}", .{tail});
        return false;
    }
    return true;
}

/// Handshake over a connected fd. `deadline_us` is the send attempt's
/// absolute budget on worker.zig's netNowUs() monotonic clock (same clock
/// as monotonicNowUs() here); every socket read AND write — inside the
/// handshake and in the session after it — is re-armed to that deadline, so
/// a peer dribbling fragments or stalling reads cannot stretch the stage
/// past it on either side. Taking the absolute deadline instead of a
/// remaining-duration avoids re-basing it onto a second, later now() sample.
/// null = failure, reason in last_error.
/// The caller owns the fd (worker's send_conn_fd / closeSendFd discipline —
/// a second SIGTERM close(2) punches the blocked handshake read the same way
/// it punches a plain one).
pub fn connect(fd: c_int, url_host: []const u8, opts: Options, deadline_us: i64) ?*Conn {
    clearFailure();
    const c = &conn_storage;
    const io_ref = io();
    c.deadline_reader = .{
        .io_ctx = io_ref,
        .interface = .{
            .vtable = &.{ .stream = DeadlineReader.streamImpl, .readVec = DeadlineReader.readVec },
            .buffer = &c.socket_read_buf,
            .seek = 0,
            .end = 0,
        },
        .sock_fd = fd,
        .deadline_us = deadline_us,
    };
    c.deadline_writer = DeadlineWriter.init(io_ref, &c.socket_write_buf, fd, deadline_us);
    io_ref.random(&c.entropy);
    var client_opts: tls.Client.Options = .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = &c.app_read_buf,
        .write_buffer = &c.app_write_buf,
        .entropy = &c.entropy,
        .realtime_now = realNow(),
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
    c.client = tls.Client.init(&c.deadline_reader.interface, &c.deadline_writer.interface, client_opts) catch |e| {
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
        failIfEmpty("tls handshake: {s}{s}", .{ name, hint });
        return null;
    };
    return c;
}
