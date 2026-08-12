//! Match CLI (SPEC §7): players from config.json in the cwd — `human`
//! (interactive stdin move-choice), `minimax` (engine), or `llm` (provider +
//! validation loop). The shipped config.json is llm vs minimax; human is
//! opt-in via a manual config edit.

const std = @import("std");
const game_mod = @import("../core/game.zig");
const move_mod = @import("../core/move.zig");
const board_mod = @import("../core/board.zig");
const minimax = @import("../core/engine/minimax.zig");
const config_mod = @import("../utils/config.zig");
const factory = @import("../llm/factory.zig");
const provider_mod = @import("../llm/provider.zig");
const validation = @import("../llm/validation.zig");

/// Run a config-driven match. `rules_flag` (from `--rules`) overrides the
/// variant in config.json.
pub fn runMatch(rules_flag: ?config_mod.Variant) !void {
    const allocator = std.heap.page_allocator;

    // ponytail: fixed path in cwd; no argv parsing (std.os.argv was removed
    // in 0.16-dev) — env override (e.g. DZ_CONFIG) later if needed.
    const cfg = config_mod.load(allocator, "config.json") catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("error: config.json not found in cwd\n", .{});
            std.process.exit(1);
        },
        else => |err| return err,
    };
    defer {
        config_mod.freePlayerStrings(allocator, cfg.player_white);
        config_mod.freePlayerStrings(allocator, cfg.player_black);
    }

    // LLM provider is built once per match (factory dups key/model into its
    // state) and freed at exit.
    // ponytail: first model wins — llm player cache keyed once per match; config
    // with two llm players of different models keeps white's provider.
    var llm: ?provider_mod.LlmProvider = null;
    defer if (llm) |p| p.deinit();

    const variant = rules_flag orelse cfg.rules;
    var game = try game_mod.Game.initRules(allocator, variant);
    defer game.deinit();

    while (true) {
        printBoard(game.board);
        if (game.isGameOver()) {
            const name: []const u8 = switch (game.winner().?) {
                .white => "white",
                .black => "black",
            };
            std.debug.print("Game over. Winner: {s}\n", .{name});
            return;
        }
        const player = switch (game.turn) {
            .white => cfg.player_white,
            .black => cfg.player_black,
        };
        switch (player) {
            .human => if (try playHuman(game)) return,
            .minimax => |mm| try playMinimax(game, mm.time_limit_ms),
            .llm => |lc| try playLlm(allocator, game, lc, &llm),
        }
    }
}

/// Human turn: pick a move by number from the legal-move list. Returns true
/// if stdin closed (quit the match cleanly).
fn playHuman(game: *game_mod.Game) !bool {
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
        error.Eof => return true, // stdin closed: quit cleanly
        else => return e,
    };
    _ = game.applyMove(moves.slice()[choice]);
    return false;
}

fn playMinimax(game: *game_mod.Game, time_limit_ms: u32) !void {
    const res = try minimax.search(game.board, game.turn, time_limit_ms, std.heap.page_allocator, game.rules);
    const f = board_mod.squareToRowCol(res.move.from);
    const t = board_mod.squareToRowCol(res.move.to);
    std.debug.print("Engine: {d},{d} -> {d},{d} (score {d}, depth {d}, {d} nodes)\n", .{
        f.row, f.col, t.row, t.col, res.score, res.depth, res.nodes,
    });
    _ = game.applyMove(res.move);
}

fn playLlm(
    allocator: std.mem.Allocator,
    game: *game_mod.Game,
    cfg: config_mod.LlmConfig,
    llm: *?provider_mod.LlmProvider,
) !void {
    if (llm.* == null) {
        llm.* = factory.fromConfig(allocator, cfg) catch |e| switch (e) {
            error.MissingApiKey => {
                std.debug.print("error: missing API key for provider \"{s}\" (set its env var, e.g. GROQ_API_KEY)\n", .{cfg.provider});
                std.process.exit(1);
            },
            else => |err| return err,
        };
    }
    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    const resp = validation.requestValidMove(allocator, llm.*.?, game.board, moves.slice()) catch |e| {
        std.debug.print("LLM failed: {s} — match aborted\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer allocator.free(resp.reasoning);
    const f = board_mod.squareToRowCol(resp.move.from);
    const t = board_mod.squareToRowCol(resp.move.to);
    std.debug.print("LLM ({s}): {d},{d} -> {d},{d}", .{ cfg.model, f.row, f.col, t.row, t.col });
    if (resp.reasoning.len > 0) std.debug.print(" — reasoning: {s}", .{resp.reasoning});
    std.debug.print("\n", .{});
    _ = game.applyMove(resp.move);
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
