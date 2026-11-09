const std = @import("std");
const log = std.log.scoped(.ziglibgit2_oid);
const mod = @import("module.zig");

/// A git object id: a SHA-1 hash, held by value.
pub const Oid = struct {
    const Self = @This();

    /// The length of an id in hexadecimal.
    pub const hex_len = 40;

    /// The libgit2 representation.
    raw: mod.c.git_oid,

    /// Wraps an id libgit2 returned.
    ///
    /// - `raw`: the id, copied.
    /// - Returns: the id.
    pub fn init(raw: *const mod.c.git_oid) Self {
        return Self{ .raw = raw.* };
    }

    /// Parses a full 40-character hexadecimal id.
    ///
    /// - `hex`: the id in hexadecimal.
    /// - Returns: the id; `error.Invalid` unless `hex` is exactly 40 hex digits.
    pub fn fromHex(hex: []const u8) mod.GitErrorSet!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        if (hex.len != hex_len) return error.Invalid;
        var self = Self{ .raw = .{} };
        try mod.GitError.check(mod.c.git_oid_fromstrn(&self.raw, hex.ptr, hex.len));
        return self;
    }

    /// Formats the id in hexadecimal.
    ///
    /// - `self`: the id.
    /// - `buffer`: where the digits go.
    /// - Returns: `buffer`, filled.
    pub fn toHex(self: *const Self, buffer: *[hex_len]u8) []const u8 {
        _ = mod.c.git_oid_fmt(buffer, &self.raw);
        return buffer;
    }

    /// Returns whether two ids are the same object.
    ///
    /// - `self`: the id.
    /// - `other`: the id to compare with.
    /// - Returns: true when equal.
    pub fn eql(self: *const Self, other: *const Self) bool {
        return mod.c.git_oid_equal(&self.raw, &other.raw) != 0;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Oid);
}

test "oid round-trips through hexadecimal" {
    const hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = try Oid.fromHex(hex);

    var buffer: [Oid.hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(hex, oid.toHex(&buffer));
    try std.testing.expect(oid.eql(&(try Oid.fromHex(hex))));
}

test "oid rejects malformed hexadecimal" {
    try std.testing.expectError(error.Invalid, Oid.fromHex("e69de29b"));
    try std.testing.expectError(error.Generic, Oid.fromHex("zz9de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
}
