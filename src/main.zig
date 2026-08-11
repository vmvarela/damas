//! CLI: human (white) vs minimax engine (black). Moves are chosen by number
//! from the legal-move list. Engine time limit: 500ms (ponytail: no argv
//! parsing — std.os.argv was removed in 0.16-dev; add when needed).

const std = @import("std");
const game_mod = @import("core/game.zig");
const move_mod = @import("core/move.zig");
const board_mod = @import("core/board.zig");
const minimax = @import("core/engine/minimax.zig");

const TIME_LIMIT_MS: u32 = 500;

pub fn main() !void {
    var game = try game_mod.Game.init(std.heap.page_allocator);
    defer game.deinit();

    while (true) {
        printBoard(game.board);
        if (game.isGameOver()) {
            const name: []const u8 = switch (game.winner().?) {
                .white => "white (you)",
                .black => "black (engine)",
            };
            std.debug.print("Game over. Winner: {s}\n", .{name});
            return;
        }
        if (game.turn == .white) {
            var moves = move_mod.MoveList{};
            game.generateMoves(&moves);
            std.debug.print("Your move ({d} legal):\n", .{moves.len});
            for (moves.slice(), 0..) |m, i| {
                const f = board_mod.squareToRowCol(m.from);
                const t = board_mod.squareToRowCol(m.to);
                std.debug.print("  {d}: {d},{d} -> {d},{d}{s}\n", .{
                    i + 1, f.row, f.col, t.row, t.col,
                    if (m.num_captured > 0) " (capture)" else "",
                });
            }
            const choice = readChoice(moves.len) catch |e| switch (e) {
                error.Eof => return, // stdin closed: quit cleanly
                else => return e,
            };
            _ = game.applyMove(moves.slice()[choice]);
        } else {
            const res = try minimax.search(game.board, game.turn, TIME_LIMIT_MS, std.heap.page_allocator);
            const f = board_mod.squareToRowCol(res.move.from);
            const t = board_mod.squareToRowCol(res.move.to);
            std.debug.print("Engine: {d},{d} -> {d},{d} (score {d}, depth {d}, {d} nodes)\n", .{
                f.row, f.col, t.row, t.col, res.score, res.depth, res.nodes,
            });
            _ = game.applyMove(res.move);
        }
    }
}

fn printBoard(board: board_mod.Board32) void {
    const ascii = board_mod.boardToAscii(board);
    std.debug.print("  +----------------+\n", .{});
    for (0..8) |row| {
        std.debug.print("{d} |{s}|\n", .{ row, ascii[row * 8 .. row * 8 + 8] });
    }
    std.debug.print("  +----------------+\n", .{});
}

fn readChoice(max: usize) !usize {
    var buf: [64]u8 = undefined;
    while (true) {
        var len: usize = 0;
        while (true) {
            const n = try std.posix.read(0, buf[len..]);
            if (n == 0) return error.Eof;
            len += n;
            if (std.mem.indexOfScalar(u8, buf[0..len], '\n') != null) break;
            if (len == buf.len) break; // overlong line: discard, re-prompt
        }
        const nl = std.mem.indexOfScalar(u8, buf[0..len], '\n') orelse len;
        const line = std.mem.trim(u8, buf[0..nl], " \t\r");
        const v = std.fmt.parseInt(usize, line, 10) catch {
            std.debug.print("Invalid input. Enter a number 1-{d}.\n", .{max});
            continue;
        };
        if (v < 1 or v > max) {
            std.debug.print("Out of range. Enter a number 1-{d}.\n", .{max});
            continue;
        }
        return v - 1;
    }
}