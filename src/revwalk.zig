const std = @import("std");
const log = std.log.scoped(.ziglibgit2_revwalk);
const mod = @import("module.zig");

/// The order a `Revwalk` returns commits in.
pub const RevwalkSort = enum {
    /// libgit2's default: reverse chronological, unspecified for ties.
    none,
    /// Parents never before their children.
    topological,
    /// By commit time, newest first.
    time,
    /// By commit time, keeping parents after children.
    topologicalTime,
};

/// A walk over commit history, as `git log` does.
pub const Revwalk = struct {
    const Self = @This();

    /// The libgit2 walk, owned.
    handle: *mod.c.git_revwalk,

    /// Creates a walk over `repo`, with no starting points.
    ///
    /// - `repo`: the repository to walk.
    /// - Returns: the walk; propagates libgit2 failures.
    pub fn init(repo: *const mod.Repository) mod.GitErrorSet!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var handle: ?*mod.c.git_revwalk = null;
        try mod.GitError.check(mod.c.git_revwalk_new(&handle, repo.handle));
        return Self{ .handle = handle.? };
    }

    /// Releases the walk.
    ///
    /// - `self`: the walk.
    pub fn deinit(self: *Self) void {
        mod.c.git_revwalk_free(self.handle);
    }

    /// Starts the walk from `HEAD`.
    ///
    /// - `self`: the walk.
    /// - Returns: nothing; `error.UnbornBranch` before the first commit.
    pub fn pushHead(self: *Self) mod.GitErrorSet!void {
        try mod.GitError.check(mod.c.git_revwalk_push_head(self.handle));
    }

    /// Sets the order commits come out in; resets the walk.
    ///
    /// - `self`: the walk.
    /// - `sort`: the order.
    /// - Returns: nothing; propagates libgit2 failures.
    pub fn setSorting(self: *Self, sort: RevwalkSort) mod.GitErrorSet!void {
        const mode: c_int = switch (sort) {
            .none => 0,
            .topological => mod.c.GIT_SORT_TOPOLOGICAL,
            .time => mod.c.GIT_SORT_TIME,
            .topologicalTime => mod.c.GIT_SORT_TOPOLOGICAL | mod.c.GIT_SORT_TIME,
        };
        try mod.GitError.check(mod.c.git_revwalk_sorting(self.handle, @intCast(mode)));
    }

    /// Returns the next commit's id.
    ///
    /// - `self`: the walk.
    /// - Returns: the id, or null once the walk is over; propagates failures.
    pub fn next(self: *Self) mod.GitErrorSet!?mod.Oid {
        var oid: mod.c.git_oid = .{};
        const code = mod.c.git_revwalk_next(&oid, self.handle);
        // The normal end of a walk, not a failure to report.
        if (code == mod.c.GIT_ITEROVER) return null;
        try mod.GitError.check(code);
        return mod.Oid.init(&oid);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Revwalk);
}

test "revwalk returns history newest first" {
    var fixture = try mod.TestRepo.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const first = try fixture.commitFile("README", "one\n", "First");
    const second = try fixture.commitFile("README", "two\n", "Second");

    var walk = try Revwalk.init(&fixture.repo);
    defer walk.deinit();
    try walk.setSorting(.topologicalTime);
    try walk.pushHead();

    try std.testing.expect((try walk.next()).?.eql(&second));
    try std.testing.expect((try walk.next()).?.eql(&first));
    try std.testing.expectEqual(null, try walk.next());
}
