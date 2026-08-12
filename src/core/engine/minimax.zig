//! Negamax alpha-beta search with iterative deepening, transposition table,
//! MVV-LVA move ordering, and a time limit.
//!
//! Simplifications (deliberate): no quiescence search (horizon effect
//! accepted), TT replacement is overwrite-only, eval is material + small
//! positional terms. Board copies (32 bytes) are used for undo.

const std = @import("std");
const board_mod = @import("../board.zig");
const move_mod = @import("../move.zig");
const rules = @import("../rules.zig");
const zobrist = @import("zobrist.zig");
const tt_mod = @import("tt.zig");
const timer_mod = @import("timer.zig");

pub const Color = board_mod.Color;
pub const Piece = board_mod.Piece;
pub const Board32 = board_mod.Board32;
pub const Move = move_mod.Move;
pub const MoveList = move_mod.MoveList;
pub const Variant = rules.Variant;
pub const TranspositionTable = tt_mod.TranspositionTable;
pub const TTFlag = tt_mod.TTFlag;
pub const Timer = timer_mod.Timer;

const MAX_DEPTH: u8 = 24;
const MATE_SCORE: i32 = 100_000;
const PAWN_VALUE: i32 = 100;
const KING_VALUE: i32 = 300;

pub const SearchResult = struct {
    move: Move,
    score: i32,
    depth: u8,
    nodes: u64,
};

const SearchCtx = struct {
    tt: *TranspositionTable,
    timer: Timer,
    nodes: u64 = 0,
    aborted: bool = false,
    root_best: Move = undefined,
    variant: Variant,
};

/// Time-limited search with iterative deepening. Returns the best move from
/// the deepest completed iteration. Deterministic for a given position and
/// time limit (fixed Zobrist seed, fresh TT per call).
pub fn search(board: Board32, turn: Color, time_limit_ms: u32, allocator: std.mem.Allocator, variant: Variant) !SearchResult {
    var tt = try TranspositionTable.init(allocator, 1 << 16);
    defer tt.deinit();
    var ctx = SearchCtx{ .tt = &tt, .timer = Timer.init(time_limit_ms), .variant = variant };

    var moves = MoveList{};
    rules.generateMoves(board, turn, &moves, variant);
    if (moves.len == 0) return error.NoMoves;

    var best = moves.slice()[0];
    var best_score: i32 = 0;
    var completed_depth: u8 = 0;
    var depth: u8 = 1;
    while (depth <= MAX_DEPTH) : (depth += 1) {
        ctx.aborted = false;
        ctx.nodes = 0;
        const score = rootSearch(board, turn, depth, &ctx);
        if (ctx.aborted) break;
        best = ctx.root_best;
        best_score = score;
        completed_depth = depth;
    }
    return .{ .move = best, .score = best_score, .depth = completed_depth, .nodes = ctx.nodes };
}

/// Fixed-depth search (no time limit). Depth 0 is clamped to 1.
pub fn searchDepth(board: Board32, turn: Color, depth: u8, allocator: std.mem.Allocator, variant: Variant) !SearchResult {
    var tt = try TranspositionTable.init(allocator, 1 << 16);
    defer tt.deinit();
    var ctx = SearchCtx{ .tt = &tt, .timer = Timer.init(0), .variant = variant };

    var moves = MoveList{};
    rules.generateMoves(board, turn, &moves, variant);
    if (moves.len == 0) return error.NoMoves;

    const d: u8 = if (depth == 0) 1 else depth;
    const score = rootSearch(board, turn, d, &ctx);
    return .{ .move = ctx.root_best, .score = score, .depth = d, .nodes = ctx.nodes };
}

/// Searches all root moves, tracks the best, and stores it in ctx.root_best.
fn rootSearch(board: Board32, turn: Color, depth: u8, ctx: *SearchCtx) i32 {
    var moves = MoveList{};
    rules.generateMoves(board, turn, &moves, ctx.variant);
    var best_score: i32 = std.math.minInt(i32) + 1;
    var best_move = moves.slice()[0];
    var alpha = best_score;
    const beta: i32 = std.math.maxInt(i32);
    for (moves.slice()) |m| {
        var b2 = board;
        rules.applyMove(&b2, m);
        const score = -negamax(b2, board_mod.opponent(turn), depth - 1, -beta, -alpha, 1, ctx);
        if (ctx.aborted) return 0;
        if (score > best_score) {
            best_score = score;
            best_move = m;
        }
        if (score > alpha) alpha = score;
    }
    ctx.root_best = best_move;
    return best_score;
}

fn negamax(board: Board32, turn: Color, depth: u8, alpha_in: i32, beta_in: i32, ply: u8, ctx: *SearchCtx) i32 {
    ctx.nodes += 1;
    if (ctx.timer.expired()) {
        ctx.aborted = true;
        return 0;
    }
    var alpha = alpha_in;
    var beta = beta_in;

    var moves = MoveList{};
    rules.generateMoves(board, turn, &moves, ctx.variant);
    if (moves.len == 0) return -MATE_SCORE + @as(i32, ply);
    if (depth == 0) return evaluate(board, turn);

    const key = zobrist.hash(board, turn);
    const tt_entry = ctx.tt.get(key);
    if (tt_entry) |e| {
        if (e.depth >= depth) {
            switch (e.flag) {
                .exact => return e.score,
                .lower_bound => alpha = @max(alpha, e.score),
                .upper_bound => beta = @min(beta, e.score),
            }
            if (alpha >= beta) return e.score;
        }
    }

    orderMoves(&moves, board, if (tt_entry) |e| e.move else null);

    var best_score: i32 = std.math.minInt(i32) + 1;
    var best_move: ?Move = null;
    for (moves.slice()) |m| {
        var b2 = board;
        rules.applyMove(&b2, m);
        const score = -negamax(b2, board_mod.opponent(turn), depth - 1, -beta, -alpha, ply + 1, ctx);
        if (ctx.aborted) return 0;
        if (score > best_score) {
            best_score = score;
            best_move = m;
        }
        if (score > alpha) alpha = score;
        if (alpha >= beta) break;
    }

    var flag: TTFlag = .upper_bound;
    if (best_score > alpha_in) flag = .exact;
    if (alpha >= beta) flag = .lower_bound;
    if (best_move) |bm| {
        ctx.tt.put(.{ .key = key, .depth = depth, .score = best_score, .flag = flag, .move = bm });
    }
    return best_score;
}

/// Material + small positional terms, from the side-to-move's perspective.
/// Pawn 100, king 300; pawns +10 per row advanced past their start rows;
/// kings +5 toward the center columns.
fn evaluate(board: Board32, turn: Color) i32 {
    var score: i32 = 0;
    for (0..32) |sq| {
        const piece = board[sq];
        const rc = board_mod.squareToRowCol(@intCast(sq));
        const v: i32 = switch (piece) {
            .white_pawn => PAWN_VALUE + 10 * @as(i32, rc.row),
            .white_king => KING_VALUE + centerBonus(rc.col),
            .black_pawn => -(PAWN_VALUE + 10 * @as(i32, 7 - rc.row)),
            .black_king => -(KING_VALUE + centerBonus(rc.col)),
            .empty => 0,
        };
        score += v;
    }
    return if (turn == .white) score else -score;
}

fn centerBonus(col: u8) i32 {
    return if (col >= 3 and col <= 4) 5 else 0;
}

const OrderCtx = struct { board: Board32, tt_move: ?Move };

/// MVV-LVA ordering: TT move first, then captures by victim value desc /
/// attacker value asc, then quiet moves.
fn orderMoves(moves: *MoveList, board: Board32, tt_move: ?Move) void {
    const ctx = OrderCtx{ .board = board, .tt_move = tt_move };
    std.sort.block(Move, moves.mutSlice(), ctx, lessThan);
}

fn lessThan(ctx: OrderCtx, a: Move, b: Move) bool {
    return moveScore(a, ctx) > moveScore(b, ctx);
}

fn moveScore(m: Move, ctx: OrderCtx) i32 {
    if (ctx.tt_move) |tm| {
        if (tm.from == m.from and tm.to == m.to and tm.num_captured == m.num_captured) return 1_000_000;
    }
    if (m.num_captured > 0) {
        const victim = pieceValue(ctx.board[m.captured[0]]);
        const attacker = pieceValue(ctx.board[m.from]);
        return victim * 10 - attacker;
    }
    return 0;
}

fn pieceValue(piece: Piece) i32 {
    return switch (piece) {
        .white_king, .black_king => KING_VALUE,
        .white_pawn, .black_pawn => PAWN_VALUE,
        .empty => 0,
    };
}

test "forced capture is found" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    board[board_mod.rowColToSquare(3, 3)] = .black_pawn;
    const result = try searchDepth(board, .white, 3, std.testing.allocator, .english);
    try std.testing.expect(move_mod.isCapture(result.move));
}

test "material advantage evaluates positive" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    board[board_mod.rowColToSquare(3, 3)] = .black_pawn;
    board[board_mod.rowColToSquare(5, 5)] = .white_pawn;
    const result = try searchDepth(board, .white, 2, std.testing.allocator, .english);
    try std.testing.expect(result.score > 0);
}

test "search is deterministic with fresh TT" {
    const board = board_mod.initialBoard();
    const r1 = try searchDepth(board, .white, 3, std.testing.allocator, .english);
    const r2 = try searchDepth(board, .white, 3, std.testing.allocator, .english);
    try std.testing.expectEqual(r1.move.from, r2.move.from);
    try std.testing.expectEqual(r1.move.to, r2.move.to);
    try std.testing.expectEqual(r1.score, r2.score);
}

test "search with 1ms time limit returns a legal move" {
    const board = board_mod.initialBoard();
    const result = try search(board, .white, 1, std.testing.allocator, .english);
    var moves = MoveList{};
    rules.generateMoves(board, .white, &moves, .english);
    var found = false;
    for (moves.slice()) |m| {
        if (m.from == result.move.from and m.to == result.move.to) found = true;
    }
    try std.testing.expect(found);
}

test "initial position search returns a legal move" {
    const board = board_mod.initialBoard();
    const result = try search(board, .white, 100, std.testing.allocator, .english);
    try std.testing.expect(result.depth >= 1);
    var moves = MoveList{};
    rules.generateMoves(board, .white, &moves, .english);
    var found = false;
    for (moves.slice()) |m| {
        if (m.from == result.move.from and m.to == result.move.to) found = true;
    }
    try std.testing.expect(found);
}

test "deeper search finds at least as good a score" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    board[board_mod.rowColToSquare(3, 3)] = .black_pawn;
    board[board_mod.rowColToSquare(5, 5)] = .black_pawn;
    const d1 = try searchDepth(board, .white, 1, std.testing.allocator, .english);
    const d3 = try searchDepth(board, .white, 3, std.testing.allocator, .english);
    try std.testing.expect(d3.score >= d1.score);
}

test "promotion move is found when it is the only move" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[board_mod.rowColToSquare(6, 6)] = .white_pawn;
    const result = try searchDepth(board, .white, 2, std.testing.allocator, .english);
    const rc = board_mod.squareToRowCol(result.move.to);
    try std.testing.expectEqual(@as(u8, 7), rc.row);
}
