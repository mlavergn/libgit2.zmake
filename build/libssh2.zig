const std = @import("std");
const log = std.log.scoped(.libgit2_build_libssh2);
const mod = @import("module.zig");

/// libssh2 1.11, libgit2's SSH transport, with mbedTLS as its crypto backend.
///
/// libssh2 picks its crypto at compile time from a fixed list
/// (`src/crypto.h:44-55`) and has no hook for another, so a C crypto library
/// is unavoidable; mbedTLS is the one that needs nothing beyond the Zig
/// toolchain. zlib compression stays off, as `ENABLE_ZLIB_COMPRESSION`
/// defaults (`src/CMakeLists.txt:59`).
pub const LibSsh2 = struct {
    const Self = @This();

    /// The name of the package in `build.zig.zon`.
    pub const dep_name = "libssh2";

    /// `CSOURCES`, verbatim from `src/Makefile.inc:3-29`, which
    /// `src/CMakeLists.txt` reads. `agent_win.c` and `blowfish.c` are not
    /// listed because `agent.c` and `bcrypt_pbkdf.c` `#include` them.
    const csources = [_][]const u8{
        "agent.c",
        "bcrypt_pbkdf.c",
        "channel.c",
        "comp.c",
        "chacha.c",
        "cipher-chachapoly.c",
        "crypt.c",
        "crypto.c",
        "global.c",
        "hostkey.c",
        "keepalive.c",
        "kex.c",
        "knownhost.c",
        "mac.c",
        "misc.c",
        "packet.c",
        "pem.c",
        "poly1305.c",
        "publickey.c",
        "scp.c",
        "session.c",
        "sftp.c",
        "transport.c",
        "userauth.c",
        "userauth_kbd_packet.c",
        "version.c",
    };

    /// Creates the module that compiles libssh2.
    ///
    /// - `cfg`: the shared build configuration.
    /// - Returns: a C-only module; importing it into a library's module graph
    ///   bundles its objects into that library.
    pub fn createModule(cfg: *const mod.Config) *std.Build.Module {
        if (cfg.verbose) log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        const b = cfg.b;
        const dep = cfg.dependency(dep_name);
        const root = cfg.createCModule();

        // `CMakeLists.txt:287`: `libssh2_config.h`, found through `HAVE_CONFIG_H`.
        const config_header = b.addConfigHeader(.{
            .style = .{ .cmake = dep.path("src/libssh2_config_cmake.h.in") },
            .include_path = "libssh2_config.h",
        }, .{});
        addConfigValues(cfg, config_header);
        root.addConfigHeader(config_header);

        // `src/CMakeLists.txt:116-122`.
        root.addIncludePath(dep.path("include"));
        root.addIncludePath(mod.MbedTls.includePath(cfg));

        root.addCSourceFiles(.{
            .root = dep.path("src"),
            .files = &csources,
            .flags = &.{
                // `CMakeLists.txt:285`.
                "-DHAVE_CONFIG_H",
                // `CMakeLists.txt:397`, by way of `src/CMakeLists.txt:43`.
                "-DLIBSSH2_MBEDTLS",
            },
        });

        // `CMakeLists.txt:105-107`.
        if (cfg.isWindows()) root.linkSystemLibrary("ws2_32", .{});

        return root;
    }

    /// Returns the public include directory, for packages built against it.
    ///
    /// - `cfg`: the shared build configuration.
    /// - Returns: the lazy path of libssh2's `include/`.
    pub fn includePath(cfg: *const mod.Config) std.Build.LazyPath {
        return cfg.dependency(dep_name).path("include");
    }

    /// Sets what `CMakeLists.txt`'s platform checks find, per target OS.
    ///
    /// Each value was verified by compiling the same check with `zig cc`
    /// against that target. `LIBSSH2_API` is substituted as `${LIBSSH2_API}`,
    /// so it must be supplied; it is empty, as CMake leaves it for a static
    /// build.
    ///
    /// - `cfg`: the shared build configuration.
    /// - `config_header`: the header to add the values to.
    fn addConfigValues(cfg: *const mod.Config, config_header: *std.Build.Step.ConfigHeader) void {
        config_header.addValue("LIBSSH2_API", []const u8, "");

        // `CMakeLists.txt:179-186` prefills these for MinGW; the checks at
        // 206-209 find the same on every Unix.
        config_header.addValue("HAVE_UNISTD_H", bool, true);
        config_header.addValue("HAVE_INTTYPES_H", bool, true);
        config_header.addValue("HAVE_SYS_TIME_H", bool, true);
        config_header.addValue("HAVE_GETTIMEOFDAY", bool, true);
        config_header.addValue("HAVE_STRTOLL", bool, true);
        config_header.addValue("HAVE_SNPRINTF", bool, true);
        // `CMakeLists.txt:267-271`.
        config_header.addValue("HAVE_SELECT", bool, true);

        if (cfg.isWindows()) return;

        // `CMakeLists.txt:211-219`.
        config_header.addValue("HAVE_SYS_SELECT_H", bool, true);
        config_header.addValue("HAVE_SYS_UIO_H", bool, true);
        config_header.addValue("HAVE_SYS_SOCKET_H", bool, true);
        config_header.addValue("HAVE_SYS_IOCTL_H", bool, true);
        config_header.addValue("HAVE_SYS_UN_H", bool, true);
        config_header.addValue("HAVE_ARPA_INET_H", bool, true);
        config_header.addValue("HAVE_NETINET_IN_H", bool, true);
        // `CMakeLists.txt:276-281`, `cmake/CheckNonblockingSocketSupport.cmake`.
        config_header.addValue("HAVE_O_NONBLOCK", bool, true);

        if (cfg.isDarwin()) {
            // `CMakeLists.txt:250-262`: poll() is deliberately not used on Darwin.
            // `CMakeLists.txt:240-244`: Darwin has memset_s, not explicit_bzero.
            config_header.addValue("HAVE_MEMSET_S", bool, true);
        } else {
            config_header.addValue("HAVE_POLL", bool, true);
            config_header.addValue("HAVE_EXPLICIT_BZERO", bool, true);
        }
    }
};
