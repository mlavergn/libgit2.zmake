const std = @import("std");
const log = std.log.scoped(.ziglibgit2_tls_stream);
const mod = @import("module.zig");

/// `git_stream`'s two bitfields, which share one `unsigned int`, in
/// allocation order: from the least significant bit on every target this
/// project builds for.
const GitStreamFlags = packed struct(c_uint) {
    const Self = @This();

    /// Whether the stream is encrypted.
    encrypted: bool = false,
    /// Whether the stream supports `set_proxy`.
    proxy_support: bool = false,
    /// The rest of the `unsigned int`, unused.
    _: u30 = 0,
};

/// `git_stream` (`include/git2/sys/stream.h`), declared by hand.
///
/// translate-c cannot represent its `encrypted : 1, proxy_support : 1`
/// bitfields and makes the whole struct opaque, so the layout is restated
/// here. The unit tests check it against the C compiler's through
/// `src/abi_probe.c`.
const GitStreamAbi = extern struct {
    const Self = @This();

    /// `GIT_STREAM_VERSION`.
    version: c_int,
    /// `encrypted` and `proxy_support`.
    flags: GitStreamFlags,
    /// Read and write timeout in milliseconds; 0 blocks indefinitely.
    timeout: c_int = 0,
    /// Connect timeout in milliseconds; 0 uses the system's.
    connect_timeout: c_int = 0,
    /// Opens the connection.
    connect: ?*const fn (*Self) callconv(.c) c_int,
    /// Returns the peer's certificate.
    certificate: ?*const fn (*?*mod.c.git_cert, *Self) callconv(.c) c_int,
    /// Sets the proxy, when `proxy_support` is set.
    set_proxy: ?*const fn (*Self, ?*const mod.c.git_proxy_options) callconv(.c) c_int,
    /// Reads up to the given length; returns the count, 0 at the end, -1 on error.
    read: ?*const fn (*Self, ?*anyopaque, usize) callconv(.c) isize,
    /// Writes the given bytes; returns the count or -1 on error.
    write: ?*const fn (*Self, [*]const u8, usize, c_int) callconv(.c) isize,
    /// Closes the connection.
    close: ?*const fn (*Self) callconv(.c) c_int,
    /// Releases the stream.
    free: ?*const fn (*Self) callconv(.c) void,
};

/// The process-wide state `TlsStream`'s C constructor reads: libgit2's
/// `git_stream_registration.init` carries no payload.
const TlsStreamShared = struct {
    const Self = @This();

    /// The allocator for streams and the trust store.
    allocator: std.mem.Allocator,
    /// The I/O implementation streams connect and read with.
    io: std.Io,
    /// The system's trusted roots, loaded on first connect.
    bundle: std.crypto.Certificate.Bundle = .empty,
    /// Guards `bundle` and `bundle_loaded`.
    bundle_lock: std.Io.RwLock = .init,
    /// Whether `bundle` holds the system's roots.
    bundle_loaded: bool = false,
};

/// The TLS stream libgit2 uses for `https://`, built on `std.crypto.tls`.
///
/// libgit2 is compiled with no HTTPS backend (`GIT_HTTPS` undefined), and
/// `streams/tls.c` asks the stream registry before any built-in backend, so
/// registering this stream is what gives the library HTTPS. Certificates are
/// verified against the system's trusted roots, loaded once through
/// `std.crypto.Certificate.Bundle.rescan`. The handshake fails on an untrusted
/// certificate, so a `certificate_check` callback sees only connections that
/// already passed, and is given a `GIT_CERT_NONE` certificate: `std` does not
/// expose the peer's X.509.
///
/// libgit2's constructor callback carries no payload, so the allocator, the
/// I/O implementation and the trust store are process-wide, set by the first
/// `register` and released by the last `unregister`.
pub const TlsStream = struct {
    const Self = @This();

    var shared: TlsStreamShared = undefined;
    /// Live registrations.
    var users: std.atomic.Value(usize) = .init(0);
    /// Registrations plus live streams: `shared` is released when the last of
    /// either goes, so a stream never outlives the trust store it verifies with.
    var refs: std.atomic.Value(usize) = .init(0);

    /// The certificate handed to `certificate_check` callbacks.
    var no_certificate: mod.c.git_cert = .{ .cert_type = mod.c.GIT_CERT_NONE };

    var registration: mod.c.git_stream_registration = .{
        .version = mod.c.GIT_STREAM_VERSION,
        .init = create,
        // Without `wrap`, HTTP CONNECT proxies are unsupported.
        .wrap = null,
    };

    /// The `git_stream` libgit2 holds a pointer to; `@fieldParentPtr` leads
    /// back to the rest.
    parent: GitStreamAbi,
    /// The allocator this stream and its buffers come from.
    allocator: std.mem.Allocator,
    /// The I/O implementation the socket uses.
    io: std.Io,
    /// The host to connect to and verify the certificate against.
    host: [:0]u8,
    /// The port to connect to.
    port: u16,
    /// The socket's and the TLS client's buffers, allocated by `connect`.
    buffer: []u8 = &.{},
    /// The socket, from connecting until `close`.
    socket: ?mod.TimedSocket = null,
    /// The TLS session; valid only while `connected`.
    client: std.crypto.tls.Client = undefined,
    /// Whether the handshake completed. `close` touches `client` only then.
    connected: bool = false,

    /// Registers the stream for every `https://` connection libgit2 makes.
    ///
    /// Reference-counted: each call must be paired with `unregister`. The
    /// allocator and I/O implementation of the call that found nothing alive
    /// serve every stream until the last registration and stream are gone.
    /// Call it from one thread at a time.
    ///
    /// - `allocator`: allocator for streams and the trust store.
    /// - `io`: the I/O implementation streams connect and read with.
    /// - Returns: nothing; propagates libgit2's registration failure.
    pub fn register(allocator: std.mem.Allocator, io: std.Io) mod.GitErrorSet!void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        if (refs.fetchAdd(1, .acq_rel) == 0) shared = .{ .allocator = allocator, .io = io };
        if (users.fetchAdd(1, .acq_rel) > 0) return;

        mod.GitError.check(mod.c.git_stream_register(mod.c.GIT_STREAM_TLS, &registration)) catch |err| {
            _ = users.fetchSub(1, .acq_rel);
            release();
            return err;
        };
    }

    /// Releases one `register`. The last one removes the stream from libgit2;
    /// the trust store goes with the last live stream. An `unregister` with no
    /// registration left is ignored.
    pub fn unregister() void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var current = users.load(.acquire);
        while (true) {
            if (current == 0) {
                log.warn("TlsStream.unregister without a matching register", .{});
                return;
            }
            current = users.cmpxchgWeak(current, current - 1, .acq_rel, .acquire) orelse break;
        }

        if (current == 1) _ = mod.c.git_stream_register(mod.c.GIT_STREAM_TLS, null);
        release();
    }

    /// Drops one reference; the last frees the trust store.
    fn release() void {
        if (refs.fetchSub(1, .acq_rel) != 1) return;
        shared.bundle.deinit(shared.allocator);
        shared.bundle_loaded = false;
    }

    /// `git_stream_registration.init`: creates an unconnected stream.
    ///
    /// - `out`: where the stream goes.
    /// - `host`: the host to connect to.
    /// - `port`: the port, as a number or service name.
    /// - Returns: 0, or `GIT_ERROR` with libgit2's error set.
    fn create(out: [*c]?*mod.c.git_stream, host: [*c]const u8, port: [*c]const u8) callconv(.c) c_int {
        const self = createStream(std.mem.span(host), std.mem.span(port)) catch |err| {
            return fail(mod.c.GIT_ERROR_NET, "cannot create TLS stream to {s}:{s}: {t}", .{ host, port, err });
        };
        out.* = @ptrCast(&self.parent);
        return 0;
    }

    fn createStream(host: []const u8, port: []const u8) !*Self {
        const allocator = shared.allocator;
        // Before any allocation, so a bad port leaks nothing.
        const port_number = try parsePort(port);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        const host_z = try allocator.dupeSentinel(u8, host, 0);

        self.* = .{
            .parent = .{
                .version = mod.c.GIT_STREAM_VERSION,
                .flags = .{ .encrypted = true },
                .connect = connect,
                .certificate = certificate,
                .set_proxy = setProxy,
                .read = read,
                .write = write,
                .close = close,
                .free = free,
            },
            .allocator = allocator,
            .io = shared.io,
            .host = host_z,
            .port = port_number,
        };

        // What libgit2's own socket stream takes from the global settings
        // (`streams/socket.c:380-381`); callers may still change them before
        // `connect`.
        _ = mod.c.git_libgit2_opts(mod.c.GIT_OPT_GET_SERVER_TIMEOUT, &self.parent.timeout);
        _ = mod.c.git_libgit2_opts(mod.c.GIT_OPT_GET_SERVER_CONNECT_TIMEOUT, &self.parent.connect_timeout);

        _ = refs.fetchAdd(1, .acq_rel);
        return self;
    }

    /// `git_stream.connect`: resolves the host, connects, and completes the
    /// TLS handshake.
    ///
    /// - `parent`: the stream.
    /// - Returns: 0, or `GIT_ERROR` with libgit2's error set.
    fn connect(parent: *GitStreamAbi) callconv(.c) c_int {
        const self: *Self = @alignCast(@fieldParentPtr("parent", parent));
        log.debug("{s}:{d} :: {s} {s}:{d}", .{ @src().file, @src().line, @src().fn_name, self.host, self.port });
        self.open() catch |err| {
            return fail(mod.c.GIT_ERROR_SSL, "TLS connection to {s}:{d} failed: {t}", .{ self.host, self.port, err });
        };
        return 0;
    }

    fn open(self: *Self) !void {
        try loadTrustStore();

        // As `std.http.Client` sizes them: the socket reader must hold a whole
        // ciphertext record, and the TLS reader a record plus room to spare.
        const record = std.crypto.tls.Client.min_buffer_len;
        if (self.buffer.len == 0) self.buffer = try self.allocator.alloc(u8, 5 * record);
        const socket_read = self.buffer[0..record];
        const socket_write = self.buffer[record .. 2 * record];
        const tls_read = self.buffer[2 * record .. 4 * record];
        const tls_write = self.buffer[4 * record ..];

        const host_name = try std.Io.net.HostName.init(self.host);
        const stream = try host_name.connect(self.io, self.port, .{
            .mode = .stream,
            .timeout = mod.TimedSocket.timeoutFromMilliseconds(self.parent.connect_timeout),
        });
        self.socket = mod.TimedSocket.init(self.io, stream, mod.TimedSocket.timeoutFromMilliseconds(self.parent.timeout), socket_read, socket_write) catch |err| {
            stream.close(self.io);
            return err;
        };
        // A failed handshake leaves nothing behind for `close` to touch.
        errdefer {
            self.socket.?.deinit();
            self.socket = null;
        }
        const socket = &self.socket.?;

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);

        self.client = std.crypto.tls.Client.init(&socket.reader, &socket.writer, .{
            .host = .{ .explicit = self.host },
            .ca = .{ .bundle = .{
                .gpa = shared.allocator,
                .io = shared.io,
                .lock = &shared.bundle_lock,
                .bundle = &shared.bundle,
            } },
            .read_buffer = tls_read,
            .write_buffer = tls_write,
            .entropy = &entropy,
            .realtime_now = std.Io.Clock.real.now(self.io),
            // Git's smart HTTP frames every body with a content length or
            // chunked encoding, so truncation is detected above TLS, as it is
            // for `std.http.Client`. Many servers close without close_notify.
            .allow_truncation_attacks = true,
        }) catch |err| switch (err) {
            error.WriteFailed, error.ReadFailed => return socket.err orelse err,
            else => return err,
        };
        self.connected = true;
    }

    /// `git_stream.certificate`: the handshake already verified the peer.
    ///
    /// - `out`: where the certificate goes: always `GIT_CERT_NONE`.
    /// - `parent`: the stream.
    /// - Returns: 0.
    fn certificate(out: *?*mod.c.git_cert, parent: *GitStreamAbi) callconv(.c) c_int {
        _ = parent;
        out.* = &no_certificate;
        return 0;
    }

    /// `git_stream.set_proxy`: never called, since `proxy_support` is 0.
    ///
    /// - `parent`: the stream.
    /// - `options`: the proxy.
    /// - Returns: `GIT_ERROR`.
    fn setProxy(parent: *GitStreamAbi, options: ?*const mod.c.git_proxy_options) callconv(.c) c_int {
        _ = parent;
        _ = options;
        return fail(mod.c.GIT_ERROR_NET, "the TLS stream does not support proxies", .{});
    }

    /// `git_stream.read`: returns what is available, at least one byte, or 0
    /// at the end of the stream.
    ///
    /// - `parent`: the stream.
    /// - `data`: where the plaintext goes.
    /// - `len`: the most to read.
    /// - Returns: the count, 0 at the end, or `GIT_ERROR`.
    fn read(parent: *GitStreamAbi, data: ?*anyopaque, len: usize) callconv(.c) isize {
        const self: *Self = @alignCast(@fieldParentPtr("parent", parent));
        if (!self.connected) return fail(mod.c.GIT_ERROR_SSL, "TLS read from {s}: not connected", .{self.host});
        const dest: [*]u8 = @ptrCast(data orelse return 0);
        const reader = &self.client.reader;

        if (reader.bufferedLen() == 0) {
            // `fill(1)`, not `fillMore`: one underlying read can yield no
            // application data, e.g. a TLS 1.3 session ticket, and 0 would
            // tell libgit2 the stream had ended.
            reader.fill(1) catch |err| switch (err) {
                error.EndOfStream => {
                    log.debug("end of stream from {s}", .{self.host});
                    return 0;
                },
                error.ReadFailed => {
                    const cause: anyerror = if (self.client.read_err) |e| e else if (self.socket.?.err) |e| e else err;
                    return fail(mod.c.GIT_ERROR_SSL, "TLS read from {s} failed: {t}", .{ self.host, cause });
                },
            };
        }

        const n = @min(len, reader.bufferedLen());
        @memcpy(dest[0..n], reader.buffered()[0..n]);
        reader.toss(n);
        log.debug("read {d} of {d} bytes from {s}", .{ n, len, self.host });
        return @intCast(n);
    }

    /// `git_stream.write`: encrypts and sends all of `data`.
    ///
    /// - `parent`: the stream.
    /// - `data`: the plaintext.
    /// - `len`: its length.
    /// - `flags`: unused, as in libgit2's own streams.
    /// - Returns: `len`, or `GIT_ERROR`.
    fn write(parent: *GitStreamAbi, data: [*]const u8, len: usize, flags: c_int) callconv(.c) isize {
        _ = flags;
        const self: *Self = @alignCast(@fieldParentPtr("parent", parent));
        if (!self.connected) return fail(mod.c.GIT_ERROR_SSL, "TLS write to {s}: not connected", .{self.host});
        self.send(data[0..len]) catch |err| {
            return fail(mod.c.GIT_ERROR_SSL, "TLS write to {s} failed: {t}", .{ self.host, err });
        };
        log.debug("wrote {d} bytes to {s}", .{ len, self.host });
        return @intCast(len);
    }

    fn send(self: *Self, bytes: []const u8) !void {
        self.client.writer.writeAll(bytes) catch return self.writeError();
        self.client.writer.flush() catch return self.writeError();
        self.socket.?.writer.flush() catch return self.writeError();
    }

    /// Returns the socket's error behind a failed write.
    ///
    /// - `self`: the stream.
    /// - Returns: the recorded error, or `error.WriteFailed`.
    fn writeError(self: *const Self) anyerror {
        if (self.socket.?.err) |e| return e;
        return error.WriteFailed;
    }

    /// `git_stream.close`: sends close_notify and closes the socket.
    ///
    /// - `parent`: the stream.
    /// - Returns: 0.
    fn close(parent: *GitStreamAbi) callconv(.c) c_int {
        const self: *Self = @alignCast(@fieldParentPtr("parent", parent));
        const socket = if (self.socket) |*s| s else return 0;

        if (self.connected) {
            // The peer may already be gone; closing proceeds either way.
            self.client.end() catch |err| log.debug("close_notify to {s}: {t}", .{ self.host, err });
            socket.writer.flush() catch |err| log.debug("flush to {s}: {t}", .{ self.host, err });
        }
        socket.deinit();
        self.socket = null;
        self.connected = false;
        return 0;
    }

    /// `git_stream.free`: releases the stream, closing it first if needed.
    ///
    /// - `parent`: the stream.
    fn free(parent: *GitStreamAbi) callconv(.c) void {
        const self: *Self = @alignCast(@fieldParentPtr("parent", parent));
        _ = close(parent);
        const allocator = self.allocator;
        allocator.free(self.buffer);
        allocator.free(self.host);
        allocator.destroy(self);
        release();
    }

    /// Loads the system's trusted roots once, as `std.http.Client` does.
    ///
    /// - Returns: nothing; propagates lock and rescan failures.
    fn loadTrustStore() !void {
        const io = shared.io;
        {
            try shared.bundle_lock.lockShared(io);
            defer shared.bundle_lock.unlockShared(io);
            if (shared.bundle_loaded) return;
        }

        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(shared.allocator);
        try bundle.rescan(shared.allocator, io, std.Io.Clock.real.now(io));

        try shared.bundle_lock.lock(io);
        defer shared.bundle_lock.unlock(io);
        if (shared.bundle_loaded) return;
        std.mem.swap(std.crypto.Certificate.Bundle, &shared.bundle, &bundle);
        shared.bundle_loaded = true;
    }

    /// Parses the port libgit2 passes: a number, or `https`/`http`.
    ///
    /// - `port`: the port string.
    /// - Returns: the port; `error.InvalidCharacter` or `error.Overflow`.
    fn parsePort(port: []const u8) !u16 {
        if (std.mem.eql(u8, port, "https")) return 443;
        if (std.mem.eql(u8, port, "http")) return 80;
        return std.fmt.parseInt(u16, port, 10);
    }

    /// Records an error for libgit2 to report.
    ///
    /// - `class`: the `GIT_ERROR_*` class.
    /// - `fmt`: the message format.
    /// - `args`: its arguments.
    /// - Returns: `GIT_ERROR`, for the callback to return.
    fn fail(class: c_int, comptime fmt: []const u8, args: anytype) c_int {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buffer, fmt, args, 0) catch "TLS stream error (message truncated)";
        log.debug("{s}", .{message});
        _ = mod.c.git_error_set_str(class, message.ptr);
        return mod.c.GIT_ERROR;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

extern fn ziglibgit2_git_stream_size() usize;
extern fn ziglibgit2_git_stream_probe(
    stream: *const GitStreamAbi,
    encrypted: *c_int,
    proxy_support: *c_int,
    timeout: *c_int,
    connect_timeout: *c_int,
    read_fn: *?*anyopaque,
    free_fn: *?*anyopaque,
) c_int;

test {
    std.testing.refAllDecls(@This());
}

test "git_stream layout matches the C compiler's" {
    try std.testing.expectEqual(ziglibgit2_git_stream_size(), @sizeOf(GitStreamAbi));

    const stream = GitStreamAbi{
        .version = 7,
        .flags = .{ .encrypted = true, .proxy_support = false },
        .timeout = 11,
        .connect_timeout = 13,
        .connect = null,
        .certificate = null,
        .set_proxy = null,
        .read = TlsStream.read,
        .write = null,
        .close = null,
        .free = TlsStream.free,
    };

    var encrypted: c_int = 0;
    var proxy_support: c_int = 0;
    var timeout: c_int = 0;
    var connect_timeout: c_int = 0;
    var read_fn: ?*anyopaque = null;
    var free_fn: ?*anyopaque = null;
    const version = ziglibgit2_git_stream_probe(&stream, &encrypted, &proxy_support, &timeout, &connect_timeout, &read_fn, &free_fn);

    try std.testing.expectEqual(7, version);
    try std.testing.expectEqual(1, encrypted);
    try std.testing.expectEqual(0, proxy_support);
    try std.testing.expectEqual(11, timeout);
    try std.testing.expectEqual(13, connect_timeout);
    try std.testing.expectEqual(@intFromPtr(&TlsStream.read), @intFromPtr(read_fn));
    try std.testing.expectEqual(@intFromPtr(&TlsStream.free), @intFromPtr(free_fn));
}

test "a failed handshake can still be closed and freed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var lib = try mod.Libgit2.init(allocator, io);
    defer lib.deinit();

    // A loopback server that answers the ClientHello with plain text.
    const NotTls = struct {
        const Self = @This();

        fn serve(server_io: std.Io, server: *std.Io.net.Server) void {
            var stream = server.accept(server_io) catch |err| return log.warn("accept: {t}", .{err});
            defer stream.close(server_io);
            var writer = stream.writer(server_io, &.{});
            writer.interface.writeAll("HTTP/1.1 400 Not TLS\r\n\r\n") catch |err| log.warn("write: {t}", .{err});
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const thread = try std.Thread.spawn(.{}, NotTls.serve, .{ io, &server });
    defer thread.join();

    var port_buffer: [8]u8 = undefined;
    const port = try std.fmt.bufPrintSentinel(&port_buffer, "{d}", .{server.socket.address.getPort()}, 0);
    var out: ?*mod.c.git_stream = null;
    try std.testing.expectEqual(0, TlsStream.create(&out, "127.0.0.1", port));
    const parent: *GitStreamAbi = @ptrCast(@alignCast(out.?));

    // libgit2 closes and frees a stream whose connect failed
    // (`httpclient.c:1061-1062`); both used to touch the unset TLS client.
    try std.testing.expectEqual(mod.c.GIT_ERROR, TlsStream.connect(parent));
    try std.testing.expectEqual(0, TlsStream.close(parent));
    TlsStream.free(parent);
}

test "a silent server times out" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var lib = try mod.Libgit2.init(allocator, io);
    defer lib.deinit();

    try mod.GitError.check(mod.c.git_libgit2_opts(mod.c.GIT_OPT_SET_SERVER_TIMEOUT, @as(c_int, 200)));
    defer _ = mod.c.git_libgit2_opts(mod.c.GIT_OPT_SET_SERVER_TIMEOUT, @as(c_int, 0));

    // A loopback server that accepts, then says nothing until the client hangs up.
    const Silent = struct {
        const Self = @This();

        fn serve(server_io: std.Io, server: *std.Io.net.Server) void {
            var stream = server.accept(server_io) catch |err| return log.warn("accept: {t}", .{err});
            defer stream.close(server_io);
            var buffer: [256]u8 = undefined;
            var reader = stream.reader(server_io, &buffer);
            _ = reader.interface.discardRemaining() catch |err| log.debug("silent server: {t}", .{err});
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const thread = try std.Thread.spawn(.{}, Silent.serve, .{ io, &server });
    defer thread.join();

    var port_buffer: [8]u8 = undefined;
    const port = try std.fmt.bufPrintSentinel(&port_buffer, "{d}", .{server.socket.address.getPort()}, 0);
    var out: ?*mod.c.git_stream = null;
    try std.testing.expectEqual(0, TlsStream.create(&out, "127.0.0.1", port));
    const parent: *GitStreamAbi = @ptrCast(@alignCast(out.?));
    defer TlsStream.free(parent);
    try std.testing.expectEqual(200, parent.timeout);

    try std.testing.expectEqual(mod.c.GIT_ERROR, TlsStream.connect(parent));
    try std.testing.expect(std.mem.find(u8, mod.GitError.lastMessage(), "Timeout") != null);
}

test "a bad port is refused without a leak" {
    var lib = try mod.Libgit2.init(std.testing.allocator, std.testing.io);
    defer lib.deinit();

    var out: ?*mod.c.git_stream = null;
    try std.testing.expectEqual(mod.c.GIT_ERROR, TlsStream.create(&out, "example.com", "git"));
    try std.testing.expectEqual(null, out);
}

test "an unbalanced unregister is ignored" {
    // The warning it logs is the expected outcome here.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;

    try std.testing.expectEqual(0, TlsStream.users.load(.acquire));
    TlsStream.unregister();
    try std.testing.expectEqual(0, TlsStream.users.load(.acquire));
    try std.testing.expectEqual(0, TlsStream.refs.load(.acquire));
}

test "registration is reference-counted" {
    var lib = try mod.Libgit2.init(std.testing.allocator, std.testing.io);
    defer lib.deinit();

    try TlsStream.register(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(2, TlsStream.users.load(.acquire));
    TlsStream.unregister();
    try std.testing.expectEqual(1, TlsStream.users.load(.acquire));
}

test "ports parse as numbers or service names" {
    try std.testing.expectEqual(443, try TlsStream.parsePort("443"));
    try std.testing.expectEqual(443, try TlsStream.parsePort("https"));
    try std.testing.expectEqual(8443, try TlsStream.parsePort("8443"));
    try std.testing.expectError(error.InvalidCharacter, TlsStream.parsePort("git"));
}
