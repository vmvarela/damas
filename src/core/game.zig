//! Game state: board, turn, and lifecycle.

const std = @import("std");
const board_mod = @import("board.zig");
const move_mod = @import("move.zig");
const rules = @import("rules.zig");
const zobrist = @import("engine/zobrist.zig");

pub const Color = board_mod.Color;
pub const Piece = board_mod.Piece;
pub const Board32 = board_mod.Board32;
pub const Move = move_mod.Move;
pub const MoveList = move_mod.MoveList;
pub const Variant = rules.Variant;

pub const Game = struct {
    board: Board32,
    turn: Color,
    rules: Variant,
    allocator: std.mem.Allocator,

    /// Zobrist hash -> occurrence count for 3-fold repetition. Null until the
    /// first move, then allocated lazily: protocol.zig's new_game assigns the
    /// struct via a literal (which would leak an eagerly allocated map), so
    /// the map is only created on first use.
    position_history: ?std.AutoHashMap(u64, u8) = null,
    /// Plies since the last capture or promotion; >= 80 declares a draw.
    halfmove_clock: u16 = 0,

    /// Default to Spanish damas.
    pub fn init(allocator: std.mem.Allocator) !*Game {
        return initRules(allocator, .spanish);
    }

    pub fn initRules(allocator: std.mem.Allocator, variant: Variant) !*Game {
        const game = try allocator.create(Game);
        game.* = .{
            .board = board_mod.initialBoard(),
            .turn = .white,
            .rules = variant,
            .allocator = allocator,
            .halfmove_clock = 0,
        };
        return game;
    }

    pub fn deinit(self: *Game) void {
        if (self.position_history) |*h| h.deinit();
        self.allocator.destroy(self);
    }

    pub fn generateMoves(self: *Game, moves: *MoveList) void {
        rules.generateMoves(self.board, self.turn, moves, self.rules);
    }

    /// Validate and apply a move; flips the turn. Returns false if illegal
    /// (board and turn unchanged). Tracks the halfmove clock and 3-fold
    /// repetition: captures and promotions are irreversible (clock resets,
    /// history clears), quiet moves advance the clock and record the position.
    pub fn applyMove(self: *Game, move: Move) bool {
        if (!rules.isLegalMove(self.board, self.turn, move, self.rules)) return false;
        const moved_piece = self.board[move.from]; // rules.applyMove empties `from`
        rules.applyMove(&self.board, move);
        self.turn = board_mod.opponent(self.turn);

        // Only a promotion turns a pawn into a king, so a king on the landing
        // square that wasn't one before the move proves promotion.
        const promoted = board_mod.isKing(self.board[move.to]) and !board_mod.isKing(moved_piece);
        if (move.num_captured > 0 or promoted) {
            self.halfmove_clock = 0;
            if (self.position_history) |*h| h.clearRetainingCapacity();
        } else {
            self.halfmove_clock += 1;
        }
        self.recordPosition();
        return true;
    }

    /// Game over when the current turn has no moves, a side has no pieces,
    /// 80 plies pass without a capture or promotion, or a position repeats
    /// 3 times.
    pub fn isGameOver(self: *Game) bool {
        if (!rules.hasAnyMove(self.board, self.turn, self.rules)) return true;
        if (!hasPieces(self.board, .white) or !hasPieces(self.board, .black)) return true;
        if (self.halfmove_clock >= 80) return true;
        if (self.position_history) |h| {
            var it = h.valueIterator();
            while (it.next()) |count| {
                if (count.* >= 3) return true;
            }
        }
        return false;
    }

    /// The position history map, allocated on first use (kept null otherwise:
    /// protocol.zig's new_game assigns the Game via a struct literal, which
    /// would leak an eagerly allocated map).
    fn history(self: *Game) *std.AutoHashMap(u64, u8) {
        if (self.position_history) |*h| return h;
        self.position_history = std.AutoHashMap(u64, u8).init(self.allocator);
        return &self.position_history.?;
    }

    /// Record the current position, incrementing its occurrence count
    /// (saturating at 255).
    fn recordPosition(self: *Game) void {
        const gop = self.history().getOrPut(zobrist.hash(self.board, self.turn)) catch unreachable; // ponytail: tiny map, OOM ~impossible
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
    }

    /// Winner, or null if the game is not over or ended in a draw.
    /// A player blocked with no legal move does not lose — it's a draw.
    pub fn winner(self: *Game) ?Color {
        if (!self.isGameOver()) return null;
        if (!hasPieces(self.board, .white)) return .black;
        if (!hasPieces(self.board, .black)) return .white;
        // Both sides have pieces: the current turn is stalemated → draw.
        return null;
    }
};

fn hasPieces(board: Board32, color: Color) bool {
    for (board) |p| {
        if (board_mod.pieceColor(p) == color) return true;
    }
    return false;
}

test "init/deinit and initial state" {
    var game = try Game.init(std.testing.allocator);
    defer game.deinit();
    try std.testing.expectEqual(Color.white, game.turn);
    var moves = MoveList{};
    game.generateMoves(&moves);
    try std.testing.expectEqual(@as(usize, 7), moves.len);
}

test "applyMove flips turn and rejects illegal moves" {
    var game = try Game.init(std.testing.allocator);
    defer game.deinit();

    // Legal opening move: (2,0) -> (3,1).
    const legal = Move{ .from = board_mod.rowColToSquare(2, 0), .to = board_mod.rowColToSquare(3, 1), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    try std.testing.expect(game.applyMove(legal));
    try std.testing.expectEqual(Color.black, game.turn);

    // Illegal move (white's pawn, black's turn): rejected, turn unchanged.
    const illegal = Move{ .from = board_mod.rowColToSquare(2, 2), .to = board_mod.rowColToSquare(3, 3), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    try std.testing.expect(!game.applyMove(illegal));
    try std.testing.expectEqual(Color.black, game.turn);
}

test "initRules selects the variant" {
    var game = try Game.initRules(std.testing.allocator, .spanish);
    defer game.deinit();
    try std.testing.expectEqual(Variant.spanish, game.rules);
    var moves = MoveList{};
    game.generateMoves(&moves);
    // Initial position: pawns only, same 7 forward quiet moves as English.
    try std.testing.expectEqual(@as(usize, 7), moves.len);
}

test "game over detection and winner" {
    var game = try Game.init(std.testing.allocator);
    defer game.deinit();

    // White pawn at (0,0) fully blocked: no moves for white.
    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(0, 0)] = .white_pawn;
    game.board[board_mod.rowColToSquare(1, 1)] = .black_pawn;
    game.board[board_mod.rowColToSquare(2, 0)] = .black_pawn;
    game.board[board_mod.rowColToSquare(2, 2)] = .black_pawn;
    game.turn = .white;

    try std.testing.expect(game.isGameOver());
    // Stalemated side doesn't lose: the game is a draw.
    try std.testing.expectEqual(@as(?Color, null), game.winner());

    // No pieces left for white.
    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(7, 7)] = .black_pawn;
    game.turn = .white;
    try std.testing.expect(game.isGameOver());
    try std.testing.expectEqual(@as(?Color, .black), game.winner());
}

/// Find the generated move from `from` to `to`, or null.
fn findMove(moves: *const MoveList, from: u8, to: u8) ?Move {
    for (moves.slice()) |m| {
        if (m.from == from and m.to == to) return m;
    }
    return null;
}

/// Play the generated move (from_row, from_col) -> (to_row, to_col); panics
/// if the move generator doesn't produce it.
fn playFromTo(game: *Game, from_row: u8, from_col: u8, to_row: u8, to_col: u8) !void {
    var moves = MoveList{};
    game.generateMoves(&moves);
    const m = findMove(&moves, board_mod.rowColToSquare(from_row, from_col), board_mod.rowColToSquare(to_row, to_col)) orelse
        @panic("expected move not generated");
    try std.testing.expect(game.applyMove(m));
}

// Two-king shuffle: kings at (4,2)/(4,6) out-and-back. Never adjacent, so no
// captures exist; the position repeats every 4 plies (row, col, to_row, to_col).
const shuffle_cycle = [_][4]u8{
    .{ 4, 2, 3, 1 },
    .{ 4, 6, 3, 5 },
    .{ 3, 1, 4, 2 },
    .{ 3, 5, 4, 6 },
};

test "repetition: same position 3 times is a draw" {
    var game = try Game.initRules(std.testing.allocator, .english);
    defer game.deinit();

    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(4, 2)] = .white_king;
    game.board[board_mod.rowColToSquare(4, 6)] = .black_king;
    game.turn = .white;
    game.halfmove_clock = 0;
    game.recordPosition(); // seed the test position (lazily allocates the map)

    // One full cycle (4 plies): the start position has occurred twice.
    for (shuffle_cycle) |c| try playFromTo(game, c[0], c[1], c[2], c[3]);
    try std.testing.expect(!game.isGameOver());

    // Second full cycle: the start position occurs a third time -> draw.
    for (shuffle_cycle) |c| try playFromTo(game, c[0], c[1], c[2], c[3]);
    try std.testing.expect(game.isGameOver());
    try std.testing.expectEqual(@as(?Color, null), game.winner());
}

test "40-move rule: no capture or promotion for 80 plies is a draw" {
    var game = try Game.init(std.testing.allocator);
    defer game.deinit();

    game.halfmove_clock = 79;
    const legal = Move{ .from = board_mod.rowColToSquare(2, 0), .to = board_mod.rowColToSquare(3, 1), .captured = [_]u8{0} ** 12, .num_captured = 0 };
    try std.testing.expect(game.applyMove(legal));
    try std.testing.expectEqual(@as(u16, 80), game.halfmove_clock);
    try std.testing.expect(game.isGameOver());
    try std.testing.expectEqual(@as(?Color, null), game.winner());
}

test "capture resets the halfmove clock" {
    var game = try Game.initRules(std.testing.allocator, .english);
    defer game.deinit();

    // White pawn captures (3,3); a second black pawn survives the capture so
    // the game isn't over from missing pieces.
    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    game.board[board_mod.rowColToSquare(3, 3)] = .black_pawn;
    game.board[board_mod.rowColToSquare(6, 6)] = .black_pawn;
    game.turn = .white;
    game.halfmove_clock = 79;
    game.recordPosition();

    var moves = MoveList{};
    game.generateMoves(&moves);
    const cap = findMove(&moves, board_mod.rowColToSquare(2, 2), board_mod.rowColToSquare(4, 4)) orelse
        @panic("expected capture move not generated");
    try std.testing.expect(cap.num_captured > 0);
    try std.testing.expect(game.applyMove(cap));
    try std.testing.expectEqual(@as(u16, 0), game.halfmove_clock);
    try std.testing.expect(!game.isGameOver());
}

test "promotion resets the halfmove clock" {
    var game = try Game.initRules(std.testing.allocator, .english);
    defer game.deinit();

    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(6, 2)] = .white_pawn;
    game.board[board_mod.rowColToSquare(6, 6)] = .black_pawn; // survives the promotion
    game.turn = .white;
    game.halfmove_clock = 79;
    game.recordPosition();

    var moves = MoveList{};
    game.generateMoves(&moves);
    const promo = findMove(&moves, board_mod.rowColToSquare(6, 2), board_mod.rowColToSquare(7, 1)) orelse
        @panic("expected promotion move not generated");
    try std.testing.expectEqual(@as(u8, 0), promo.num_captured);
    try std.testing.expect(game.applyMove(promo));
    try std.testing.expectEqual(@as(u16, 0), game.halfmove_clock);
    try std.testing.expectEqual(Piece.white_king, game.board[board_mod.rowColToSquare(7, 1)]);
    try std.testing.expect(!game.isGameOver());
}

test "repetition history is cleared after a capture" {
    var game = try Game.initRules(std.testing.allocator, .english);
    defer game.deinit();

    // Phase 1: shuffle cycle builds up repetition counts.
    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(4, 2)] = .white_king;
    game.board[board_mod.rowColToSquare(4, 6)] = .black_king;
    game.turn = .white;
    game.halfmove_clock = 0;
    game.recordPosition();
    for (shuffle_cycle) |c| try playFromTo(game, c[0], c[1], c[2], c[3]);
    try std.testing.expect(!game.isGameOver());

    // Phase 2: an irreversible capture clears the history and resets the clock.
    game.board = [_]Piece{.empty} ** 32;
    game.board[board_mod.rowColToSquare(2, 2)] = .white_pawn;
    game.board[board_mod.rowColToSquare(3, 3)] = .black_pawn;
    game.board[board_mod.rowColToSquare(6, 6)] = .black_pawn;
    game.turn = .white;
    var moves = MoveList{};
    game.generateMoves(&moves);
    const cap = findMove(&moves, board_mod.rowColToSquare(2, 2), board_mod.rowColToSquare(4, 4)) orelse
        @panic("expected capture move not generated");
    try std.testing.expect(game.applyMove(cap));
    try std.testing.expectEqual(@as(u16, 0), game.halfmove_clock);
    try std.testing.expect(!game.isGameOver());

    // Phase 3: quiet moves on the fresh position — stale shuffle history must
    // not cause a false draw.
    game.generateMoves(&moves);
    const quiet = findMove(&moves, board_mod.rowColToSquare(6, 6), board_mod.rowColToSquare(5, 5)) orelse
        @panic("expected quiet move not generated");
    try std.testing.expect(game.applyMove(quiet));
    try std.testing.expectEqual(@as(u16, 1), game.halfmove_clock);
    try std.testing.expect(!game.isGameOver());
}
