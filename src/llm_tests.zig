//! Test aggregator for the LLM layer (config, validation, prompt building,
//! response parsing). Module root must be src/ so that the imports resolve.
//! No network: providers are compile-checked and exercised via fake vtables
//! and canned response bodies.

const std = @import("std");
const board_mod = @import("core/board.zig");
const move_mod = @import("core/move.zig");
const game_mod = @import("core/game.zig");
const config_mod = @import("utils/config.zig");
const http_util = @import("utils/http.zig");
const provider = @import("llm/provider.zig");
const validation = @import("llm/validation.zig");
const openai = @import("llm/openai.zig");
const ollama = @import("llm/ollama.zig");
const factory = @import("llm/factory.zig");

comptime {
    // Compile-check the network-capable and file-reading code without
    // running it (postJson and load are exercised in Phase C).
    _ = openai.init;
    _ = openai.buildChatBody;
    _ = openai.parseChatResponse;
    _ = ollama.init;
    _ = ollama.parseGenerateResponse;
    _ = factory.fromConfig;
    _ = http_util.postJson;
    _ = config_mod.load;
}

test "config: parse() reads llm and minimax players" {
    const allocator = std.testing.allocator;
    const cfg = try config_mod.parse(allocator,
        \\{"player_white":{"type":"llm","provider":"groq","model":"llama-3.3-70b-versatile"},"player_black":{"type":"minimax","time_limit_ms":2000}}
    );
    defer switch (cfg.player_white) {
        .llm => |l| {
            allocator.free(l.provider);
            allocator.free(l.model);
        },
        else => {},
    };

    const white = cfg.player_white;
    const black = cfg.player_black;
    try std.testing.expect(white == .llm);
    try std.testing.expectEqualStrings("groq", white.llm.provider);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", white.llm.model);
    try std.testing.expect(black == .minimax);
    try std.testing.expectEqual(@as(u32, 2000), black.minimax.time_limit_ms);
}

test "config: type-mismatched fields error instead of panicking" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "[1,2]",
        "\"str\"",
        "{\"player_white\":{\"type\":5},\"player_black\":{\"type\":\"human\"}}",
        "{\"player_white\":{\"type\":\"llm\",\"provider\":3,\"model\":\"m\"},\"player_black\":{\"type\":\"human\"}}",
        "{\"player_white\":{\"type\":\"minimax\",\"time_limit_ms\":\"fast\"},\"player_black\":{\"type\":\"human\"}}",
    }) |bad| {
        try std.testing.expectError(error.InvalidConfig, config_mod.parse(allocator, bad));
    }
}

test "config: apiKey missing variable errors" {
    try std.testing.expectError(
        error.MissingApiKey,
        config_mod.apiKey(std.testing.allocator, "DAMAS_NO_SUCH_KEY_XYZ"),
    );
}

/// Fake provider: returns responses from a fixed list, one per call.
const FakeCtx = struct {
    responses: []const provider.Response,
    calls: usize = 0,
};

fn fakeRequestMove(ctx: *anyopaque, allocator: std.mem.Allocator, req: provider.Request) anyerror!provider.Response {
    _ = req;
    const self: *FakeCtx = @ptrCast(@alignCast(ctx));
    const resp = self.responses[self.calls];
    self.calls += 1;
    return .{
        .reasoning = try allocator.dupe(u8, resp.reasoning),
        .move = resp.move,
    };
}

fn fakeDeinit(ctx: *anyopaque) void {
    _ = ctx;
}

const fake_vtable = provider.LlmProvider.VTable{
    .request_move = fakeRequestMove,
    .deinit = fakeDeinit,
};

/// A canned LLM reply carrying the chosen move.
fn fakeResp(m: move_mod.Move, reasoning: []const u8) provider.Response {
    return .{ .reasoning = reasoning, .move = m };
}

/// A move that is not in any legal list used by these tests.
fn noMove(from: u8, to: u8) move_mod.Move {
    return .{ .from = from, .to = to, .captured = [_]u8{0} ** 12, .num_captured = 0 };
}

fn initialLegalMoves(allocator: std.mem.Allocator) !struct { board: board_mod.Board32, list: move_mod.MoveList } {
    var game = try game_mod.Game.init(allocator);
    defer game.deinit();
    var list = move_mod.MoveList{};
    game.generateMoves(&list);
    return .{ .board = game.board, .list = list };
}

test "validation: valid move accepted on first try" {
    const allocator = std.testing.allocator;
    const pos = try initialLegalMoves(allocator);
    const moves = pos.list.slice();
    const first = moves[0];

    var ctx = FakeCtx{ .responses = &.{ fakeResp(first, "looks good") } };
    const prov = provider.LlmProvider{ .ctx = &ctx, .vtable = &fake_vtable };

    const resp = try validation.requestValidMove(allocator, prov, pos.board, moves);
    defer allocator.free(resp.reasoning);
    try std.testing.expectEqual(first.from, resp.move.from);
    try std.testing.expectEqual(first.to, resp.move.to);
    try std.testing.expectEqual(first.num_captured, resp.move.num_captured);
    try std.testing.expectEqualSlices(u8, &first.captured, &resp.move.captured);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "validation: invalid move is retried" {
    const allocator = std.testing.allocator;
    const pos = try initialLegalMoves(allocator);
    const moves = pos.list.slice();
    const first = moves[0];

    var ctx = FakeCtx{ .responses = &.{
        fakeResp(noMove(0, 1), "oops"),
        fakeResp(first, "fixed"),
    } };
    const prov = provider.LlmProvider{ .ctx = &ctx, .vtable = &fake_vtable };

    const resp = try validation.requestValidMove(allocator, prov, pos.board, moves);
    defer allocator.free(resp.reasoning);
    try std.testing.expectEqual(first.from, resp.move.from);
    try std.testing.expectEqual(first.to, resp.move.to);
    try std.testing.expectEqual(@as(usize, 2), ctx.calls);
}

test "validation: three invalid moves -> InvalidMove" {
    const allocator = std.testing.allocator;
    const pos = try initialLegalMoves(allocator);

    var ctx = FakeCtx{ .responses = &.{
        fakeResp(noMove(0, 1), "a"),
        fakeResp(noMove(2, 3), "b"),
        fakeResp(noMove(4, 5), "c"),
    } };
    const prov = provider.LlmProvider{ .ctx = &ctx, .vtable = &fake_vtable };

    try std.testing.expectError(
        error.InvalidMove,
        validation.requestValidMove(allocator, prov, pos.board, pos.list.slice()),
    );
    try std.testing.expectEqual(@as(usize, 3), ctx.calls);
}

test "validation: provider's resolved move is returned unchanged" {
    const allocator = std.testing.allocator;
    const board = board_mod.initialBoard();
    // Two capture chains sharing the same from/to. The model's number is
    // authoritative: the fake resolves to m2, and validation must NOT
    // replace it with the first from/to match (m1).
    const m1 = move_mod.Move{ .from = 9, .to = 18, .captured = [_]u8{13, 17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, .num_captured = 2 };
    const m2 = move_mod.Move{ .from = 9, .to = 18, .captured = [_]u8{0} ** 12, .num_captured = 0 };
    const legal = [_]move_mod.Move{ m1, m2 };

    var ctx = FakeCtx{ .responses = &.{ fakeResp(m2, "number 1, the quiet one") } };
    const prov = provider.LlmProvider{ .ctx = &ctx, .vtable = &fake_vtable };

    const resp = try validation.requestValidMove(allocator, prov, board, &legal);
    defer allocator.free(resp.reasoning);
    try std.testing.expectEqual(@as(u8, 0), resp.move.num_captured);
    try std.testing.expectEqualSlices(u8, &m2.captured, &resp.move.captured);
}

test "prompt builder: board, move list, and number-based reply instruction" {
    const allocator = std.testing.allocator;
    const ascii = board_mod.boardToAscii(board_mod.initialBoard());
    const moves = [_]move_mod.Move{
        .{ .from = 8, .to = 12, .captured = [_]u8{0} ** 12, .num_captured = 0 },
        .{ .from = 9, .to = 13, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    };

    const prompt = try provider.buildPrompt(allocator, &ascii, &moves, "");
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Legal moves") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "8,12") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "9,13") != null);
    // Strict reply instruction present...
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Reply with ONLY compact JSON") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "The number must be one of the legal move numbers above") != null);
    // ...and the old coordinate-math hint is gone.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "square index = row*4") == null);

    const prompt2 = try provider.buildPrompt(allocator, &ascii, &moves, "Your previous move number is not in the legal list.");
    defer allocator.free(prompt2);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "not in the legal list") != null);
}

/// Canned legal-move list for response-parsing tests (3 entries so move
/// number 2 is in range).
const test_moves = [_]move_mod.Move{
    .{ .from = 8, .to = 12, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    .{ .from = 9, .to = 13, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    .{ .from = 10, .to = 14, .captured = [_]u8{0} ** 12, .num_captured = 0 },
};

test "openai.parseChatResponse: valid move numbers" {
    const allocator = std.testing.allocator;

    const body0 =
        \\{"choices":[{"message":{"content":"{\"move\": 0, \"reasoning\": \"advance\"}"}}]}
    ;
    const r0 = try openai.parseChatResponse(allocator, body0, &test_moves);
    defer allocator.free(r0.reasoning);
    try std.testing.expectEqual(test_moves[0].from, r0.move.from);
    try std.testing.expectEqual(test_moves[0].to, r0.move.to);
    try std.testing.expectEqual(test_moves[0].num_captured, r0.move.num_captured);
    try std.testing.expectEqualSlices(u8, &test_moves[0].captured, &r0.move.captured);
    try std.testing.expectEqualStrings("advance", r0.reasoning);

    const body2 =
        \\{"choices":[{"message":{"content":"{\"move\": 2, \"reasoning\": \"\"}"}}]}
    ;
    const r2 = try openai.parseChatResponse(allocator, body2, &test_moves);
    defer allocator.free(r2.reasoning);
    try std.testing.expectEqual(test_moves[2].from, r2.move.from);
    try std.testing.expectEqual(test_moves[2].to, r2.move.to);
}

test "openai.parseChatResponse: malformed bodies -> InvalidLlmResponse" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidLlmResponse, openai.parseChatResponse(allocator, "not json", &test_moves));
    try std.testing.expectError(error.InvalidLlmResponse, openai.parseChatResponse(allocator, "{\"choices\":[]}", &test_moves));

    const prose =
        \\{"choices":[{"message":{"content":"plain text"}}]}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, openai.parseChatResponse(allocator, prose, &test_moves));

    const out_of_range =
        \\{"choices":[{"message":{"content":"{\"move\": 5, \"reasoning\": \"\"}"}}]}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, openai.parseChatResponse(allocator, out_of_range, &test_moves));

    const no_move =
        \\{"choices":[{"message":{"content":"{\"reasoning\": \"forgot the move\"}"}}]}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, openai.parseChatResponse(allocator, no_move, &test_moves));

    // Empty legal-move list: nothing to resolve against.
    const any_move =
        \\{"choices":[{"message":{"content":"{\"move\": 0, \"reasoning\": \"\"}"}}]}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, openai.parseChatResponse(allocator, any_move, &.{}));
}

test "ollama.parseGenerateResponse: valid move numbers" {
    const allocator = std.testing.allocator;

    const body0 =
        \\{"response":"{\"move\": 0, \"reasoning\": \"ok\"}"}
    ;
    const r0 = try ollama.parseGenerateResponse(allocator, body0, &test_moves);
    defer allocator.free(r0.reasoning);
    try std.testing.expectEqual(test_moves[0].from, r0.move.from);
    try std.testing.expectEqual(test_moves[0].to, r0.move.to);
    try std.testing.expectEqual(test_moves[0].num_captured, r0.move.num_captured);
    try std.testing.expectEqualSlices(u8, &test_moves[0].captured, &r0.move.captured);
    try std.testing.expectEqualStrings("ok", r0.reasoning);

    const body2 =
        \\{"response":"{\"move\": 2, \"reasoning\": \"\"}"}
    ;
    const r2 = try ollama.parseGenerateResponse(allocator, body2, &test_moves);
    defer allocator.free(r2.reasoning);
    try std.testing.expectEqual(test_moves[2].from, r2.move.from);
    try std.testing.expectEqual(test_moves[2].to, r2.move.to);
}

test "ollama.parseGenerateResponse: malformed bodies -> InvalidLlmResponse" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidLlmResponse, ollama.parseGenerateResponse(allocator, "not json", &test_moves));

    const prose =
        \\{"response":"plain text"}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, ollama.parseGenerateResponse(allocator, prose, &test_moves));

    const out_of_range =
        \\{"response":"{\"move\": 5, \"reasoning\": \"\"}"}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, ollama.parseGenerateResponse(allocator, out_of_range, &test_moves));

    const no_move =
        \\{"response":"{\"reasoning\": \"forgot the move\"}"}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, ollama.parseGenerateResponse(allocator, no_move, &test_moves));

    const any_move =
        \\{"response":"{\"move\": 0, \"reasoning\": \"\"}"}
    ;
    try std.testing.expectError(error.InvalidLlmResponse, ollama.parseGenerateResponse(allocator, any_move, &.{}));
}

test "openai.buildChatBody: valid JSON with system and user messages" {
    const allocator = std.testing.allocator;
    const body = try openai.buildChatBody(allocator, "m", "SYS", "USER \"quoted\" \nnewline");
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("m", obj.get("model").?.string);
    const msgs = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqualStrings("system", msgs[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("SYS", msgs[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("user", msgs[1].object.get("role").?.string);
    // Quotes and newlines in the user content survive round-trip escaped.
    try std.testing.expectEqualStrings("USER \"quoted\" \nnewline", msgs[1].object.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 0), obj.get("temperature").?.integer);
}
