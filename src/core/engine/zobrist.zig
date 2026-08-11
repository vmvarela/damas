//! Zobrist hashing for board positions.
//!
//! `init(seed)` fills a [32][5]u64 table (32 squares x 5 piece types) plus a
//! turn hash using a seeded PRNG — deterministic, so tests and search are
//! reproducible. `hash` XORs the piece entries plus the turn hash when it is
//! black's turn. `hashMove` updates a hash incrementally for the search hot
//! path.

const std = @import("std");
const board_mod = @import("../board.zig");
const move_mod = @import("../move.zig");
const rules = @import("../rules.zig");

pub const Color = board_mod.Color;
pub const Piece = board_mod.Piece;
pub const Board32 = board_mod.Board32;
pub const Move = move_mod.Move;

var table: [32][5]u64 = undefined;
var turn_hash: u64 = 0;

/// Fill the hash tables from a seeded PRNG. Must be called before hash().
pub fn init(seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (0..32) |sq| {
        for (0..5) |pt| {
            table[sq][pt] = rand.int(u64);
        }
    }
    turn_hash = rand.int(u64);
}

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

test "hash is deterministic for same seed" {
    zobrist_init(42);
    const board = board_mod.initialBoard();
    const h1 = hash(board, .white);
    try std.testing.expectEqual(h1, hash(board, .white));
    zobrist_init(42);
    try std.testing.expectEqual(h1, hash(board, .white));
}

test "different positions hash differently" {
    zobrist_init(42);
    const b1 = board_mod.initialBoard();
    var b2 = b1;
    b2[board_mod.rowColToSquare(2, 0)] = .empty; // remove a white pawn
    const h1 = hash(b1, .white);
    try std.testing.expect(h1 != hash(b2, .white));
    try std.testing.expect(h1 != hash(b1, .black));
}

test "hashMove matches hash after applyMove" {
    zobrist_init(42);

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

// Test-only alias so the test block reads naturally.
const zobrist_init = init;
