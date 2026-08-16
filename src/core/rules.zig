//! Draughts rules: move generation, move application, legality.
//!
//! Two rule variants:
//! - English: captures are mandatory; if any exist, only capture moves are
//!   generated. Multi-jump chains are generated fully — each Move in the list
//!   is one complete chain (start square, final landing square, all captured
//!   squares in order). Pawns move and capture forward only. Kings move and
//!   capture in any of the four diagonal directions, non-flying (one square
//!   per step). A pawn that lands on the last row is
//!   promoted, and the move ends there.
//! - Spanish (damas españolas): pawns capture forward only. Kings are flying:
//!   they move any distance along a diagonal, and capture by sliding to the
//!   first enemy, jumping it, and landing on any free square beyond (the
//!   chain continues from the landing). `visited` marks only landing squares
//!   and the origin, so a flying king's slide may CROSS squares already
//!   landed on earlier in the same chain (including the origin; standard
//!   engine practice — the literal "never pass twice over the same square"
//!   reading is not applied). Captures are mandatory and the
//!   Spanish capture laws apply: among all chains keep only the ones with
//!   the most captured pieces (ley de la cantidad), and among those the ones
//!   capturing the most kings (ley de la calidad). Promotion is the same as
//!   English.

const std = @import("std");
const board_mod = @import("board.zig");
const move_mod = @import("move.zig");

pub const Color = board_mod.Color;
pub const Piece = board_mod.Piece;
pub const Board32 = board_mod.Board32;
pub const Move = move_mod.Move;
pub const MoveList = move_mod.MoveList;

/// Draughts rule variant. Spanish is the project default; English is the
/// classic variant (Spanish adds flying kings and the capture
/// quantity/quality laws).
/// Tags are explicit: 0/1 match the Spanish/English variant enum.
pub const Variant = enum(u8) { english = 0, spanish = 1 };

const squareToRowCol = board_mod.squareToRowCol;
const rowColToSquare = board_mod.rowColToSquare;
const opponent = board_mod.opponent;
const isKing = board_mod.isKing;
const pieceColor = board_mod.pieceColor;
const isCapture = move_mod.isCapture;

const Dir = struct { dr: i8, dc: i8 };

const king_dirs = [_]Dir{
    .{ .dr = -1, .dc = -1 }, .{ .dr = -1, .dc = 1 },
    .{ .dr = 1, .dc = -1 },  .{ .dr = 1, .dc = 1 },
};

/// Quiet-move direction set for a piece: pawns move one step forward
/// diagonally, kings move one step in any of the four diagonal directions
/// (flying kings extend this by sliding, see generateMoves).
fn pieceDirs(piece: Piece) []const Dir {
    return switch (piece) {
        .white_pawn => &[_]Dir{ .{ .dr = 1, .dc = -1 }, .{ .dr = 1, .dc = 1 } },
        .black_pawn => &[_]Dir{ .{ .dr = -1, .dc = -1 }, .{ .dr = -1, .dc = 1 } },
        else => &king_dirs,
    };
}

/// Capture direction set. Pawns capture forward only in both variants; kings
/// capture in any of the four non-flying diagonal directions. Spanish kings
/// never reach here (handled by flyCaptures).
fn captureDirs(piece: Piece, variant: Variant) []const Dir {
    return switch (piece) {
        .white_pawn, .black_pawn => pieceDirs(piece),
        else => switch (variant) {
            .english => &king_dirs,
            .spanish => unreachable, // Spanish kings go through flyCaptures
        },
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
fn genCaptures(board_in: Board32, from: u8, start: u8, turn: Color, visited: *[32]bool, captured: *[12]u8, num: u8, moves: *MoveList, variant: Variant) void {
    var board = board_in;
    // The moving piece never leaves `start` on the (copy of the) board —
    // landing squares are only marked via `visited` and captured squares are
    // emptied. Reading from `start` keeps the piece identity across the whole
    // chain (a landing square would read .empty).
    const piece = board[start];

    // A pawn landing on the last row is promoted and the move ends: no
    // further jumps after promotion (both variants).
    if (num > 0 and !isKing(piece)) {
        const last_row: u8 = if (turn == .white) 7 else 0;
        if (squareToRowCol(from).row == last_row) {
            _ = moves.add(.{ .from = start, .to = from, .captured = captured.*, .num_captured = num });
            return;
        }
    }

    var made = false;
    const rc = squareToRowCol(from);
    if (variant == .spanish and isKing(piece)) {
        flyCaptures(&board, rc, start, turn, visited, captured, num, moves, &made);
    } else {
        for (captureDirs(piece, variant)) |d| {
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
            genCaptures(board, land_sq, start, turn, visited, captured, num + 1, moves, variant);
            board[mid_sq] = saved;
            visited[land_sq] = false;
            made = true;
        }
    }
    if (!made and num > 0) {
        _ = moves.add(.{ .from = start, .to = from, .captured = captured.*, .num_captured = num });
    }
}

/// Spanish flying-king capture in all four directions: slide along a
/// diagonal to the FIRST enemy piece (own pieces block the slide), jump it,
/// and land on any free square beyond. The captured square is emptied during
/// the recursive continuation (preventing re-jumps over the same piece) and
/// restored afterwards. `made` tracks whether any capture was found.
fn flyCaptures(board: *Board32, from_rc: board_mod.RowCol, start: u8, turn: Color, visited: *[32]bool, captured: *[12]u8, num: u8, moves: *MoveList, made: *bool) void {
    for (king_dirs) |d| {
        // Slide to the first enemy piece; own pieces block the slide. The
        // chain's origin square still holds the moving king on the board
        // copy, but the king has vacated it — treat it as passable so chains
        // may double back through the origin (M2).
        var rc = step(from_rc, d) orelse continue;
        var mid_sq: ?u8 = null;
        while (true) {
            const sq = rowColToSquare(rc.row, rc.col);
            if (sq == start) {
                rc = step(rc, d) orelse break;
                continue;
            }
            const p = board[sq];
            if (p != .empty) {
                if (pieceColor(p).? == turn) break; // own piece blocks
                mid_sq = sq;
                break;
            }
            rc = step(rc, d) orelse break;
        }
        const mid = mid_sq orelse continue;

        // Land on any free square beyond the captured piece; an occupied or
        // already-used landing square ends the enumeration in this direction.
        var lrc = step(squareToRowCol(mid), d) orelse continue;
        while (true) {
            const lsq = rowColToSquare(lrc.row, lrc.col);
            if (board[lsq] != .empty) break;
            if (!visited[lsq]) {
                visited[lsq] = true;
                captured[num] = mid;
                const saved = board[mid];
                board[mid] = .empty;
                genCaptures(board.*, lsq, start, turn, visited, captured, num + 1, moves, .spanish);
                board[mid] = saved;
                visited[lsq] = false;
                made.* = true;
            }
            lrc = step(lrc, d) orelse break;
        }
    }
}

/// Number of kings among the pieces captured by `m`. The board is the
/// pre-move position, which generation leaves untouched.
fn kingsCaptured(board: Board32, m: Move) u8 {
    var n: u8 = 0;
    for (0..m.num_captured) |i| {
        if (isKing(board[m.captured[i]])) n += 1;
    }
    return n;
}

/// Spanish capture laws (ley de la cantidad, then ley de la calidad): keep
/// only the chains with the most captured pieces, and among those, the ones
/// capturing the most kings. Then drop duplicate chains (see below). No-op
/// when there are no captures.
fn applyCaptureLaws(board: Board32, moves: *MoveList) void {
    if (moves.len == 0) return;
    var max_num: u8 = 0;
    for (moves.slice()) |m| max_num = @max(max_num, m.num_captured);
    var max_kings: u8 = 0;
    for (moves.slice()) |m| {
        if (m.num_captured != max_num) continue;
        max_kings = @max(max_kings, kingsCaptured(board, m));
    }
    var w: usize = 0;
    for (moves.slice()) |m| {
        if (m.num_captured != max_num or kingsCaptured(board, m) != max_kings) continue;
        moves.items[w] = m;
        w += 1;
    }
    moves.len = w;

    // Dedupe convergent chains: a flying king can produce several chains with
    // the same (from, to, captured) Move via different intermediate landing
    // choices — e.g. the "chain never re-lands on the origin" test position
    // yields 3 identical entries, all ending on (7,7). A Move records only
    // start/final/captured, so these are the same board transformation:
    // keeping one per distinct Move cuts wasted search nodes.
    // ponytail: dedupe runs after generation, so it can't recover a list that
    // overflowed the 256-slot MoveList during emission — a contrived flying-
    // king position with 5+ enemy pieces could still truncate a mandatory
    // capture. Never observed; if it ever fires, dedupe at emission or assert
    // on add().
    var j: usize = 0;
    for (moves.slice()) |m| {
        var dup = false;
        for (moves.items[0..j]) |keep| {
            if (movesEqual(keep, m)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            moves.items[j] = m;
            j += 1;
        }
    }
    moves.len = j;
}

/// True if two moves are the same chain: same origin, same final square,
/// same captured squares in the same order (matches isLegalMove's comparison).
fn movesEqual(a: Move, b: Move) bool {
    if (a.from != b.from or a.to != b.to or a.num_captured != b.num_captured) return false;
    for (0..a.num_captured) |i| {
        if (a.captured[i] != b.captured[i]) return false;
    }
    return true;
}

/// Generate all legal moves for `turn`. Captures are mandatory: if any
/// capture exists, only capture moves are returned (under Spanish rules,
/// filtered by the capture laws). Each Move is one complete chain (or one
/// quiet step).
pub fn generateMoves(board: Board32, turn: Color, moves: *MoveList, variant: Variant) void {
    moves.clear();

    for (0..32) |sq| {
        const piece = board[sq];
        if (piece == .empty) continue;
        const color = pieceColor(piece) orelse continue;
        if (color != turn) continue;
        var visited = [_]bool{false} ** 32;
        visited[sq] = true;
        var captured = [_]u8{0} ** 12;
        genCaptures(board, @intCast(sq), @intCast(sq), turn, &visited, &captured, 0, moves, variant);
    }
    if (variant == .spanish) applyCaptureLaws(board, moves);
    if (moves.len > 0) return;

    for (0..32) |sq| {
        const piece = board[sq];
        if (piece == .empty) continue;
        const color = pieceColor(piece) orelse continue;
        if (color != turn) continue;
        const from: u8 = @intCast(sq);
        const rc = squareToRowCol(from);
        if (variant == .spanish and isKing(piece)) {
            // Flying king: slide to every free square on each diagonal.
            for (king_dirs) |d| {
                var cur = step(rc, d) orelse continue;
                while (true) {
                    const cur_sq = rowColToSquare(cur.row, cur.col);
                    if (board[cur_sq] != .empty) break;
                    _ = moves.add(.{ .from = from, .to = cur_sq, .captured = [_]u8{0} ** 12, .num_captured = 0 });
                    cur = step(cur, d) orelse break;
                }
            }
        } else {
            for (pieceDirs(piece)) |d| {
                const to = step(rc, d) orelse continue;
                const to_sq = rowColToSquare(to.row, to.col);
                if (board[to_sq] != .empty) continue;
                _ = moves.add(.{ .from = from, .to = to_sq, .captured = [_]u8{0} ** 12, .num_captured = 0 });
            }
        }
    }
}

/// Apply a move: move the piece from -> to, remove captured squares,
/// promote a pawn reaching the last row. The chain is precomputed in the
/// move, so this just applies the recorded captures. Identical for both
/// variants.
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
pub fn isLegalMove(board: Board32, turn: Color, move: Move, variant: Variant) bool {
    var moves = MoveList{};
    generateMoves(board, turn, &moves, variant);
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

pub fn hasAnyMove(board: Board32, turn: Color, variant: Variant) bool {
    var moves = MoveList{};
    generateMoves(board, turn, &moves, variant);
    return moves.len > 0;
}

test "initial position: 7 legal non-capture moves for white" {
    const board = board_mod.initialBoard();
    var moves = MoveList{};
    generateMoves(board, .white, &moves, .english);
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
    generateMoves(board, .white, &moves, .english);
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
    generateMoves(board, .white, &moves, .english);
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
    generateMoves(board, .white, &moves, .english);
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
    generateMoves(board, .white, &moves, .english);
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
    generateMoves(board, .white, &moves, .english);
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
    try std.testing.expect(isLegalMove(board, .white, legal, .english));

    // Wrong turn: same move claimed for black.
    try std.testing.expect(!isLegalMove(board, .black, legal, .english));

    // Non-diagonal move.
    const non_diag = Move{ .from = rowColToSquare(2, 2), .to = rowColToSquare(2, 4), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    try std.testing.expect(!isLegalMove(board, .white, non_diag, .english));

    // Jumping own piece: white at (2,2), white at (3,3), empty (4,4).
    board[rowColToSquare(3, 3)] = .white_pawn;
    const own_jump = Move{ .from = rowColToSquare(2, 2), .to = rowColToSquare(4, 4), .captured = [_]u8{rowColToSquare(3, 3)} ** 12, .num_captured = 1 };
    try std.testing.expect(!isLegalMove(board, .white, own_jump, .english));
}

test "pawn does not capture backward (both variants)" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(3, 3)] = .white_pawn;
    board[rowColToSquare(2, 2)] = .black_pawn; // behind white's forward direction

    // Pawns capture forward only in both variants: no backward capture to
    // (1,1) over (2,2) — just the two forward quiet moves, both landing on
    // row 4 (a backward regression would land on row 1).
    var english = MoveList{};
    generateMoves(board, .white, &english, .english);
    try std.testing.expectEqual(@as(usize, 2), english.len);
    for (english.slice()) |m| {
        try std.testing.expect(!isCapture(m));
        try std.testing.expect(squareToRowCol(m.to).row > 3);
    }

    var spanish = MoveList{};
    generateMoves(board, .white, &spanish, .spanish);
    try std.testing.expectEqual(@as(usize, 2), spanish.len);
    for (spanish.slice()) |m| {
        try std.testing.expect(!isCapture(m));
        try std.testing.expect(squareToRowCol(m.to).row > 3);
    }
}

test "english: king captures backward" {
    var kboard: Board32 = [_]Piece{.empty} ** 32;
    kboard[rowColToSquare(3, 3)] = .white_king;
    kboard[rowColToSquare(2, 2)] = .black_pawn;
    var king_moves = MoveList{};
    generateMoves(kboard, .white, &king_moves, .english);
    try std.testing.expectEqual(@as(usize, 1), king_moves.len); // mandatory capture only
    const m = king_moves.slice()[0];
    try std.testing.expect(isCapture(m));
    try std.testing.expectEqual(rowColToSquare(1, 1), m.to);
    try std.testing.expectEqual(rowColToSquare(2, 2), m.captured[0]);
}

test "english: pawn in a chain captures forward only" {
    // WP(3,3), BP(4,4), BP(4,6). The pawn captures (4,4) landing on (5,5)
    // and must NOT continue on to (4,6): that would be a backward capture,
    // which English pawns never make (the pre-fix code continued chains with
    // all four directions, ending at (3,7) with 2 captures).
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(3, 3)] = .white_pawn;
    board[rowColToSquare(4, 4)] = .black_pawn;
    board[rowColToSquare(4, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .english);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(5, 5), m.to);
    try std.testing.expectEqual(@as(u8, 1), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(4, 4), m.captured[0]);
}

test "black pawn does not capture backward" {
    // BP(3,3), WP(4,4) behind black's forward direction (black moves up,
    // row -1). Expect the 2 forward quiet moves to row 2; a backward
    // capture regression would land on (5,5), row 5.
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(3, 3)] = .black_pawn;
    board[rowColToSquare(4, 4)] = .white_pawn;

    var moves = MoveList{};
    generateMoves(board, .black, &moves, .english);
    try std.testing.expectEqual(@as(usize, 2), moves.len);
    for (moves.slice()) |m| {
        try std.testing.expect(!isCapture(m));
        try std.testing.expect(squareToRowCol(m.to).row == 2); // forward only, never row 5
    }
}

test "spanish: flying king quiet moves slide the full diagonal" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    // Four diagonals from (4,4): 4 + 3 + 3 + 3 = 13 free squares.
    try std.testing.expectEqual(@as(usize, 13), moves.len);
    var has_00 = false;
    var has_77 = false;
    for (moves.slice()) |m| {
        try std.testing.expect(!isCapture(m));
        if (m.to == rowColToSquare(0, 0)) has_00 = true;
        if (m.to == rowColToSquare(7, 7)) has_77 = true;
    }
    try std.testing.expect(has_00);
    try std.testing.expect(has_77);
}

test "spanish: flying king captures the square beyond the enemy" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;
    board[rowColToSquare(6, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expect(isCapture(m));
    try std.testing.expectEqual(rowColToSquare(7, 7), m.to);
    try std.testing.expectEqual(@as(u8, 1), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(6, 6), m.captured[0]);
}

test "spanish: flying king may land on any free square beyond the enemy" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(1, 1)] = .white_king;
    board[rowColToSquare(3, 3)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 4), moves.len);
    const expected = [_]u8{ rowColToSquare(4, 4), rowColToSquare(5, 5), rowColToSquare(6, 6), rowColToSquare(7, 7) };
    for (moves.slice()) |m| {
        try std.testing.expect(isCapture(m));
        try std.testing.expectEqual(rowColToSquare(3, 3), m.captured[0]);
        var found = false;
        for (expected) |e| {
            if (m.to == e) found = true;
        }
        try std.testing.expect(found);
    }
}

test "spanish: flying king multi-capture chain" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;
    board[rowColToSquare(3, 3)] = .black_pawn;
    board[rowColToSquare(1, 1)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(0, 0), m.to);
    try std.testing.expectEqual(@as(u8, 2), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(3, 3), m.captured[0]);
    try std.testing.expectEqual(rowColToSquare(1, 1), m.captured[1]);
}

test "spanish: ley de la cantidad keeps only the longest chains" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    // Single capture: (0,0) -> (2,2) over (1,1).
    board[rowColToSquare(0, 0)] = .white_pawn;
    board[rowColToSquare(1, 1)] = .black_pawn;
    // Double capture: (1,3) -> (5,7) over (2,4), (4,6).
    board[rowColToSquare(1, 3)] = .white_pawn;
    board[rowColToSquare(2, 4)] = .black_pawn;
    board[rowColToSquare(4, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(1, 3), m.from);
    try std.testing.expectEqual(rowColToSquare(5, 7), m.to);
    try std.testing.expectEqual(@as(u8, 2), m.num_captured);
}

test "spanish: ley de la calidad prefers chains capturing more kings" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    // Chain with a king: (0,0) -> (4,4) over king (1,1), pawn (3,3).
    board[rowColToSquare(0, 0)] = .white_pawn;
    board[rowColToSquare(1, 1)] = .black_king;
    board[rowColToSquare(3, 3)] = .black_pawn;
    // Chain of two pawns: (1,3) -> (5,7).
    board[rowColToSquare(1, 3)] = .white_pawn;
    board[rowColToSquare(2, 4)] = .black_pawn;
    board[rowColToSquare(4, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(0, 0), m.from);
    try std.testing.expectEqual(rowColToSquare(4, 4), m.to);
    try std.testing.expectEqual(@as(u8, 2), m.num_captured);
}

test "spanish: ley de la cantidad outranks quality" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    // Chain of one king: (0,0) -> (2,2) over king (1,1).
    board[rowColToSquare(0, 0)] = .white_pawn;
    board[rowColToSquare(1, 1)] = .black_king;
    // Chain of two pawns: (1,3) -> (5,7).
    board[rowColToSquare(1, 3)] = .white_pawn;
    board[rowColToSquare(2, 4)] = .black_pawn;
    board[rowColToSquare(4, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(1, 3), m.from);
    try std.testing.expectEqual(@as(u8, 2), m.num_captured);
}

test "spanish: own piece blocks the king's slide" {
    // WK(4,4), own WP(5,5), BP(6,6). The king's slide on the (1,1) diagonal
    // stops at the own pawn, so the king never captures (6,6). Note: the own
    // pawn itself captures (6,6) forward (captures are mandatory), so the
    // position yields one capture — by the pawn, never by the king.
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;
    board[rowColToSquare(5, 5)] = .white_pawn;
    board[rowColToSquare(6, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expect(isCapture(m));
    try std.testing.expectEqual(rowColToSquare(5, 5), m.from);
    try std.testing.expectEqual(rowColToSquare(7, 7), m.to);
    try std.testing.expectEqual(rowColToSquare(6, 6), m.captured[0]);
    // The king at (4,4) must not have generated any capture: its slide is
    // blocked by the own pawn at (5,5).
    try std.testing.expect(m.from != rowColToSquare(4, 4));
}

test "spanish: own piece blocks the landing" {
    // WK(4,4), BP(5,5), own WP(6,6). The king slides up to the enemy (5,5)
    // but cannot land beyond it: (6,6) is its own pawn, so there is no
    // capture at all. The king still slides 10 quiet moves; the pawn adds 2
    // quiet moves of its own (total 12).
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;
    board[rowColToSquare(5, 5)] = .black_pawn;
    board[rowColToSquare(6, 6)] = .white_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 12), moves.len);
    var king_quiet: usize = 0;
    for (moves.slice()) |m| {
        try std.testing.expect(!isCapture(m));
        if (m.from == rowColToSquare(4, 4)) king_quiet += 1;
    }
    // The king slides to every free square on its four diagonals: 3 + 4 + 3.
    try std.testing.expectEqual(@as(usize, 10), king_quiet);
}

test "spanish: flying king continues on another diagonal after landing" {
    // WK(3,3), BP(4,4), BP(6,4). The king captures (4,4) landing on (5,5),
    // then continues on the (1,-1) diagonal: captures (6,4) landing on (7,3).
    // The shorter chains (landing (6,6)/(7,7), 1 capture) lose to this
    // 2-capture chain by the ley de la cantidad.
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(3, 3)] = .white_king;
    board[rowColToSquare(4, 4)] = .black_pawn;
    board[rowColToSquare(6, 4)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(7, 3), m.to);
    try std.testing.expectEqual(@as(u8, 2), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(4, 4), m.captured[0]);
    try std.testing.expectEqual(rowColToSquare(6, 4), m.captured[1]);
}

test "spanish: chain never re-lands on the origin" {
    // WK(4,4), BP(3,3), BP(6,6). Chains double back through the origin
    // (M2: the slide may cross it, and it is emptied in the slide), but the
    // origin is marked visited, so no chain may END on (4,4). Without dedupe
    // this position yields 6 chains: capture (3,3) first gives 3 landing
    // choices (0,0)/(1,1)/(2,2) that all converge to the SAME move ending on
    // (7,7), so applyCaptureLaws collapses them into 1; capture (6,6) first
    // gives the 3 chains ending on (2,2)/(1,1)/(0,0). Total 4. Assert the
    // relevant properties: all chains capture 2 pieces, at least one ends on
    // (7,7), none on (4,4).
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(4, 4)] = .white_king;
    board[rowColToSquare(3, 3)] = .black_pawn;
    board[rowColToSquare(6, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 4), moves.len);
    var ends_on_77 = false;
    for (moves.slice()) |m| {
        try std.testing.expectEqual(@as(u8, 2), m.num_captured);
        try std.testing.expect(m.to != rowColToSquare(4, 4));
        if (m.to == rowColToSquare(7, 7)) ends_on_77 = true;
    }
    try std.testing.expect(ends_on_77);
}

test "english: promotion ends the capture chain" {
    // WP(5,3), BP(6,4), BP(6,6). The pawn captures (6,4) and lands on row 7
    // (promotion), which ends the move: it must NOT continue on to capture
    // (6,6). Same promotion rule in both variants.
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(5, 3)] = .white_pawn;
    board[rowColToSquare(6, 4)] = .black_pawn;
    board[rowColToSquare(6, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .english);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(7, 5), m.to);
    try std.testing.expectEqual(@as(u8, 1), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(6, 4), m.captured[0]);
}

test "spanish: pawn in a chain captures forward only" {
    // WP(3,3), BP(4,4), BP(4,6). The pawn captures (4,4) landing on (5,5)
    // and must NOT continue on to (4,6): that would be a backward capture,
    // which Spanish pawns never make (the pre-fix code continued chains with
    // all four directions, ending at (3,7) with 2 captures). Exactly one
    // 1-capture chain exists here, so the capture laws don't filter it.
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[rowColToSquare(3, 3)] = .white_pawn;
    board[rowColToSquare(4, 4)] = .black_pawn;
    board[rowColToSquare(4, 6)] = .black_pawn;

    var moves = MoveList{};
    generateMoves(board, .white, &moves, .spanish);
    try std.testing.expectEqual(@as(usize, 1), moves.len);
    const m = moves.slice()[0];
    try std.testing.expectEqual(rowColToSquare(5, 5), m.to);
    try std.testing.expectEqual(@as(u8, 1), m.num_captured);
    try std.testing.expectEqual(rowColToSquare(4, 4), m.captured[0]);
}
