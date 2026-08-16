//! Test aggregator for the WebSocket runtime (SPEC §5.3/5.4 protocol
//! dispatch). Module root must be src/. No sockets: `handleMessage` is
//! exercised directly with a fake LLM provider.

const std = @import("std");
const board_mod = @import("core/board.zig");
const move_mod = @import("core/move.zig");
const game_mod = @import("core/game.zig");
const provider = @import("llm/provider.zig");
const protocol = @import("runtime/protocol.zig");

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

/// Wire format of a legal_moves response (must match what the server emits).
const LegalMove = struct { from: u8, to: u8, captured: []const u8 };

const LegalMovesResp = struct {
    moves: []const LegalMove,
    @"error": ?[]const u8,
};

fn parseLegalMoves(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(LegalMovesResp) {
    return std.json.parseFromSlice(LegalMovesResp, allocator, json, .{
        .ignore_unknown_fields = true,
    });
}

/// Issue #24 position: white man on 4, black king on 9, black man on 18,
/// landing squares 13 and 22 free, white to move, Spanish. White's only
/// legal move is the two-jump chain 4 -> 13 (takes 9) -> 22 (takes 18).
fn issue24Game(allocator: std.mem.Allocator) !*game_mod.Game {
    var game = try game_mod.Game.init(allocator);
    game.rules = .spanish;
    game.board = [_]board_mod.Piece{.empty} ** 32;
    game.board[4] = .white_pawn;
    game.board[9] = .black_king;
    game.board[18] = .black_pawn;
    return game;
}

/// Convergent-chains position (verified against the generator): white king
/// on 4, black pawns on 6, 9, 14, 19, Spanish. The flying king produces two
/// chains sharing from=4 AND to=2, differing only in the middle capture:
///   A: cap 9 (2,2) -> land 18 (4,4); cap 14 (3,5) -> land 11 (2,6); cap 6
///      (1,5) -> land (0,4)=2. captured [9,14,6].
///   B: cap 9 -> land 22 (5,5); cap 19 (4,6) -> land 15 (3,7); cap 6 (1,5)
///      -> land (0,4)=2. captured [9,19,6].
/// Both survive the capture laws (3 pieces each, 0 kings each), so from/to
/// alone is ambiguous — captured[] must pin the exact chain.
fn convergentGame(allocator: std.mem.Allocator) !*game_mod.Game {
    var game = try game_mod.Game.init(allocator);
    game.rules = .spanish;
    game.board = [_]board_mod.Piece{.empty} ** 32;
    game.board[4] = .white_king;
    game.board[6] = .black_pawn;
    game.board[9] = .black_pawn;
    game.board[14] = .black_pawn;
    game.board[19] = .black_pawn;
    return game;
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
    .requestMove = fakeRequestMove,
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
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\"}", .english);
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
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"spanish\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqual(game_mod.Variant.spanish, state.value.rules);
    try std.testing.expect(state.value.@"error" == null);

    // Unknown variant falls back to the server's default (English here).
    const resp2 = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"bogus\"}", .english);
    defer allocator.free(resp2);
    var state2 = try parseState(allocator, resp2);
    defer state2.deinit();
    try std.testing.expectEqual(game_mod.Variant.english, state2.value.rules);
}

test "ws: new_game without rules uses the server default variant" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    // Server started with --rules spanish: a new_game without "rules" stays
    // Spanish, and an invalid value also falls back to the server default.
    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\"}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();
    try std.testing.expectEqual(game_mod.Variant.spanish, state.value.rules);
    try std.testing.expect(state.value.@"error" == null);

    const resp2 = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"bogus\"}", .spanish);
    defer allocator.free(resp2);
    var state2 = try parseState(allocator, resp2);
    defer state2.deinit();
    try std.testing.expectEqual(game_mod.Variant.spanish, state2.value.rules);

    // An explicit valid value still wins over the server default.
    const resp3 = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"english\"}", .spanish);
    defer allocator.free(resp3);
    var state3 = try parseState(allocator, resp3);
    defer state3.deinit();
    try std.testing.expectEqual(game_mod.Variant.english, state3.value.rules);
}

test "ws: make_move applies a legal move" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    const m = moves.slice()[0];

    const body = try std.fmt.allocPrint(allocator, "{{\"action\":\"make_move\",\"from\":{d},\"to\":{d}}}", .{ m.from, m.to });
    defer allocator.free(body);
    const resp = try protocol.handleMessage(allocator, game, &conn, body, .english);
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

test "ws: new_game after a played move frees the position history" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    // A quiet move records a position and allocates the repetition history
    // map; a subsequent new_game must free it, not drop it (leak).
    const resp0 = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\"}", .english);
    defer allocator.free(resp0);

    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    const m = moves.slice()[0];
    const body = try std.fmt.allocPrint(allocator, "{{\"action\":\"make_move\",\"from\":{d},\"to\":{d}}}", .{ m.from, m.to });
    defer allocator.free(body);
    const resp1 = try protocol.handleMessage(allocator, game, &conn, body, .english);
    defer allocator.free(resp1);

    const resp2 = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\"}", .english);
    defer allocator.free(resp2);
    var state = try parseState(allocator, resp2);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
}

test "ws: illegal make_move sets error and leaves the board unchanged" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":0,\"to\":1}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" != null);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(board_mod.initialBoard()), &state.value.board);
}

test "ws: legal_moves returns the full multi-jump capture chain" {
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"legal_moves\",\"from\":4}", .spanish);
    defer allocator.free(resp);
    var parsed = try parseLegalMoves(allocator, resp);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.@"error" == null);
    // Exactly one legal move from square 4: the whole two-jump chain.
    try std.testing.expectEqual(@as(usize, 1), parsed.value.moves.len);
    const m = parsed.value.moves[0];
    try std.testing.expectEqual(@as(u8, 4), m.from);
    try std.testing.expectEqual(@as(u8, 22), m.to);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 18 }, m.captured);
    // Raw-shape pin: `captured` must serialize as a JSON ARRAY of numbers,
    // not a string (a u8-slice-as-string regression would still pass the
    // expectEqualSlices above — [9,18] and "\t\x12" parse to the same bytes,
    // but the frontend echoes `captured` back and needs an array).
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"captured\":[9,18]") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"captured\":\"") == null);
}

test "ws: legal_moves serializes an empty captured array as []" {
    // Quiet moves must serialize captured as `[]` (array), not `""` (string):
    // the frontend echoes captured back into make_move, which rejects a
    // string with "invalid captured".
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"legal_moves\",\"from\":8}", .spanish);
    defer allocator.free(resp);
    var parsed = try parseLegalMoves(allocator, resp);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.@"error" == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.moves.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{}, parsed.value.moves[0].captured);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"captured\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"captured\":\"") == null);
}

test "ws: make_move with captured[] applies the exact multi-jump chain" {
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":[9,18]}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    const lm = state.value.last_move orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 4), lm.from);
    try std.testing.expectEqual(@as(u8, 22), lm.to);
    // Board reflects the full capture: both taken squares emptied, the pawn
    // on the final landing square.
    try std.testing.expectEqual(board_mod.Piece.empty, game.board[4]);
    try std.testing.expectEqual(board_mod.Piece.empty, game.board[9]);
    try std.testing.expectEqual(board_mod.Piece.empty, game.board[18]);
    try std.testing.expectEqual(board_mod.Piece.white_pawn, game.board[22]);
}

test "ws: make_move with a wrong captured[] chain is rejected" {
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    // captured [9] doesn't match the real chain [9,18]: exact-match must fail.
    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":[9]}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqualStrings("not a legal move", state.value.@"error".?);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
    // Board unchanged.
    try std.testing.expectEqual(board_mod.Piece.white_pawn, game.board[4]);
    try std.testing.expectEqual(board_mod.Piece.black_king, game.board[9]);
    try std.testing.expectEqual(board_mod.Piece.black_pawn, game.board[18]);
    try std.testing.expectEqual(board_mod.Piece.empty, game.board[22]);
}

test "ws: make_move without captured[] keeps from/to matching" {
    // Backward compat: old clients (TUI, LLM, pre-fix UI) send only
    // from/to; the full-chain position must still be accepted.
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":4,\"to\":22}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    const lm = state.value.last_move orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 4), lm.from);
    try std.testing.expectEqual(@as(u8, 22), lm.to);
    try std.testing.expectEqual(board_mod.Piece.white_pawn, game.board[22]);
}

test "ws: make_move with empty captured[] matches a quiet move" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    const m = moves.slice()[0];
    try std.testing.expectEqual(@as(u8, 0), m.num_captured); // opening move is quiet

    const body = try std.fmt.allocPrint(allocator, "{{\"action\":\"make_move\",\"from\":{d},\"to\":{d},\"captured\":[]}}", .{ m.from, m.to });
    defer allocator.free(body);
    const resp = try protocol.handleMessage(allocator, game, &conn, body, .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state.value.turn);
    const lm = state.value.last_move orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(m.from, lm.from);
    try std.testing.expectEqual(m.to, lm.to);
}

test "ws: make_move with captured[] in the wrong order is rejected" {
    // Same squares, same length, wrong order: the exact chain match must
    // compare the captured sequence in order, not as a set.
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":[18,9]}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqualStrings("not a legal move", state.value.@"error".?);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
    // Board unchanged.
    try std.testing.expectEqual(board_mod.Piece.white_pawn, game.board[4]);
    try std.testing.expectEqual(board_mod.Piece.black_king, game.board[9]);
    try std.testing.expectEqual(board_mod.Piece.black_pawn, game.board[18]);
}

test "ws: legal_moves returns convergent chains sharing from and to" {
    // Two distinct chains share from=4 and to=2 but capture different
    // squares: [9,14,6] vs [9,19,6]. Both must be reported.
    const allocator = std.testing.allocator;
    var game = try convergentGame(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"legal_moves\",\"from\":4}", .spanish);
    defer allocator.free(resp);
    var parsed = try parseLegalMoves(allocator, resp);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.@"error" == null);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.moves.len);
    var saw_via_14 = false;
    var saw_via_19 = false;
    for (parsed.value.moves) |m| {
        try std.testing.expectEqual(@as(u8, 4), m.from);
        try std.testing.expectEqual(@as(u8, 2), m.to);
        if (std.mem.eql(u8, m.captured, &[_]u8{ 9, 14, 6 })) saw_via_14 = true;
        if (std.mem.eql(u8, m.captured, &[_]u8{ 9, 19, 6 })) saw_via_19 = true;
    }
    try std.testing.expect(saw_via_14);
    try std.testing.expect(saw_via_19);
}

test "ws: make_move picks the exact convergent chain by captured[]" {
    // Same from/to, different captured: only the exact chain is applied, and
    // the board proves which one — the unchosen middle square survives.
    const allocator = std.testing.allocator;

    var game_a = try convergentGame(allocator);
    defer game_a.deinit();
    var conn_a = protocol.ConnState{};
    const resp_a = try protocol.handleMessage(allocator, game_a, &conn_a, "{\"action\":\"make_move\",\"from\":4,\"to\":2,\"captured\":[9,14,6]}", .spanish);
    defer allocator.free(resp_a);
    var state_a = try parseState(allocator, resp_a);
    defer state_a.deinit();
    try std.testing.expect(state_a.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state_a.value.turn);
    const lm_a = state_a.value.last_move orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 4), lm_a.from);
    try std.testing.expectEqual(@as(u8, 2), lm_a.to);
    // Chain [9,14,6]: 9, 14 and 6 emptied; 19 (the other path's middle) survives.
    try std.testing.expectEqual(board_mod.Piece.empty, game_a.board[9]);
    try std.testing.expectEqual(board_mod.Piece.empty, game_a.board[14]);
    try std.testing.expectEqual(board_mod.Piece.empty, game_a.board[6]);
    try std.testing.expectEqual(board_mod.Piece.black_pawn, game_a.board[19]);
    try std.testing.expectEqual(board_mod.Piece.white_king, game_a.board[2]);

    var game_b = try convergentGame(allocator);
    defer game_b.deinit();
    var conn_b = protocol.ConnState{};
    const resp_b = try protocol.handleMessage(allocator, game_b, &conn_b, "{\"action\":\"make_move\",\"from\":4,\"to\":2,\"captured\":[9,19,6]}", .spanish);
    defer allocator.free(resp_b);
    var state_b = try parseState(allocator, resp_b);
    defer state_b.deinit();
    try std.testing.expect(state_b.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, state_b.value.turn);
    const lm_b = state_b.value.last_move orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 4), lm_b.from);
    try std.testing.expectEqual(@as(u8, 2), lm_b.to);
    // Chain [9,19,6]: 9, 19 and 6 emptied; 14 survives.
    try std.testing.expectEqual(board_mod.Piece.empty, game_b.board[9]);
    try std.testing.expectEqual(board_mod.Piece.empty, game_b.board[19]);
    try std.testing.expectEqual(board_mod.Piece.empty, game_b.board[6]);
    try std.testing.expectEqual(board_mod.Piece.black_pawn, game_b.board[14]);
    try std.testing.expectEqual(board_mod.Piece.white_king, game_b.board[2]);
}

test "ws: legal_moves with missing or invalid from returns the state error envelope" {
    // The error path is stateJson: no `moves` key in the response. Parsing
    // as LegalMovesResp (moves required) must fail with MissingField.
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    for ([_][]const u8{
        "{\"action\":\"legal_moves\"}",
        "{\"action\":\"legal_moves\",\"from\":\"x\"}",
        "{\"action\":\"legal_moves\",\"from\":-1}",
    }) |frame| {
        const resp = try protocol.handleMessage(allocator, game, &conn, frame, .spanish);
        defer allocator.free(resp);

        var state = try parseState(allocator, resp);
        defer state.deinit();
        try std.testing.expect(state.value.@"error" != null);
        try std.testing.expectEqual(board_mod.Color.white, state.value.turn);

        const parsed = std.json.parseFromSlice(LegalMovesResp, allocator, resp, .{ .ignore_unknown_fields = true });
        try std.testing.expectError(error.MissingField, parsed);
    }
}

test "ws: make_move malformed captured[] variants are rejected" {
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    for ([_][]const u8{
        // Non-array captured.
        "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":5}",
        // Float element (not an integer).
        "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":[9,1.5]}",
        // Negative element (out of u8 range).
        "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":[-1]}",
        // More than the 12-slot Move.captured capacity.
        "{\"action\":\"make_move\",\"from\":4,\"to\":22,\"captured\":[0,1,2,3,4,5,6,7,8,9,10,11,12]}",
    }) |frame| {
        const resp = try protocol.handleMessage(allocator, game, &conn, frame, .spanish);
        defer allocator.free(resp);
        var state = try parseState(allocator, resp);
        defer state.deinit();

        try std.testing.expectEqualStrings("invalid captured", state.value.@"error".?);
        try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
        try std.testing.expect(state.value.last_move == null);
    }
}

test "ws: make_move cross-mismatch rejects a wrong from" {
    // captured matches the chain, but `from` does not (9 is a black square
    // in the issue24 position) — the exact match requires from too.
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"make_move\",\"from\":9,\"to\":22,\"captured\":[9,18]}", .spanish);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqualStrings("not a legal move", state.value.@"error".?);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
    try std.testing.expectEqual(board_mod.Piece.white_pawn, game.board[4]);
}

test "ws: legal_moves on an empty square returns an empty moves array" {
    const allocator = std.testing.allocator;
    var game = try issue24Game(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    // Square 0 is empty in the issue24 position: no moves, no error.
    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"legal_moves\",\"from\":0}", .spanish);
    defer allocator.free(resp);
    var parsed = try parseLegalMoves(allocator, resp);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.@"error" == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.moves.len);
}

test "ws: compute_minimax applies the engine move" {
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"compute_minimax\",\"time_limit_ms\":1}", .english);
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
    var conn = protocol.ConnState{};

    const new_resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"new_game\",\"rules\":\"spanish\"}", .english);
    defer allocator.free(new_resp);
    var new_state = try parseState(allocator, new_resp);
    defer new_state.deinit();
    try std.testing.expectEqual(game_mod.Variant.spanish, new_state.value.rules);

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"compute_minimax\",\"time_limit_ms\":50}", .english);
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
    var conn = protocol.ConnState{ .provider = fakeProvider() };

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\",\"model\":\"test-model\"}", .english);
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
    var conn = protocol.ConnState{};

    for ([_][]const u8{
        "not json",
        "{\"action\":42}",
        "{}",
        "123",
        "[]",
        "\"text\"",
        "null",
    }) |frame| {
        const resp = try protocol.handleMessage(allocator, game, &conn, frame, .english);
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
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"explode\"}", .english);
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
    var conn = protocol.ConnState{ .build_provider = failProviderBuild };

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\",\"model\":\"x\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expect(state.value.@"error" != null);
    try std.testing.expectEqual(board_mod.Color.white, state.value.turn);
    try std.testing.expect(state.value.last_move == null);
}

test "ws: request_llm with no build_provider errors (exact WASM path)" {
    // F1 oracle: ConnState{} with build_provider = null is exactly what the
    // WASM build ships (no LLM in the browser), so request_llm must answer
    // with the precise "LLM provider unavailable" error.
    const allocator = std.testing.allocator;
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var conn = protocol.ConnState{};

    const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\"}", .english);
    defer allocator.free(resp);
    var state = try parseState(allocator, resp);
    defer state.deinit();

    try std.testing.expectEqualStrings("LLM provider unavailable", state.value.@"error".?);
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
    var conn = protocol.ConnState{ .build_provider = countingBuild };

    for (0..2) |_| {
        const resp = try protocol.handleMessage(allocator, game, &conn, "{\"action\":\"request_llm\"}", .english);
        defer allocator.free(resp);
        var state = try parseState(allocator, resp);
        defer state.deinit();
        try std.testing.expect(state.value.@"error" == null);
    }
    try std.testing.expectEqual(@as(usize, 1), build_calls);
}
