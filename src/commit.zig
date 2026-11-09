const std = @import("std");
const log = std.log.scoped(.ziglibgit2_commit);
const mod = @import("module.zig");

/// A commit object.
///
/// Owns its `git_commit`. The strings it returns are borrowed from it and
/// valid until `deinit`.
pub const Commit = struct {
    const Self = @This();

    /// The libgit2 commit, owned.
    handle: *mod.c.git_commit,

    /// Looks up a commit by id.
    ///
    /// - `repo`: the repository holding it.
    /// - `oid`: the commit's id.
    /// - Returns: the commit; `error.NotFound` when there is no such commit.
    pub fn lookup(repo: *const mod.Repository, oid: *const mod.Oid) mod.GitErrorSet!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var handle: ?*mod.c.git_commit = null;
        try mod.GitError.check(mod.c.git_commit_lookup(&handle, repo.handle, &oid.raw));
        return Self{ .handle = handle.? };
    }

    /// Releases the commit.
    ///
    /// - `self`: the commit.
    pub fn deinit(self: *Self) void {
        mod.c.git_commit_free(self.handle);
    }

    /// Returns the commit's id.
    ///
    /// - `self`: the commit.
    /// - Returns: the id.
    pub fn id(self: *const Self) mod.Oid {
        return mod.Oid.init(mod.c.git_commit_id(self.handle));
    }

    /// Returns the first paragraph of the message, on one line.
    ///
    /// - `self`: the commit.
    /// - Returns: the summary, borrowed; empty if libgit2 cannot allocate it.
    pub fn summary(self: *const Self) []const u8 {
        const text = mod.c.git_commit_summary(self.handle);
        if (text == null) return "";
        return std.mem.span(text);
    }

    /// Returns the full message.
    ///
    /// - `self`: the commit.
    /// - Returns: the message, borrowed.
    pub fn message(self: *const Self) []const u8 {
        return std.mem.span(mod.c.git_commit_message(self.handle));
    }

    /// Returns the author's name.
    ///
    /// - `self`: the commit.
    /// - Returns: the name, borrowed.
    pub fn authorName(self: *const Self) []const u8 {
        return std.mem.span(mod.c.git_commit_author(self.handle).*.name);
    }

    /// Returns the author's email address.
    ///
    /// - `self`: the commit.
    /// - Returns: the address, borrowed.
    pub fn authorEmail(self: *const Self) []const u8 {
        return std.mem.span(mod.c.git_commit_author(self.handle).*.email);
    }

    /// Returns the committer's timestamp.
    ///
    /// - `self`: the commit.
    /// - Returns: seconds since the Unix epoch.
    pub fn time(self: *const Self) i64 {
        return mod.c.git_commit_time(self.handle);
    }

    /// Returns the number of parents: 0 for a root commit, 2+ for a merge.
    ///
    /// - `self`: the commit.
    /// - Returns: the parent count.
    pub fn parentCount(self: *const Self) usize {
        return mod.c.git_commit_parentcount(self.handle);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Commit);
}

test "commit exposes its message, author and parents" {
    var fixture = try mod.TestRepo.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    _ = try fixture.commitFile("README", "hello\n", "Initial commit");
    const second = try fixture.commitFile("README", "hello again\n", "Second commit\n\nWith a body.");

    var commit = try Commit.lookup(&fixture.repo, &second);
    defer commit.deinit();

    try std.testing.expect(commit.id().eql(&second));
    try std.testing.expectEqualStrings("Second commit", commit.summary());
    try std.testing.expectEqualStrings("Second commit\n\nWith a body.", commit.message());
    try std.testing.expectEqualStrings(mod.TestRepo.author_name, commit.authorName());
    try std.testing.expectEqualStrings(mod.TestRepo.author_email, commit.authorEmail());
    try std.testing.expectEqual(mod.TestRepo.commit_time, commit.time());
    try std.testing.expectEqual(1, commit.parentCount());
}
