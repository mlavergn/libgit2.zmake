//! A port of libgit2's `tests/clar/generate.py` to Zig.
//!
//! Scans a clar test directory for `void test_<module>__<name>(void)`
//! functions and writes the `clar.suite` and `clar_suite.h` that `clar.c`
//! includes, byte for byte as the Python script does with `-f`. The build
//! runs it on the host, so building the suites needs no Python.
//!
//! Usage: `clar_generate -o <output dir> [-f] [-x <prefix>]... <test dir>`

const std = @import("std");
const log = std.log.scoped(.libgit2_clar_generate);

/// One test, initializer or cleanup function found in a module.
const Callback = struct {
    const Self = @This();

    /// The text after `test_<module>__`, e.g. `initialize` or `simple`.
    short_name: []const u8,
    /// The declaration as written, from `void` through `)`.
    declaration: []const u8,
    /// The function name, `test_<module>__<short_name>`.
    symbol: []const u8,
};

/// One test source file: a clar module.
const Module = struct {
    const Self = @This();

    /// `<dir>_<dir>_<file stem>`, with `-` replaced by `_`.
    name: []const u8,
    /// The tests, in source order.
    callbacks: []const Callback = &.{},
    /// The `initialize*` functions, in source order.
    initializers: []const Callback = &.{},
    /// The `cleanup` function, if any.
    cleanup: ?Callback = null,
    /// False once excluded with `-x`; the module is still listed.
    enabled: bool = true,

    /// Returns the name clar prints and `-s`/`-x` match: `_` as `::`.
    ///
    /// - `self`: the module.
    /// - `allocator`: allocator for the returned string.
    /// - Returns: the clean name; propagates allocation failure.
    fn cleanName(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.mem.replaceOwned(u8, allocator, self.name, "_", "::");
    }
};

/// The suite generator: loads modules from a directory and renders them.
pub const ClarGenerate = struct {
    const Self = @This();

    /// Holds every module, string and rendered file.
    arena: std.heap.ArenaAllocator,
    /// The arena's allocator, set by `load`.
    allocator: std.mem.Allocator = undefined,
    /// The I/O implementation used to read the test sources.
    io: std.Io,
    /// The modules found, sorted by name.
    modules: std.ArrayList(Module) = .empty,

    /// Creates an empty generator.
    ///
    /// - `allocator`: backing allocator for the generator's arena.
    /// - `io`: the I/O implementation used to read the test sources.
    /// - Returns: the generator; call `deinit` to free it.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        return Self{ .arena = std.heap.ArenaAllocator.init(allocator), .io = io };
    }

    /// Frees every module and string the generator holds.
    ///
    /// - `self`: the generator.
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Loads every `*.c` file under `dir` that defines at least one test, as
    /// `TestSuite.find_modules` and `Module.refresh` do.
    ///
    /// - `self`: the generator.
    /// - `dir`: the test directory, opened with `.iterate = true`.
    /// - Returns: nothing; propagates read and allocation failures.
    pub fn load(self: *Self, dir: std.Io.Dir) !void {
        log.debug("{s}:{d} :: {s}", .{ @src().file, @src().line, @src().fn_name });
        self.allocator = self.arena.allocator();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;

            const name = try self.moduleName(entry.path);
            const contents = try dir.readFileAlloc(self.io, entry.path, self.allocator, .unlimited);
            var module = Module{ .name = name };
            if (try self.parse(&module, contents)) try self.modules.append(self.allocator, module);
        }

        std.mem.sort(Module, self.modules.items, {}, moduleLessThan);
    }

    /// Disables every module whose clean name starts with an excluded prefix,
    /// as `TestSuite.disable` does.
    ///
    /// - `self`: the generator.
    /// - `excluded`: the `-x` prefixes, e.g. `online`.
    /// - Returns: nothing; propagates allocation failure.
    pub fn disable(self: *Self, excluded: []const []const u8) !void {
        for (self.modules.items) |*module| {
            const clean = try module.cleanName(self.allocator);
            for (excluded) |prefix| {
                if (std.mem.startsWith(u8, clean, prefix)) module.enabled = false;
            }
        }
    }

    /// Renders `clar.suite`, as `TestSuite.write_suite` does.
    ///
    /// - `self`: the generator.
    /// - Returns: the file contents, owned by the generator; propagates
    ///   allocation failure.
    pub fn renderSuite(self: *Self) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &out.writer;

        for (self.modules.items) |*module| try writeDeclarations(w, module);

        for (self.modules.items) |*module| {
            try w.print("static const struct clar_func _clar_cb_{s}[] = {{\n", .{module.name});
            for (module.callbacks, 0..) |cb, i| {
                if (i > 0) try w.writeAll(",\n");
                try writeCallback(w, cb);
            }
            try w.writeAll("\n};\n");
        }

        try w.writeAll("static struct clar_suite _clar_suites[] = {");
        var first = true;
        for (self.modules.items) |*module| {
            const clean = try module.cleanName(self.allocator);
            const initializers: []const ?Callback = if (module.initializers.len == 0)
                &.{null}
            else
                try self.optionals(module.initializers);

            for (initializers) |initializer| {
                if (!first) try w.writeAll(",");
                first = false;
                try self.writeInfo(w, module, clean, initializer);
            }
        }
        try w.writeAll("\n};\n");

        try w.print("static const size_t _clar_suite_count = {d};\n", .{self.suiteCount()});
        try w.print("static const size_t _clar_callback_count = {d};\n", .{self.callbackCount()});

        return out.written();
    }

    /// Renders `clar_suite.h`, as `TestSuite.write_header` does.
    ///
    /// - `self`: the generator.
    /// - Returns: the file contents, owned by the generator; propagates
    ///   allocation failure.
    pub fn renderHeader(self: *Self) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &out.writer;

        try w.writeAll("#ifndef _____clar_suite_h_____\n");
        try w.writeAll("#define _____clar_suite_h_____\n");
        for (self.modules.items) |*module| try writeDeclarations(w, module);
        try w.writeAll("#endif\n");

        return out.written();
    }

    /// Returns the number of suites: one per initializer, at least one per
    /// module.
    ///
    /// - `self`: the generator.
    /// - Returns: the suite count.
    pub fn suiteCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.modules.items) |module| count += @max(1, module.initializers.len);
        return count;
    }

    /// Returns the number of tests across every module.
    ///
    /// - `self`: the generator.
    /// - Returns: the test count.
    pub fn callbackCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.modules.items) |module| count += module.callbacks.len;
        return count;
    }

    /// Finds the module's functions, as `Module.parse` does with
    /// `^(void\s+(test_<name>__(\w+))\s*\(\s*void\s*\))\s*\{` after comments
    /// are stripped.
    ///
    /// - `self`: the generator.
    /// - `module`: the module to fill; its `name` must be set.
    /// - `contents`: the source file.
    /// - Returns: true when the module defines at least one test; propagates
    ///   allocation failure.
    fn parse(self: *Self, module: *Module, contents: []const u8) !bool {
        const text = try self.skipComments(contents);
        const prefix = try self.allocator.print("test_{s}__", .{module.name});

        var callbacks: std.ArrayList(Callback) = .empty;
        var initializers: std.ArrayList(Callback) = .empty;

        var pos: usize = 0;
        while (pos < text.len) {
            if (matchTest(text, pos, prefix)) |found| {
                if (std.mem.startsWith(u8, found.callback.short_name, "initialize")) {
                    try initializers.append(self.allocator, found.callback);
                } else if (std.mem.eql(u8, found.callback.short_name, "cleanup")) {
                    module.cleanup = found.callback;
                } else {
                    try callbacks.append(self.allocator, found.callback);
                }
                pos = found.end;
            }
            // `^` under `re.MULTILINE`: the next candidate is the next line.
            const newline = std.mem.findScalarPos(u8, text, pos, '\n') orelse break;
            pos = newline + 1;
        }

        module.callbacks = callbacks.items;
        module.initializers = initializers.items;
        return callbacks.items.len > 0;
    }

    /// Derives a module name from a path relative to the test directory.
    ///
    /// - `self`: the generator.
    /// - `path`: e.g. `refs/branches/create.c`.
    /// - Returns: e.g. `refs_branches_create`; propagates allocation failure.
    fn moduleName(self: *Self, path: []const u8) ![]const u8 {
        const stem = path[0 .. path.len - ".c".len];
        const joined = try std.mem.replaceOwned(u8, self.allocator, stem, std.Io.Dir.path.sep_str, "_");
        return std.mem.replaceOwned(u8, self.allocator, joined, "-", "_");
    }

    /// Wraps each callback as an optional, for the one-suite-per-initializer
    /// loop in `renderSuite`.
    ///
    /// - `self`: the generator.
    /// - `callbacks`: the initializers.
    /// - Returns: the same callbacks as optionals; propagates allocation failure.
    fn optionals(self: *Self, callbacks: []const Callback) ![]const ?Callback {
        const out = try self.allocator.alloc(?Callback, callbacks.len);
        for (callbacks, out) |cb, *slot| slot.* = cb;
        return out;
    }

    /// Writes one `clar_suite` initializer, as `Module.InfoTemplate` does.
    ///
    /// - `self`: the generator.
    /// - `w`: the output.
    /// - `module`: the module.
    /// - `clean`: the module's clean name.
    /// - `initializer`: the suite's initializer, or null for none.
    /// - Returns: nothing; propagates write failure.
    fn writeInfo(self: *Self, w: *std.Io.Writer, module: *const Module, clean: []const u8, initializer: ?Callback) !void {
        var name = clean;
        if (initializer) |init_cb| {
            if (std.mem.startsWith(u8, init_cb.short_name, "initialize_")) {
                const variant = try std.mem.replaceOwned(u8, self.allocator, init_cb.short_name["initialize_".len..], "_", " ");
                name = try self.allocator.print("{s} ({s})", .{ clean, variant });
            }
        }

        try w.print("\n    {{\n        \"{s}\",\n    ", .{name});
        try writeOptionalCallback(w, initializer);
        try w.writeAll(",\n    ");
        try writeOptionalCallback(w, module.cleanup);
        try w.print(",\n        _clar_cb_{s}, {d}, {d}\n    }}", .{
            module.name,
            module.callbacks.len,
            @intFromBool(module.enabled),
        });
    }

    /// Writes the `extern` declarations, as `Module.DeclarationTemplate` does.
    ///
    /// - `w`: the output.
    /// - `module`: the module.
    /// - Returns: nothing; propagates write failure.
    fn writeDeclarations(w: *std.Io.Writer, module: *const Module) !void {
        for (module.callbacks, 0..) |cb, i| {
            if (i > 0) try w.writeAll("\n");
            try w.print("extern {s};", .{cb.declaration});
        }
        try w.writeAll("\n");
        for (module.initializers) |cb| try w.print("extern {s};\n", .{cb.declaration});
        if (module.cleanup) |cb| try w.print("extern {s};\n", .{cb.declaration});
    }

    /// Writes a `clar_func` initializer, as `_render_callback` does.
    ///
    /// - `w`: the output.
    /// - `cb`: the callback.
    /// - Returns: nothing; propagates write failure.
    fn writeCallback(w: *std.Io.Writer, cb: Callback) !void {
        try w.print("    {{ \"{s}\", &{s} }}", .{ cb.short_name, cb.symbol });
    }

    /// Writes a `clar_func` initializer, or `{ NULL, NULL }` for none.
    ///
    /// - `w`: the output.
    /// - `cb`: the callback, or null.
    /// - Returns: nothing; propagates write failure.
    fn writeOptionalCallback(w: *std.Io.Writer, cb: ?Callback) !void {
        if (cb) |some| return writeCallback(w, some);
        try w.writeAll("    { NULL, NULL }");
    }

    /// Matches the test-function pattern at `pos`, which must be a line start.
    ///
    /// - `text`: the comment-stripped source.
    /// - `pos`: where to try the match.
    /// - `prefix`: `test_<module>__`.
    /// - Returns: the callback and the offset just past the `{`, or null.
    fn matchTest(text: []const u8, pos: usize, prefix: []const u8) ?struct { callback: Callback, end: usize } {
        var i = pos;
        if (!std.mem.startsWith(u8, text[i..], "void")) return null;
        i += "void".len;

        const after_void = i;
        i = skipSpace(text, i);
        if (i == after_void) return null;

        const symbol_start = i;
        if (!std.mem.startsWith(u8, text[i..], prefix)) return null;
        i += prefix.len;
        const short_start = i;
        while (i < text.len and isWord(text[i])) i += 1;
        if (i == short_start) return null;
        const symbol_end = i;

        i = skipSpace(text, i);
        if (i >= text.len or text[i] != '(') return null;
        i = skipSpace(text, i + 1);
        if (!std.mem.startsWith(u8, text[i..], "void")) return null;
        i = skipSpace(text, i + "void".len);
        if (i >= text.len or text[i] != ')') return null;
        const declaration_end = i + 1;

        i = skipSpace(text, declaration_end);
        if (i >= text.len or text[i] != '{') return null;

        return .{
            .callback = .{
                .short_name = text[short_start..symbol_end],
                .declaration = text[pos..declaration_end],
                .symbol = text[symbol_start..symbol_end],
            },
            .end = i + 1,
        };
    }

    /// Removes `//` and `/* */` comments, keeping string and character
    /// literals intact, as `Module._skip_comments` does.
    ///
    /// - `self`: the generator, whose arena holds the result.
    /// - `text`: the source.
    /// - Returns: the source without comments; propagates allocation failure.
    fn skipComments(self: *Self, text: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            const rest = text[i..];
            if (std.mem.startsWith(u8, rest, "//")) {
                // `//.*?$`: up to, not including, the newline.
                i = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "/*")) {
                if (std.mem.find(u8, text[i + 2 ..], "*/")) |close| {
                    i += 2 + close + 2;
                    continue;
                }
            }
            if (text[i] == '"' or text[i] == '\'') {
                if (literalEnd(text, i)) |end| {
                    try out.appendSlice(self.allocator, text[i..end]);
                    i = end;
                    continue;
                }
            }
            try out.append(self.allocator, text[i]);
            i += 1;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Finds the end of a string or character literal starting at `start`.
    ///
    /// - `text`: the source.
    /// - `start`: the offset of the opening quote.
    /// - Returns: the offset just past the closing quote, or null when the
    ///   literal is unterminated (the regex then matches nothing there).
    fn literalEnd(text: []const u8, start: usize) ?usize {
        const quote = text[start];
        var i = start + 1;
        while (i < text.len) {
            if (text[i] == '\\') {
                // `\\.` under `re.DOTALL`: any escaped character, newline too.
                if (i + 1 >= text.len) return null;
                i += 2;
                continue;
            }
            if (text[i] == quote) return i + 1;
            i += 1;
        }
        return null;
    }

    fn skipSpace(text: []const u8, start: usize) usize {
        var i = start;
        while (i < text.len and isSpace(text[i])) i += 1;
        return i;
    }

    fn isSpace(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
            else => false,
        };
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn moduleLessThan(_: void, lhs: Module, rhs: Module) bool {
        return std.mem.order(u8, lhs.name, rhs.name) == .lt;
    }
};

/// Entry point: parses the `generate.py` options and writes both files.
///
/// - `init`: process capabilities supplied by the runtime (allocator, IO, args).
/// - Returns: nothing on success; propagates usage, read and write failures.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var output: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var excluded: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f")) continue;
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-x")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            if (arg[1] == 'o') output = args[i] else try excluded.append(init.arena.allocator(), args[i]);
            continue;
        }
        // `generate.py` also accepts `-x<prefix>` without the space.
        if (std.mem.startsWith(u8, arg, "-x")) {
            try excluded.append(init.arena.allocator(), arg[2..]);
            continue;
        }
        if (path != null) return error.MoreThanOnePath;
        path = arg;
    }

    const test_path = path orelse ".";
    const out_path = output orelse test_path;

    var generator = try ClarGenerate.init(init.gpa, init.io);
    defer generator.deinit();

    var dir = try std.Io.Dir.cwd().openDir(init.io, test_path, .{ .iterate = true });
    defer dir.close(init.io);
    try generator.load(dir);
    try generator.disable(excluded.items);

    const suite = try generator.renderSuite();
    const header = try generator.renderHeader();

    var out_dir = try std.Io.Dir.cwd().openDir(init.io, out_path, .{});
    defer out_dir.close(init.io);
    try out_dir.writeFile(init.io, .{ .sub_path = "clar.suite", .data = suite });
    try out_dir.writeFile(init.io, .{ .sub_path = "clar_suite.h", .data = header });
}

// -----------------------------------------------------------------------------
// Unit Tests

test "comments are stripped but literals kept" {
    var generator = try ClarGenerate.init(std.testing.allocator, std.testing.io);
    defer generator.deinit();
    generator.allocator = generator.arena.allocator();

    const out = try generator.skipComments("a // x\nb /* y */ c \"// z\" '/*'");
    try std.testing.expectEqualStrings("a \nb  c \"// z\" '/*'", out);
}

test "only line-start test functions of the module match" {
    var generator = try ClarGenerate.init(std.testing.allocator, std.testing.io);
    defer generator.deinit();
    generator.allocator = generator.arena.allocator();

    var module = Module{ .name = "core_buf" };
    const source =
        \\void test_core_buf__initialize(void) { }
        \\void test_core_buf__cleanup(void) { }
        \\void test_core_buf__append(void)
        \\{
        \\}
        \\ void test_core_buf__indented(void) { }
        \\static void test_core_buf__static(void) { }
        \\void test_core_other__x(void) { }
        \\/* void test_core_buf__commented(void) { } */
        \\void test_core_buf__args(int x) { }
    ;
    try std.testing.expect(try generator.parse(&module, source));
    try std.testing.expectEqual(1, module.callbacks.len);
    try std.testing.expectEqualStrings("append", module.callbacks[0].short_name);
    try std.testing.expectEqualStrings("void test_core_buf__append(void)", module.callbacks[0].declaration);
    try std.testing.expectEqual(1, module.initializers.len);
    try std.testing.expectEqualStrings("test_core_buf__cleanup", module.cleanup.?.symbol);
}
