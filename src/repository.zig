const std = @import("std");
const log = std.log.scoped(.ziglibgit2_repository);
const mod = @import("module.zig");

/// A git repository: opened, created, or cloned.
///
/// Needs a live `mod.Libgit2`. Owns its `git_repository`; values derived from
/// it (references, commits, walks, status lists) must be released first.
pub const Repository = struct {
    const Self = @This();

    /// The libgit2 repository, owned.
    handle: *mod.c.git_repository,

    /// Opens the repository at `path`.
    ///
    /// - `allocator`: allocator for the copies of the paths passed to libgit2,
    ///   freed before returning.
    /// - `path`: the working directory or the `.git` directory.
    /// - Returns: the repository; `error.NotFound` when `path` is not one.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        var handle: ?*mod.c.git_repository = null;
        try mod.GitError.check(mod.c.git_repository_open(&handle, path_z));
        return Self{ .handle = handle.? };
    }

    /// Creates a repository at `path`, as `git init` does.
    ///
    /// - `allocator`: allocator for the copies of the paths passed to libgit2,
    ///   freed before returning.
    /// - `path`: the directory to create it in.
    /// - `bare`: true for a bare repository.
    /// - Returns: the new repository; propagates libgit2 failures.
    pub fn create(allocator: std.mem.Allocator, path: []const u8, bare: bool) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        var handle: ?*mod.c.git_repository = null;
        try mod.GitError.check(mod.c.git_repository_init(&handle, path_z, @intFromBool(bare)));
        return Self{ .handle = handle.? };
    }

    /// Clones `url` into `path`, as `git clone` does.
    ///
    /// `https://` goes through `mod.TlsStream`; `ssh://` and `user@host:`
    /// through libssh2, authenticating with `credentials`.
    ///
    /// - `allocator`: allocator for the copies of the strings passed to
    ///   libgit2, freed before returning.
    /// - `url`: the remote to clone.
    /// - `path`: the new working directory; must not exist or be empty.
    /// - `credentials`: SSH credentials, or null for anonymous access.
    /// - Returns: the clone; propagates libgit2 failures, whose message
    ///   `mod.GitError.lastMessage` gives.
    pub fn clone(allocator: std.mem.Allocator, url: []const u8, path: []const u8, credentials: ?*mod.Credentials) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const url_z = try allocator.dupeSentinel(u8, url, 0);
        defer allocator.free(url_z);
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        var options: mod.c.git_clone_options = .{};
        try mod.GitError.check(mod.c.git_clone_options_init(&options, mod.c.GIT_CLONE_OPTIONS_VERSION));
        if (credentials) |creds| creds.install(&options.fetch_opts.callbacks);

        var handle: ?*mod.c.git_repository = null;
        try mod.GitError.check(mod.c.git_clone(&handle, url_z, path_z, &options));
        return Self{ .handle = handle.? };
    }

    /// Releases the repository.
    ///
    /// - `self`: the repository.
    pub fn deinit(self: *Self) void {
        mod.c.git_repository_free(self.handle);
    }

    /// Returns the reference `HEAD` points to.
    ///
    /// - `self`: the repository.
    /// - Returns: the reference; `error.UnbornBranch` before the first commit.
    pub fn head(self: *const Self) mod.GitErrorSet!mod.Reference {
        var ref: ?*mod.c.git_reference = null;
        try mod.GitError.check(mod.c.git_repository_head(&ref, self.handle));
        return try mod.Reference.init(ref.?);
    }

    /// Returns the working directory.
    ///
    /// - `self`: the repository.
    /// - Returns: the path, with a trailing `/`, or null for a bare repository.
    pub fn workdir(self: *const Self) ?[]const u8 {
        const path = mod.c.git_repository_workdir(self.handle);
        if (path == null) return null;
        return std.mem.span(path);
    }

    /// Returns the `.git` directory, or the repository itself when bare.
    ///
    /// - `self`: the repository.
    /// - Returns: the path, with a trailing `/`.
    pub fn gitDir(self: *const Self) []const u8 {
        return std.mem.span(mod.c.git_repository_path(self.handle));
    }

    /// Returns whether the repository has no working directory.
    ///
    /// - `self`: the repository.
    /// - Returns: true when bare.
    pub fn isBare(self: *const Self) bool {
        return mod.c.git_repository_is_bare(self.handle) != 0;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Repository);
}

test "repository is created and reopened" {
    const allocator = std.testing.allocator;
    var fixture = try mod.TestRepo.init(allocator, std.testing.io);
    defer fixture.deinit();

    try std.testing.expect(!fixture.repo.isBare());
    try std.testing.expect(std.mem.endsWith(u8, fixture.repo.gitDir(), ".git/"));
    try std.testing.expectError(error.UnbornBranch, fixture.repo.head());

    var reopened = try Repository.open(allocator, fixture.path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings(fixture.repo.workdir().?, reopened.workdir().?);
}

test "repository open fails outside a repository" {
    const allocator = std.testing.allocator;
    var lib = try mod.Libgit2.init(allocator, std.testing.io);
    defer lib.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    try std.testing.expectError(error.NotFound, Repository.open(allocator, path));
}

test "repository clones a local repository" {
    const allocator = std.testing.allocator;
    var fixture = try mod.TestRepo.init(allocator, std.testing.io);
    defer fixture.deinit();
    const first = try fixture.commitFile("README", "hello\n", "Initial commit");

    const target = try std.fs.path.join(allocator, &.{ fixture.path, "..", "clone" });
    defer allocator.free(target);

    var cloned = try Repository.clone(allocator, fixture.path, target, null);
    defer cloned.deinit();

    var ref = try cloned.head();
    defer ref.deinit();
    try std.testing.expect(ref.target().?.eql(&first));
}
