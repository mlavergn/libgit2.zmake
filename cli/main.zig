const std = @import("std");
const log = std.log.scoped(.ziglibgit2_cli);
const mod = @import("ziglibgit2");

/// Log configuration for the executable: warnings only, so the trace lines
/// of a debug build do not interleave with `git2`'s own output.
pub const std_options: std.Options = .{
    .log_level = .warn,
};

/// Upstream's `main` (`src/cli/main.c:79`), which `build/git2_cli.zig`
/// compiles under this name.
extern fn ziglibgit2_git2_main(argc: c_int, argv: [*]const ?[*:0]const u8) c_int;

/// Entry point for the CLI: `git2`, libgit2's own command-line client.
///
/// Initializes libgit2 and registers the Zig TLS stream, which upstream's
/// `main` cannot do, then hands the process to it. Upstream calls
/// `git_libgit2_init` and `git_libgit2_shutdown` itself; libgit2 counts
/// them, so this handle keeps the library, and the stream, alive throughout.
///
/// - `init`: process capabilities supplied by the runtime (allocator, IO, args).
/// - Returns: nothing on success; exits with upstream's status otherwise.
pub fn main(init: std.process.Init) !void {
    log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const argv = try init.arena.allocator().alloc(?[*:0]const u8, args.len + 1);
    for (args, argv[0..args.len]) |arg, *slot| slot.* = arg.ptr;
    argv[args.len] = null;

    var lib = try mod.Libgit2.init(init.gpa, init.io);
    const code = ziglibgit2_git2_main(@intCast(args.len), argv.ptr);
    lib.deinit();

    if (code != 0) {
        const status: c_uint = @bitCast(code);
        std.process.exit(@truncate(status));
    }
}
