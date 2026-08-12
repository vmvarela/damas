//! Zobrist hashing for board positions.
//!
//! The [32][5]u64 table plus the turn hash are generated at comptime from a
//! fixed seed — deterministic (tests and search are reproducible) and
//! immutable, so concurrent searches from multiple threads (web mode) never
//! race on shared state. `hash` XORs the piece entries plus the turn hash
//! when it is black's turn. `hashMove` updates a hash incrementally for the
//! search hot path.

const std = @import("std");
const board_mod = @import("../board.zig");
const move_mod = @import("../move.zig");
const rules = @import("../rules.zig");

pub const Color = board_mod.Color;
pub const Piece = board_mod.Piece;
pub const Board32 = board_mod.Board32;
pub const Move = move_mod.Move;

const SEED: u64 = 0x9E3779B97F4A7C15;

/// Comptime-generated from the fixed seed; identical to the old runtime
/// `init(SEED)` output, so search results don't change. One PRNG stream:
/// the table consumes 160 ints, then turn_hash is the 161st.
const generated = blk: {
    @setEvalBranchQuota(100_000); // Xoshiro256 comptime fill exceeds the default 1000
    var prng = std.Random.DefaultPrng.init(SEED);
    const rand = prng.random();
    var t: [32][5]u64 = undefined;
    for (0..32) |sq| {
        for (0..5) |pt| {
            t[sq][pt] = rand.int(u64);
        }
    }
    break :blk .{ .table = t, .turn_hash = rand.int(u64) };
};
const table: [32][5]u64 = generated.table;
const turn_hash: u64 = generated.turn_hash;

/// Hash of a position: XOR of piece entries plus the turn hash if black.
pub fn hash(board: Board32, turn: Color) u64 {
    var h: u64 = 0;
    for (0..32) |sq| {
        const p = board[sq];
        if (p != .empty) h ^= table[sq][@intFromEnum(p)];
    }
    if (turn == .black) h ^= turn_hash;
    return h;
}

/// Incremental hash update for applying `move` to `board` (the board BEFORE
/// the move — needed to know the moving piece and the captured pieces).
/// The turn always flips after a move, so the turn hash is XORed
/// unconditionally. Handles promotion (pawn -> king at `to`).
pub fn hashMove(h: u64, board: Board32, move: Move) u64 {
    const piece = board[move.from];
    var nh = h ^ table[move.from][@intFromEnum(piece)] ^ table[move.to][@intFromEnum(piece)];
    for (0..move.num_captured) |i| {
        const cap = board[move.captured[i]];
        nh ^= table[move.captured[i]][@intFromEnum(cap)];
    }
    const rc = board_mod.squareToRowCol(move.to);
    if (piece == .white_pawn and rc.row == 7) {
        nh ^= table[move.to][@intFromEnum(Piece.white_pawn)] ^ table[move.to][@intFromEnum(Piece.white_king)];
    } else if (piece == .black_pawn and rc.row == 0) {
        nh ^= table[move.to][@intFromEnum(Piece.black_pawn)] ^ table[move.to][@intFromEnum(Piece.black_king)];
    }
    return nh ^ turn_hash;
}

test "hash is deterministic" {
    const board = board_mod.initialBoard();
    const h1 = hash(board, .white);
    try std.testing.expectEqual(h1, hash(board, .white));
}

test "different positions hash differently" {
    const b1 = board_mod.initialBoard();
    var b2 = b1;
    b2[board_mod.rowColToSquare(2, 0)] = .empty; // remove a white pawn
    const h1 = hash(b1, .white);
    try std.testing.expect(h1 != hash(b2, .white));
    try std.testing.expect(h1 != hash(b1, .black));
}

test "hashMove matches hash after applyMove" {
    // Quiet move.
    const board = board_mod.initialBoard();
    const quiet = Move{ .from = board_mod.rowColToSquare(2, 0), .to = board_mod.rowColToSquare(3, 1), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    const h_inc = hashMove(hash(board, .white), board, quiet);
    var after = board;
    rules.applyMove(&after, quiet);
    try std.testing.expectEqual(hash(after, .black), h_inc);

    // Capture.
    var b2: Board32 = [_]Piece{.empty} ** 32;
    b2[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    b2[board_mod.rowColToSquare(3, 3)] = .black_pawn;
    const cap = Move{ .from = board_mod.rowColToSquare(2, 2), .to = board_mod.rowColToSquare(4, 4), .captured = [_]u8{board_mod.rowColToSquare(3, 3)} ** 12, .num_captured = 1 };
    const h2_inc = hashMove(hash(b2, .white), b2, cap);
    var b2_after = b2;
    rules.applyMove(&b2_after, cap);
    try std.testing.expectEqual(hash(b2_after, .black), h2_inc);

    // Promotion.
    var b3: Board32 = [_]Piece{.empty} ** 32;
    b3[board_mod.rowColToSquare(6, 6)] = .white_pawn;
    const prom = Move{ .from = board_mod.rowColToSquare(6, 6), .to = board_mod.rowColToSquare(7, 5), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    const h3_inc = hashMove(hash(b3, .white), b3, prom);
    var b3_after = b3;
    rules.applyMove(&b3_after, prom);
    try std.testing.expectEqual(hash(b3_after, .black), h3_inc);
}
