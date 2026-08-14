//! Board representation for English draughts (checkers).
//!
//! Square indexing convention: the 32 playable squares are the dark squares
//! of an 8x8 board, indexed row-major. Row 0 is the top of the board (white's
//! home rows), row 7 the bottom (black's home rows). A square (row, col) is
//! playable when (row + col) is even, and its index is:
//!     sq = row * 4 + col / 2
//! The inverse:
//!     row = sq / 4
//!     col = (sq % 4) * 2 + (row % 2)
//! White moves toward increasing row (down the board), black toward
//! decreasing row.

const std = @import("std");

pub const Color = enum(u8) { white, black };

pub const Piece = enum(u8) { empty, white_pawn, white_king, black_pawn, black_king };

pub const Board32 = [32]Piece;

pub const RowCol = struct { row: u8, col: u8 };

/// Standard opening position: 12 white pawns on rows 0-2, 12 black pawns on
/// rows 5-7.
pub fn initialBoard() Board32 {
    var board: Board32 = [_]Piece{.empty} ** 32;
    for (0..3) |row| {
        const start: u8 = if (row % 2 == 1) 1 else 0;
        var col: u8 = start;
        while (col < 8) : (col += 2) {
            board[rowColToSquare(@intCast(row), col)] = .white_pawn;
        }
    }
    for (5..8) |row| {
        const start: u8 = if (row % 2 == 1) 1 else 0;
        var col: u8 = start;
        while (col < 8) : (col += 2) {
            board[rowColToSquare(@intCast(row), col)] = .black_pawn;
        }
    }
    return board;
}

/// Map a playable square index to its (row, col) on the 8x8 board.
pub fn squareToRowCol(sq: u8) RowCol {
    const row = sq / 4;
    const col = (sq % 4) * 2 + (row % 2);
    return .{ .row = row, .col = col };
}

/// Map an (row, col) pair to a playable square index. The pair must be a
/// dark square ((row + col) even); behavior is undefined otherwise.
pub fn rowColToSquare(row: u8, col: u8) u8 {
    return row * 4 + col / 2;
}

pub fn opponent(color: Color) Color {
    return switch (color) {
        .white => .black,
        .black => .white,
    };
}

pub fn isKing(piece: Piece) bool {
    return piece == .white_king or piece == .black_king;
}

/// Color of a piece, or null for an empty square.
pub fn pieceColor(piece: Piece) ?Color {
    return switch (piece) {
        .empty => null,
        .white_pawn, .white_king => .white,
        .black_pawn, .black_king => .black,
    };
}

/// 8x8 ASCII rendering: '.' empty dark square, ' ' light square,
/// 'w'/'W'/'b'/'B' for pawn/king. Row-major, 64 chars, no newlines.
pub fn boardToAscii(board: Board32) [64]u8 {
    var out: [64]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |col| {
            const idx = row * 8 + col;
            if ((row + col) % 2 == 1) {
                out[idx] = ' ';
            } else {
                const sq = rowColToSquare(@intCast(row), @intCast(col));
                out[idx] = switch (board[sq]) {
                    .empty => '.',
                    .white_pawn => 'w',
                    .white_king => 'W',
                    .black_pawn => 'b',
                    .black_king => 'B',
                };
            }
        }
    }
    return out;
}

test "initial board has 12 white and 12 black pawns in correct rows" {
    const board = initialBoard();
    var white_count: usize = 0;
    var black_count: usize = 0;
    for (0..32) |sq| {
        switch (board[sq]) {
            .white_pawn => white_count += 1,
            .black_pawn => black_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 12), white_count);
    try std.testing.expectEqual(@as(usize, 12), black_count);

    for (0..32) |sq| {
        const rc = squareToRowCol(@intCast(sq));
        switch (board[sq]) {
            .white_pawn => try std.testing.expect(rc.row < 3),
            .black_pawn => try std.testing.expect(rc.row >= 5),
            else => {},
        }
    }

    try std.testing.expectEqual(Piece.white_pawn, board[rowColToSquare(0, 0)]);
    try std.testing.expectEqual(Piece.white_pawn, board[rowColToSquare(2, 6)]);
    try std.testing.expectEqual(Piece.black_pawn, board[rowColToSquare(5, 1)]);
    try std.testing.expectEqual(Piece.black_pawn, board[rowColToSquare(7, 7)]);
    try std.testing.expectEqual(Piece.empty, board[rowColToSquare(3, 1)]);
    try std.testing.expectEqual(Piece.empty, board[rowColToSquare(4, 4)]);
}

test "row/col mapping round-trips" {
    for (0..32) |sq| {
        const rc = squareToRowCol(@intCast(sq));
        try std.testing.expectEqual(@as(u8, @intCast(sq)), rowColToSquare(rc.row, rc.col));
    }
    for (0..8) |row| {
        for (0..8) |col| {
            if ((row + col) % 2 == 1) continue;
            const sq = rowColToSquare(@intCast(row), @intCast(col));
            const rc = squareToRowCol(sq);
            try std.testing.expectEqual(@as(u8, @intCast(row)), rc.row);
            try std.testing.expectEqual(@as(u8, @intCast(col)), rc.col);
        }
    }
}

test "opponent flips color" {
    try std.testing.expectEqual(Color.black, opponent(.white));
    try std.testing.expectEqual(Color.white, opponent(.black));
}

test "boardToAscii renders 8x8 with correct shape" {
    const ascii = boardToAscii(initialBoard());
    try std.testing.expectEqual(@as(usize, 64), ascii.len);
    // Row 0: dark squares hold white pawns, light squares are spaces.
    try std.testing.expectEqual(@as(u8, 'w'), ascii[0]);
    try std.testing.expectEqual(@as(u8, ' '), ascii[1]);
    try std.testing.expectEqual(@as(u8, 'w'), ascii[2]);
    // Row 3 is empty: '.' on dark, ' ' on light.
    try std.testing.expectEqual(@as(u8, ' '), ascii[24]);
    try std.testing.expectEqual(@as(u8, '.'), ascii[25]);
    // Row 7: black pawns.
    try std.testing.expectEqual(@as(u8, ' '), ascii[56]);
    try std.testing.expectEqual(@as(u8, 'b'), ascii[57]);
}
