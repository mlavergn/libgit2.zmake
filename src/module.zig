//! Library barrel for ziglibgit2: libgit2, built with the Zig toolchain, and
//! a Zig API over it.
//!
//! Re-exports every public type in `src/`, plus the translated C API as `c`,
//! so sibling files and consumers import through this module rather than
//! reaching for each other directly. Create a `Libgit2` before using any of
//! the others.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this is a debug build.
pub const is_debug = builtin.mode == .debug;

/// libgit2's public C API, translated from `src/c.h`.
pub const c = @import("c");

/// Build options: `version` (`build.zig.zon`) and `test_filter`.
pub const config = @import("config");

/// libgit2's global state and the TLS stream; create one first.
pub const Libgit2 = @import("libgit2.zig").Libgit2;
/// libgit2's error codes as a Zig error set.
pub const GitErrorSet = @import("git_error.zig").GitErrorSet;
/// Turns libgit2 return codes into errors and reads their messages.
pub const GitError = @import("git_error.zig").GitError;
/// HTTPS for libgit2 over `std.crypto.tls`.
pub const TlsStream = @import("tls_stream.zig").TlsStream;
/// A TCP stream's reader and writer with per-operation timeouts.
pub const TimedSocket = @import("timed_socket.zig").TimedSocket;
/// The passphrase provider `Credentials` asks for encrypted keys.
pub const PassphraseFn = @import("credentials.zig").PassphraseFn;
/// SSH credentials: ssh-agent, then the default key files.
pub const Credentials = @import("credentials.zig").Credentials;
/// A git object id.
pub const Oid = @import("oid.zig").Oid;
/// A repository: opened, created, or cloned.
pub const Repository = @import("repository.zig").Repository;
/// A branch, tag, or other reference.
pub const Reference = @import("reference.zig").Reference;
/// A commit object.
pub const Commit = @import("commit.zig").Commit;
/// The order a `Revwalk` returns commits in.
pub const RevwalkSort = @import("revwalk.zig").RevwalkSort;
/// A walk over commit history.
pub const Revwalk = @import("revwalk.zig").Revwalk;
/// One changed path in a `Status` list.
pub const StatusEntry = @import("status.zig").StatusEntry;
/// The changed paths of a working directory.
pub const Status = @import("status.zig").Status;

/// A throwaway repository for the unit tests.
pub const TestRepo = @import("test_repo.zig").TestRepo;

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}
