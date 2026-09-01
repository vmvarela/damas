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

/// Provider default for request_llm (from --provider); null = auto-detect.
/// Set once in serveWeb (single-threaded, before the accept loop); read-only
/// after, from spawned connection threads.
var g_default_provider: ?[]const u8 = null;

/// Default provider builder injected into `protocol.ConnState` by serveGame:
/// the factory-backed path that used to be handleMessage's implicit default.
/// Keeps the factory (and its HTTP deps) out of the pure protocol layer.
fn defaultProvider(allocator: std.mem.Allocator, model: []const u8) anyerror!provider_mod.LlmProvider {
    return factory.fromConfig(allocator, .{ .provider = g_default_provider, .model = model });
}

/// Accept loop on loopback:port. Each connection gets a fresh game and is
/// served in its own thread; a long-lived WebSocket must not starve the
/// static HTTP serving (browsers load assets while the WS is open).
/// ponytail: thread-per-connection with hard cap; thread pool still YAGNI.
/// std.Io.Threaded is thread-safe for blocking net ops from spawned threads.
const max_connection_threads: u32 = 16;

const ConnectionSlots = struct {
    active: std.atomic.Value(u32) = .init(0),
    max: u32,

    fn init(max: u32) ConnectionSlots {
        return .{ .max = max };
    }

    fn tryAcquire(self: *ConnectionSlots) bool {
        const prev = self.active.fetchAdd(1, .acq_rel);
        if (prev >= self.max) {
            _ = self.active.fetchSub(1, .acq_rel);
            return false;
        }
        return true;
    }

    fn release(self: *ConnectionSlots) void {
        const prev = self.active.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }
};

pub fn serve(port: u16, default_rules: game_mod.Variant) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try addr.listen(io, .{ .kernel_backlog = 16 });
    defer server.deinit(io);
    const listen_port = server.socket.address.getPort();
    var slots = ConnectionSlots.init(max_connection_threads);
    while (true) {
        // Transient accept errors (EMFILE etc.) shouldn't kill the whole server.
        const stream = server.accept(io) catch continue;
        if (!slots.tryAcquire()) {
            stream.close(io);
            continue;
        }
        const t = std.Thread.spawn(.{}, handleConnectionThread, .{ io, stream, default_rules, listen_port, &slots }) catch {
            slots.release();
            stream.close(io); // spawn failure: drop the connection, keep serving
            continue;
        };
        t.detach(); // fire-and-forget; the connection frees its own resources
    }
}

fn handleConnectionThread(
    io: std.Io,
    stream: std.Io.net.Stream,
    default_rules: game_mod.Variant,
    listen_port: u16,
    slots: *ConnectionSlots,
) void {
    defer slots.release();
    handleConnection(io, stream, default_rules, listen_port) catch {};
}

/// Web mode: static frontend + WebSocket on the same port, browser opened.
/// Set DZ_NO_BROWSER=1 to skip launching a browser (CI, headless).
pub fn serveWeb(port: u16, default_rules: game_mod.Variant, default_provider: ?[]const u8) !void {
    g_default_provider = default_provider;
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
    autoReapChildren();
    // global_single_threaded can't spawn (allocator is `.failing`), so build a
    // local Threaded with a real allocator and the process environ.
    const env = config_mod.processEnviron() orelse return;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = env });
    defer threaded.deinit();
    // ponytail: no wait() — reaping would block the accept loop; SIGCHLD is
    // ignored (autoReapChildren above) so the kernel reaps the launcher for us.
    _ = std.process.spawn(threaded.io(), .{ .argv = &.{ launcher, url } }) catch {
        std.debug.print("Abriendo {s} en tu navegador\n", .{url});
    };
}

/// POSIX: ignore SIGCHLD so the kernel auto-reaps the fire-and-forget browser
/// launcher. Comptime-pruned everywhere but macOS/Linux (SIG is `void` on
/// Windows). Process-wide and permanent: do not add `Child.wait()` while this
/// is set — std panics on the resulting ECHILD.
fn autoReapChildren() void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    _ = std.posix.sigaction(std.posix.SIG.CHLD, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
}

test "server: browser-launch children are auto-reaped on POSIX" {
    if (builtin.os.tag == .windows) return; // fix is POSIX-only
    // Save the current disposition: the test must leave the process exactly
    // as it found it (the server sets SIG_IGN once, for its whole lifetime).
    var prev: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.CHLD, null, &prev);
    defer std.posix.sigaction(std.posix.SIG.CHLD, &prev, null);
    autoReapChildren();

    // Spawn fire-and-forget children the way openBrowser spawns the launcher.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pids: [3]std.posix.pid_t = undefined;
    for (&pids) |*pid| {
        const child = try std.process.spawn(io, .{ .argv = &.{"true"} });
        pid.* = child.id.?;
    }
    // Give them time to exit; with SIGCHLD ignored the kernel reaps at exit.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .boot);

    // ps -o stat= prints one process-state row per pid; a zombie shows as Z.
    // Auto-reaped children are gone from the table, so ps reports nothing.
    // ponytail: ps + pipe read instead of waitpid — Child.wait() treats the
    // ECHILD that SIG_IGN produces as a programmer bug and panics.
    var argv_list: [8][]const u8 = undefined;
    var pid_args: [3][16]u8 = undefined;
    argv_list[0..4].* = .{ "ps", "-o", "stat=", "-p" };
    var n: usize = 4;
    for (pids, 0..) |pid, i| {
        argv_list[n] = try std.fmt.bufPrint(&pid_args[i], "{d}", .{pid});
        n += 1;
    }
    const ps = try std.process.spawn(io, .{
        .argv = argv_list[0..n],
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var out_buf: [4096]u8 = undefined;
    var reader = ps.stdout.?.reader(io, &out_buf);
    // readSliceShort returns < buffer.len iff EOF, so one call drains it.
    const nread = try reader.interface.readSliceShort(&out_buf);
    try std.testing.expect(std.mem.indexOfScalar(u8, out_buf[0..nread], 'Z') == null);
}

const OriginCase = enum {
    none,
    evil,
    localhost,
    loopback,
    null_origin,
    malformed,
};

fn handshakeStatusLine(origin_case: OriginCase) ![]const u8 {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .kernel_backlog = 1 });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const T = struct {
        fn run(io_t: std.Io, srv: *std.Io.net.Server, listen_port: u16) void {
            const stream = srv.accept(io_t) catch return;
            handleConnection(io_t, stream, .english, listen_port) catch {};
        }
    };
    const accept_t = try std.Thread.spawn(.{}, T.run, .{ io, &server, port });

    var connect_addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var client = try connect_addr.connect(io, .{ .mode = .stream, .protocol = .tcp });

    var out_buf: [1024]u8 = undefined;
    var client_writer = client.writer(io, &out_buf);
    switch (origin_case) {
        .none => try client_writer.interface.print(
            "GET /ws HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n",
            .{port},
        ),
        .evil => try client_writer.interface.print(
            "GET /ws HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Origin: http://evil.test\r\n" ++
                "\r\n",
            .{port},
        ),
        .localhost => try client_writer.interface.print(
            "GET /ws HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Origin: http://localhost:{d}\r\n" ++
                "\r\n",
            .{ port, port },
        ),
        .loopback => try client_writer.interface.print(
            "GET /ws HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Origin: http://127.0.0.1:{d}\r\n" ++
                "\r\n",
            .{ port, port },
        ),
        .null_origin => try client_writer.interface.print(
            "GET /ws HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Origin: null\r\n" ++
                "\r\n",
            .{port},
        ),
        .malformed => try client_writer.interface.print(
            "GET /ws HTTP/1.1\r\n" ++
                "Host: 127.0.0.1:{d}\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Origin: ://broken\r\n" ++
                "\r\n",
            .{port},
        ),
    }
    try client_writer.interface.flush();

    var in_buf: [1024]u8 = undefined;
    var client_reader = client.reader(io, &in_buf);
    const line = try client_reader.interface.takeDelimiterExclusive('\n');
    const status = try std.testing.allocator.dupe(u8, std.mem.trim(u8, line, "\r"));

    client.close(io);
    accept_t.join();
    return status;
}

test "server: websocket handshake rejects foreign Origin" {
    const status = try handshakeStatusLine(.evil);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("HTTP/1.1 403 Forbidden", status);
}

test "server: websocket handshake allows localhost/127.0.0.1 and missing Origin" {
    const status_localhost = try handshakeStatusLine(.localhost);
    defer std.testing.allocator.free(status_localhost);
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", status_localhost);

    const status_loopback = try handshakeStatusLine(.loopback);
    defer std.testing.allocator.free(status_loopback);
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", status_loopback);

    const status_no_origin = try handshakeStatusLine(.none);
    defer std.testing.allocator.free(status_no_origin);
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", status_no_origin);
}

test "server: websocket handshake rejects null and malformed Origin" {
    const status_null = try handshakeStatusLine(.null_origin);
    defer std.testing.allocator.free(status_null);
    try std.testing.expectEqualStrings("HTTP/1.1 403 Forbidden", status_null);

    const status_malformed = try handshakeStatusLine(.malformed);
    defer std.testing.allocator.free(status_malformed);
    try std.testing.expectEqualStrings("HTTP/1.1 403 Forbidden", status_malformed);
}

test "server: connection slot counter caps active handlers" {
    var slots = ConnectionSlots.init(2);
    try std.testing.expect(slots.tryAcquire());
    try std.testing.expect(slots.tryAcquire());
    try std.testing.expect(!slots.tryAcquire());
    slots.release();
    try std.testing.expect(slots.tryAcquire());
    slots.release();
    slots.release();
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

fn requestHeader(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn defaultOriginPort(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    return null;
}

fn isLocalhostOriginHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    return false;
}

fn isAllowedWebSocketOrigin(origin_header: ?[]const u8, listen_port: u16) bool {
    // Compatibility policy: non-browser clients often omit Origin.
    const origin = origin_header orelse return true;
    if (std.mem.eql(u8, origin, "null")) return false;

    const uri = std.Uri.parse(origin) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    if (!isLocalhostOriginHost(host)) return false;

    const origin_port = uri.port orelse defaultOriginPort(uri.scheme) orelse return false;
    return origin_port == listen_port;
}

fn respondForbiddenOrigin(req: *std.http.Server.Request) !void {
    try req.respond("forbidden origin", .{
        .status = .forbidden,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream, default_rules: game_mod.Variant, listen_port: u16) !void {
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
            if (!isAllowedWebSocketOrigin(requestHeader(&req, "origin"), listen_port)) {
                try respondForbiddenOrigin(&req);
                return;
            }
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
