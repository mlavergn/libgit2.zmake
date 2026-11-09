const std = @import("std");
const log = std.log.scoped(.ziglibgit2_libgit2);
const mod = @import("module.zig");

/// libgit2's global state, plus the Zig TLS stream that gives it HTTPS.
///
/// Every other type in this module needs a live `Libgit2`. libgit2 counts
/// `git_libgit2_init` calls itself and tears down on the last
/// `git_libgit2_shutdown`; `TlsStream.register` is counted the same way, so
/// values may be created more than once, provided each is `deinit`ed.
pub const Libgit2 = struct {
    const Self = @This();

    /// The allocator TLS streams and the trust store use.
    allocator: std.mem.Allocator,
    /// The I/O implementation TLS streams use.
    io: std.Io,

    /// Initializes libgit2 and registers the TLS stream.
    ///
    /// - `allocator`: allocator for TLS streams and the trust store; must
    ///   outlive every value.
    /// - `io`: the I/O implementation TLS streams use.
    /// - Returns: the handle; propagates libgit2 initialization failure.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) mod.GitErrorSet!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        try mod.GitError.check(mod.c.git_libgit2_init());
        mod.TlsStream.register(allocator, io) catch |err| {
            _ = mod.c.git_libgit2_shutdown();
            return err;
        };
        return Self{ .allocator = allocator, .io = io };
    }

    /// Releases this handle's share of libgit2 and the TLS stream.
    ///
    /// - `self`: the handle.
    pub fn deinit(self: *Self) void {
        _ = self;
        mod.TlsStream.unregister();
        _ = mod.c.git_libgit2_shutdown();
    }

    /// Returns the libgit2 version the module was built from.
    ///
    /// - Returns: the version; libgit2's revision is the `patch` number.
    pub fn version() std.SemanticVersion {
        var major: c_int = 0;
        var minor: c_int = 0;
        var revision: c_int = 0;
        _ = mod.c.git_libgit2_version(&major, &minor, &revision);
        return .{ .major = @intCast(major), .minor = @intCast(minor), .patch = @intCast(revision) };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Libgit2);
}

test "libgit2 is the version build.zig.zon declares" {
    var lib = try Libgit2.init(std.testing.allocator, std.testing.io);
    defer lib.deinit();

    // `.version` tracks the libgit2 pin; this fails when one moves alone.
    const declared = try std.SemanticVersion.parse(mod.config.version);
    try std.testing.expectEqual(std.math.Order.eq, declared.order(Libgit2.version()));
}

test "libgit2 initializes more than once" {
    var first = try Libgit2.init(std.testing.allocator, std.testing.io);
    defer first.deinit();
    var second = try Libgit2.init(std.testing.allocator, std.testing.io);
    defer second.deinit();
}
