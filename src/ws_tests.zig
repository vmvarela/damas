//! Test aggregator for the WebSocket runtime (SPEC §5.3/5.4 protocol
//! dispatch). Module root must be src/. No sockets: `handleMessage` is
//! exercised directly with a fake LLM provider.

const std = @import("std");
const board_mod = @import("core/board.zig");
const move_mod = @import("core/move.zig");
const game_mod = @import("core/game.zig");
const provider = @import("llm/provider.zig");
const server = @import("runtime/websocket/server.zig");

/// Wire format of a state response (must match what the server emits).
const State = struct {
    board: [64]u8,
    turn: board_mod.Color,
    rules: game_mod.Variant,
    over: bool,
    winner: ?board_mod.Color,
    last_move: ?struct { from: u8, to: u8 },
    @"error": ?[]const u8,
};

fn parseState(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(State) {
    return std.json.parseFromSlice(State, allocator, json, .{
        .ignore_unknown_fields = true,
    });
}

/// Fake provider: always returns the first legal move for the current
/// position (works across turns, so multi-request tests stay valid).
fn fakeRequestMove(ctx: *anyopaque, allocator: std.mem.Allocator, req: provider.Request) anyerror!provider.Response {
    _ = ctx;
    const m = req.legal_moves[0];
    return .{
        .reasoning = try allocator.dupe(u8, "fake move"),
        .move = m,
    };
}

fn fakeDeinit(ctx: *anyopaque) void {
    _ = ctx;
}

const fake_vtable = provider.LlmProvider.VTable{
    .request_move = fakeRequestMove,
    .deinit = fakeDeinit,
};

/// Never dereferenced by the fake; module-level so the pointer stays valid.
var dummy_ctx: u8 = 0;

fn fakeProvider() provider.LlmProvider {
    return .{ .ctx = &dummy_ctx, .vtable = &fake_vtable };
}

test "ws: new_game returns initial state" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(board_mod.initialBoard()), &state.value.board);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    // new_game without a "rules" field defaults to English.
    try std.testing.expectEqual(game_mod.Variant.english, state.value.rules);
    try std.testing.expect(!state.value.over);
    try std.testing.expect(state.value.winner == null);
    try std.testing.expect(state.value.last_move == null);
    try std.testing.expect(state.value.@"error" == null);
}

test "ws: new_game honors the requested rules variant" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"spanish\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqual(game_mod.Variant.spanish, state.value.rules);
    try std.testing.expect(state.value.@"error" == null);

    // Unknown variant falls back to the server's default (English here).
    const resp2 = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"bogus\"}", .english);
    defer allocator.free(resp2);
    var state2 = try parseState(allocator, resp2);
    defer state2.deinit();
    try std.testing.expectEqual(game_mod.Variant.english, state2.value.rules);
}

test "ws: new_game without rules uses the server default variant" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    // Server started with --rules spanish: a new_game without "rules" stays
    // Spanish, and an invalid value also falls back to the server default.
    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\"}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();
    try std.testing.expectEqual(game_mod.Variant.spanish, state.value.rules);
    try std.testing.expect(state.value.@"error" == null);

    const resp2 = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"bogus\"}", .spanish);
    defer allocator.free(resp2);
    var state2 = try parseState(allocator, resp2);
    defer state2.deinit();
    try std.testing.expectEqual(game_mod.Variant.spanish, state2.value.rules);

    // An explicit valid value still wins over the server default.
    const resp3 = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"english\"}", .spanish);
    defer allocator.free(resp3);
    var state3 = try parseState(allocator, resp3);
    defer state3.deinit();
    try std.testing.expectEqual(game_mod.Variant.english, state3.value.rules);
}

test "ws: make_move applies a legal move" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    const m = moves.slice()[0];

    const body = try std.fmt.allocPrint(allocator, "{{\"action\":\"make_move\",\"from\":{d},\"to\":{d}}}", .{ m.from, m.to });
    defer allocator.free(body);
    const resp = try server.handleMessage(allocator, game, &conn, body, .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    const lm = state.value.last_move orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(m.from, lm.from);
    try std.testing.expectEqual(m.to, lm.to);

    // Board matches a fresh game with the same move applied.
    var expected = try game_mod.Game.init(allocator);
    defer expected.deinit();
    try std.testing.expect(expected.applyMove(m));
    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(expected.board), &state.value.board);
}

test "ws: illegal make_move sets error and leaves the board unchanged" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":0,\"to\":1}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" != null);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(board_mod.initialBoard()), &state.value.board);
}

test "ws: compute_minimax applies the engine move" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"compute_minimax\",\"time_limit_ms\":1}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    const lm = state.value.last_move orelse return error.TestUnexpectedResult;

    // The move must be legal in the initial position, and the board must
    // match a fresh game with that authoritative move applied.
    var fresh = try game_mod.Game.init(allocator);
    defer fresh.deinit();
    var moves = move_mod.MoveList{};
    fresh.generateMoves(&moves);
    var found: ?move_mod.Move = null;
    for (moves.slice()) |c| {
        if (c.from == lm.from and c.to == lm.to) {
            found = c;
            break;
        }
    }
    const authoritative = found orelse return error.TestUnexpectedResult;
    try std.testing.expect(fresh.applyMove(authoritative));
    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(fresh.board), &state.value.board);
}

test "ws: compute_minimax in a spanish game keeps the variant" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    const new_resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"spanish\"}", .english);
    defer allocator.free(new_resp);
    var new_state = try parseState(allocator, new_resp);
    defer new_state.deinit();
    try std.testing.expectEqual(game_mod.Variant.spanish, new_state.value.rules);

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"compute_minimax\",\"time_limit_ms\":50}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    try std.testing.expect(state.value.last_move != null);
    // The variant survives the engine move: still a spanish game.
    try std.testing.expectEqual(game_mod.Variant.spanish, state.value.rules);
}

test "ws: request_llm applies the provider move" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{ .provider = fakeProvider() };

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\",\"model\":\"test-model\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    try std.testing.expect(state.value.last_move != null);

    var fresh = try game_mod.Game.init(allocator);
    defer fresh.deinit();
    var moves = move_mod.MoveList{};
    fresh.generateMoves(&moves);
    const lm = state.value.last_move.?;
    var found = false;
    for (moves.slice()) |c| {
        if (c.from == lm.from and c.to == lm.to) found = true;
    }
    try std.testing.expect(found);
    // Fake provider always plays legal_moves[0]; assert that coupling explicitly
    // so a change to the fake fails loudly instead of silently mis-asserting.
    try std.testing.expectEqual(moves.slice()[0].from, lm.from);
    try std.testing.expectEqual(moves.slice()[0].to, lm.to);
    try std.testing.expect(fresh.applyMove(moves.slice()[0]));
    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(fresh.board), &state.value.board);
}

test "ws: malformed frames return an error, no crash" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    for ([_][]const u8{
        "not json",
        "{\"action\":42}",
        "{}",
        "123",
        "[]",
        "\"text\"",
        "null",
    }) |frame| {
        const resp = try server.handleMessage(allocator, game, &conn, frame, .english);
        defer allocator.free(resp);
        var state = try parseState(allocator, resp);
        defer state.deinit();
        try std.testing.expect(state.value.@"error" != null);
        try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    }
}

test "ws: unknown action returns an error" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{};

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"explode\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();
    try std.testing.expect(state.value.@"error" != null);
}

fn failProviderBuild(allocator: std.mem.Allocator, model: []const u8) anyerror!provider.LlmProvider {
    _ = allocator;
    _ = model;
    return error.MissingApiKey;
}

test "ws: request_llm without a provider returns an error response" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{ .build_provider = failProviderBuild };

    const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\",\"model\":\"x\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" != null);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
}

var build_calls: usize = 0;

fn countingBuild(allocator: std.mem.Allocator, model: []const u8) anyerror!provider.LlmProvider {
    _ = allocator;
    _ = model;
    build_calls += 1;
    return fakeProvider();
}

test "ws: provider is built once and cached across requests" {
    const allocator = std.testing.allocator;
    build_calls = 0;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = server.ConnState{ .build_provider = countingBuild };

    for (0..2) |_| {
        const resp = try server.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\"}", .english);
        defer allocator.free(resp);
        var state = try parseState(allocator, resp);
        defer state.deinit();
        try std.testing.expect(state.value.@"error" == null);
    }
    try std.testing.expectEqual(@as(usize, 1), build_calls);
}
