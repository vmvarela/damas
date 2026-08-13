//! Build anchor for damas. The module root must be the repo root (not src/)
//! so that @embedFile("../../apps/web/*") inside src/runtime/web_assets.zig
//! resolves within the package path — Zig rejects embeds/imports that escape
//! the root source file's directory. The real entry lives in src/damas.zig;
//! this mirrors the tui_root.zig pattern.

const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    try @import("src/damas.zig").main(init);
}
