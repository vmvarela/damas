//! Pure WebSocket game protocol (SPEC §5). One connection = one game, reset
//! by the `new_game` action. Clients send JSON text frames; every action gets
//! a state JSON response. No sockets, no HTTP, no provider factory: the
//! transport layer feeds `handleMessage` and injects the LLM provider
//! constructor via `ConnState.build_provider`, so this module is reusable
//! from WASM.

const std = @import("std");
const game_mod = @import("../core/game.zig");
const board_mod = @import("../core/board.zig");
const move_mod = @import("../core/move.zig");
const minimax = @import("../core/engine/minimax.zig");
const provider_mod = @import("../llm/provider.zig");
const validation = @import("../llm/validation.zig");

pub const DEFAULT_LLM_MODEL = "llama-3.3-70b-versatile";

/// Per-connection state, alive for the whole connection.
pub const ConnState = struct {
    /// Most recent applied move (null until the first move is played).
    last_move: ?move_mod.Move = null,
    /// Cached LLM provider, built lazily on the first request_llm.
    /// factory dups the key/model into provider state, so building per
    /// request would leak — build once and keep. Tests inject a fake
    /// provider directly here (no network).
    provider: ?provider_mod.LlmProvider = null,
    /// Provider construction hook, injected by the transport layer: the
    /// server injects a factory-backed builder in serveGame; tests inject
    /// fakes. null = provider unavailable.
    build_provider: ?*const fn (allocator: std.mem.Allocator, model: []const u8) anyerror!provider_mod.LlmProvider = null,
};

/// Handle one client frame and return the response JSON (caller owns).
/// `default_rules` is the variant applied when a new_game request has no
/// (or an invalid) "rules" field — set by the server's `--rules` flag.
pub fn handleMessage(
    allocator: std.mem.Allocator,
    game: *game_mod.Game,
    conn: *ConnState,
    json: []const u8,
    default_rules: game_mod.Variant,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch {
        return stateJson(allocator, game, conn, "malformed JSON");
    };
    defer parsed.deinit();

    // Valid JSON that isn't an object (e.g. `123`, `[]`, `"x"`) must not hit
    // the union field access below — that would panic and kill the server.
    if (parsed.value != .object)
        return stateJson(allocator, game, conn, "expected JSON object");
    const root = parsed.value.object;
    const action = fieldString(root, "action") orelse
        return stateJson(allocator, game, conn, "missing or invalid action");

    if (std.mem.eql(u8, action, "new_game")) {
        // Optional "rules" field; a missing, non-string, or unknown value
        // falls back to the server's default variant (the --rules flag).
        var variant = default_rules;
        if (root.get("rules")) |v| {
            if (v == .string) variant = variantFromString(v.string, default_rules);
        }
        // The literal below resets position_history to null; free the map from
        // the previous game first (it holds the repetition counts).
        if (game.position_history) |*h| h.deinit();
        game.* = .{
            .board = board_mod.initialBoard(),
            .turn = .white,
            .rules = variant,
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
        // Cap the client-supplied budget: u32 max (~49 days) would pin a
        // search thread forever; 0 means "no limit" in timer.zig, so floor
        // at 1ms to keep the deadline finite.
        const ms = @max(@min(fieldU32(root, "time_limit_ms") orelse 1000, 30_000), 1);
        const result = minimax.search(game.board, game.turn, ms, allocator, game.rules) catch
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
/// null means construction failed (e.g. missing GROQ_API_KEY) or no builder
/// was injected.
/// ponytail: first model wins — a later request_llm with a different model
/// keeps the first provider; rebuild per model only if it ever matters.
fn getProvider(
    allocator: std.mem.Allocator,
    conn: *ConnState,
    model: []const u8,
) ?provider_mod.LlmProvider {
    if (conn.provider) |p| return p;
    const build = conn.build_provider orelse return null;
    const prov = build(allocator, model) catch return null;
    conn.provider = prov;
    return prov;
}

const LastMove = struct { from: u8, to: u8, captured: u8 };

const StateResponse = struct {
    board: [64]u8,
    turn: board_mod.Color,
    /// Active rule variant; std.json stringifies the enum as
    /// "english"/"spanish" so the frontend knows which rules apply.
    rules: game_mod.Variant,
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
        .{ .from = m.from, .to = m.to, .captured = m.num_captured }
    else
        null;
    const resp = StateResponse{
        .board = board_mod.boardToAscii(game.board),
        .turn = game.turn,
        .rules = game.rules,
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

/// Strict "rules" parsing for new_game: unknown values fall back to the
/// server's default variant (the --rules flag), unlike config parseVariant
/// which always falls back to English.
fn variantFromString(s: []const u8, default_rules: game_mod.Variant) game_mod.Variant {
    if (std.mem.eql(u8, s, "english")) return .english;
    if (std.mem.eql(u8, s, "spanish")) return .spanish;
    return default_rules;
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
