const std = @import("std");
const log = std.log.scoped(.libgit2_credentials);
const mod = @import("module.zig");

/// Supplies the passphrase for an encrypted SSH key, or null to skip the key.
///
/// - `context`: the `passphrase_context` given to `Credentials.init`.
/// - `key_path`: the private key that needs it.
/// - `buffer`: storage the returned passphrase may live in.
/// - Returns: the passphrase, or null.
pub const PassphraseFn = *const fn (context: ?*anyopaque, key_path: []const u8, buffer: []u8) ?[]const u8;

/// The SSH credentials offered to a remote, in order.
///
/// Implements `git_credential_acquire_cb`. libgit2 calls it again after each
/// rejected credential, so every call offers the next candidate: ssh-agent,
/// then each of `~/.ssh/id_ed25519`, `id_ecdsa` and `id_rsa` that exists.
/// An encrypted key is offered only when a passphrase provider supplies its
/// passphrase. After one pass through the list the callback fails with
/// `GIT_EAUTH` instead of looping forever.
///
/// HTTPS credentials are not handled: the callback passes, and libgit2
/// reports that authentication is required.
pub const Credentials = struct {
    const Self = @This();

    /// The key files tried after ssh-agent, under `~/.ssh`.
    pub const key_names = [_][]const u8{ "id_ed25519", "id_ecdsa", "id_rsa" };

    /// Holds the key paths and passphrases handed to libgit2.
    arena: std.heap.ArenaAllocator,
    /// The arena's allocator, set by `install`.
    allocator: std.mem.Allocator = undefined,
    /// The I/O implementation key files are read with.
    io: std.Io,
    /// The home directory holding `.ssh`, or null for agent only.
    home: ?[]const u8,
    /// The provider for encrypted keys, or null to skip them.
    passphrase_fn: ?PassphraseFn = null,
    /// Passed to `passphrase_fn`.
    passphrase_context: ?*anyopaque = null,
    /// The next candidate: 0 is ssh-agent, then one per `key_names` entry.
    next: usize = 0,
    /// Where `passphrase_fn` reads a passphrase into; zeroed by `deinit`.
    passphrase_buffer: [1024]u8 = undefined,

    /// Creates the credential source.
    ///
    /// - `allocator`: backing allocator for key paths.
    /// - `io`: the I/O implementation key files are read with.
    /// - `home`: the home directory holding `.ssh`, or null for agent only.
    /// - `passphrase_fn`: provider for encrypted keys, or null to skip them.
    /// - `passphrase_context`: passed to `passphrase_fn`.
    /// - Returns: the credential source; call `deinit` to free it.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8, passphrase_fn: ?PassphraseFn, passphrase_context: ?*anyopaque) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return Self{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .io = io,
            .home = home,
            .passphrase_fn = passphrase_fn,
            .passphrase_context = passphrase_context,
        };
    }

    /// Frees the key paths and clears any passphrase held.
    ///
    /// - `self`: the credential source.
    pub fn deinit(self: *Self) void {
        std.crypto.secureZero(u8, &self.passphrase_buffer);
        self.arena.deinit();
    }

    /// Installs the callback on a remote's callbacks.
    ///
    /// - `self`: the credential source; must outlive the operation.
    /// - `callbacks`: the `git_remote_callbacks` of a fetch or clone.
    pub fn install(self: *Self, callbacks: *mod.c.git_remote_callbacks) void {
        self.allocator = self.arena.allocator();
        self.next = 0;
        callbacks.credentials = acquire;
        callbacks.payload = self;
    }

    /// Returns whether a private key file needs a passphrase.
    ///
    /// PEM keys say so in a `Proc-Type: 4,ENCRYPTED` header. OpenSSH keys
    /// name their cipher right after the `openssh-key-v1` magic; `none` means
    /// unencrypted.
    ///
    /// - `contents`: the key file.
    /// - Returns: true for an encrypted key.
    pub fn isEncrypted(contents: []const u8) bool {
        if (std.mem.find(u8, contents, "ENCRYPTED") != null) return true;

        const begin = "-----BEGIN OPENSSH PRIVATE KEY-----";
        const start = std.mem.find(u8, contents, begin) orelse return false;

        // The magic and the cipher name fit in the first 64 base64 digits.
        var digits: [64]u8 = undefined;
        var len: usize = 0;
        for (contents[start + begin.len ..]) |ch| {
            if (std.ascii.isWhitespace(ch)) continue;
            if (ch == '-' or len == digits.len) break;
            digits[len] = ch;
            len += 1;
        }
        len -= len % 4;

        var decoded: [48]u8 = undefined;
        std.base64.standard.Decoder.decode(decoded[0 .. len / 4 * 3], digits[0..len]) catch return false;
        const magic = "openssh-key-v1\x00";
        const header = decoded[0 .. len / 4 * 3];
        if (header.len < magic.len + 4 or !std.mem.startsWith(u8, header, magic)) return false;

        const cipher_len = std.mem.readInt(u32, header[magic.len..][0..4], .big);
        const cipher_start = magic.len + 4;
        if (cipher_start + cipher_len > header.len) return true;
        return !std.mem.eql(u8, header[cipher_start .. cipher_start + cipher_len], "none");
    }

    /// `git_credential_acquire_cb`: offers the next candidate.
    ///
    /// - `out`: where the credential goes.
    /// - `url`: the remote being authenticated to.
    /// - `username_from_url`: the URL's user, or null (`git` is used).
    /// - `allowed_types`: the `GIT_CREDENTIAL_*` types the server accepts.
    /// - `payload`: the `*Credentials` set by `install`.
    /// - Returns: 0 with a credential, `GIT_PASSTHROUGH` for types this does
    ///   not handle, or `GIT_EAUTH` once every candidate was refused.
    fn acquire(out: [*c][*c]mod.c.git_credential, url: [*c]const u8, username_from_url: [*c]const u8, allowed_types: c_uint, payload: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(payload orelse return mod.c.GIT_PASSTHROUGH));
        const username: [*c]const u8 = if (username_from_url != null) username_from_url else "git";

        if (allowed_types & @as(c_uint, mod.c.GIT_CREDENTIAL_USERNAME) != 0) {
            return mod.c.git_credential_username_new(out, username);
        }
        if (allowed_types & @as(c_uint, mod.c.GIT_CREDENTIAL_SSH_KEY) == 0) {
            return mod.c.GIT_PASSTHROUGH;
        }

        while (self.next <= key_names.len) {
            const candidate = self.next;
            self.next += 1;

            if (candidate == 0) {
                log.debug("offering ssh-agent to {s}", .{url});
                return mod.c.git_credential_ssh_key_from_agent(out, username);
            }

            const key = self.keyCandidate(key_names[candidate - 1]) catch |err| {
                log.debug("skipping {s}: {t}", .{ key_names[candidate - 1], err });
                continue;
            } orelse continue;

            log.debug("offering {s} to {s}", .{ key.private, url });
            const rc = mod.c.git_credential_ssh_key_new(out, username, key.public, key.private.ptr, key.passphrase);
            // libgit2 has its own copy now (`credential.c:260`).
            std.crypto.secureZero(u8, &self.passphrase_buffer);
            return rc;
        }

        _ = mod.c.git_error_set_str(mod.c.GIT_ERROR_SSH, "no SSH credential was accepted (tried ssh-agent and ~/.ssh/id_ed25519, id_ecdsa, id_rsa)");
        return mod.c.GIT_EAUTH;
    }

    /// Resolves a key file, or null when it does not exist or is encrypted
    /// with no passphrase available.
    ///
    /// - `self`: the credential source.
    /// - `name`: the key's file name under `~/.ssh`.
    /// - Returns: the paths and passphrase; propagates read and allocation
    ///   failures.
    fn keyCandidate(self: *Self, name: []const u8) !?struct { private: [:0]const u8, public: [*c]const u8, passphrase: [*c]const u8 } {
        const home = self.home orelse return null;
        const private = try self.allocator.printSentinel("{s}/.ssh/{s}", .{ home, name }, 0);
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, private, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        // Only the header is needed; the key itself must not linger in the
        // arena until `deinit`.
        const encrypted = isEncrypted(contents);
        std.crypto.secureZero(u8, contents);

        // libssh2 derives the public key when its file is absent.
        const public_path = try self.allocator.printSentinel("{s}.pub", .{private}, 0);
        const public: [*c]const u8 = if (std.Io.Dir.cwd().access(self.io, public_path, .{})) |_| public_path.ptr else |_| null;

        var passphrase: [*c]const u8 = null;
        if (encrypted) {
            const provider = self.passphrase_fn orelse return null;
            const room = self.passphrase_buffer.len - 1;
            const value = provider(self.passphrase_context, private, self.passphrase_buffer[0..room]) orelse return null;
            if (value.len > room) return error.PassphraseTooLong;
            // Kept in `passphrase_buffer` only, which is zeroed once libgit2
            // has copied it, rather than in the arena.
            @memmove(self.passphrase_buffer[0..value.len], value);
            self.passphrase_buffer[value.len] = 0;
            passphrase = &self.passphrase_buffer;
        }

        return .{ .private = private, .public = public, .passphrase = passphrase };
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Credentials);
}

test "encrypted keys are recognized" {
    // `ssh-keygen -t ed25519 -N ''`, truncated after the header it inspects.
    const plain =
        \\-----BEGIN OPENSSH PRIVATE KEY-----
        \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        \\-----END OPENSSH PRIVATE KEY-----
    ;
    // The same with `-N secret`: cipher `aes256-ctr`.
    const encrypted =
        \\-----BEGIN OPENSSH PRIVATE KEY-----
        \\b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBGbB4hRb
        \\-----END OPENSSH PRIVATE KEY-----
    ;
    const pem =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\Proc-Type: 4,ENCRYPTED
        \\-----END RSA PRIVATE KEY-----
    ;
    try std.testing.expect(!Credentials.isEncrypted(plain));
    try std.testing.expect(Credentials.isEncrypted(encrypted));
    try std.testing.expect(Credentials.isEncrypted(pem));
}

test "candidates run out after one pass" {
    var lib = try mod.Libgit2.init(std.testing.allocator, std.testing.io);
    defer lib.deinit();

    // No home directory: ssh-agent is the only candidate.
    var credentials = try Credentials.init(std.testing.allocator, std.testing.io, null, null, null);
    defer credentials.deinit();
    var callbacks: mod.c.git_remote_callbacks = .{};
    credentials.install(&callbacks);

    var cred: [*c]mod.c.git_credential = null;
    const ssh_key: c_uint = @intCast(mod.c.GIT_CREDENTIAL_SSH_KEY);
    try std.testing.expectEqual(0, Credentials.acquire(&cred, "ssh://example.com/repo", "git", ssh_key, &credentials));
    mod.c.git_credential_free(cred);
    try std.testing.expectEqual(mod.c.GIT_EAUTH, Credentials.acquire(&cred, "ssh://example.com/repo", "git", ssh_key, &credentials));
}
