//! Headless WebSocket server entry point (SPEC §5). Port from DZ_WS_PORT,
//! default 8080. argv-free (std.os.argv removed in 0.16-dev).

const std = @import("std");
const server = @import("server.zig");

pub fn main() !void {
    const port = getPort();
    std.debug.print("listening on ws://127.0.0.1:{d}\n", .{port});
    try server.serve(port);
}

/// DZ_WS_PORT env override; 8080 when unset or not a valid u16.
/// ponytail: std.process.getEnvVar was removed in this build; reuse the
/// std.c.environ scan from utils/config.zig (getPosix avoids allocating).
fn getPort() u16 {
    var count: usize = 0;
    while (std.c.environ[count]) |_| count += 1;
    const env: std.process.Environ = .{ .block = .{ .slice = std.c.environ[0..count :null] } };
    const val = std.process.Environ.getPosix(env, "DZ_WS_PORT") orelse return 8080;
    return std.fmt.parseInt(u16, val, 10) catch 8080;
}
