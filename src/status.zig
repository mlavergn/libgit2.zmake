const std = @import("std");
const log = std.log.scoped(.ziglibgit2_status);
const mod = @import("module.zig");

/// One changed path in a `Status` list.
pub const StatusEntry = struct {
    const Self = @This();

    /// The path, relative to the working directory; borrowed from the list.
    path: []const u8,
    /// The `git_status_t` flags.
    flags: c_uint,

    /// Returns the two-letter code `git status --short` prints.
    ///
    /// The first letter is the index's change against `HEAD`, the second the
    /// working directory's against the index: `M` modified, `A` added, `D`
    /// deleted, `R` renamed, `T` type changed, `?` untracked, `!` ignored,
    /// `U` conflicted, space for unchanged.
    ///
    /// - `self`: the entry.
    /// - Returns: the code.
    pub fn code(self: *const Self) [2]u8 {
        const f = self.flags;
        if (f & flag(mod.c.GIT_STATUS_CONFLICTED) != 0) return "UU".*;
        if (f & flag(mod.c.GIT_STATUS_IGNORED) != 0) return "!!".*;
        if (f & flag(mod.c.GIT_STATUS_WT_NEW) != 0) return "??".*;

        var out = "  ".*;
        if (f & flag(mod.c.GIT_STATUS_INDEX_NEW) != 0) out[0] = 'A';
        if (f & flag(mod.c.GIT_STATUS_INDEX_MODIFIED) != 0) out[0] = 'M';
        if (f & flag(mod.c.GIT_STATUS_INDEX_DELETED) != 0) out[0] = 'D';
        if (f & flag(mod.c.GIT_STATUS_INDEX_RENAMED) != 0) out[0] = 'R';
        if (f & flag(mod.c.GIT_STATUS_INDEX_TYPECHANGE) != 0) out[0] = 'T';
        if (f & flag(mod.c.GIT_STATUS_WT_MODIFIED) != 0) out[1] = 'M';
        if (f & flag(mod.c.GIT_STATUS_WT_DELETED) != 0) out[1] = 'D';
        if (f & flag(mod.c.GIT_STATUS_WT_RENAMED) != 0) out[1] = 'R';
        if (f & flag(mod.c.GIT_STATUS_WT_TYPECHANGE) != 0) out[1] = 'T';
        return out;
    }

    fn flag(value: c_int) c_uint {
        return @intCast(value);
    }
};

/// The changed paths of a working directory, as `git status` lists them.
///
/// Owns its `git_status_list`; entries borrow their paths from it.
pub const Status = struct {
    const Self = @This();

    /// The libgit2 status list, owned.
    handle: *mod.c.git_status_list,

    /// Computes the status of `repo`'s index and working directory.
    ///
    /// - `repo`: a repository with a working directory.
    /// - `include_untracked`: true to list untracked files, recursing into
    ///   untracked directories.
    /// - Returns: the list; `error.BareRepo` for a bare repository.
    pub fn init(repo: *const mod.Repository, include_untracked: bool) mod.GitErrorSet!Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        var options: mod.c.git_status_options = .{};
        try mod.GitError.check(mod.c.git_status_options_init(&options, mod.c.GIT_STATUS_OPTIONS_VERSION));
        options.show = @intCast(mod.c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR);
        var flags: c_int = mod.c.GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX;
        if (include_untracked) flags |= mod.c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | mod.c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
        options.flags = @intCast(flags);

        var handle: ?*mod.c.git_status_list = null;
        try mod.GitError.check(mod.c.git_status_list_new(&handle, repo.handle, &options));
        return Self{ .handle = handle.? };
    }

    /// Releases the list.
    ///
    /// - `self`: the list.
    pub fn deinit(self: *Self) void {
        mod.c.git_status_list_free(self.handle);
    }

    /// Returns the number of changed paths.
    ///
    /// - `self`: the list.
    /// - Returns: the count.
    pub fn count(self: *const Self) usize {
        return mod.c.git_status_list_entrycount(self.handle);
    }

    /// Returns one changed path.
    ///
    /// - `self`: the list.
    /// - `index`: the position in the list.
    /// - Returns: the entry, or null when `index` is not below `count()`.
    pub fn entry(self: *const Self, index: usize) ?StatusEntry {
        // libgit2 returns NULL past the end.
        const raw = mod.c.git_status_byindex(self.handle, index);
        if (raw == null) return null;
        // The working directory's delta names untracked and modified files;
        // the index's names staged ones.
        const delta = if (raw.*.index_to_workdir != null) raw.*.index_to_workdir else raw.*.head_to_index;
        const path = if (delta.*.new_file.path != null) delta.*.new_file.path else delta.*.old_file.path;
        return StatusEntry{ .path = std.mem.span(path), .flags = raw.*.status };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Status);
}

test "status lists untracked and modified files" {
    var fixture = try mod.TestRepo.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    _ = try fixture.commitFile("README", "hello\n", "Initial commit");

    try fixture.writeFile("README", "changed\n");
    try fixture.writeFile("notes/todo.txt", "new\n");

    var status = try Status.init(&fixture.repo, true);
    defer status.deinit();

    // The order follows `core.ignorecase`, so it differs between file systems.
    try std.testing.expectEqual(2, status.count());
    var seen: usize = 0;
    for (0..status.count()) |i| {
        const entry = status.entry(i).?;
        if (std.mem.eql(u8, entry.path, "README")) {
            try std.testing.expectEqualStrings(" M", &entry.code());
            seen += 1;
        } else if (std.mem.eql(u8, entry.path, "notes/todo.txt")) {
            try std.testing.expectEqualStrings("??", &entry.code());
            seen += 1;
        }
    }
    try std.testing.expectEqual(2, seen);
}

test "status of a clean working directory is empty" {
    var fixture = try mod.TestRepo.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    _ = try fixture.commitFile("README", "hello\n", "Initial commit");

    var status = try Status.init(&fixture.repo, true);
    defer status.deinit();
    try std.testing.expectEqual(0, status.count());
    try std.testing.expectEqual(null, status.entry(0));
}
