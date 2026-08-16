//! Negamax alpha-beta search with iterative deepening, transposition table,
//! MVV-LVA move ordering, and a time limit.
//!
//! Simplifications (deliberate): no quiescence search (horizon effect
//! accepted), TT replacement is overwrite-only, eval is material + mobility
//! + promo bonus + edge/perro structure. Board copies (32 bytes) are used
//! for undo.

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
const KING_VALUE: i32 = 300; // ordering heuristic only; eval uses kingValue(variant)

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
    // TT is per-call, so scores from different variants never mix. A
    // persistent TT would need the variant in the zobrist key.
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
    // Check the clock only every 1024 nodes: clock_gettime per node was the
    // dominant cost in millions-node searches. Worst-case abort delay is
    // 1024 nodes (~tens of us) — negligible against any real time budget.
    if ((ctx.nodes & 0x3ff) == 0 and ctx.timer.expired()) {
        ctx.aborted = true;
        return 0;
    }
    var alpha = alpha_in;
    var beta = beta_in;

    var moves = MoveList{};
    rules.generateMoves(board, turn, &moves, ctx.variant);
    if (moves.len == 0) return -MATE_SCORE + @as(i32, ply);
    if (depth == 0) return evaluate(board, turn, ctx.variant);

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

/// King value used by the evaluator: Spanish flying kings are worth more.
/// `pieceValue` (move ordering) deliberately stays at the static 300.
fn kingValue(variant: Variant) i32 {
    return switch (variant) {
        .english => 300,
        .spanish => 500,
    };
}

/// The four diagonal directions as (dr, dc) offsets.
// Order must match rules.zig king_dirs — structurePenalty/pawnDest index by it.
const dirs = [_][2]i8{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 } };

/// ray_table[sq][d][k] = square reached from sq after k+1 steps in direction
/// d, or -1 once the ray leaves the board. An 8x8 diagonal is at most 7
/// steps long, so the table IS the spec's cap-7 per ray.
const ray_table: [32][4][7]i8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [32][4][7]i8 = undefined;
    for (0..32) |sq| {
        const rc = board_mod.squareToRowCol(@intCast(sq));
        for (0..4) |d| {
            var row: i8 = @intCast(rc.row);
            var col: i8 = @intCast(rc.col);
            for (0..7) |k| {
                row += dirs[d][0];
                col += dirs[d][1];
                if (row < 0 or row >= 8 or col < 0 or col >= 8) {
                    t[sq][d][k] = -1;
                } else {
                    t[sq][d][k] = @intCast(board_mod.rowColToSquare(@intCast(row), @intCast(col)));
                }
            }
        }
    }
    break :blk t;
};

/// Empty forward-diagonal destinations for a man (2 max, 1 on an edge).
fn pawnDest(board: Board32, sq: u8, color: Color) i32 {
    var n: i32 = 0;
    const first: usize = if (color == .white) 2 else 0;
    for (first..first + 2) |d| {
        const nsq = ray_table[sq][d][0];
        if (nsq < 0) continue;
        if (board[@intCast(nsq)] == .empty) n += 1;
    }
    return n;
}

/// Empty destinations for a king: one step per diagonal (English) or a walk
/// to the first blocker (Spanish — a flying king can't pass an occupied
/// square without capturing, see rules.zig slide semantics).
fn kingDest(board: Board32, sq: u8, variant: Variant) i32 {
    var n: i32 = 0;
    for (0..4) |d| {
        if (variant == .english) {
            const nsq = ray_table[sq][d][0];
            if (nsq >= 0 and board[@intCast(nsq)] == .empty) n += 1;
        } else {
            for (ray_table[sq][d]) |nsq| {
                if (nsq < 0) break;
                if (board[@intCast(nsq)] != .empty) break;
                n += 1;
            }
        }
    }
    return n;
}

/// Pseudo-mobility by piece color: white's empty destinations minus black's
/// (3 per king dest, 1 per man dest). Color-based, never side-to-move, so
/// the single perspective flip in evaluate carries no tempo bias.
fn mobility(board: Board32, variant: Variant) i32 {
    var mob: i32 = 0;
    for (0..32) |sq| {
        switch (board[sq]) {
            .white_pawn => mob += pawnDest(board, @intCast(sq), .white),
            .black_pawn => mob -= pawnDest(board, @intCast(sq), .black),
            .white_king => mob += 3 * kingDest(board, @intCast(sq), variant),
            .black_king => mob -= 3 * kingDest(board, @intCast(sq), variant),
            .empty => {},
        }
    }
    return mob;
}

/// +40 for a man on the penultimate row (6 white / 1 black) with an empty
/// forward-diagonal landing square. Not the last row: men are promoted on
/// landing (rules.zig) and never sit there.
fn promotionBonus(board: Board32, sq: u8, color: Color) i32 {
    const rc = board_mod.squareToRowCol(sq);
    const promo_row: u8 = if (color == .white) 6 else 1;
    if (rc.row != promo_row) return 0;
    return if (pawnDest(board, sq, color) > 0) 40 else 0;
}

/// Edge structure: -10 per man on an edge column, -50 extra for a true
/// "perro" — an edge man with no legal move and no legal capture. Capture
/// detection matches rules.zig: pawns capture forward only in both variants,
/// so only the two forward directions are checked (English kings capture in
/// all four directions, but kings never reach this function — it is called
/// only for pawns). A capture exists only when the intermediate square holds
/// an enemy piece AND the landing square is on-board and empty.
fn structurePenalty(board: Board32, sq: u8, color: Color) i32 {
    const rc = board_mod.squareToRowCol(sq);
    if (rc.col != 0 and rc.col != 7) return 0;
    var penalty: i32 = 10;
    const has_move = pawnDest(board, sq, color) > 0;
    const first: usize = if (color == .white) 2 else 0;
    var has_capture = false;
    for (first..first + 2) |d| {
        const mid = ray_table[sq][d][0];
        if (mid < 0) continue;
        const p = board[@intCast(mid)];
        if (p == .empty) continue;
        if (board_mod.pieceColor(p).? == color) continue;
        const land = ray_table[sq][d][1];
        if (land >= 0 and board[@intCast(land)] == .empty) {
            has_capture = true;
            break;
        }
    }
    if (!has_move and !has_capture) penalty += 50;
    return -penalty;
}

/// Material + positional terms, white-positive, flipped exactly once into
/// the side-to-move's perspective. Man 100 (+10/row, +40 promo bonus on the
/// penultimate row, edge/perro penalty); king kingValue(variant) (+5 center);
/// pseudo-mobility (3/king dest, 1/man dest).
fn evaluate(board: Board32, turn: Color, variant: Variant) i32 {
    var score: i32 = 0;
    for (0..32) |sq| {
        const piece = board[sq];
        const rc = board_mod.squareToRowCol(@intCast(sq));
        const v: i32 = switch (piece) {
            .white_pawn => PAWN_VALUE + 10 * @as(i32, rc.row) + promotionBonus(board, @intCast(sq), .white) + structurePenalty(board, @intCast(sq), .white),
            .white_king => kingValue(variant) + centerBonus(rc.col),
            .black_pawn => -(PAWN_VALUE + 10 * @as(i32, 7 - rc.row) + promotionBonus(board, @intCast(sq), .black) + structurePenalty(board, @intCast(sq), .black)),
            .black_king => -(kingValue(variant) + centerBonus(rc.col)),
            .empty => 0,
        };
        score += v;
    }
    score += mobility(board, variant);
    return if (turn == .white) score else -score;
}

/// Old material + row-advance + center logic (now variant-aware king value),
/// white-positive with no flip. Kept for test comparison against the
/// positional terms.
fn evaluateMaterial(board: Board32, variant: Variant) i32 {
    var score: i32 = 0;
    for (0..32) |sq| {
        const piece = board[sq];
        const rc = board_mod.squareToRowCol(@intCast(sq));
        const v: i32 = switch (piece) {
            .white_pawn => PAWN_VALUE + 10 * @as(i32, rc.row),
            .white_king => kingValue(variant) + centerBonus(rc.col),
            .black_pawn => -(PAWN_VALUE + 10 * @as(i32, 7 - rc.row)),
            .black_king => -(kingValue(variant) + centerBonus(rc.col)),
            .empty => 0,
        };
        score += v;
    }
    return score;
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

/// Positional terms (mobility + promo + structure) for one color only; the
/// corpus test uses it to check each side stays well under one pawn.
fn sidePositional(board: Board32, variant: Variant, color: Color) i32 {
    var s: i32 = 0;
    for (0..32) |sq| {
        const p = board[sq];
        const c = board_mod.pieceColor(p) orelse continue;
        if (c != color) continue;
        const sq_u: u8 = @intCast(sq);
        switch (p) {
            .white_pawn, .black_pawn => s += pawnDest(board, sq_u, color) + promotionBonus(board, sq_u, color) + structurePenalty(board, sq_u, color),
            else => s += 3 * kingDest(board, sq_u, variant),
        }
    }
    return s;
}

test "evaluate is antisymmetric in turn" {
    var b1: Board32 = undefined;
    b1 = board_mod.initialBoard();
    var b2: Board32 = [_]Piece{.empty} ** 32;
    b2[board_mod.rowColToSquare(4, 4)] = .white_king;
    b2[board_mod.rowColToSquare(0, 0)] = .black_king;
    b2[board_mod.rowColToSquare(7, 7)] = .black_king;
    var b3: Board32 = [_]Piece{.empty} ** 32;
    b3[board_mod.rowColToSquare(5, 5)] = .white_pawn;
    b3[board_mod.rowColToSquare(4, 2)] = .white_pawn;
    b3[board_mod.rowColToSquare(2, 4)] = .black_pawn;
    const cases = [_]struct { board: Board32, variant: Variant }{
        .{ .board = b1, .variant = .english },
        .{ .board = b1, .variant = .spanish },
        .{ .board = b2, .variant = .spanish }, // king-heavy endgame
        .{ .board = b3, .variant = .english },
    };
    for (cases) |c| {
        try std.testing.expectEqual(-evaluate(c.board, .black, c.variant), evaluate(c.board, .white, c.variant));
    }
}

test "evaluate: blocked diagonals change the mobility term" {
    // Same material (one king each). `blocked` corners the black king (1
    // destination vs 4), flipping the white-black mobility balance from 0 to
    // +9 — mobility is the only term that differs.
    var blocked: Board32 = [_]Piece{.empty} ** 32;
    blocked[board_mod.rowColToSquare(4, 4)] = .white_king;
    blocked[board_mod.rowColToSquare(7, 7)] = .black_king;
    var open: Board32 = [_]Piece{.empty} ** 32;
    open[board_mod.rowColToSquare(4, 4)] = .white_king;
    open[board_mod.rowColToSquare(1, 1)] = .black_king;
    try std.testing.expect(evaluate(blocked, .white, .english) > evaluate(open, .white, .english));
}

test "evaluate: spanish king scores higher than english king" {
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[board_mod.rowColToSquare(4, 4)] = .white_king;
    try std.testing.expect(evaluate(board, .white, .spanish) > evaluate(board, .white, .english));
}

test "evaluate: penultimate-row man gets the promo bonus" {
    var near: Board32 = [_]Piece{.empty} ** 32;
    near[board_mod.rowColToSquare(6, 6)] = .white_pawn;
    var far: Board32 = [_]Piece{.empty} ** 32;
    far[board_mod.rowColToSquare(5, 5)] = .white_pawn;
    try std.testing.expect(evaluate(near, .white, .english) > evaluate(far, .white, .english));
}

test "evaluate: edge man blocked behind an own piece is a perro" {
    // Identical material (a row-0 and a row-1 white pawn). In `blocked` the
    // (0,0) man has no forward move and no capture ((1,1) is own) → perro;
    // in `open` (1,1) is clear and the man moves freely.
    var blocked: Board32 = [_]Piece{.empty} ** 32;
    blocked[board_mod.rowColToSquare(0, 0)] = .white_pawn;
    blocked[board_mod.rowColToSquare(1, 1)] = .white_pawn;
    var open: Board32 = [_]Piece{.empty} ** 32;
    open[board_mod.rowColToSquare(0, 0)] = .white_pawn;
    open[board_mod.rowColToSquare(1, 3)] = .white_pawn;
    try std.testing.expect(evaluate(blocked, .white, .english) < evaluate(open, .white, .english));
}

test "evaluate: a legal forward capture rescues an edge man from perro" {
    // Pawns capture forward only in both variants, so an enemy behind the
    // man never rescues it. W(4,0) has its own W(5,1) forward (no quiet
    // move); a backward enemy B(3,1) leaves it a perro — identical in
    // English and Spanish (old code scored english > spanish here because
    // the eval re-implemented the backward-capture bug).
    var backward_enemy: Board32 = [_]Piece{.empty} ** 32;
    backward_enemy[board_mod.rowColToSquare(4, 0)] = .white_pawn;
    backward_enemy[board_mod.rowColToSquare(5, 1)] = .white_pawn;
    backward_enemy[board_mod.rowColToSquare(3, 1)] = .black_pawn;
    try std.testing.expectEqual(evaluate(backward_enemy, .white, .english), evaluate(backward_enemy, .white, .spanish));

    // A forward enemy with an empty landing rescues the man — identically
    // in both variants. Same material as backward_enemy (2 white, 1 black),
    // so the rescue signal is comparable.
    var forward_capture: Board32 = [_]Piece{.empty} ** 32;
    forward_capture[board_mod.rowColToSquare(4, 0)] = .white_pawn;
    forward_capture[board_mod.rowColToSquare(5, 1)] = .black_pawn;
    forward_capture[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    try std.testing.expectEqual(evaluate(forward_capture, .white, .english), evaluate(forward_capture, .white, .spanish));
    try std.testing.expect(evaluate(forward_capture, .white, .english) > evaluate(backward_enemy, .white, .english));
}

test "evaluate: positional terms stay under one pawn per side" {
    // Tagged quiet positions; the initial board is excluded — its corner
    // perros (-123/side: -120 structure + 7 mobility) legitimately exceed
    // one pawn, and it is covered by the exact-value regression instead.
    const Pos = struct { board: Board32, variant: Variant };
    var mat: Board32 = [_]Piece{.empty} ** 32;
    mat[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    mat[board_mod.rowColToSquare(4, 4)] = .white_pawn;
    mat[board_mod.rowColToSquare(6, 6)] = .black_pawn;
    var mob: Board32 = [_]Piece{.empty} ** 32;
    mob[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    mob[board_mod.rowColToSquare(5, 7)] = .black_pawn;
    var promo: Board32 = [_]Piece{.empty} ** 32;
    promo[board_mod.rowColToSquare(6, 6)] = .white_pawn;
    var perro: Board32 = [_]Piece{.empty} ** 32;
    perro[board_mod.rowColToSquare(0, 0)] = .white_pawn;
    perro[board_mod.rowColToSquare(1, 1)] = .white_pawn;
    var kings: Board32 = [_]Piece{.empty} ** 32;
    kings[board_mod.rowColToSquare(4, 4)] = .white_king;
    kings[board_mod.rowColToSquare(0, 0)] = .black_king;
    kings[board_mod.rowColToSquare(7, 7)] = .black_king;
    const cases = [_]Pos{
        .{ .board = mat, .variant = .english },
        .{ .board = mob, .variant = .english },
        .{ .board = promo, .variant = .english },
        .{ .board = perro, .variant = .english },
        .{ .board = kings, .variant = .spanish },
    };
    for (cases) |c| {
        try std.testing.expect(@abs(evaluate(c.board, .white, c.variant) - evaluateMaterial(c.board, c.variant)) < 100);
        try std.testing.expect(@abs(sidePositional(c.board, c.variant, .white)) < 100);
        try std.testing.expect(@abs(sidePositional(c.board, c.variant, .black)) < 100);
    }
}

test "evaluate: quiet-position regression (exact values)" {
    // Exact expected values, no tolerance. Comments name the deciding term.
    const Pos = struct { board: Board32, variant: Variant, expected: i32 };
    var initial: Board32 = undefined;
    initial = board_mod.initialBoard();
    var mat: Board32 = [_]Piece{.empty} ** 32;
    mat[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    mat[board_mod.rowColToSquare(4, 4)] = .white_pawn;
    mat[board_mod.rowColToSquare(6, 6)] = .black_pawn;
    var mob: Board32 = [_]Piece{.empty} ** 32;
    mob[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    mob[board_mod.rowColToSquare(5, 7)] = .black_pawn;
    var promo: Board32 = [_]Piece{.empty} ** 32;
    promo[board_mod.rowColToSquare(6, 6)] = .white_pawn;
    var perro: Board32 = [_]Piece{.empty} ** 32;
    perro[board_mod.rowColToSquare(0, 0)] = .white_pawn;
    perro[board_mod.rowColToSquare(1, 1)] = .white_pawn;
    var king: Board32 = [_]Piece{.empty} ** 32;
    king[board_mod.rowColToSquare(4, 4)] = .white_king;
    const cases = [_]Pos{
        .{ .board = initial, .variant = .english, .expected = 0 }, // symmetric: material and corner perros cancel
        .{ .board = mat, .variant = .english, .expected = 152 }, // material +1 pawn, open mobility
        .{ .board = mob, .variant = .english, .expected = 11 }, // mobility 2 vs 1 (+1), black edge man -10 (+10)
        .{ .board = promo, .variant = .english, .expected = 202 }, // promo-row man (2 forward squares)
        .{ .board = perro, .variant = .english, .expected = 152 }, // (0,0) perro -60
        .{ .board = king, .variant = .spanish, .expected = 544 }, // open flying king 500 + center + mobility
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.expected, evaluate(c.board, .white, c.variant));
    }
}

test "evaluate: promotion race picks the racing man at shallow depth" {
    // White (5,5) and black (2,4) both promote in two moves; white moves
    // first. The old eval (row advance only) ties between pushing (5,5) and
    // shuffling (4,2) at depth 2; the +40 promo bonus breaks the tie toward
    // the racing man at depth 3.
    var board: Board32 = [_]Piece{.empty} ** 32;
    board[board_mod.rowColToSquare(5, 5)] = .white_pawn;
    board[board_mod.rowColToSquare(4, 2)] = .white_pawn;
    board[board_mod.rowColToSquare(2, 4)] = .black_pawn;
    const result = try searchDepth(board, .white, 3, std.testing.allocator, .english);
    try std.testing.expectEqual(board_mod.rowColToSquare(5, 5), result.move.from);
}
