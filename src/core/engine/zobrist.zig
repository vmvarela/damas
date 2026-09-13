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

/// Incremental child hash from the PRE-move board: XORs out the moved piece
/// and each captured piece, XORs in the final piece on the landing square,
/// and flips the turn. Captured-square piece types are read from
/// `pre_board` because they are lost after applying the move. `final_piece`
/// mirrors rules.applyMove's promotion exactly (white_pawn reaching row 7 ->
/// white_king, black_pawn reaching row 0 -> black_king). `parent_hash` is
/// the parent's hash as returned by `hash`/`updateHash`; the 0->1 remap is
/// applied at the end, mirroring `hash`.
pub fn updateHash(pre_board: Board32, move: Move, parent_hash: u64) u64 {
    var h = parent_hash;
    // The turn hash is present iff the parent is black; XORing it always
    // both removes it and adds the child's (opponent's) copy.
    h ^= turn_hash;
    const piece = pre_board[move.from];
    h ^= table[move.from][@intFromEnum(piece)];
    // Final piece on `to`: mirrors rules.applyMove (promotion on landing).
    var final_piece = piece;
    const rc = board_mod.squareToRowCol(move.to);
    if (piece == .white_pawn and rc.row == 7) {
        final_piece = .white_king;
    } else if (piece == .black_pawn and rc.row == 0) {
        final_piece = .black_king;
    }
    h ^= table[move.to][@intFromEnum(final_piece)];
    for (0..move.num_captured) |i| {
        const cap_sq = move.captured[i];
        h ^= table[cap_sq][@intFromEnum(pre_board[cap_sq])];
    }
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
    // transposition table's empty-slot marker (key 0). The black case pins
    // turn_hash != 0 (white/black would otherwise hash identically).
    const empty = [_]Piece{.empty} ** 32;
    try std.testing.expect(hash(empty, .white) != 0);
    try std.testing.expect(hash(empty, .black) != 0);
}

test "different positions hash differently" {
    const b1 = board_mod.initialBoard();
    var b2 = b1;
    b2[board_mod.rowColToSquare(2, 0)] = .empty; // remove a white pawn
    const h1 = hash(b1, .white);
    try std.testing.expect(h1 != hash(b2, .white));
    try std.testing.expect(h1 != hash(b1, .black));
}

test "updateHash matches hash for every legal move across positions" {
    // Equivalence: the incremental child hash must equal a from-scratch
    // hash of the post-move board, for EVERY legal move from each corpus
    // position. Corpus covers quiet moves, single captures, multi-jump
    // chains, promotions (both colors, quiet and via capture), non-flying
    // kings, and Spanish flying kings — plus the initial position.
    const rules = @import("../rules.zig");

    var quiet: Board32 = [_]Piece{.empty} ** 32;
    quiet[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    quiet[board_mod.rowColToSquare(5, 5)] = .black_pawn;

    var single: Board32 = [_]Piece{.empty} ** 32;
    single[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    single[board_mod.rowColToSquare(3, 3)] = .black_pawn;

    var multi: Board32 = [_]Piece{.empty} ** 32;
    multi[board_mod.rowColToSquare(0, 0)] = .white_pawn;
    multi[board_mod.rowColToSquare(1, 1)] = .black_pawn;
    multi[board_mod.rowColToSquare(3, 3)] = .black_pawn;

    var promo_w: Board32 = [_]Piece{.empty} ** 32;
    promo_w[board_mod.rowColToSquare(6, 6)] = .white_pawn;

    var promo_w_cap: Board32 = [_]Piece{.empty} ** 32;
    promo_w_cap[board_mod.rowColToSquare(5, 5)] = .white_pawn;
    promo_w_cap[board_mod.rowColToSquare(6, 6)] = .black_pawn;

    var promo_b: Board32 = [_]Piece{.empty} ** 32;
    promo_b[board_mod.rowColToSquare(1, 1)] = .black_pawn;

    var promo_b_cap: Board32 = [_]Piece{.empty} ** 32;
    promo_b_cap[board_mod.rowColToSquare(2, 2)] = .black_pawn;
    promo_b_cap[board_mod.rowColToSquare(1, 1)] = .white_pawn;

    var kings: Board32 = [_]Piece{.empty} ** 32;
    kings[board_mod.rowColToSquare(4, 4)] = .white_king;
    kings[board_mod.rowColToSquare(3, 3)] = .black_pawn;

    var king_vs_king: Board32 = [_]Piece{.empty} ** 32;
    king_vs_king[board_mod.rowColToSquare(4, 4)] = .white_king;
    king_vs_king[board_mod.rowColToSquare(5, 5)] = .black_king;

    var flying: Board32 = [_]Piece{.empty} ** 32;
    flying[board_mod.rowColToSquare(2, 2)] = .white_king;
    flying[board_mod.rowColToSquare(5, 5)] = .black_pawn;

    const positions = [_]Board32{
        board_mod.initialBoard(), quiet,        single,  multi,
        promo_w,                  promo_w_cap,  promo_b, promo_b_cap,
        kings,                    king_vs_king, flying,
    };

    // Corpus-shape guards: every move class below must actually occur, or
    // the test silently covers nothing.
    var saw_quiet = false;
    var saw_single_cap = false;
    var saw_multi_cap = false;
    var saw_promo_w = false;
    var saw_promo_b = false;

    const variants = [_]rules.Variant{ .english, .spanish };
    for (positions) |board| {
        for (variants) |variant| {
            for ([_]Color{ .white, .black }) |turn| {
                var moves = move_mod.MoveList{};
                rules.generateMoves(board, turn, &moves, variant);
                const parent = hash(board, turn);
                for (moves.slice()) |m| {
                    var child = board;
                    rules.applyMove(&child, m);
                    const child_turn = board_mod.opponent(turn);
                    const expected = hash(child, child_turn);
                    const actual = updateHash(board, m, parent);
                    try std.testing.expectEqual(expected, actual);

                    if (m.num_captured == 0) saw_quiet = true;
                    if (m.num_captured == 1) saw_single_cap = true;
                    if (m.num_captured >= 2) saw_multi_cap = true;
                    const moved = board[m.from];
                    if (moved == .white_pawn and board_mod.isKing(child[m.to])) saw_promo_w = true;
                    if (moved == .black_pawn and board_mod.isKing(child[m.to])) saw_promo_b = true;
                }
            }
        }
    }
    try std.testing.expect(saw_quiet);
    try std.testing.expect(saw_single_cap);
    try std.testing.expect(saw_multi_cap);
    try std.testing.expect(saw_promo_w);
    try std.testing.expect(saw_promo_b);
}
