//! damas-ws executable build anchor. The module root must be src/ so that
//! runtime/websocket/server.zig's relative imports (../../core/*) resolve;
//! the real entry code lives in runtime/websocket/main.zig.

pub fn main() !void {
    try @import("runtime/websocket/main.zig").main();
}
