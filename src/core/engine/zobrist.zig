//! Zobrist hashing for board positions.
//!
//! The [32][5]u64 table plus the turn hash are generated at comptime from a
//! fixed seed — deterministic (tests and search are reproducible) and
//! immutable, so concurrent searches from multiple threads (web mode) never
//! race on shared state. `hash` XORs the piece entries plus the turn hash
//! when it is black's turn.

const std = @import("std");
const board_mod = @import("../board.zig");
const move_mod = @import("../move.zig");

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

comptime {
    // A zero entry would alias the empty marker or white/black turns (a zero
    // turn_hash makes white and black positions hash identically, which would
    // also poison the repetition map in game.zig). 2^-64 per entry, but free.
    for (generated.table) |row| {
        for (row) |v| {
            if (v == 0) @compileError("zobrist table entry must not be zero");
        }
    }
    if (generated.turn_hash == 0) @compileError("zobrist turn hash must not be zero");
}

/// Hash of a position: XOR of piece entries plus the turn hash if black.
pub fn hash(board: Board32, turn: Color) u64 {
    var h: u64 = 0;
    for (0..32) |sq| {
        const p = board[sq];
        if (p != .empty) h ^= table[sq][@intFromEnum(p)];
    }
    if (turn == .black) h ^= turn_hash;
    // Key 0 is the TT empty-slot marker; never hand a position hash of 0 to
    // the table (a rare XOR cancellation would otherwise be treated as a miss).
    if (h == 0) h = 1;
    return h;
}

test "hash is deterministic" {
    const board = board_mod.initialBoard();
    const h1 = hash(board, .white);
    try std.testing.expectEqual(h1, hash(board, .white));
}

test "hash never returns zero (TT empty marker)" {
    // Empty board, white to move: XOR of nothing must not collide with the
    // transposition table's empty-slot marker (key 0).
    const empty = [_]Piece{.empty} ** 32;
    try std.testing.expect(hash(empty, .white) != 0);
    try std.testing.expect(hash(empty, .black) != 0);
    // A few ordinary positions must stay non-zero too.
    const b1 = board_mod.initialBoard();
    try std.testing.expect(hash(b1, .white) != 0);
    try std.testing.expect(hash(b1, .black) != 0);
}

test "empty-board hash round-trips through the TT (issue #4)" {
    // End-to-end proof of the reported bug: the empty board (which XORs to 0)
    // must be storable and retrievable like any other position.
    const tt_mod = @import("tt.zig");
    var tt = try tt_mod.TranspositionTable.init(std.testing.allocator, 1 << 4);
    defer tt.deinit();
    const empty = [_]Piece{.empty} ** 32;
    const key = hash(empty, .white);
    try std.testing.expect(key != 0);
    tt.put(.{
        .key = key,
        .depth = 1,
        .score = 1,
        .flag = .exact,
        .move = Move{ .from = 0, .to = 1, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    });
    try std.testing.expect(tt.get(key) != null);
}

test "different positions hash differently" {
    const b1 = board_mod.initialBoard();
    var b2 = b1;
    b2[board_mod.rowColToSquare(2, 0)] = .empty; // remove a white pawn
    const h1 = hash(b1, .white);
    try std.testing.expect(h1 != hash(b2, .white));
    try std.testing.expect(h1 != hash(b1, .black));
}
