//! Restores clar's test fixtures with the file modes upstream ships them with.
//!
//! `zig fetch` keeps a file's executable bit only when the file starts with
//! `#!`, so the unpacked libgit2 package loses it on fixtures such as
//! `filemodes/exec_on`, and the tests that compare file modes then fail. This
//! copies `tests/resources` to a directory of its own, symlinks included, and
//! sets the executable bit back on the files named on the command line. The
//! package itself is never modified.
//!
//! Usage: `clar_fixtures <source dir> <dest dir> [<relative path>]...`
//!
//! A `.complete` stamp in `<dest dir>` makes later runs a no-op; the build
//! keys the destination by package hash, so a new pin gets a fresh copy.

const std = @import("std");
const log = std.log.scoped(.ziglibgit2_clar_fixtures);
const builtin = @import("builtin");

/// Copies a fixture tree and restores its executable bits.
pub const ClarFixtures = struct {
    const Self = @This();

    /// The name of the stamp written once a copy is complete.
    pub const stamp_name = ".complete";

    /// `rwxr-xr-x`, the mode the upstream tarball gives these files. Windows
    /// has no executable bit, so there it is the platform's default.
    pub const executable: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        std.Io.File.Permissions.executable_file
    else
        std.Io.File.Permissions.fromMode(0o755);

    /// The allocator for paths and the directory walk.
    allocator: std.mem.Allocator,
    /// The I/O implementation used for every file operation.
    io: std.Io,

    /// Creates the copier.
    ///
    /// - `allocator`: allocator for paths and the directory walk.
    /// - `io`: the I/O implementation used for every file operation.
    /// - Returns: the copier.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        return Self{ .allocator = allocator, .io = io };
    }

    /// Releases the copier.
    ///
    /// - `self`: the copier.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Copies `src_path` to `dest_path` unless a complete copy is there, then
    /// marks each of `executables` executable.
    ///
    /// - `self`: the copier.
    /// - `src_path`: the fixture directory to copy.
    /// - `dest_path`: where the copy goes; replaced if incomplete.
    /// - `executables`: paths relative to `src_path` to mark executable.
    /// - Returns: nothing; propagates file-system failures.
    pub fn restore(self: *Self, src_path: []const u8, dest_path: []const u8, executables: []const []const u8) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const cwd = std.Io.Dir.cwd();

        if (cwd.openDir(self.io, dest_path, .{})) |existing| {
            var dest = existing;
            defer dest.close(self.io);
            if (dest.access(self.io, stamp_name, .{})) |_| return else |_| {}
        } else |_| {}

        // An interrupted copy is discarded rather than patched up.
        try cwd.deleteTree(self.io, dest_path);
        try cwd.createDirPath(self.io, dest_path);

        var src = try cwd.openDir(self.io, src_path, .{ .iterate = true });
        defer src.close(self.io);
        var dest = try cwd.openDir(self.io, dest_path, .{});
        defer dest.close(self.io);

        try self.copyTree(src, dest);

        for (executables) |path| {
            try dest.setFilePermissions(self.io, path, executable, .{});
        }

        try dest.writeFile(self.io, .{ .sub_path = stamp_name, .data = "" });
    }

    /// Copies every directory, file and symlink under `src` into `dest`.
    ///
    /// - `self`: the copier.
    /// - `src`: the source, opened with `.iterate = true`.
    /// - `dest`: the empty destination.
    /// - Returns: nothing; propagates file-system failures.
    fn copyTree(self: *Self, src: std.Io.Dir, dest: std.Io.Dir) !void {
        var walker = try src.walk(self.allocator);
        defer walker.deinit();

        var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
        while (try walker.next(self.io)) |entry| {
            switch (entry.kind) {
                .directory => try dest.createDirPath(self.io, entry.path),
                .file => try src.copyFile(entry.path, dest, entry.path, self.io, .{}),
                .sym_link => {
                    const len = try src.readLink(self.io, entry.path, &link_buffer);
                    try dest.symLink(self.io, link_buffer[0..len], entry.path, .{});
                },
                else => log.warn("skipping {s}: unsupported file kind", .{entry.path}),
            }
        }
    }
};

/// Entry point: copies the fixtures named on the command line.
///
/// - `init`: process capabilities supplied by the runtime (allocator, IO, args).
/// - Returns: nothing on success; propagates usage and file-system failures.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;

    var fixtures = try ClarFixtures.init(init.gpa, init.io);
    defer fixtures.deinit();

    try fixtures.restore(args[1], args[2], args[3..]);
}

// -----------------------------------------------------------------------------
// Unit Tests

test "fixtures are copied once, with their executable bits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/exec_on", .data = "Hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/plain", .data = "x" });
    try tmp.dir.symLink(io, "plain", "src/link", .{});

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const src = try std.fs.path.join(allocator, &.{ root, "src" });
    defer allocator.free(src);
    const dest = try std.fs.path.join(allocator, &.{ root, "dest" });
    defer allocator.free(dest);

    var fixtures = try ClarFixtures.init(allocator, io);
    defer fixtures.deinit();
    try fixtures.restore(src, dest, &.{"sub/exec_on"});

    if (builtin.os.tag != .windows) {
        const stat = try tmp.dir.statFile(io, "dest/sub/exec_on", .{});
        try std.testing.expectEqual(0o755, stat.permissions.toMode() & 0o777);
    }

    var link_buffer: [64]u8 = undefined;
    const len = try tmp.dir.readLink(io, "dest/link", &link_buffer);
    try std.testing.expectEqualStrings("plain", link_buffer[0..len]);

    // A second run sees the stamp and leaves the copy alone.
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/plain", .data = "changed" });
    try fixtures.restore(src, dest, &.{"sub/exec_on"});
    const plain = try tmp.dir.readFileAlloc(io, "dest/plain", allocator, .unlimited);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("changed", plain);
}
