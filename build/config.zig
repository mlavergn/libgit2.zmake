const std = @import("std");
const log = std.log.scoped(.libgit2_build_config);

/// Configuration shared by the upstream C builds.
///
/// Holds the build graph and the resolved target, and reads the pinned
/// packages. Every path into an upstream package goes through `dependency`
/// and `appendGlob`, so the sources stay where `zig fetch` unpacked them and
/// are never copied or modified.
pub const Config = struct {
    const Self = @This();

    /// The build graph every step is registered on.
    b: *std.Build,

    /// The target the C sources compile for.
    target: std.Build.ResolvedTarget,

    /// The optimization mode the C sources compile with.
    optimize: std.lang.Optimize,

    /// Whether the build description traces itself (`-Dverbose-build`).
    ///
    /// Off by default: the build script re-runs whenever the configured graph
    /// goes stale, in this repository and in every package depending on it,
    /// and the entry traces ZIGSTYLE asks for would print each time.
    verbose: bool,

    /// Bundles the build graph with the resolved target and optimize mode.
    ///
    /// - `b`: the build graph.
    /// - `target`: the target the C sources compile for.
    /// - `optimize`: the optimization mode.
    /// - Returns: the configuration; the error union is reserved for the
    ///   lifecycle convention and yields no error today.
    pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) !Self {
        const verbose = b.option(bool, "verbose-build", "Trace the C build description") orelse false;
        if (verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return Self{ .b = b, .target = target, .optimize = optimize, .verbose = verbose };
    }

    /// Returns the target's operating system.
    ///
    /// - `self`: the configuration.
    /// - Returns: the OS tag of the resolved target.
    pub fn os(self: *const Self) std.Target.Os.Tag {
        return self.target.result.os.tag;
    }

    /// Returns whether the target is Windows.
    ///
    /// - `self`: the configuration.
    /// - Returns: true for any Windows target.
    pub fn isWindows(self: *const Self) bool {
        return self.os() == .windows;
    }

    /// Returns whether the target is a Darwin platform.
    ///
    /// - `self`: the configuration.
    /// - Returns: true for macOS and the other Apple platforms.
    pub fn isDarwin(self: *const Self) bool {
        return self.target.result.os.tag.isDarwin();
    }

    /// Returns whether the build is a debug build.
    ///
    /// - `self`: the configuration.
    /// - Returns: true when optimizing for debug.
    pub fn isDebug(self: *const Self) bool {
        return self.optimize == .debug;
    }

    /// Resolves a pinned package from `build.zig.zon`.
    ///
    /// - `self`: the configuration.
    /// - `name`: the dependency's name in `build.zig.zon`.
    /// - Returns: the dependency, whose `path` gives lazy paths into it.
    pub fn dependency(self: *const Self, name: []const u8) *std.Build.Dependency {
        return self.b.dependency(name, .{});
    }

    /// Creates a module for C sources, with libc, for this target.
    ///
    /// The C sanitizers are off. Zig enables them in Debug, where CMake never
    /// does, and the upstream sources are not written against them: clar's
    /// own `tests/clar/clar/sandbox.h:194` left-shifts a `pid_t` past its
    /// range before the first test runs.
    ///
    /// - `self`: the configuration.
    /// - Returns: an empty module to add C sources and include paths to.
    pub fn createCModule(self: *const Self) *std.Build.Module {
        return self.b.createModule(.{
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = true,
            .sanitize_c = .off,
        });
    }

    /// Appends every file in `dir` whose name ends in `ext`, as CMake's
    /// `file(GLOB)` does, sorted as CMake's `list(SORT)` leaves them.
    ///
    /// A directory listing is not a build input by default, and Zig 0.17
    /// reuses a configured graph until an input changes, so the directory is
    /// declared as one: an edit to the unpacked copy under `zig-pkg/` must
    /// reconfigure.
    ///
    /// - `self`: the configuration.
    /// - `dep`: the package to read.
    /// - `files`: the list to append package-relative paths to.
    /// - `dir`: the directory to read, relative to the package root.
    /// - `ext`: the suffix to match, including the dot.
    /// - Returns: nothing; propagates directory-read and allocation failures.
    pub fn appendGlob(self: *const Self, dep: *std.Build.Dependency, files: *std.ArrayList([]const u8), dir: []const u8, ext: []const u8) !void {
        const b = self.b;
        b.dependOnDirectoryContents(dep.path(dir));

        var handle = try dep.builder.root.openDir(b.graph.io, dir, .{ .iterate = true });
        defer handle.close(b.graph.io);

        const start = files.items.len;
        var it = handle.iterate();
        while (try it.next(b.graph.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ext)) continue;
            try files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name }));
        }

        std.mem.sort([]const u8, files.items[start..], {}, lessThan);
    }

    /// Appends every file under `dir`, at any depth from `min_depth` down,
    /// whose name ends in `ext`, as CMake's `file(GLOB_RECURSE)` does, sorted.
    ///
    /// - `self`: the configuration.
    /// - `dep`: the package to read.
    /// - `files`: the list to append package-relative paths to.
    /// - `dir`: the directory to walk, relative to the package root.
    /// - `ext`: the suffix to match, including the dot.
    /// - `min_depth`: 1 to include files directly in `dir`; 2 for
    ///   `<dir>/*/*.c`, which matches only inside subdirectories.
    /// - Returns: nothing; propagates directory-read and allocation failures.
    pub fn appendGlobRecursive(self: *const Self, dep: *std.Build.Dependency, files: *std.ArrayList([]const u8), dir: []const u8, ext: []const u8, min_depth: usize) !void {
        const b = self.b;
        b.dependOnDirectoryContents(dep.path(dir));

        var handle = try dep.builder.root.openDir(b.graph.io, dir, .{ .iterate = true });
        defer handle.close(b.graph.io);

        const start = files.items.len;
        var walker = try handle.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next(b.graph.io)) |entry| {
            if (entry.kind != .file) continue;
            if (entry.depth() < min_depth) continue;
            if (!std.mem.endsWith(u8, entry.basename, ext)) continue;
            // Package paths use `/` on every host.
            const rel = try std.mem.replaceOwned(u8, b.allocator, entry.path, std.Io.Dir.path.sep_str, "/");
            try files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, rel }));
        }

        std.mem.sort([]const u8, files.items[start..], {}, lessThan);
    }

    /// Returns an absolute path under the project's `.zig-cache`.
    ///
    /// Zig 0.17 exposes the cache only as a lazy path, which C code cannot
    /// have baked in at compile time. This is a fixed location under the build
    /// root instead, for the one artifact that needs it: clar's fixtures.
    ///
    /// - `self`: the configuration.
    /// - `sub_path`: the path under `.zig-cache`.
    /// - Returns: the absolute path; propagates resolution and allocation
    ///   failures.
    pub fn projectCachePath(self: *const Self, sub_path: []const u8) ![]const u8 {
        const b = self.b;
        const root = try b.root.joinString(b.allocator, ".");
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root, b.allocator);
        return std.Io.Dir.path.join(b.allocator, &.{ absolute, ".zig-cache", sub_path });
    }

    fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.order(u8, lhs, rhs) == .lt;
    }
};
