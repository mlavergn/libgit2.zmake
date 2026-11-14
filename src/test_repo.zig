const std = @import("std");
const log = std.log.scoped(.libgit2_test_repo);
const mod = @import("module.zig");

/// A throwaway repository for the unit tests.
///
/// Initializes libgit2, creates a non-bare repository in a temporary
/// directory, and makes commits with a fixed author and time so tests can
/// assert on them. Everything is removed by `deinit`.
pub const TestRepo = struct {
    const Self = @This();

    /// The author and committer of every fixture commit.
    pub const author_name = "Zig Tester";
    /// The author's email address.
    pub const author_email = "tester@example.com";
    /// The time of every fixture commit, in seconds since the Unix epoch.
    pub const commit_time: i64 = 1_700_000_000;

    /// The allocator for paths and libgit2 strings.
    allocator: std.mem.Allocator,
    /// The I/O implementation for files and TLS.
    io: std.Io,
    /// The fixture's share of libgit2.
    lib: mod.Libgit2,
    /// The temporary directory holding the repository.
    tmp: std.testing.TmpDir,
    /// The absolute path of the working directory.
    path: [:0]const u8,
    /// The repository under test.
    repo: mod.Repository,

    /// Creates the repository, in a `repo` directory inside a fresh temporary
    /// directory, so tests may place siblings next to it.
    ///
    /// - `allocator`: allocator for paths and libgit2 strings.
    /// - `io`: the I/O implementation for files and TLS.
    /// - Returns: the fixture; propagates file-system and libgit2 failures.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var lib = try mod.Libgit2.init(allocator, io);
        errdefer lib.deinit();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "repo");

        const path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
        errdefer allocator.free(path);

        const repo = try mod.Repository.create(allocator, path, false);
        return Self{ .allocator = allocator, .io = io, .lib = lib, .tmp = tmp, .path = path, .repo = repo };
    }

    /// Removes the repository and releases libgit2.
    ///
    /// - `self`: the fixture.
    pub fn deinit(self: *Self) void {
        self.repo.deinit();
        self.allocator.free(self.path);
        self.tmp.cleanup();
        self.lib.deinit();
    }

    /// Writes a file in the working directory, creating its directories.
    ///
    /// - `self`: the fixture.
    /// - `rel_path`: the path relative to the working directory.
    /// - `contents`: the file's contents.
    /// - Returns: nothing; propagates file-system failures.
    pub fn writeFile(self: *Self, rel_path: []const u8, contents: []const u8) !void {
        const sub_path = try std.Io.Dir.path.join(self.allocator, &.{ "repo", rel_path });
        defer self.allocator.free(sub_path);
        if (std.Io.Dir.path.dirname(sub_path)) |dir| try self.tmp.dir.createDirPath(self.io, dir);
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = sub_path, .data = contents });
    }

    /// Writes a file, stages it, and commits it on `HEAD`.
    ///
    /// - `self`: the fixture.
    /// - `rel_path`: the path relative to the working directory.
    /// - `contents`: the file's contents.
    /// - `message`: the commit message.
    /// - Returns: the new commit's id; propagates file-system and libgit2
    ///   failures.
    pub fn commitFile(self: *Self, rel_path: []const u8, contents: []const u8, message: []const u8) !mod.Oid {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const repo = self.repo.handle;

        try self.writeFile(rel_path, contents);

        const path_z = try self.allocator.dupeSentinel(u8, rel_path, 0);
        defer self.allocator.free(path_z);
        const message_z = try self.allocator.dupeSentinel(u8, message, 0);
        defer self.allocator.free(message_z);

        var index: ?*mod.c.git_index = null;
        try mod.GitError.check(mod.c.git_repository_index(&index, repo));
        defer mod.c.git_index_free(index);
        try mod.GitError.check(mod.c.git_index_add_bypath(index, path_z));
        try mod.GitError.check(mod.c.git_index_write(index));

        var tree_id: mod.c.git_oid = .{};
        try mod.GitError.check(mod.c.git_index_write_tree(&tree_id, index));
        var tree: ?*mod.c.git_tree = null;
        try mod.GitError.check(mod.c.git_tree_lookup(&tree, repo, &tree_id));
        defer mod.c.git_tree_free(tree);

        var signature: [*c]mod.c.git_signature = null;
        try mod.GitError.check(mod.c.git_signature_new(&signature, author_name, author_email, commit_time, 0));
        defer mod.c.git_signature_free(signature);

        var parent: ?mod.Commit = null;
        defer if (parent) |*p| p.deinit();
        if (self.repo.head()) |head_ref| {
            var ref = head_ref;
            defer ref.deinit();
            parent = try mod.Commit.lookup(&self.repo, &ref.target().?);
        } else |err| switch (err) {
            error.UnbornBranch => {},
            else => return err,
        }

        var parents = [_]?*const mod.c.git_commit{if (parent) |p| p.handle else null};
        var id: mod.c.git_oid = .{};
        try mod.GitError.check(mod.c.git_commit_create(&id, repo, "HEAD", signature, signature, null, message_z, tree, @intFromBool(parent != null), &parents));
        return mod.Oid.fromRaw(&id);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}
