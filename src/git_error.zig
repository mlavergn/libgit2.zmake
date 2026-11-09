const std = @import("std");
const log = std.log.scoped(.ziglibgit2_git_error);
const mod = @import("module.zig");

/// Every `git_error_code` (`include/git2/errors.h`) a caller can act on,
/// plus `Generic` for `GIT_ERROR` and any code this version does not name.
pub const GitErrorSet = error{
    Generic,
    NotFound,
    Exists,
    Ambiguous,
    BufferTooShort,
    User,
    BareRepo,
    UnbornBranch,
    Unmerged,
    NonFastForward,
    InvalidSpec,
    Conflict,
    Locked,
    Modified,
    Auth,
    Certificate,
    Applied,
    Peel,
    Eof,
    Invalid,
    Uncommitted,
    Directory,
    MergeConflict,
    Passthrough,
    IterOver,
    Retry,
    Mismatch,
    IndexDirty,
    ApplyFail,
    Owner,
    Timeout,
    Unchanged,
    NotSupported,
    ReadOnly,
};

/// Converts libgit2's error codes and messages.
///
/// libgit2 functions return a negative `git_error_code` and leave a message
/// in thread-local storage. `check` turns the first into a Zig error;
/// `lastMessage` reads the second, which stays valid until the next libgit2
/// call on the same thread.
pub const GitError = struct {
    const Self = @This();

    /// Turns a libgit2 return code into a Zig error.
    ///
    /// - `code`: the value a libgit2 function returned.
    /// - Returns: nothing for zero or positive codes; the matching error
    ///   otherwise.
    pub fn check(code: c_int) GitErrorSet!void {
        if (code >= 0) return;
        log.debug("libgit2 error {d}: {s}", .{ code, lastMessage() });
        return fromCode(code);
    }

    /// Maps a negative `git_error_code` to its Zig error.
    ///
    /// - `code`: a negative libgit2 return code.
    /// - Returns: the matching error, `Generic` for any unnamed code.
    pub fn fromCode(code: c_int) GitErrorSet {
        return switch (code) {
            mod.c.GIT_ENOTFOUND => error.NotFound,
            mod.c.GIT_EEXISTS => error.Exists,
            mod.c.GIT_EAMBIGUOUS => error.Ambiguous,
            mod.c.GIT_EBUFS => error.BufferTooShort,
            mod.c.GIT_EUSER => error.User,
            mod.c.GIT_EBAREREPO => error.BareRepo,
            mod.c.GIT_EUNBORNBRANCH => error.UnbornBranch,
            mod.c.GIT_EUNMERGED => error.Unmerged,
            mod.c.GIT_ENONFASTFORWARD => error.NonFastForward,
            mod.c.GIT_EINVALIDSPEC => error.InvalidSpec,
            mod.c.GIT_ECONFLICT => error.Conflict,
            mod.c.GIT_ELOCKED => error.Locked,
            mod.c.GIT_EMODIFIED => error.Modified,
            mod.c.GIT_EAUTH => error.Auth,
            mod.c.GIT_ECERTIFICATE => error.Certificate,
            mod.c.GIT_EAPPLIED => error.Applied,
            mod.c.GIT_EPEEL => error.Peel,
            mod.c.GIT_EEOF => error.Eof,
            mod.c.GIT_EINVALID => error.Invalid,
            mod.c.GIT_EUNCOMMITTED => error.Uncommitted,
            mod.c.GIT_EDIRECTORY => error.Directory,
            mod.c.GIT_EMERGECONFLICT => error.MergeConflict,
            mod.c.GIT_PASSTHROUGH => error.Passthrough,
            mod.c.GIT_ITEROVER => error.IterOver,
            mod.c.GIT_RETRY => error.Retry,
            mod.c.GIT_EMISMATCH => error.Mismatch,
            mod.c.GIT_EINDEXDIRTY => error.IndexDirty,
            mod.c.GIT_EAPPLYFAIL => error.ApplyFail,
            mod.c.GIT_EOWNER => error.Owner,
            mod.c.GIT_TIMEOUT => error.Timeout,
            mod.c.GIT_EUNCHANGED => error.Unchanged,
            mod.c.GIT_ENOTSUPPORTED => error.NotSupported,
            mod.c.GIT_EREADONLY => error.ReadOnly,
            else => error.Generic,
        };
    }

    /// Returns the message libgit2 left for the last failure on this thread.
    ///
    /// - Returns: the message, valid until the next libgit2 call on this
    ///   thread; a placeholder when there is none.
    pub fn lastMessage() []const u8 {
        const last = mod.c.git_error_last();
        if (last == null or last.*.message == null) return "no error message";
        return std.mem.span(last.*.message);
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(GitError);
}

test "error codes map to the named errors" {
    try GitError.check(0);
    try GitError.check(1);
    try std.testing.expectError(error.NotFound, GitError.check(mod.c.GIT_ENOTFOUND));
    try std.testing.expectError(error.Auth, GitError.check(mod.c.GIT_EAUTH));
    try std.testing.expectError(error.IterOver, GitError.check(mod.c.GIT_ITEROVER));
    try std.testing.expectError(error.Generic, GitError.check(mod.c.GIT_ERROR));
    try std.testing.expectError(error.Generic, GitError.check(-999));
}
