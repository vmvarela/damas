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
/// On success `response.move` is the matched legal move (carrying its
/// captured set; two capture chains may share the same from/to).
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
        var resp = prov.request_move(allocator, .{
            .board_ascii = ascii[0..],
            .legal_moves = legal_moves,
            .note = note,
        }) catch |err| switch (err) {
            error.InvalidLlmResponse => {
                note = "Reply with ONLY the JSON object {\"move\": <number>, \"reasoning\": \"...\"} — nothing else.";
                continue;
            },
            else => |e| return e,
        };
        if (findMatch(resp, legal_moves)) |m| {
            // Authoritative move: the provider resolved the list number, so
            // `move` already matches; keep the guard for misbehaving fakes.
            resp.move = m.*;
            return resp;
        }
        allocator.free(resp.reasoning);
        note = "Your previous move number is not in the legal list. Reply with one number from the legal moves list.";
    }
    return error.InvalidMove;
}

/// First legal move with the same from/to as the reply, or null.
fn findMatch(resp: Response, legal_moves: []const Move) ?*const Move {
    for (legal_moves) |*m| {
        if (m.from == resp.from and m.to == resp.to) return m;
    }
    return null;
}
