//! Terminal UI for damas (SPEC §2). Full-screen ANSI checkers board with
//! keyboard cursor selection, engine/LLM helpers, and raw-mode input.

const std = @import("std");
const game_mod = @import("../../src/core/game.zig");
const move_mod = @import("../../src/core/move.zig");
const board_mod = @import("../../src/core/board.zig");
const minimax = @import("../../src/core/engine/minimax.zig");
const config_mod = @import("../../src/utils/config.zig");
const factory = @import("../../src/llm/factory.zig");
const provider_mod = @import("../../src/llm/provider.zig");
const validation = @import("../../src/llm/validation.zig");

const Color = game_mod.Color;
const Piece = game_mod.Piece;
const Move = game_mod.Move;

const esc = "\x1b[";
const clear = esc ++ "2J" ++ esc ++ "H";
const hide_cursor = esc ++ "?25l";
const show_cursor = esc ++ "?25h";
const alt_on = esc ++ "?1049h";
const alt_off = esc ++ "?1049l";
const reset = esc ++ "0m";

const bg_dark = esc ++ "48;5;94m"; // wood dark
const bg_light = esc ++ "48;5;180m"; // wood light
const bg_selected = esc ++ "48;5;226m"; // yellow
const bg_target = esc ++ "48;5;118m"; // green
const bg_cursor = esc ++ "48;5;15m"; // white
const fg_white = esc ++ "97;1m";
const fg_black = esc ++ "38;5;16;1m";
const fg_status = esc ++ "38;5;231m";

const Input = union(enum) {
    arrow: Dir,
    enter,
    esc,
    key: u8,

    const Dir = enum { up, down, left, right };
};

const State = struct {
    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    cfg_loaded: bool,
    game: *game_mod.Game,
    llm: ?provider_mod.LlmProvider,
    raw_mode: bool,
    orig_termios: ?std.posix.termios,
    raw_termios: ?std.posix.termios,

    cursor_row: u8,
    cursor_col: u8,
    selected: ?u8,
    targets: [32]bool,
    last_move: ?Move,
    msg: ?[]const u8,
    /// Key swallowed by the ESC probe (pressed right after Esc); replayed
    /// on the next readInput so Esc doesn't eat it (Esc+q must still quit).
    pending: ?u8,

    fn init(allocator: std.mem.Allocator, cfg: config_mod.Config, loaded: bool, game: *game_mod.Game) State {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .cfg_loaded = loaded,
            .game = game,
            .llm = null,
            .raw_mode = false,
            .orig_termios = null,
            .raw_termios = null,
            .cursor_row = 0,
            .cursor_col = 0,
            .selected = null,
            .targets = [_]bool{false} ** 32,
            .last_move = null,
            .msg = null,
            .pending = null,
        };
    }

    fn deinit(self: *State) void {
        if (self.llm) |p| p.deinit();
        self.game.deinit();
        if (self.cfg_loaded) {
            config_mod.freePlayerStrings(self.allocator, self.cfg.player_white);
            config_mod.freePlayerStrings(self.allocator, self.cfg.player_black);
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var cfg = config_mod.Config{ .player_white = .human, .player_black = .human };
    var cfg_loaded = false;
    cfg = config_mod.load(allocator, "config.json") catch |e| switch (e) {
        error.FileNotFound => cfg,
        else => |err| return err,
    };
    cfg_loaded = true;

    var game = try game_mod.Game.init(allocator);
    errdefer game.deinit();

    var state = State.init(allocator, cfg, cfg_loaded, game);
    defer restoreTerminal(&state);
    defer state.deinit();

    try enterRawMode(&state);
    std.debug.print("{s}{s}{s}", .{ alt_on, hide_cursor, clear });

    while (true) {
        draw(&state);
        const input = readInput(&state) catch |e| switch (e) {
            error.Eof => break,
            else => |err| return err,
        };
        switch (input) {
            .key => |k| switch (k) {
                // `return` (not break): break here would only exit the inner
                // switch and the loop would spin forever in a pty (no EOF).
                3, 'q', 'Q' => return, // Ctrl-C or q quits cleanly
                'n', 'N' => try newGame(&state),
                'm', 'M' => try engineMove(&state),
                'l', 'L' => try llmMove(&state),
                'h', 'H' => state.msg = "Ayuda: flechas+Enter selecciona/mueve, Esc cancela",
                else => {},
            },
            .arrow => |d| moveCursor(&state, d),
            .enter => try handleEnter(&state),
            .esc => clearSelection(&state),
        }
    }
}

fn enterRawMode(state: *State) !void {
    const orig = std.posix.tcgetattr(0) catch |e| switch (e) {
        error.NotATerminal => return, // non-tty: run without raw mode
        else => |err| return err,
    };
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false; // keep Ctrl-C in-band so defer restores terminal
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .FLUSH, raw);
    // SIGTERM / kill -9 unhandled by design; only in-band Ctrl-C is caught.
    state.raw_mode = true;
    state.orig_termios = orig;
    state.raw_termios = raw;
}

fn restoreTerminal(state: *State) void {
    std.debug.print("{s}{s}", .{ show_cursor, alt_off });
    if (state.raw_mode) {
        if (state.orig_termios) |t| {
            std.posix.tcsetattr(0, .FLUSH, t) catch {};
        }
    }
}

fn readInput(state: *State) !Input {
    // Replay a key the ESC probe swallowed (pressed right after Esc).
    if (state.pending) |p| {
        state.pending = null;
        return byteInput(p);
    }
    var buf: [1]u8 = undefined;
    const n = try std.posix.read(0, &buf);
    if (n == 0) return error.Eof;
    const c = buf[0];
    if (c == '\r' or c == '\n') return .enter;
    if (c == 3) return .{ .key = 3 }; // Ctrl-C handled in main loop
    if (c == 27) { // ESC
        if (!state.raw_mode) return .esc;
        var tmp = state.raw_termios.?;
        tmp.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        tmp.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        std.posix.tcsetattr(0, .NOW, tmp) catch {};
        defer {
            var restore = state.raw_termios.?;
            restore.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            restore.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(0, .NOW, restore) catch {};
        }
        var seq: [2]u8 = undefined;
        const n2 = try std.posix.read(0, &seq);
        if (n2 == 0) return .esc;
        if (seq[0] == '[' and n2 >= 2) {
            return switch (seq[1]) {
                'A' => .{ .arrow = .up },
                'B' => .{ .arrow = .down },
                'C' => .{ .arrow = .right },
                'D' => .{ .arrow = .left },
                else => .esc,
            };
        }
        // Esc followed by a plain key within the probe window: don't eat it —
        // replay on the next readInput (Esc+q still quits).
        if (n2 == 1 and seq[0] != '[') state.pending = seq[0];
        return .esc;
    }
    return .{ .key = c };
}

/// Map a raw byte to an Input (used for direct reads and ESC-probe replays).
fn byteInput(c: u8) Input {
    if (c == '\r' or c == '\n') return .enter;
    if (c == 3) return .{ .key = 3 };
    if (c == 27) return .esc; // a replayed lone Esc
    return .{ .key = c };
}

fn moveCursor(state: *State, d: Input.Dir) void {
    state.msg = null;
    switch (d) {
        .up => state.cursor_row = if (state.cursor_row == 0) 7 else state.cursor_row - 1,
        .down => state.cursor_row = if (state.cursor_row == 7) 0 else state.cursor_row + 1,
        .left => state.cursor_col = if (state.cursor_col == 0) 7 else state.cursor_col - 1,
        .right => state.cursor_col = if (state.cursor_col == 7) 0 else state.cursor_col + 1,
    }
}

fn handleEnter(state: *State) !void {
    state.msg = null;
    if (state.game.isGameOver()) {
        state.msg = "Partida terminada — n para reiniciar";
        return;
    }
    const sq = squareAt(state.cursor_row, state.cursor_col) orelse {
        state.msg = "Casilla no valida";
        return;
    };
    if (state.selected) |sel| {
        if (state.targets[sq]) {
            const move = findMove(state.game, sel, sq) orelse {
                state.msg = "Movida no encontrada";
                return;
            };
            _ = state.game.applyMove(move);
            state.last_move = move;
            clearSelection(state);
        } else {
            state.msg = "Objetivo ilegal";
        }
    } else {
        const piece = state.game.board[sq];
        if (board_mod.pieceColor(piece) == state.game.turn) {
            state.selected = sq;
            updateTargets(state);
            if (!hasTargets(state)) {
                state.msg = "Sin movidas para esta pieza";
                clearSelection(state);
            }
        } else {
            state.msg = "Selecciona una pieza tuya";
        }
    }
}

fn clearSelection(state: *State) void {
    state.selected = null;
    state.targets = [_]bool{false} ** 32;
    state.msg = null;
}

fn updateTargets(state: *State) void {
    state.targets = [_]bool{false} ** 32;
    const sel = state.selected.?;
    var moves = move_mod.MoveList{};
    state.game.generateMoves(&moves);
    for (moves.slice()) |m| {
        if (m.from == sel) state.targets[m.to] = true;
    }
}

fn hasTargets(state: *State) bool {
    for (state.targets) |t| if (t) return true;
    return false;
}

fn findMove(game: *game_mod.Game, from: u8, to: u8) ?Move {
    var moves = move_mod.MoveList{};
    game.generateMoves(&moves);
    for (moves.slice()) |m| {
        if (m.from == from and m.to == to) return m;
    }
    return null;
}

fn squareAt(row: u8, col: u8) ?u8 {
    if ((row + col) % 2 == 1) return null;
    return board_mod.rowColToSquare(row, col);
}

fn newGame(state: *State) !void {
    const g = try game_mod.Game.init(state.allocator);
    state.game.deinit();
    state.game = g;
    state.cursor_row = 0;
    state.cursor_col = 0;
    state.last_move = null;
    clearSelection(state);
}

fn engineMove(state: *State) !void {
    state.msg = null;
    if (state.game.isGameOver()) return;
    const time_ms = minimaxTimeForTurn(state);
    const result = minimax.search(state.game.board, state.game.turn, time_ms, state.allocator) catch |e| switch (e) {
        error.NoMoves => {
            state.msg = "Sin movimientos legales";
            return;
        },
        else => |err| return err,
    };
    _ = state.game.applyMove(result.move);
    state.last_move = result.move;
    clearSelection(state);
}

fn minimaxTimeForTurn(state: *State) u32 {
    const player = switch (state.game.turn) {
        .white => state.cfg.player_white,
        .black => state.cfg.player_black,
    };
    if (player == .minimax) return player.minimax.time_limit_ms;
    return 1000;
}

fn llmMove(state: *State) !void {
    state.msg = null;
    if (state.game.isGameOver()) return;
    try ensureLlm(state);
    var moves = move_mod.MoveList{};
    state.game.generateMoves(&moves);
    if (moves.len == 0) {
        state.msg = "Sin movimientos legales";
        return;
    }
    const resp = validation.requestValidMove(state.allocator, state.llm.?, state.game.board, moves.slice()) catch |e| switch (e) {
        error.InvalidMove => {
            state.msg = "LLM no encontro movida valida";
            return;
        },
        error.MissingApiKey => {
            state.msg = "Falta API key (GROQ_API_KEY)";
            return;
        },
        else => |err| return err,
    };
    defer state.allocator.free(resp.reasoning);
    _ = state.game.applyMove(resp.move);
    state.last_move = resp.move;
    clearSelection(state);
}

fn ensureLlm(state: *State) !void {
    if (state.llm != null) return;
    const cfg = llmConfigForTurn(state);
    state.llm = factory.fromConfig(state.allocator, cfg) catch |e| switch (e) {
        error.MissingApiKey => return error.MissingApiKey,
        else => |err| return err,
    };
}

fn llmConfigForTurn(state: *State) config_mod.LlmConfig {
    const player = switch (state.game.turn) {
        .white => state.cfg.player_white,
        .black => state.cfg.player_black,
    };
    if (player == .llm) return player.llm;
    return .{ .provider = "groq", .model = "llama-3.3-70b-versatile" };
}

fn draw(state: *State) void {
    std.debug.print("{s}{s}", .{ clear, fg_status });
    std.debug.print("  Damas-Z TUI\n\n", .{});

    for (0..8) |row| {
        std.debug.print("{d} ", .{row});
        for (0..8) |col| {
            const bg = cellBg(state, @intCast(row), @intCast(col));
            const piece = pieceAt(state.game.board, @intCast(row), @intCast(col));
            const fg = pieceFg(piece);
            const glyph = pieceGlyph(piece, state.cursor_row == row and state.cursor_col == col);
            std.debug.print("{s}{s} {s} {s}", .{ bg, fg, glyph, reset });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("   ", .{});
    for (0..8) |col| {
        std.debug.print(" {d} ", .{col});
    }
    std.debug.print("\n\n", .{});

    drawStatus(state);
    std.debug.print("{s}", .{reset});
}

fn cellBg(state: *State, row: u8, col: u8) []const u8 {
    const is_cursor = state.cursor_row == row and state.cursor_col == col;
    const sq = squareAt(row, col);
    if (sq) |s| {
        if (is_cursor) return bg_cursor;
        if (state.selected) |sel| {
            if (sel == s) return bg_selected;
            if (state.targets[s]) return bg_target;
        }
        return bg_dark;
    }
    if (is_cursor) return bg_cursor;
    return bg_light;
}

fn pieceAt(board: board_mod.Board32, row: u8, col: u8) Piece {
    const sq = squareAt(row, col) orelse return .empty;
    return board[sq];
}

fn pieceFg(piece: Piece) []const u8 {
    return switch (piece) {
        .white_pawn, .white_king => fg_white,
        .black_pawn, .black_king => fg_black,
        .empty => "",
    };
}

fn pieceGlyph(piece: Piece, is_cursor: bool) []const u8 {
    if (is_cursor and piece == .empty) return "·";
    return switch (piece) {
        .empty => " ",
        .white_pawn => "●",
        .white_king => "♔",
        .black_pawn => "●",
        .black_king => "♚",
    };
}

fn drawStatus(state: *State) void {
    const turn_name = if (state.game.turn == .white) "blancas" else "negras";
    std.debug.print("Turno: {s}", .{turn_name});
    if (state.game.isGameOver()) {
        const winner = state.game.winner().?;
        const win_name = if (winner == .white) "blancas" else "negras";
        std.debug.print("  |  FIN: ganan {s}", .{win_name});
    }
    if (state.last_move) |m| {
        const f = board_mod.squareToRowCol(m.from);
        const t = board_mod.squareToRowCol(m.to);
        std.debug.print("  |  Ultima: {d},{d} -> {d},{d}", .{ f.row, f.col, t.row, t.col });
    }
    std.debug.print("\n", .{});
    std.debug.print("[n]uevo  [m]otor  [l]LM  [h]elp  [q]salir", .{});
    if (state.msg) |msg| {
        std.debug.print("  |  {s}", .{msg});
    }
    std.debug.print("\n", .{});
}
