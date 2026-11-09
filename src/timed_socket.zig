const std = @import("std");
const log = std.log.scoped(.ziglibgit2_timed_socket);

/// A connected TCP stream's reader and writer, with a deadline on every read
/// and write.
///
/// `std.Io.net.Stream`'s own reader and writer block indefinitely, and a
/// socket-level timeout (`SO_RCVTIMEO`) is no way out: std's I/O treats the
/// `EAGAIN` it produces as a bug. These go through `std.Io.operateTimeout`
/// instead. An `Io` that cannot run operations concurrently cannot time them
/// out either; then they wait indefinitely, as a timeout of 0 does in libgit2.
pub const TimedSocket = struct {
    const Self = @This();

    /// The I/O implementation every operation runs on.
    io: std.Io,
    /// The connected stream; closed by `close`.
    stream: std.Io.net.Stream,
    /// The deadline for each read and each write.
    timeout: std.Io.Timeout,
    /// Bytes in: the TLS client's ciphertext input.
    reader: std.Io.Reader,
    /// Bytes out: the TLS client's ciphertext output.
    writer: std.Io.Writer,
    /// The error behind the last `error.ReadFailed` or `error.WriteFailed`.
    err: ?anyerror = null,

    /// Wraps a connected stream.
    ///
    /// The value must not move after `init`: `reader` and `writer` find it
    /// through `@fieldParentPtr`.
    ///
    /// - `io`: the I/O implementation every operation runs on.
    /// - `stream`: the connected stream; owned from here on.
    /// - `timeout`: the deadline for each read and each write.
    /// - `read_buffer`: the reader's buffer.
    /// - `write_buffer`: the writer's buffer.
    /// - Returns: the socket; the error union is reserved for the lifecycle
    ///   convention and yields no error today.
    pub fn init(io: std.Io, stream: std.Io.net.Stream, timeout: std.Io.Timeout, read_buffer: []u8, write_buffer: []u8) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return Self{
            .io = io,
            .stream = stream,
            .timeout = timeout,
            .reader = .{ .vtable = &.{ .stream = streamImpl }, .buffer = read_buffer, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = write_buffer },
        };
    }

    /// Closes the stream.
    ///
    /// - `self`: the socket.
    pub fn deinit(self: *Self) void {
        self.stream.close(self.io);
    }

    /// Converts a libgit2 timeout to a std one.
    ///
    /// - `milliseconds`: libgit2's timeout; 0 or less waits indefinitely.
    /// - Returns: the timeout.
    pub fn timeoutFromMilliseconds(milliseconds: c_int) std.Io.Timeout {
        if (milliseconds <= 0) return .none;
        return .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(milliseconds), .clock = .awake } };
    }

    /// `std.Io.Reader.VTable.stream`: one timed read into `io_w`.
    ///
    /// - `io_r`: the socket's `reader`.
    /// - `io_w`: where the bytes go.
    /// - `limit`: the most to read.
    /// - Returns: the count; `error.EndOfStream` when the peer closed, or
    ///   `error.ReadFailed` with the cause in `err`.
    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Self = @alignCast(@fieldParentPtr("reader", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};

        const result = self.perform(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &data } }) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        const read = result.net_read catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (read.data_len == 0) return error.EndOfStream;

        io_w.advance(read.data_len);
        return read.data_len;
    }

    /// `std.Io.Writer.VTable.drain`: one timed write of the buffer, then
    /// `data`, as `std.Io.net.Stream.Writer` does it.
    ///
    /// - `io_w`: the socket's `writer`.
    /// - `data`: the slices after the buffer; the last is repeated `splat` times.
    /// - `splat`: how many times the last slice is written.
    /// - Returns: the bytes of `data` consumed; `error.WriteFailed` with the
    ///   cause in `err`.
    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Self = @alignCast(@fieldParentPtr("writer", io_w));

        const result = self.perform(.{ .net_write = .{
            .socket_handle = self.stream.socket.handle,
            .header = io_w.buffered(),
            .data = data,
            .splat = splat,
        } }) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        const n = result.net_write catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }

    /// Runs one operation under the deadline, or without one when the `Io`
    /// cannot run operations concurrently.
    ///
    /// - `self`: the socket.
    /// - `operation`: the read or write.
    /// - Returns: its result; `error.Timeout` past the deadline.
    fn perform(self: *Self, operation: std.Io.Operation) !std.Io.Operation.Result {
        return self.io.operateTimeout(operation, self.timeout) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                log.debug("no concurrency for a timed operation; waiting indefinitely", .{});
                return self.io.operate(operation);
            },
            else => return err,
        };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(TimedSocket);
}

test "libgit2 timeouts convert to std ones" {
    try std.testing.expectEqual(std.Io.Timeout.none, TimedSocket.timeoutFromMilliseconds(0));
    try std.testing.expectEqual(std.Io.Timeout.none, TimedSocket.timeoutFromMilliseconds(-1));
    const timeout = TimedSocket.timeoutFromMilliseconds(1500);
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), timeout.duration.raw);
}
