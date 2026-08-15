//! Test anchor for the WebSocket server process tests (browser-launch zombie
//! reaping). Module root must be the repo root (not src/): server.zig's
//! @embedFile of apps/web/* via web_assets.zig escapes a src/-rooted module
//! — see damas_root.zig for the same constraint. The test blocks live in
//! src/runtime/websocket/server.zig.
comptime {
    _ = @import("src/runtime/websocket/server.zig");
}
