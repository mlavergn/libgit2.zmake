//! Build barrel for the upstream C libraries.
//!
//! Re-exports every public type in `build/` so `build.zig` and the files here
//! import through this module rather than reaching for each other directly.
//! Each upstream package is built from its pinned, unmodified tarball; these
//! files are the build description CMake would otherwise supply.

/// The target, optimize mode and package access the C builds share.
pub const Config = @import("config.zig").Config;
/// mbedTLS's `mbedcrypto`, libssh2's crypto.
pub const MbedTls = @import("mbedtls.zig").MbedTls;
/// libssh2, libgit2's SSH transport.
pub const LibSsh2 = @import("libssh2.zig").LibSsh2;
/// libgit2 and its bundled dependencies.
pub const LibGit2 = @import("libgit2.zig").LibGit2;
/// libgit2's clar test suites.
pub const Clar = @import("clar.zig").Clar;
/// libgit2's own CLI, `git2`.
pub const Git2Cli = @import("git2_cli.zig").Git2Cli;
