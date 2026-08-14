//! Headless WebSocket game server (SPEC §5). One connection = one game,
//! reset by the `new_game` action. Clients send JSON text frames; every
//! action gets a state JSON response. The network shell is deliberately
//! thin: all protocol logic lives in `runtime/protocol.zig` (pure, no
//! sockets), this module only moves bytes between the socket and it.

const std = @import("std");
const builtin = @import("builtin");
const game_mod = @import("../../core/game.zig");
const config_mod = @import("../../utils/config.zig");
const factory = @import("../../llm/factory.zig");
const provider_mod = @import("../../llm/provider.zig");
const protocol = @import("../protocol.zig");
const web = @import("../web_assets.zig");

/// Default provider builder injected into `protocol.ConnState` by serveGame:
/// the factory-backed groq path that used to be handleMessage's implicit
/// default. Keeps the factory (and its HTTP deps) out of the pure protocol
/// layer.
fn defaultProvider(allocator: std.mem.Allocator, model: []const u8) anyerror!provider_mod.LlmProvider {
    return factory.fromConfig(allocator, .{ .provider = "groq", .model = model });
}

/// Accept loop on loopback:port. Each connection gets a fresh game and is
/// served in its own thread; a long-lived WebSocket must not starve the
/// static HTTP serving (browsers load assets while the WS is open).
/// ponytail: thread-per-connection, fire-and-forget; a thread pool is YAGNI
/// until connection counts matter. std.Io.Threaded is thread-safe for
/// blocking net ops from spawned threads.
pub fn serve(port: u16, default_rules: game_mod.Variant) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try addr.listen(io, .{ .kernel_backlog = 16 });
    defer server.deinit(io);
    while (true) {
        // Transient accept errors (EMFILE etc.) shouldn't kill the whole server.
        const stream = server.accept(io) catch continue;
        const t = std.Thread.spawn(.{}, handleConnection, .{ io, stream, default_rules }) catch {
            stream.close(io); // spawn failure: drop the connection, keep serving
            continue;
        };
        t.detach(); // fire-and-forget; the connection frees its own resources
    }
}

/// Web mode: static frontend + WebSocket on the same port, browser opened.
/// Set DZ_NO_BROWSER=1 to skip launching a browser (CI, headless).
pub fn serveWeb(port: u16, default_rules: game_mod.Variant) !void {
    std.debug.print("Damas web en http://127.0.0.1:{d} — Ctrl-C para salir\n", .{port});
    if (config_mod.getEnvPosix("DZ_NO_BROWSER") == null) openBrowser(port);
    try serve(port, default_rules);
}

/// Fire-and-forget `open`/`xdg-open` for the URL. Failure is non-fatal: the
/// server still runs, the URL is printed.
fn openBrowser(port: u16) void {
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port}) catch return;
    const launcher: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        .linux => "xdg-open",
        else => return,
    };
    // global_single_threaded can't spawn (allocator is `.failing`), so build a
    // local Threaded with a real allocator and the process environ.
    const env = config_mod.processEnviron() orelse return;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = env });
    defer threaded.deinit();
    // ponytail: no wait() — reaping would block the accept loop; the child may
    // linger as a zombie until the server exits. Fine.
    _ = std.process.spawn(threaded.io(), .{ .argv = &.{ launcher, url } }) catch {
        std.debug.print("Abriendo {s} en tu navegador\n", .{url});
    };
}

/// Serve one embedded asset or a 404. `writer` is the raw connection writer.
fn serveStatic(writer: *std.Io.Writer, target: []const u8, method: std.http.Method) !void {
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const asset = if (method == .GET) web.get(path) else null;
    if (asset) |a| {
        try writer.print("HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ a.content_type, a.content.len });
        try writer.writeAll(a.content);
    } else {
        try writer.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    }
    try writer.flush();
}

/// Idle read deadline: a connection with no incoming data for this long is
/// reaped (dead tab, silent handshake). Dribbling data never hits it — the
/// window only counts total silence.
/// ponytail: covers only the wait for the FIRST byte of a message; a peer
/// that sends a partial frame then stalls still parks the thread (the poll
/// gate can't interrupt inside readSmallMessage). Pre-existing behavior,
/// accepted. Also: poll-gate instead of SO_RCVTIMEO — Threaded's read path
/// maps a read timeout's EAGAIN to errnoBug, which panics the server in
/// Debug builds.
const idle_timeout_ms: i32 = 5 * 60 * 1000;

/// True if the connection has data to read, waiting up to `timeout_ms` for it.
/// Data already buffered in `reader` counts as available (frames can arrive
/// in one TCP segment). On platforms without a portable poll (windows) the
/// read just blocks, status quo.
fn waitReadable(reader: *const std.Io.Reader, fd: std.posix.fd_t, timeout_ms: i32) bool {
    if (reader.end > reader.seek) return true;
    if (builtin.os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    // poll failure: let the read surface the real error.
    const n = std.posix.poll(&fds, timeout_ms) catch return true;
    return n > 0;
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream, default_rules: game_mod.Variant) !void {
    defer stream.close(io);
    var in_buf: [65536]u8 = undefined;
    var out_buf: [65536]u8 = undefined;
    var connection_reader = stream.reader(io, &in_buf);
    var connection_writer = stream.writer(io, &out_buf);
    var srv = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    // Idle reaping also covers the handshake: a client that connects but never
    // sends a request must not park its thread forever.
    if (!waitReadable(&connection_reader.interface, stream.socket.handle, idle_timeout_ms)) return;
    var req = try srv.receiveHead();
    switch (req.upgradeRequested()) {
        .websocket => |opt_key| {
            const key = opt_key orelse return;
            var ws = try req.respondWebSocket(.{ .key = key });
            // respondWebSocket buffers the 101; flush it NOW or the client
            // waits for the handshake while we block in readSmallMessage
            // (deadlock — verified with a raw-socket client).
            try ws.flush();
            serveGame(&ws, default_rules, stream.socket.handle) catch {};
        },
        // Plain HTTP: serve the embedded frontend (apps/web/*) or 404 so
        // non-WebSocket clients don't hang.
        else => {
            try serveStatic(&connection_writer.interface, req.head.target, req.head.method);
        },
    }
}

fn serveGame(ws: *std.http.Server.WebSocket, default_rules: game_mod.Variant, fd: std.posix.fd_t) !void {
    // Default from the server's --rules flag; new_game can override.
    var game = try game_mod.Game.initRules(std.heap.page_allocator, default_rules);
    defer game.deinit();
    var conn = protocol.ConnState{ .build_provider = defaultProvider };
    defer if (conn.provider) |p| p.deinit();

    while (true) {
        // Idle reaping: close after `idle_timeout_ms` of silence. `return`
        // unwinds handleConnection's `defer stream.close`, so the thread
        // exits and the fd is freed.
        if (!waitReadable(ws.input, fd, idle_timeout_ms)) return;
        const msg = ws.readSmallMessage() catch return; // close, oversize, or protocol error
        switch (msg.opcode) {
            .ping => {
                try ws.writeMessage(msg.data, .pong);
                continue;
            },
            .text, .binary => {},
            else => return,
        }
        const resp = protocol.handleMessage(std.heap.page_allocator, game, &conn, msg.data, default_rules) catch {
            try ws.writeMessage("{\"error\":\"server error\"}", .text);
            return;
        };
        defer std.heap.page_allocator.free(resp);
        try ws.writeMessage(resp, .text);
    }
}
