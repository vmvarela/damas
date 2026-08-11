//! English draughts rules: move generation, move application, legality.
//!
//! Capture rules: captures are mandatory; if any exist, only capture moves
//! are generated. Multi-jump chains are generated fully — each Move in the
//! list is one complete chain (start square, final landing square, all
//! captured squares in order). Kings are non-flying: one square per step.
//! A pawn that lands on the last row is promoted, and the move ends there.

const std = @import("std");
const board_mod = @import("board.zig");
const move_mod = @import("move.zig");

pub const Color = board_mod.Color;
pub const Piece = board_mod.Piece;
pub const Board32 = board_mod.Board32;
pub const Move = move_mod.Move;
pub const MoveList = move_mod.MoveList;

const squareToRowCol = board_mod.squareToRowCol;
const rowColToSquare = board_mod.rowColToSquare;
const opponent = board_mod.opponent;
const isKing = board_mod.isKing;
const pieceColor = board_mod.pieceColor;
const isCapture = move_mod.isCapture;

const Dir = struct { dr: i8, dc: i8 };

/// Direction set for a piece: pawns move one step forward diagonally,
/// kings move one step in any of the four diagonal directions.
fn pieceDirs(piece: Piece) []const Dir {
    return switch (piece) {
        .white_pawn => &[_]Dir{ .{ .dr = 1, .dc = -1 }, .{ .dr = 1, .dc = 1 } },
        .black_pawn => &[_]Dir{ .{ .dr = -1, .dc = -1 }, .{ .dr = -1, .dc = 1 } },
        else => &[_]Dir{ .{ .dr = -1, .dc = -1 }, .{ .dr = -1, .dc = 1 }, .{ .dr = 1, .dc = -1 }, .{ .dr = 1, .dc = 1 } },
    };
}

/// One diagonal step from a square, or null if off the board.
fn step(rc: board_mod.RowCol, d: Dir) ?board_mod.RowCol {
    const r = @as(i8, @intCast(rc.row)) + d.dr;
    const c = @as(i8, @intCast(rc.col)) + d.dc;
    if (r < 0 or r >= 8 or c < 0 or c >= 8) return null;
    return .{ .row = @intCast(r), .col = @intCast(c) };
}

/// Recursively extend a capture chain from `from`. `start` is the chain's
/// origin square; `visited` marks landing squares already used (a piece may
/// not land on the same square twice in one chain); `captured` accumulates
/// captured squares in order. Each complete chain is emitted as one Move.
fn genCaptures(board_in: Board32, from: u8, start: u8, turn: Color, visited: *[32]bool, captured: *[12]u8, num: u8, moves: *MoveList) void {
    var board = board_in;
    const piece = board[from];

    // A pawn landing on the last row is promoted and the move ends: no
    // further jumps after promotion (English draughts rule).
    if (num > 0 and !isKing(piece)) {
        const last_row: u8 = if (turn == .white) 7 else 0;
        if (squareToRowCol(from).row == last_row) {
            _ = moves.add(.{ .from = start, .to = from, .captured = captured.*, .num_captured = num });
            return;
        }
    }

    var made = false;
    const rc = squareToRowCol(from);
    for (pieceDirs(piece)) |d| {
        const mid = step(rc, d) orelse continue;
        const land = step(mid, d) orelse continue;
        const mid_sq = rowColToSquare(mid.row, mid.col);
        const land_sq = rowColToSquare(land.row, land.col);
        const target = board[mid_sq];
        if (target == .empty) continue;
        const target_color = pieceColor(target) orelse continue;
        if (target_color != opponent(turn)) continue;
        if (board[land_sq] != .empty) continue;
        if (visited[land_sq]) continue;

        visited[land_sq] = true;
        captured[num] = mid_sq;
        const saved = board[mid_sq];
        board[mid_sq] = .empty;
        genCaptures(board, land_sq, start, turn, visited, captured, num + 1, moves);
        board[mid_sq] = saved;
        visited[land_sq] = false;
        made = true;
    }
    if (!made and num > 0) {
        _ = moves.add(.{ .from = start, .to = from, .captured = captured.*, .num_captured = num });
    }
}

/// Generate all legal moves for `turn`. Captures are mandatory: if any
/// capture exists, only capture moves are returned. Each Move is one
/// complete chain (or one quiet step).
pub fn generateMoves(board: Board32, turn: Color, moves: *MoveList) void {
    moves.clear();

    for (0..32) |sq| {
        const piece = board[sq];
        if (piece == .empty) continue;
        const color = pieceColor(piece) orelse continue;
        if (color != turn) continue;
        var visited = [_]bool{false} ** 32;
        visited[sq] = true;
        var captured = [_]u8{0} ** 12;
        genCaptures(board, @intCast(sq), @intCast(sq), turn, &visited, &captured, 0, moves);
    }
    if (moves.len > 0) return;

    for (0..32) |sq| {
        const piece = board[sq];
        if (piece == .empty) continue;
        const color = pieceColor(piece) orelse continue;
        if (color != turn) continue;
        const from: u8 = @intCast(sq);
        const rc = squareToRowCol(from);
        for (pieceDirs(piece)) |d| {
            const to = step(rc, d) orelse continue;
            const to_sq = rowColToSquare(to.row, to.col);
            if (board[to_sq] != .empty) continue;
            _ = moves.add(.{ .from = from, .to = to_sq, .captured = [_]u8{0} ** 12, .num_captured = 0 });
        }
    }
}

/// Apply a move: move the piece from -> to, remove captured squares,
/// promote a pawn reaching the last row. The chain is precomputed in the
/// move, so this just applies the recorded captures.
pub fn applyMove(board: *Board32, move: Move) void {
    const piece = board[move.from];
    board[move.from] = .empty;
    board[move.to] = piece;
    for (0..move.num_captured) |i| {
        board[move.captured[i]] = .empty;
    }
    const rc = squareToRowCol(move.to);
    if (piece == .white_pawn and rc.row == 7) {
        board[move.to] = .white_king;
    } else if (piece == .black_pawn and rc.row == 0) {
        board[move.to] = .black_king;
    }
}

/// True if `move` is one of the legal moves for `turn` (compared against
/// generated moves, including the captured-square sequence).
pub fn isLegalMove(board: Board32, turn: Color, move: Move) bool {
    var moves = MoveList{};
    generateMoves(board, turn, &moves);
    for (moves.slice()) |m| {
        if (m.from != move.from or m.to != move.to or m.num_captured != move.num_captured) continue;
        var match = true;
        for (0..move.num_captured) |i| {
            if (m.captured[i] != move.captured[i]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn hasAnyCapture(board: Board32, turn: Color) bool {
    var moves = MoveList{};
    generateMoves(board, turn, &moves);
    for (moves.slice()) |m| {
        if (isCapture(m)) return true;
    }
    return false;
}

pub fn hasAnyMove(board: Board32, turn: Color) bool {
    var moves = MoveList{};
    generateMoves(board, turn, &moves);
    return moves.len > 0;
}

test "initial position: 7 legal non-capture moves for white" {
    const board = board_mod.initialBoard();
    var moves = MoveList{};
    generateMoves(board, .white, &moves);
    try std.testing.expectEqual(@as(usize, 7), moves.len);
    for (moves.slice()) |m| {
        try std.testing.expect(!isCapture(m));
    }
}

test "mandatory capture: only capture moves generated" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(2, 2)] = .white_pawn;
    board[rowColToSquare(2, 6)] = .white_pawn; // could move quietly, but must not
    board[rowColToSquare(3, 3)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expect(isCapture(m));
    try std.testing.expectEqual(rowColToSquare(2, 2), m.from);
    try std.testing.expectEqual(rowColToSquare(4, 4), m.to);
    try std.testing.expectEqual(@as(u8, 1), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(3, 3), m.captured[0]);
}

test "multi-jump chain records both captured squares" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(2, 2)] = .white_pawn;
    board[rowColToSquare(3, 3)] = .black_pawn;
    board[rowColToSquare(5, 5)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(2, 2), m.from);
    try std.testing.expectEqual(rowColToSquare(6, 6), m.to);
    try std.testing.expectEqual(@as(u8, 2), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(3, 3), m.captured[0]);
    try std.testing.expectEqual(rowColToSquare(5, 5), m.captured[1]);
}

test "promotion: pawn reaching last row becomes king" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(6, 6)] = .white_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves);
    try std.testing.expectEqual(@as(usize, 2), moves.len);

    const m = moves.slice()[0];
    applyMove(&board, m);
    try std.testing.expectEqual(Piece.white_king, board[m.to]);
    try std.testing.expectEqual(Piece.empty, board[m.from]);
}

test "king moves backward" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;

    var moves = MoveList{};
    generateMoves(board, .white, &moves);
    try std.testing.expectEqual(@as(usize, 4), moves.len);
    var found_backward = false;
    for (moves.slice()) |m| {
        if (m.to == rowColToSquare(3, 3)) found_backward = true;
    }
    try std.testing.expect(found_backward);
}

test "applyMove removes captured pieces and promotes" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(2, 2)] = .white_pawn;
    board[rowColToSquare(3, 3)] = .black_pawn;
    board[rowColToSquare(5, 5)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    applyMove(&board, m);
    try std.testing.expectEqual(Piece.empty, board[rowColToSquare(2, 2)]);
    try std.testing.expectEqual(Piece.empty, board[rowColToSquare(3, 3)]);
    try std.testing.expectEqual(Piece.empty, board[rowColToSquare(5, 5)]);
    try std.testing.expectEqual(Piece.white_pawn, board[rowColToSquare(6, 6)]);
}

test "isLegalMove accepts legal and rejects illegal moves" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(2, 2)] = .white_pawn;
    board[rowColToSquare(3, 3)] = .black_pawn;

    // Legal capture.
    const legal = Move{ .from = rowColToSquare(2, 2), .to = rowColToSquare(4, 4), .captured = [_]u8{rowColToSquare(3, 3)} ** 12, .num_captured = 1 };
    try std.testing.expect(isLegalMove(board, .white, legal));

    // Wrong turn: same move claimed for black.
    try std.testing.expect(!isLegalMove(board, .black, legal));

    // Non-diagonal move.
    const non_diag = Move{ .from = rowColToSquare(2, 2), .to = rowColToSquare(2, 4), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    try std.testing.expect(!isLegalMove(board, .white, non_diag));

    // Jumping own piece: white at (2,2), white at (3,3), empty (4,4).
    board[rowColToSquare(3, 3)] = .white_pawn;
    const own_jump = Move{ .from = rowColToSquare(2, 2), .to = rowColToSquare(4, 4), .captured = [_]u8{rowColToSquare(3, 3)} ** 12, .num_captured = 1 };
    try std.testing.expect(!isLegalMove(board, .white, own_jump));
}
