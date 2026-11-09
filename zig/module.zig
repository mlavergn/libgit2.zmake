//! Barrel for the host tools the build runs.
//!
//! Each tool is built from its own file as a separate executable; this barrel
//! exists so their unit tests run with `zig build test`.

const std = @import("std");

/// The port of clar's `generate.py`.
pub const ClarGenerate = @import("clar_generate.zig").ClarGenerate;
/// Restores the fixture file modes `zig fetch` drops.
pub const ClarFixtures = @import("clar_fixtures.zig").ClarFixtures;

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
    _ = @import("clar_generate.zig");
    _ = @import("clar_fixtures.zig");
}
