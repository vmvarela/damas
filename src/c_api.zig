//! C ABI for the damas core. Opaque game handle + flat move struct.
//! All functions are `export` with C calling convention; the header lives in
//! include/damas.h. Allocator is page_allocator — no per-call frees needed.

const std = @import("std");
const game_mod = @import("core/game.zig");
const move_mod = @import("core/move.zig");
const minimax = @import("core/engine/minimax.zig");

const Game = game_mod.Game;
const Move = move_mod.Move;

export fn dz_game_new() ?*Game {
    return Game.init(std.heap.page_allocator) catch null;
}

export fn dz_game_free(game: ?*Game) void {
    if (game) |g| g.deinit();
}

/// Fills `out` with 32 piece codes: 0 empty, 1 white_pawn, 2 white_king,
/// 3 black_pawn, 4 black_king.
export fn dz_game_board(game: *Game, out: [*]u8) void {
    for (game.board, 0..) |p, i| out[i] = @intFromEnum(p);
}

/// 0 = white, 1 = black.
export fn dz_game_turn(game: *Game) u8 {
    return @intFromEnum(game.turn);
}

/// Writes up to `cap` legal moves for the side to move; returns the count.
export fn dz_game_moves(game: *Game, out: [*]Move, cap: usize) usize {
    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    const n = @min(moves.len, cap);
    for (moves.slice()[0..n], 0..) |m, i| out[i] = m;
    return n;
}

/// Applies a move (from/to + captured squares). Returns false if illegal;
/// board and turn are unchanged then. `captured` may be null when
/// `num_captured == 0`.
export fn dz_game_apply(game: *Game, from: u8, to: u8, captured: ?[*]const u8, num_captured: u8) bool {
    if (num_captured > 12) return false;
    var move = Move{ .from = from, .to = to, .captured = [_]u8{0} ** 12, .num_captured = num_captured };
    if (captured) |cap| {
        for (0..num_captured) |i| move.captured[i] = cap[i];
    }
    return game.applyMove(move);
}

/// Runs the minimax engine for `time_limit_ms` and writes the best move.
/// Returns false if the position has no legal moves.
export fn dz_game_best_move(game: *Game, time_limit_ms: u32, out: *Move) bool {
    const res = minimax.search(game.board, game.turn, time_limit_ms, std.heap.page_allocator) catch return false;
    out.* = res.move;
    return true;
}

export fn dz_game_over(game: *Game) bool {
    return game.isGameOver();
}

/// -1 = not over, 0 = white, 1 = black.
export fn dz_game_winner(game: *Game) i8 {
    const w = game.winner() orelse return -1;
    return @intCast(@intFromEnum(w));
}