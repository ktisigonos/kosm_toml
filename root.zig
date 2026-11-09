//! TOML: the `toml` adapter, for alacritty, vicinae themes and every other `.toml` config.

const std = @import("std");

/// Reads and writes `.toml` files.
pub const adapter = @import("adapter.zig").adapter;

test {
    std.testing.refAllDecls(@This());
    _ = @import("adapter.zig");
    _ = @import("Parser.zig");
}
