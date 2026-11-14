const std = @import("std");
const log = std.log.scoped(.libgit2_build_git2_cli);
const mod = @import("module.zig");

/// `git2`, libgit2's own command-line client, built from the pinned sources.
///
/// Mirrors `src/cli/CMakeLists.txt`. The executable's entry point is Zig
/// (`cli/main.zig`): upstream's `main` calls `git_libgit2_init` and
/// knows nothing of the Zig TLS stream, so the Zig `main` initializes libgit2
/// and registers the stream first, then calls upstream's `main`, which
/// `main.c` is compiled to name `ziglibgit2_git2_main`. No source changes.
pub const Git2Cli = struct {
    const Self = @This();

    /// What upstream's `main` is compiled as (`-Dmain=`).
    pub const entry_symbol = "ziglibgit2_git2_main";

    /// Adds upstream's CLI sources to the executable's module.
    ///
    /// - `cfg`: the shared build configuration.
    /// - `libgit2`: the libgit2 build, for its include paths and flags.
    /// - `root`: the executable's root module; must import the library
    ///   module, which brings libgit2's objects.
    /// - Returns: nothing; propagates glob and allocation failures.
    pub fn addSources(cfg: *const mod.Config, libgit2: *const mod.LibGit2, root: *std.Build.Module) !void {
        if (cfg.verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const b = cfg.b;
        const dep = libgit2.dep;

        // `src/cli/CMakeLists.txt:1-7`: `CLI_INCLUDES`, `src/cli` right
        // after `src/util`, then the rest of util's paths.
        root.addIncludePath(dep.path("src/util"));
        root.addIncludePath(dep.path("src/cli"));
        libgit2.addIncludes(root, false);

        // `src/cli/CMakeLists.txt:9-18`, `main.c` apart for its rename.
        var files: std.ArrayList([]const u8) = .empty;
        try cfg.appendGlob(dep, &files, "src/cli", ".c");
        try cfg.appendGlob(dep, &files, if (cfg.isWindows()) "src/cli/win32" else "src/cli/unix", ".c");

        var others: std.ArrayList([]const u8) = .empty;
        for (files.items) |file| {
            if (!std.mem.eql(u8, file, "src/cli/main.c")) try others.append(b.allocator, file);
        }

        // `src/cli` is under `src/`, so it gets the pcre2 defines too.
        root.addCSourceFiles(.{ .root = dep.path(""), .files = others.items, .flags = libgit2.src_flags });
        root.addCSourceFiles(.{
            .root = dep.path(""),
            .files = &.{"src/cli/main.c"},
            .flags = try std.mem.concat(b.allocator, []const u8, &.{
                libgit2.src_flags,
                &.{"-Dmain=" ++ entry_symbol},
            }),
        });
    }
};
