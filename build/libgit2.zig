const std = @import("std");
const log = std.log.scoped(.libgit2_build_libgit2);
const mod = @import("module.zig");

/// libgit2 1.9, built from its pinned release tarball with no CMake.
///
/// Mirrors the object libraries CMake assembles into `libgit2package`: the
/// bundled `deps/` (zlib, pcre2, llhttp, xdiff), `src/util` and
/// `src/libgit2`. Each becomes its own module, because each gets its own
/// include paths and defines under CMake: pcre2's generated `config.h`, for
/// one, would otherwise be shadowed by `src/libgit2/config.h`.
///
/// Backends, against CMake's defaults:
/// - HTTPS: none in C. `GIT_HTTPS` stays undefined; Zig registers a TLS
///   stream at runtime (`src/tls_stream.zig`), which `streams/tls.c:28`
///   consults before any built-in backend.
/// - SSH: libssh2 (`mod.LibSsh2`), with in-memory credentials.
/// - zlib, regex, HTTP parser: the bundled copies on every platform. CMake
///   would prefer a system zlib, and `regcomp_l` on macOS; bundled keeps the
///   build to the Zig toolchain and the behavior identical everywhere.
/// - SHA1: collision detection. SHA256: builtin, CMake's choice with no HTTPS
///   backend (`cmake/SelectHashes.cmake:48-53`).
/// - NTLM and GSSAPI: off. NTLM borrows its crypto from the HTTPS backend.
pub const LibGit2 = struct {
    const Self = @This();

    /// The name of the package in `build.zig.zon`.
    pub const dep_name = "libgit2";

    /// `PCRE2_SOURCES`, verbatim from `deps/pcre2/CMakeLists.txt:65-95`.
    const pcre2_sources = [_][]const u8{
        "pcre2_auto_possess.c",
        "pcre2_chartables.c",
        "pcre2_chkdint.c",
        "pcre2_compile.c",
        "pcre2_compile_cgroup.c",
        "pcre2_compile_class.c",
        "pcre2_config.c",
        "pcre2_context.c",
        "pcre2_convert.c",
        "pcre2_dfa_match.c",
        "pcre2_error.c",
        "pcre2_extuni.c",
        "pcre2_find_bracket.c",
        "pcre2_maketables.c",
        "pcre2_match.c",
        "pcre2_match_data.c",
        "pcre2_match_next.c",
        "pcre2_newline.c",
        "pcre2_ord2utf.c",
        "pcre2_pattern_info.c",
        "pcre2_script_run.c",
        "pcre2_serialize.c",
        "pcre2_string_utils.c",
        "pcre2_study.c",
        "pcre2_substitute.c",
        "pcre2_substring.c",
        "pcre2_tables.c",
        "pcre2_ucd.c",
        "pcre2_valid_utf.c",
        "pcre2_xclass.c",
    };

    /// `add_definitions` from `cmake/SelectRegex.cmake:51-54`. They apply to
    /// everything `src/CMakeLists.txt` adds after `include(SelectRegex)` at
    /// line 43 — so to all of libgit2 except llhttp, added at line 42.
    const pcre2_defines = [_][]const u8{
        "-DPCRE2_STATIC",
        "-DPCRE2_EXPORT=",
        "-DPCRE2_EXP_DECL=",
        "-DPCRE2_EXP_DEFN=",
    };

    /// `deps/zlib/CMakeLists.txt:2`.
    const zlib_defines = [_][]const u8{
        "-DNO_VIZ",
        "-DSTDC",
        "-DNO_GZIP",
        "-DHAVE_SYS_TYPES_H",
        "-DHAVE_STDINT_H",
        "-DHAVE_STDDEF_H",
    };

    /// `deps/zlib/CMakeLists.txt:5`, for MinGW only.
    const zlib_mingw_defines = [_][]const u8{
        "-DZ_HAVE_UNISTD_H",
        "-D_LFS64_LARGEFILE",
        "-D_LARGEFILE64_SOURCE=1",
    };

    /// `src/util/CMakeLists.txt:33-35`.
    const sha1dc_defines = [_][]const u8{
        "-DSHA1DC_NO_STANDARD_INCLUDES=1",
        "-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\"git2_util.h\"",
        "-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\"git2_util.h\"",
    };

    /// The shared build configuration.
    cfg: *const mod.Config,
    /// The pinned libgit2 package.
    dep: *std.Build.Dependency,
    /// The generated `gen_headers/git2_features.h`.
    features: *std.Build.Step.ConfigHeader,
    /// The flags CMake sets for every C source in the tree (`commonFlags`).
    common_flags: []const []const u8,
    /// `common_flags` plus what `src/CMakeLists.txt` adds for everything
    /// under `src/`: the pcre2 defines.
    src_flags: []const []const u8,
    /// The C-only libgit2 module. It imports the deps, util, libssh2 and
    /// mbedTLS modules, so importing it into a module graph bundles all of
    /// them into that artifact.
    module: *std.Build.Module = undefined,

    /// Describes libgit2 and everything it links.
    ///
    /// - `cfg`: the shared build configuration; must outlive the value.
    /// - Returns: the description, with `module` ready to import; propagates
    ///   directory-read and allocation failures from the source globs.
    pub fn init(cfg: *const mod.Config) !Self {
        if (cfg.verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        // The platform choices below cover these; anything else would get
        // another platform's settings without a word.
        if (!cfg.isWindows() and cfg.os() != .linux and !cfg.isDarwin()) {
            log.err("unsupported target OS {t}: libgit2 builds for Darwin, Linux and Windows", .{cfg.os()});
            return error.UnsupportedTargetOs;
        }
        const b = cfg.b;
        const dep = cfg.dependency(dep_name);

        // `src/util/CMakeLists.txt:5`: `gen_headers/git2_features.h`.
        const features = b.addConfigHeader(.{
            .style = .{ .cmake = dep.path("src/util/git2_features.h.in") },
            .include_path = "git2_features.h",
        }, .{});
        addFeatureValues(cfg, features);

        const common = try commonFlags(cfg);
        var self = Self{
            .cfg = cfg,
            .dep = dep,
            .features = features,
            .common_flags = common,
            .src_flags = try concat(b, &.{ common, &pcre2_defines }),
        };
        self.module = try self.createCoreModule();
        return self;
    }

    /// Adds `LIBGIT2_INCLUDES` (`src/libgit2/CMakeLists.txt:9-13`) or
    /// `UTIL_INCLUDES` (`src/util/CMakeLists.txt:7-10`), followed by
    /// `LIBGIT2_DEPENDENCY_INCLUDES` in the order `src/CMakeLists.txt:42-46`
    /// appends them.
    ///
    /// - `self`: the libgit2 description.
    /// - `root`: the module to add the paths to.
    /// - `core`: true for `src/libgit2` and the tests, which also see
    ///   `src/libgit2`.
    pub fn addIncludes(self: *const Self, root: *std.Build.Module, core: bool) void {
        const dep = self.dep;
        if (core) root.addIncludePath(dep.path("src/libgit2"));
        root.addIncludePath(dep.path("src/util"));
        root.addIncludePath(dep.path("include"));
        root.addConfigHeader(self.features);
        root.addIncludePath(dep.path("deps/llhttp"));
        root.addIncludePath(dep.path("deps/pcre2"));
        root.addIncludePath(dep.path("deps/xdiff"));
        root.addIncludePath(mod.LibSsh2.includePath(self.cfg));
        root.addIncludePath(dep.path("deps/zlib"));
    }

    /// Returns the public include directory, for code built against libgit2.
    ///
    /// - `self`: the libgit2 description.
    /// - Returns: the lazy path of libgit2's `include/`.
    pub fn includePath(self: *const Self) std.Build.LazyPath {
        return self.dep.path("include");
    }

    /// Creates the `src/libgit2` module and every module it imports.
    ///
    /// - `self`: the libgit2 description.
    /// - Returns: the core module; propagates glob and allocation failures.
    fn createCoreModule(self: *const Self) !*std.Build.Module {
        const cfg = self.cfg;
        const b = cfg.b;
        const dep = self.dep;

        // `src/libgit2/CMakeLists.txt`: `gen_headers/experimental.h`.
        // `GIT_EXPERIMENTAL_SHA256` stays off, as `EXPERIMENTAL_SHA256` defaults.
        const experimental = b.addConfigHeader(.{
            .style = .{ .cmake = dep.path("src/libgit2/experimental.h.in") },
            .include_path = "experimental.h",
        }, .{});

        const common = self.common_flags;
        const with_pcre2 = self.src_flags;

        const zlib = try zlibModule(cfg, dep, with_pcre2);
        const pcre2 = try pcre2Module(cfg, dep, with_pcre2);
        const llhttp = try llhttpModule(cfg, dep, common);
        const xdiff = try xdiffModule(cfg, dep, self.features, with_pcre2);
        const ssh = mod.LibSsh2.createModule(cfg);
        ssh.addImport("mbedtls_c", mod.MbedTls.createModule(cfg));

        // `src/util/CMakeLists.txt`: the util object library.
        const util = cfg.createCModule();
        self.addIncludes(util, false);
        var util_files: std.ArrayList([]const u8) = .empty;
        try cfg.appendGlob(dep, &util_files, "src/util", ".c");
        try cfg.appendGlob(dep, &util_files, "src/util/allocators", ".c");
        // `src/util/CMakeLists.txt:19-25`.
        try cfg.appendGlob(dep, &util_files, if (cfg.isWindows()) "src/util/win32" else "src/util/unix", ".c");
        // `src/util/CMakeLists.txt:32` and `:52`: the selected hash backends.
        try util_files.append(b.allocator, "src/util/hash/collisiondetect.c");
        try cfg.appendGlob(dep, &util_files, "src/util/hash/sha1dc", ".c");
        try util_files.append(b.allocator, "src/util/hash/builtin.c");
        try cfg.appendGlob(dep, &util_files, "src/util/hash/rfc6234", ".c");
        util.addCSourceFiles(.{
            .root = dep.path(""),
            .files = util_files.items,
            .flags = try concat(b, &.{ with_pcre2, &sha1dc_defines }),
        });

        // `src/libgit2/CMakeLists.txt`: the libgit2 object library.
        const core = cfg.createCModule();
        self.addIncludes(core, true);
        core.addConfigHeader(experimental);
        var core_files: std.ArrayList([]const u8) = .empty;
        // `src/libgit2/CMakeLists.txt:23-25`. Every backend's source is
        // listed; each compiles to nothing unless its `GIT_*` feature is set.
        try cfg.appendGlob(dep, &core_files, "src/libgit2", ".c");
        try cfg.appendGlob(dep, &core_files, "src/libgit2/streams", ".c");
        try cfg.appendGlob(dep, &core_files, "src/libgit2/transports", ".c");
        core.addCSourceFiles(.{
            .root = dep.path(""),
            .files = core_files.items,
            .flags = with_pcre2,
        });

        core.addImport("libgit2_util", util);
        core.addImport("libgit2_xdiff", xdiff);
        core.addImport("libgit2_llhttp", llhttp);
        core.addImport("libgit2_pcre2", pcre2);
        core.addImport("libgit2_zlib", zlib);
        core.addImport("libssh2_c", ssh);

        linkSystemLibraries(cfg, core);

        return core;
    }

    /// Returns the flags CMake sets for every libgit2 C source.
    ///
    /// - `cfg`: the shared build configuration.
    /// - Returns: the flags; propagates allocation failure.
    fn commonFlags(cfg: *const mod.Config) ![]const []const u8 {
        const b = cfg.b;
        var flags: std.ArrayList([]const u8) = .empty;

        // `CMakeLists.txt:60-62`: C90, extensions off.
        try flags.append(b.allocator, "-std=c90");
        // `cmake/DefaultCFlags.cmake:102`.
        try flags.append(b.allocator, "-D_GNU_SOURCE");
        // `cmake/DefaultCFlags.cmake:111`.
        if (cfg.isDebug()) try flags.append(b.allocator, "-D_DEBUG");

        if (cfg.isWindows()) {
            // `cmake/DefaultCFlags.cmake:127` and `:158`.
            try flags.append(b.allocator, "-D__USE_MINGW_ANSI_STDIO=1");
            try flags.append(b.allocator, "-DWIN32");
            try flags.append(b.allocator, "-D_WIN32_WINNT=0x0600");
        } else {
            // `cmake/DefaultCFlags.cmake:116`; MinGW is left out at 113-114.
            try flags.append(b.allocator, "-fvisibility=hidden");
        }

        return flags.items;
    }

    /// Creates the bundled zlib (`deps/zlib/CMakeLists.txt`).
    ///
    /// - `cfg`: the shared build configuration.
    /// - `dep`: the libgit2 package.
    /// - `base`: the flags it inherits from `src/`.
    /// - Returns: the module; propagates glob and allocation failures.
    fn zlibModule(cfg: *const mod.Config, dep: *std.Build.Dependency, base: []const []const u8) !*std.Build.Module {
        const b = cfg.b;
        const root = cfg.createCModule();
        // `deps/zlib/CMakeLists.txt:10`.
        root.addIncludePath(dep.path("deps/zlib"));

        var files: std.ArrayList([]const u8) = .empty;
        try cfg.appendGlob(dep, &files, "deps/zlib", ".c");

        const mingw: []const []const u8 = if (cfg.isWindows()) &zlib_mingw_defines else &.{};
        root.addCSourceFiles(.{
            .root = dep.path(""),
            .files = files.items,
            .flags = try concat(b, &.{ base, &zlib_defines, mingw }),
        });
        return root;
    }

    /// Creates the bundled pcre2 (`deps/pcre2/CMakeLists.txt`), with its
    /// generated `config.h`.
    ///
    /// - `cfg`: the shared build configuration.
    /// - `dep`: the libgit2 package.
    /// - `base`: the flags it inherits from `src/`.
    /// - Returns: the module; propagates allocation failure.
    fn pcre2Module(cfg: *const mod.Config, dep: *std.Build.Dependency, base: []const []const u8) !*std.Build.Module {
        const b = cfg.b;
        const root = cfg.createCModule();

        // `deps/pcre2/CMakeLists.txt:59`.
        const config_header = b.addConfigHeader(.{
            .style = .{ .cmake = dep.path("deps/pcre2/config.h.in") },
            .include_path = "config.h",
        }, .{
            // `deps/pcre2/CMakeLists.txt:5-14`.
            .SUPPORT_PCRE2_8 = true,
            .SUPPORT_UNICODE = true,
            .NEWLINE_DEFAULT = "2",
            .PCRE2_LINK_SIZE = "2",
            .PCRE2_MAX_VARLOOKBEHIND = "255",
            .PCRE2_PARENS_NEST_LIMIT = "250",
            .PCRE2_HEAP_LIMIT = "20000000",
            .PCRE2_MATCH_LIMIT = "10000000",
            .PCRE2_MATCH_LIMIT_DEPTH = "MATCH_LIMIT",
            // Unset in CMake, so `@ONLY` substitutes nothing; pcre2grep only.
            .PCRE2GREP_BUFSIZE = "",
            .PCRE2GREP_MAX_BUFSIZE = "",
            // `deps/pcre2/CMakeLists.txt:26-55`: every compiler Zig ships
            // has these builtins and attributes.
            .HAVE_ASSERT_H = true,
            .HAVE_BUILTIN_MUL_OVERFLOW = true,
            .HAVE_BUILTIN_UNREACHABLE = true,
            .HAVE_ATTRIBUTE_UNINITIALIZED = true,
        });
        addPcre2PlatformValues(cfg, config_header);
        root.addConfigHeader(config_header);
        root.addIncludePath(dep.path("deps/pcre2"));

        root.addCSourceFiles(.{
            .root = dep.path("deps/pcre2"),
            .files = &pcre2_sources,
            // `deps/pcre2/CMakeLists.txt:101-102`.
            .flags = try concat(b, &.{ base, &.{ "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8" } }),
        });
        return root;
    }

    /// Sets the header checks of `deps/pcre2/CMakeLists.txt:26-34`, per OS.
    ///
    /// - `cfg`: the shared build configuration.
    /// - `config_header`: pcre2's `config.h`.
    fn addPcre2PlatformValues(cfg: *const mod.Config, config_header: *std.Build.Step.ConfigHeader) void {
        config_header.addValue("HAVE_SYS_STAT_H", bool, true);
        config_header.addValue("HAVE_SYS_TYPES_H", bool, true);
        if (cfg.isWindows()) {
            config_header.addValue("HAVE_WINDOWS_H", bool, true);
            return;
        }
        config_header.addValue("HAVE_DIRENT_H", bool, true);
        config_header.addValue("HAVE_UNISTD_H", bool, true);
        if (cfg.os() == .linux) {
            // glibc 2.27 and 2.17 respectively.
            config_header.addValue("HAVE_MEMFD_CREATE", bool, true);
            config_header.addValue("HAVE_SECURE_GETENV", bool, true);
        }
    }

    /// Creates the bundled llhttp (`deps/llhttp/CMakeLists.txt`).
    ///
    /// - `cfg`: the shared build configuration.
    /// - `dep`: the libgit2 package.
    /// - `base`: the flags it inherits from `src/` (no pcre2 defines).
    /// - Returns: the module; propagates glob and allocation failures.
    fn llhttpModule(cfg: *const mod.Config, dep: *std.Build.Dependency, base: []const []const u8) !*std.Build.Module {
        const root = cfg.createCModule();
        var files: std.ArrayList([]const u8) = .empty;
        try cfg.appendGlob(dep, &files, "deps/llhttp", ".c");
        root.addCSourceFiles(.{ .root = dep.path(""), .files = files.items, .flags = base });
        return root;
    }

    /// Creates the bundled xdiff (`deps/xdiff/CMakeLists.txt`).
    ///
    /// - `cfg`: the shared build configuration.
    /// - `dep`: the libgit2 package.
    /// - `features`: the generated `git2_features.h`.
    /// - `base`: the flags it inherits from `src/`.
    /// - Returns: the module; propagates glob and allocation failures.
    fn xdiffModule(cfg: *const mod.Config, dep: *std.Build.Dependency, features: *std.Build.Step.ConfigHeader, base: []const []const u8) !*std.Build.Module {
        const root = cfg.createCModule();
        // `deps/xdiff/CMakeLists.txt:6-11`.
        root.addIncludePath(dep.path("include"));
        root.addIncludePath(dep.path("src/util"));
        root.addConfigHeader(features);
        root.addIncludePath(dep.path("deps/llhttp"));
        root.addIncludePath(dep.path("deps/pcre2"));
        root.addIncludePath(dep.path("deps/xdiff"));
        root.addIncludePath(mod.LibSsh2.includePath(cfg));

        var files: std.ArrayList([]const u8) = .empty;
        try cfg.appendGlob(dep, &files, "deps/xdiff", ".c");
        root.addCSourceFiles(.{ .root = dep.path(""), .files = files.items, .flags = base });
        return root;
    }

    /// Sets the `git2_features.h` values CMake's checks produce, per OS.
    ///
    /// Each platform-dependent value was verified by compiling the same check
    /// with `zig cc` against that target.
    ///
    /// - `cfg`: the shared build configuration.
    /// - `features`: the header to add the values to.
    fn addFeatureValues(cfg: *const mod.Config, features: *std.Build.Step.ConfigHeader) void {
        // `src/CMakeLists.txt:159-166`, `USE_THREADS` defaults on.
        features.addValue("GIT_THREADS", bool, true);
        // `src/CMakeLists.txt:101-105`.
        if (cfg.target.result.ptrBitWidth() == 64) {
            features.addValue("GIT_ARCH_64", bool, true);
        } else {
            features.addValue("GIT_ARCH_32", bool, true);
        }
        // `src/CMakeLists.txt:113-115`, `USE_NSEC` defaults on.
        features.addValue("GIT_USE_NSEC", bool, true);

        // `cmake/SelectRegex.cmake:47-49`.
        features.addValue("GIT_REGEX_BUILTIN", bool, true);
        // `cmake/SelectSSH.cmake:6-35`.
        features.addValue("GIT_SSH", bool, true);
        features.addValue("GIT_SSH_LIBSSH2", bool, true);
        features.addValue("GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS", bool, true);
        // `cmake/SelectHTTPParser.cmake`, bundled.
        features.addValue("GIT_HTTPPARSER_BUILTIN", bool, true);
        // `cmake/SelectHashes.cmake`.
        features.addValue("GIT_SHA1_COLLISIONDETECT", bool, true);
        features.addValue("GIT_SHA256_BUILTIN", bool, true);
        // `cmake/SelectZlib.cmake`, bundled.
        features.addValue("GIT_COMPRESSION_BUILTIN", bool, true);

        switch (cfg.os()) {
            .windows => {
                // `src/util/util.c:747`: `qsort_s` with the MSVC signature.
                features.addValue("GIT_QSORT_MSC", bool, true);
                // `src/CMakeLists.txt:92-93`.
                features.addValue("GIT_IO_WSAPOLL", bool, true);
            },
            .linux => {
                features.addValue("GIT_USE_STAT_MTIM", bool, true);
                features.addValue("GIT_USE_FUTIMENS", bool, true);
                features.addValue("GIT_QSORT_GNU", bool, true);
                features.addValue("GIT_RAND_GETENTROPY", bool, true);
                features.addValue("GIT_RAND_GETLOADAVG", bool, true);
                features.addValue("GIT_IO_POLL", bool, true);
                features.addValue("GIT_IO_SELECT", bool, true);
            },
            else => {
                // Darwin (`init` refuses any other OS). `getentropy` is
                // declared in `sys/random.h`, not the
                // `unistd.h` `src/CMakeLists.txt:87` checks, so it is off.
                features.addValue("GIT_USE_ICONV", bool, true);
                features.addValue("GIT_USE_STAT_MTIMESPEC", bool, true);
                features.addValue("GIT_USE_FUTIMENS", bool, true);
                features.addValue("GIT_QSORT_BSD", bool, true);
                features.addValue("GIT_RAND_GETLOADAVG", bool, true);
                features.addValue("GIT_IO_POLL", bool, true);
                features.addValue("GIT_IO_SELECT", bool, true);
            },
        }
    }

    /// Links what `LIBGIT2_SYSTEM_LIBS` collects in `src/CMakeLists.txt`.
    ///
    /// - `cfg`: the shared build configuration.
    /// - `root`: the module to link them on.
    fn linkSystemLibraries(cfg: *const mod.Config, root: *std.Build.Module) void {
        switch (cfg.os()) {
            .windows => {
                // `src/CMakeLists.txt:138-139`.
                root.linkSystemLibrary("ws2_32", .{});
                root.linkSystemLibrary("secur32", .{});
                // MSVC links these by default; MinGW does not.
                root.linkSystemLibrary("advapi32", .{});
                root.linkSystemLibrary("ole32", .{});
            },
            .linux => {
                // `src/CMakeLists.txt:159-163`: `Threads`.
                root.linkSystemLibrary("pthread", .{});
            },
            else => {
                // Darwin (`init` refuses any other OS).
                // `src/CMakeLists.txt:187-195`: `IntlIconv`.
                root.linkSystemLibrary("iconv", .{});
            },
        }
    }

    /// Concatenates flag lists.
    ///
    /// - `b`: the build graph, for its allocator.
    /// - `parts`: the lists to join, in order.
    /// - Returns: one list; propagates allocation failure.
    fn concat(b: *std.Build, parts: []const []const []const u8) ![]const []const u8 {
        return std.mem.concat(b.allocator, []const u8, parts);
    }
};
