const std = @import("std");
const log = std.log.scoped(.libgit2_reference);
const mod = @import("module.zig");

/// A git reference, such as a branch, tag, or `HEAD`.
///
/// Owns its `git_reference`. The strings it returns are borrowed from it and
/// valid until `deinit`.
pub const Reference = struct {
    const Self = @This();

    /// The libgit2 reference, owned.
    handle: *mod.c.git_reference,

    /// Takes ownership of a reference libgit2 returned.
    ///
    /// - `handle`: the reference.
    /// - Returns: the wrapper; the error union is reserved for the lifecycle
    ///   convention and yields no error today.
    pub fn init(handle: *mod.c.git_reference) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return Self{ .handle = handle };
    }

    /// Releases the reference.
    ///
    /// - `self`: the reference.
    pub fn deinit(self: *Self) void {
        mod.c.git_reference_free(self.handle);
    }

    /// Returns the full name, e.g. `refs/heads/main`.
    ///
    /// - `self`: the reference.
    /// - Returns: the name, borrowed.
    pub fn name(self: *const Self) []const u8 {
        return std.mem.span(mod.c.git_reference_name(self.handle));
    }

    /// Returns the short name, e.g. `main`.
    ///
    /// - `self`: the reference.
    /// - Returns: the name, borrowed.
    pub fn shorthand(self: *const Self) []const u8 {
        return std.mem.span(mod.c.git_reference_shorthand(self.handle));
    }

    /// Returns the object a direct reference points to.
    ///
    /// - `self`: the reference.
    /// - Returns: the id, or null for a symbolic reference.
    pub fn target(self: *const Self) ?mod.Oid {
        const oid = mod.c.git_reference_target(self.handle);
        if (oid == null) return null;
        return mod.Oid.fromRaw(oid);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Reference);
}

test "head names the branch and its commit" {
    var fixture = try mod.TestRepo.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const oid = try fixture.commitFile("README", "hello\n", "Initial commit");

    var ref = try fixture.repo.head();
    defer ref.deinit();

    try std.testing.expect(std.mem.startsWith(u8, ref.name(), "refs/heads/"));
    try std.testing.expectEqualStrings(ref.name()["refs/heads/".len..], ref.shorthand());
    try std.testing.expect(ref.target().?.eql(&oid));
}
