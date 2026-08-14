//! Validation loop: ask the LLM for a move until it picks one from the legal
//! move list (up to 3 attempts).

const std = @import("std");
const board_mod = @import("../core/board.zig");
const provider = @import("provider.zig");

pub const LlmProvider = provider.LlmProvider;
pub const Request = provider.Request;
pub const Response = provider.Response;
pub const Move = provider.Move;

/// Ask the provider for a move, validating it against `legal_moves`.
/// On success `response.move` is the provider's resolved move (already an
/// authoritative entry from `legal_moves`; this loop only checks it).
/// Returns error.InvalidMove after 3 failed attempts. The returned
/// `Response.reasoning` is caller-owned.
pub fn requestValidMove(
    allocator: std.mem.Allocator,
    prov: LlmProvider,
    board: board_mod.Board32,
    legal_moves: []const Move,
) !Response {
    const ascii = board_mod.boardToAscii(board);
    var note: []const u8 = "";

    for (0..3) |_| {
        const resp = prov.requestMove(allocator, .{
            .board_ascii = ascii[0..],
            .legal_moves = legal_moves,
            .note = note,
        }) catch |err| switch (err) {
            error.InvalidLlmResponse => {
                note = "Reply with ONLY the JSON object {\"move\": <number>} — nothing else.";
                continue;
            },
            else => |e| return e,
        };
        // Pure check: the model's number is authoritative — parseMoveJson
        // already resolved it against legal_moves, so never overwrite
        // resp.move (two capture chains may share from/to).
        if (findMatch(resp, legal_moves)) return resp;
        allocator.free(resp.reasoning);
        note = "Your previous move number is not in the legal list. Reply with one number from the legal moves list.";
    }
    return error.InvalidMove;
}

/// True if the reply's move is in `legal_moves` (from/to match).
fn findMatch(resp: Response, legal_moves: []const Move) bool {
    for (legal_moves) |m| {
        if (m.from == resp.move.from and m.to == resp.move.to) return true;
    }
    return false;
}
