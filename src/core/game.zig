//! Game state: board, turn, and lifecycle.

const std = @import("std");
const board_mod = @import("board.zig");
const move_mod = @import("move.zig");
const rules = @import("rules.zig");

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
        };
        return game;
    }

    pub fn deinit(self: *Game) void {
        self.allocator.destroy(self);
    }

    pub fn generateMoves(self: *Game, moves: *MoveList) void {
        rules.generateMoves(self.board, self.turn, moves, self.rules);
    }

    /// Validate and apply a move; flips the turn. Returns false if illegal
    /// (board and turn unchanged).
    pub fn applyMove(self: *Game, move: Move) bool {
        if (!rules.isLegalMove(self.board, self.turn, move, self.rules)) return false;
        rules.applyMove(&self.board, move);
        self.turn = board_mod.opponent(self.turn);
        return true;
    }

    /// Game over when the current turn has no moves or a side has no pieces.
    pub fn isGameOver(self: *Game) bool {
        if (!rules.hasAnyMove(self.board, self.turn, self.rules)) return true;
        return !hasPieces(self.board, .white) or !hasPieces(self.board, .black);
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
