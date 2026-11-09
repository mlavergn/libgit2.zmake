const std = @import("std");
const builtin = @import("builtin");

const zon = @import("build.zig.zon");
const zigbuildx = @import("zigbuildx");
const upstream = @import("build/module.zig");

/// The project's build settings, derived from `build.zig.zon` and the
/// standard options.
const Config = struct {
    const Self = @This();

    /// The package name; also the library's.
    name: []const u8,
    /// The name the library module is imported by.
    mod_name: []const u8,
    /// The CLI executable's name: `git2`, as upstream names it.
    cli_name: []const u8,
    /// The target every artifact builds for.
    target: std.Build.ResolvedTarget,
    /// The optimization mode.
    optimize: std.lang.Optimize,
    /// The library module's root, `src/module.zig`.
    module_source_file: std.Build.LazyPath,
    /// The CLI's entry point, `cli/main.zig`.
    cli_source_file: std.Build.LazyPath,
    /// The package version, which tracks the libgit2 pin.
    version: std.SemanticVersion,
};

/// Declares the build graph for the ziglibgit2 library, the `git2` CLI, tests,
/// and docs.
///
/// Serves as the entry point the Zig build runner invokes to wire up every
/// build step consumers rely on — `lib`, `cli`, `run`, `test`, `clar` and
/// `docs` — plus the standard target, optimize, and test-filter options. The
/// upstream C libraries (libgit2, libssh2, mbedTLS) are described in `build/`
/// and reach every artifact through the library module's imports, so the one
/// static archive carries all of them. On macOS it adds the resolved SDK
/// framework path so linking succeeds. Called once per build invocation.
///
/// - `b`: the build graph the steps and options are registered on.
/// - Returns: nothing on success; propagates errors from option parsing,
///   version parsing, the upstream source globs, and macOS SDK resolution.
pub fn build(b: *std.Build) !void {
    // Pre-flight: ensure any local dependencies are cloned
    zigbuildx.Deps.cloneMissing(b, zon);

    // Build config
    const cfg = Config{
        .name = @tagName(zon.name),
        .mod_name = @tagName(zon.name),
        .cli_name = "git2",
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .module_source_file = b.path("src/module.zig"),
        .cli_source_file = b.path("cli/main.zig"),
        .version = try std.SemanticVersion.parse(zon.version),
    };

    // Build options
    const options = b.addOptions();

    // const app_bundle_id = b.option([]const u8, "appBundleId", "Set the appBundleId to use for sandbox contexts") orelse "com.example";
    // options.addOption([]const u8, "appBundleId", app_bundle_id);
    // cfg.app_bundle_id = app_bundle_id;

    const test_filter = b.option([]const u8, "test-filter", "Run unit tests that match filter") orelse "";
    options.addOption([]const u8, "test_filter", test_filter);
    options.addOption([]const u8, "version", zon.version);

    // -------------------------------------------------------------------------
    // Upstream C

    const c_cfg = try upstream.Config.init(b, cfg.target, cfg.optimize);
    const libgit2 = try upstream.LibGit2.init(&c_cfg);
    const libgit2_c = libgit2.module;

    // `@cImport` is gone in 0.17: the public headers are translated here and
    // imported as `c`.
    const c_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = cfg.target,
        .optimize = cfg.optimize,
    });
    c_headers.addIncludePath(libgit2.includePath());
    const c_module = c_headers.createModule();

    // -------------------------------------------------------------------------
    // Module

    const module = b.addModule(cfg.name, .{
        .root_source_file = cfg.module_source_file,
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = true,
    });
    module.addOptions("config", options);
    module.addImport("c", c_module);
    module.addImport("libgit2_c", libgit2_c);

    // -------------------------------------------------------------------------
    // Lib

    const lib = b.addLibrary(.{ .name = cfg.name, .root_module = module, .linkage = .static });

    if (builtin.os.tag == .macos) {
        var xcode = try zigbuildx.Xcode.init(b);
        try xcode.resolve();
        xcode.addFrameworkPath(lib.root_module);
    }

    const lib_install = b.addInstallArtifact(lib, .{});
    const lib_step = b.step("lib", "Build static library");
    lib_step.dependOn(&lib_install.step);

    // -------------------------------------------------------------------------
    // CLI: libgit2's own `git2`, entered through `cli/main.zig`

    const cli_module = b.createModule(.{
        .root_source_file = cfg.cli_source_file,
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = true,
    });
    // The library module brings the C objects with it; linking `lib` as well
    // would define every symbol twice.
    cli_module.addImport(cfg.mod_name, module);
    try upstream.Git2Cli.addSources(&c_cfg, &libgit2, cli_module);

    // `src/cli/CMakeLists.txt:43`: named after the library, `git2`.
    const cli = b.addExecutable(.{ .name = cfg.cli_name, .root_module = cli_module });
    b.installArtifact(cli);

    const cli_install = b.addInstallArtifact(cli, .{});
    const cli_step = b.step("cli", "Build the CLI (libgit2's git2)");
    cli_step.dependOn(&cli_install.step);

    // -------------------------------------------------------------------------
    // Run

    const cli_run = b.addRunArtifact(cli);

    // Run step depends on the install step to run from the installation directory
    cli_run.step.dependOn(b.getInstallStep());

    // Support arguments like: `zig build run -- argA argB`
    cli_run.addPassthruArgs();

    const run_step = b.step("run", "Run the CLI (git2)");
    run_step.dependOn(&cli_run.step);

    // -------------------------------------------------------------------------
    // Tests

    const test_filters: []const []const u8 = if (test_filter.len > 0) &.{test_filter} else &.{};

    // A module of its own, so `src/abi_probe.c` stays out of the library.
    // The probe checks `tls_stream.zig`'s hand-written `git_stream` layout
    // against the C compiler's.
    const test_module = b.createModule(.{
        .root_source_file = cfg.module_source_file,
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = true,
    });
    test_module.addOptions("config", options);
    test_module.addImport("c", c_module);
    test_module.addImport("libgit2_c", libgit2_c);
    test_module.addCSourceFile(.{ .file = b.path("src/abi_probe.c") });
    test_module.addIncludePath(libgit2.includePath());

    const tests = b.addTest(.{
        .root_module = test_module,
        .filters = test_filters,
    });

    const tests_run = b.addRunArtifact(tests);
    // force tests to run on every test run
    tests_run.has_side_effects = true;

    const tests_step = b.step("test", "Run unit tests");
    tests_step.dependOn(&tests_run.step);

    // The host tools in `zig/` are built for the build machine; so are their
    // tests.
    const tools_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/module.zig"),
            .target = b.graph.host,
            .optimize = cfg.optimize,
        }),
        .filters = test_filters,
    });
    const tools_tests_run = b.addRunArtifact(tools_tests);
    tools_tests_run.has_side_effects = true;
    tests_step.dependOn(&tools_tests_run.step);

    // -------------------------------------------------------------------------
    // clar

    // libgit2's own suites, minus what `tests/libgit2/CMakeLists.txt:37`
    // leaves out, run as its `offline` and `util` tests are.
    const clar = try upstream.Clar.init(&c_cfg, &libgit2);
    const clar_libgit2 = try clar.addSuite("libgit2", &.{ "online", "stress", "perf" }, &.{ "-v", "-xonline" });
    const clar_util = try clar.addSuite("util", &.{}, &.{"-v"});

    const clar_step = b.step("clar", "Run libgit2's clar test suites");
    clar_step.dependOn(&clar_util.step);
    clar_step.dependOn(&clar_libgit2.step);

    // -------------------------------------------------------------------------
    // Docs

    // Autodoc roots a module at `root.zig`, or failing that at the file whose
    // basename matches the artifact name; with `src/module.zig` it can do
    // neither, and the site roots itself at an arbitrary import instead.
    // ZIGSTYLE requires the barrel to be `module.zig`, so docs build from a
    // sibling `root.zig`. It is the same module — the other sources come along.
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
    });
    docs_mod.addOptions("config", options);
    docs_mod.addImport("c", c_module);
    // No `libgit2_c`: autodoc needs the Zig sources, not the C objects.

    const docs_lib = b.addLibrary(.{
        .name = cfg.name,
        .root_module = docs_mod,
        .linkage = .static,
    });

    if (builtin.os.tag == .macos) {
        var docs_xcode = try zigbuildx.Xcode.init(b);
        try docs_xcode.resolve();
        docs_xcode.addFrameworkPath(docs_lib.root_module);
    }

    const docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);
}
