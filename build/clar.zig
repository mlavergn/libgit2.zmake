const std = @import("std");
const log = std.log.scoped(.libgit2_build_clar);
const mod = @import("module.zig");

/// libgit2's own clar test suites, built against the Zig-built library.
///
/// Mirrors `tests/libgit2/CMakeLists.txt` and `tests/util/CMakeLists.txt`.
/// The suite tables those files have `generate.py` write come from
/// `zig/clar_generate.zig` instead, a port that produces byte-identical
/// output, so no Python is needed. Passing these suites is this project's
/// test of success.
pub const Clar = struct {
    const Self = @This();

    /// The shared build configuration.
    cfg: *const mod.Config,
    /// The libgit2 build the suites link.
    libgit2: *const mod.LibGit2,
    /// The suite generator, built for the host.
    generator: *std.Build.Step.Compile,
    /// The step that restores the fixtures `fixtures_path` names.
    fixtures: *std.Build.Step.Run,
    /// The absolute path of the restored fixtures (`CLAR_FIXTURE_PATH`).
    fixtures_path: []const u8,

    /// The fixtures the upstream tarball marks executable but `zig fetch`
    /// unpacks without the bit, since it keeps the bit only on `#!` files.
    /// Found by diffing `find -perm +111` over the tarball extracted with
    /// `tar` and over `zig-pkg/`. Without them,
    /// `status::worktree::filemode_changes` and `filemode_non755` fail.
    const executable_fixtures = [_][]const u8{
        "diff_format_email/file1.txt.renamed",
        "filemodes/exec_off2on_staged",
        "filemodes/exec_off2on_workdir",
        "filemodes/exec_on",
        "filemodes/exec_on_untracked",
        "redundant.git/config",
        "submod3/.gitted/modules/EIGHT/config",
        "submod3/.gitted/modules/Five/config",
        "submod3/.gitted/modules/FoUr/config",
        "submod3/.gitted/modules/nine/config",
        "submod3/.gitted/modules/One/config",
        "submod3/.gitted/modules/sEvEn/config",
        "submod3/.gitted/modules/six/config",
        "submod3/.gitted/modules/TEN/config",
        "submod3/.gitted/modules/three/config",
        "submod3/.gitted/modules/TWO/config",
    };

    /// The defines `tests/{libgit2,util}/CMakeLists.txt:18-25` add, apart
    /// from `CLAR_FIXTURE_PATH`, which needs the package's absolute path.
    const test_defines = [_][]const u8{
        "-DCLAR_TMPDIR=\"libgit2_tests\"",
        "-DCLAR_WIN32_LONGPATHS",
        "-DCLAR_HAS_REALPATH",
        "-D_FILE_OFFSET_BITS=64",
        "-DGIT_DEPRECATE_HARD",
    };

    /// Builds the host tools and the step that restores the fixtures.
    ///
    /// - `cfg`: the shared build configuration; must outlive the value.
    /// - `libgit2`: the libgit2 build; must outlive the value.
    /// - Returns: the clar builder; propagates path and allocation failures.
    pub fn init(cfg: *const mod.Config, libgit2: *const mod.LibGit2) !Self {
        if (cfg.verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const b = cfg.b;
        const generator = hostTool(b, "clar_generate");

        // Keyed by package hash, so a new pin gets a fresh copy.
        const fixtures_path = try cfg.projectCachePath(b.fmt("libgit2-clar-fixtures/{s}", .{libgit2.dep.builder.pkg_hash}));
        const fixtures = b.addRunArtifact(hostTool(b, "clar_fixtures"));
        fixtures.addDirectoryArg2(libgit2.dep.path("tests/resources"), .{});
        fixtures.addArg(fixtures_path);
        fixtures.addArgs(&executable_fixtures);
        // The output is outside the cache Zig manages; the tool's own stamp
        // makes a repeat run cheap.
        fixtures.has_side_effects = true;

        return Self{
            .cfg = cfg,
            .libgit2 = libgit2,
            .generator = generator,
            .fixtures = fixtures,
            .fixtures_path = fixtures_path,
        };
    }

    /// Builds one suite's test runner and the step that runs it.
    ///
    /// - `self`: the clar builder.
    /// - `name`: `libgit2` or `util`, the directory under `tests/`.
    /// - `excluded`: `-x` prefixes for the generator, e.g. `online`.
    /// - `args`: the arguments `add_clar_test` runs the suite with.
    /// - Returns: the run step; propagates glob, path and allocation failures.
    pub fn addSuite(self: *const Self, name: []const u8, excluded: []const []const u8, args: []const []const u8) !*std.Build.Step.Run {
        if (self.cfg.verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const cfg = self.cfg;
        const b = cfg.b;
        const dep = self.libgit2.dep;
        const test_dir = b.fmt("tests/{s}", .{name});

        // `add_custom_command(... generate.py -o <bin> -f ...)`.
        const generate = b.addRunArtifact(self.generator);
        generate.addArg("-o");
        const suite_dir = generate.addOutputDirectoryArg2("clar", .{});
        generate.addArg("-f");
        for (excluded) |prefix| generate.addArg(b.fmt("-x{s}", .{prefix}));
        generate.addDirectoryArg2(dep.path(test_dir), .{});

        const root = cfg.createCModule();
        // `TEST_INCLUDES`, then `LIBGIT2_INCLUDES` and the dependency includes.
        root.addIncludePath(dep.path("tests/clar"));
        root.addIncludePath(dep.path(test_dir));
        root.addIncludePath(suite_dir);
        self.libgit2.addIncludes(root, true);

        // `file(GLOB_RECURSE SRC_CLAR ${CLAR_PATH}/*.c)`. `tests/libgit2`
        // globs `*/*.c`, skipping its top-level MSVC `precompiled.c`;
        // `tests/util` globs `*.c` as well.
        var files: std.ArrayList([]const u8) = .empty;
        try cfg.appendGlobRecursive(dep, &files, "tests/clar", ".c", 1);
        const min_depth: usize = if (std.mem.eql(u8, name, "libgit2")) 2 else 1;
        try cfg.appendGlobRecursive(dep, &files, test_dir, ".c", min_depth);

        const fixture_define = b.fmt("-DCLAR_FIXTURE_PATH=\"{s}/\"", .{self.fixtures_path});

        root.addCSourceFiles(.{
            .root = dep.path(""),
            .files = files.items,
            .flags = try std.mem.concat(b.allocator, []const u8, &.{
                self.libgit2.common_flags,
                &test_defines,
                &.{fixture_define},
            }),
        });

        // `${LIBGIT2_OBJECTS}`: the whole library, internals included.
        root.addImport("libgit2_c", self.libgit2.module);

        const exe = b.addExecutable(.{
            .name = b.fmt("{s}_tests", .{name}),
            .root_module = root,
        });

        const run = b.addRunArtifact(exe);
        run.addArgs(args);
        run.has_side_effects = true;
        run.step.dependOn(&self.fixtures.step);
        return run;
    }

    /// Builds one of the `zig/` tools for the host.
    ///
    /// - `b`: the build graph.
    /// - `name`: the tool's file stem under `zig/`.
    /// - Returns: the executable.
    fn hostTool(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
        return b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("zig/{s}.zig", .{name})),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
    }
};
