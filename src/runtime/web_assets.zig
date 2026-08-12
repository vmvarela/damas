//! Embedded web frontend (apps/web/*) served by server.zig's plain-HTTP arm.
//!
//! The @embedFile calls live INSIDE a function on purpose: @embedFile resolves
//! relative to this file and must stay within the module's package path. The
//! damas-z exe module is rooted at the repo root, so "../../apps/web" resolves
//! fine there; the ws_tests module is rooted at src/ where the same paths
//! would be "outside package path" — but function bodies are analyzed lazily,
//! and the tests never call `get`, so the embeds are never compiled in that
//! module. apps/web stays on disk as source of truth.

const std = @import("std");

pub const Asset = struct {
    content: []const u8,
    content_type: []const u8,
};

/// Embedded asset for `path` (request target), or null for 404.
pub fn get(path: []const u8) ?Asset {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))
        return .{
            .content = @embedFile("../../apps/web/index.html"),
            .content_type = "text/html; charset=utf-8",
        };
    if (std.mem.eql(u8, path, "/style.css"))
        return .{
            .content = @embedFile("../../apps/web/style.css"),
            .content_type = "text/css; charset=utf-8",
        };
    if (std.mem.eql(u8, path, "/app.js"))
        return .{
            .content = @embedFile("../../apps/web/app.js"),
            .content_type = "application/javascript",
        };
    return null;
}
