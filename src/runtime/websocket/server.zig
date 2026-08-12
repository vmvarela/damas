//! Headless WebSocket game server (SPEC §5). One connection = one game,
//! reset by the `new_game` action. Clients send JSON text frames; every
//! action gets a state JSON response. The network shell is deliberately
//! thin: all protocol logic lives in `handleMessage` so tests exercise it
//! without sockets.

const std = @import("std");
const game_mod = @import("../../core/game.zig");
const board_mod = @import("../../core/board.zig");
const move_mod = @import("../../core/move.zig");
const minimax = @import("../../core/engine/minimax.zig");
const config_mod = @import("../../utils/config.zig");
const factory = @import("../../llm/factory.zig");
const provider_mod = @import("../../llm/provider.zig");
const validation = @import("../../llm/validation.zig");

const DEFAULT_LLM_MODEL = "llama-3.3-70b-versatile";

/// Per-connection state, alive for the whole connection.
pub const ConnState = struct {
    /// Most recent applied move (null until the first move is played).
    last_move: ?move_mod.Move = null,
    /// Cached LLM provider, built lazily on the first request_llm.
    /// factory dups the key/model into provider state, so building per
    /// request would leak — build once and keep. Tests inject a fake
    /// provider directly here (no network).
    provider: ?provider_mod.LlmProvider = null,
    /// Provider construction hook; null = default factory.fromConfig path.
    /// ponytail: test-only seam so "no provider" is deterministic without a
    /// GROQ_API_KEY dependency; production always leaves this null.
    build_provider: ?*const fn (allocator: std.mem.Allocator, model: []const u8) anyerror!provider_mod.LlmProvider = null,
};

/// Handle one client frame and return the response JSON (caller owns).
pub fn handleMessage(
    allocator: std.mem.Allocator,
    game: *game_mod.Game,
    conn: *ConnState,
    json: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch {
        return stateJson(allocator, game, conn, "malformed JSON");
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const action = fieldString(root, "action") orelse
        return stateJson(allocator, game, conn, "missing or invalid action");

    if (std.mem.eql(u8, action, "new_game")) {
        game.* = .{
            .board = board_mod.initialBoard(),
            .turn = .white,
            .allocator = game.allocator,
        };
        conn.last_move = null;
        return stateJson(allocator, game, conn, null);
    }

    if (std.mem.eql(u8, action, "make_move")) {
        const from = fieldU8(root, "from") orelse
            return stateJson(allocator, game, conn, "invalid from");
        const to = fieldU8(root, "to") orelse
            return stateJson(allocator, game, conn, "invalid to");
        var moves = move_mod.MoveList{};
        game.generateMoves(&moves);
        var found: ?move_mod.Move = null;
        for (moves.slice()) |m| {
            if (m.from == from and m.to == to) {
                found = m;
                break;
            }
        }
        const m = found orelse return stateJson(allocator, game, conn, "not a legal move");
        if (!game.applyMove(m)) return stateJson(allocator, game, conn, "not a legal move");
        conn.last_move = m;
        return stateJson(allocator, game, conn, null);
    }

    if (std.mem.eql(u8, action, "compute_minimax")) {
        const ms = fieldU32(root, "time_limit_ms") orelse 1000;
        const result = minimax.search(game.board, game.turn, ms, allocator) catch
            return stateJson(allocator, game, conn, "search failed");
        if (!game.applyMove(result.move))
            return stateJson(allocator, game, conn, "engine produced an illegal move");
        conn.last_move = result.move;
        return stateJson(allocator, game, conn, null);
    }

    if (std.mem.eql(u8, action, "request_llm")) {
        const model = fieldString(root, "model") orelse DEFAULT_LLM_MODEL;
        const prov = getProvider(allocator, conn, model) orelse
            return stateJson(allocator, game, conn, "LLM provider unavailable");
        var moves = move_mod.MoveList{};
        game.generateMoves(&moves);
        const resp = validation.requestValidMove(allocator, prov, game.board, moves.slice()) catch
            return stateJson(allocator, game, conn, "LLM did not produce a legal move");
        defer allocator.free(resp.reasoning);
        if (!game.applyMove(resp.move))
            return stateJson(allocator, game, conn, "LLM produced an illegal move");
        conn.last_move = resp.move;
        return stateJson(allocator, game, conn, null);
    }

    return stateJson(allocator, game, conn, "unknown action");
}

/// Return the connection's cached provider, building it on first use.
/// null means construction failed (e.g. missing GROQ_API_KEY).
/// ponytail: first model wins — a later request_llm with a different model
/// keeps the first provider; rebuild per model only if it ever matters.
fn getProvider(
    allocator: std.mem.Allocator,
    conn: *ConnState,
    model: []const u8,
) ?provider_mod.LlmProvider {
    if (conn.provider) |p| return p;
    const prov = if (conn.build_provider) |build|
        build(allocator, model) catch return null
    else
        factory.fromConfig(allocator, .{ .provider = "groq", .model = model }) catch return null;
    conn.provider = prov;
    return prov;
}

const LastMove = struct { from: u8, to: u8 };

const StateResponse = struct {
    board: [64]u8,
    turn: board_mod.Color,
    over: bool,
    winner: ?board_mod.Color,
    last_move: ?LastMove,
    @"error": ?[]const u8, // `error` is a Zig keyword; @"" names the JSON field.
};

/// Full state JSON: `{"board":...,"turn":...,"over":...,"winner":...,"last_move":...,"error":...}`.
fn stateJson(
    allocator: std.mem.Allocator,
    game: *game_mod.Game,
    conn: *ConnState,
    err: ?[]const u8,
) ![]u8 {
    const last_move: ?LastMove = if (conn.last_move) |m|
        .{ .from = m.from, .to = m.to }
    else
        null;
    const resp = StateResponse{
        .board = board_mod.boardToAscii(game.board),
        .turn = game.turn,
        .over = game.isGameOver(),
        .winner = game.winner(),
        .last_move = last_move,
        .@"error" = err,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(resp, .{})});
    return out.toOwnedSlice();
}

/// Object field as a string, null if absent or not a string.
fn fieldString(root: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = root.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn fieldU8(root: std.json.ObjectMap, name: []const u8) ?u8 {
    const v = root.get(name) orelse return null;
    if (v != .integer) return null;
    return std.math.cast(u8, v.integer);
}

fn fieldU32(root: std.json.ObjectMap, name: []const u8) ?u32 {
    const v = root.get(name) orelse return null;
    if (v != .integer) return null;
    return std.math.cast(u32, v.integer);
}

/// Blocking accept loop on loopback:port. Each connection gets a fresh game
/// and is served serially until it closes.
/// ponytail: single-threaded, per-connection serialized; add threads/io
/// events when concurrency matters.
pub fn serve(port: u16) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try addr.listen(io, .{ .kernel_backlog = 16 });
    defer server.deinit(io);
    while (true) {
        // Transient accept errors (EMFILE etc.) shouldn't kill the whole server.
        const stream = server.accept(io) catch continue;
        handleConnection(io, stream) catch {};
    }
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var in_buf: [65536]u8 = undefined;
    var out_buf: [65536]u8 = undefined;
    var connection_reader = stream.reader(io, &in_buf);
    var connection_writer = stream.writer(io, &out_buf);
    var srv = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    var req = try srv.receiveHead();
    switch (req.upgradeRequested()) {
        .websocket => |opt_key| {
            const key = opt_key orelse return;
            var ws = try req.respondWebSocket(.{ .key = key });
            // respondWebSocket buffers the 101; flush it NOW or the client
            // waits for the handshake while we block in readSmallMessage
            // (deadlock — verified with a raw-socket client).
            try ws.flush();
            serveGame(&ws) catch {};
        },
        // Plain HTTP: answer so non-WebSocket clients don't hang.
        else => {
            try connection_writer.interface.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
            try connection_writer.interface.flush();
        },
    }
}

fn serveGame(ws: *std.http.Server.WebSocket) !void {
    var game = try game_mod.Game.init(std.heap.page_allocator);
    defer game.deinit();
    var conn = ConnState{};
    defer if (conn.provider) |p| p.deinit();

    while (true) {
        const msg = ws.readSmallMessage() catch return; // close, oversize, or protocol error
        switch (msg.opcode) {
            .ping => {
                try ws.writeMessage(msg.data, .pong);
                continue;
            },
            .text, .binary => {},
            else => return,
        }
        const resp = handleMessage(std.heap.page_allocator, game, &conn, msg.data) catch {
            try ws.writeMessage("{\"error\":\"server error\"}", .text);
            return;
        };
        defer std.heap.page_allocator.free(resp);
        try ws.writeMessage(resp, .text);
    }
}
