//! Terminal UI for damas (SPEC §2). Full-screen checkers board rendered via
//! libvaxis (cell buffer + truecolor styles), keyboard cursor selection,
//! engine/LLM helpers. Terminal state (raw mode, alt screen, resize events,
//! key parsing) is owned by vaxis; this file keeps the game logic and layout.

const std = @import("std");
const vaxis = @import("vaxis");
const game_mod = @import("../core/game.zig");
const move_mod = @import("../core/move.zig");
const board_mod = @import("../core/board.zig");
const minimax = @import("../core/engine/minimax.zig");
const config_mod = @import("../utils/config.zig");
const factory = @import("../llm/factory.zig");
const provider_mod = @import("../llm/provider.zig");
const validation = @import("../llm/validation.zig");

const Color = game_mod.Color;
const Piece = game_mod.Piece;
const Move = game_mod.Move;

const VColor = vaxis.Color;
const VStyle = vaxis.Style;

// True-color palette in the same green-on-dark family as the web UI: dark
// board, bright green pieces and accents. White = solid bright-green discs,
// black = near-black discs ringed in bright green (same idea as the web's
// filled vs outlined circles).
const bg_dark = VColor{ .rgb = .{ 14, 33, 17 } }; // #0e2111 playable square
const bg_light = VColor{ .rgb = .{ 18, 43, 22 } }; // #122b16 non-playable square
const bg_selected = VColor{ .rgb = .{ 45, 105, 55 } }; // selected square
const bg_target = VColor{ .rgb = .{ 28, 72, 36 } }; // legal target
const bg_cursor = VColor{ .rgb = .{ 40, 60, 44 } }; // cursor
const fg_piece = VColor{ .rgb = .{ 0, 255, 59 } }; // #00ff3b discs and accents
const fg_fill_black = VColor{ .rgb = .{ 15, 35, 18 } }; // #0f2312 black fill
const fg_status = VColor{ .rgb = .{ 0, 255, 59 } }; // accent text
const fg_idx = VColor{ .rgb = .{ 0, 179, 71 } }; // #00b347 square numbers
const fg_dark = VColor{ .rgb = .{ 8, 18, 10 } }; // near-black king markers
const bg_disc_white = VColor{ .rgb = .{ 0, 255, 59 } }; // white disc fill
const bg_disc_black = VColor{ .rgb = .{ 15, 35, 18 } }; // black disc fill

const Dir = enum { up, down, left, right };

/// Events vaxis delivers to the main loop. Keyboard-only (the TUI never used
/// the mouse) plus the mandatory winsize for resize handling.
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const State = struct {
    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    cfg_loaded: bool,
    game: *game_mod.Game,
    llm: ?provider_mod.LlmProvider,
    /// From --provider; null = auto-detect / config.json.
    provider_flag: ?[]const u8,

    cursor_row: u8,
    cursor_col: u8,
    selected: ?u8,
    targets: [32]bool,
    last_move: ?Move,
    /// Applied moves, oldest first; rendered with standard 1-32 notation.
    history: move_mod.MoveList,
    msg: ?[]const u8,

    fn init(allocator: std.mem.Allocator, cfg: config_mod.Config, loaded: bool, game: *game_mod.Game, provider_flag: ?[]const u8) State {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .cfg_loaded = loaded,
            .game = game,
            .llm = null,
            .provider_flag = provider_flag,
            .cursor_row = 0,
            .cursor_col = 0,
            .selected = null,
            .targets = [_]bool{false} ** 32,
            .last_move = null,
            .history = .{},
            .msg = null,
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

/// Run the TUI. `rules_flag` (from `--rules`) overrides the variant in
/// config.json (and the English default when no config is present);
/// `provider_flag` (from `--provider`) overrides the LLM provider.
pub fn run(io: std.Io, env_map: *std.process.Environ.Map, rules_flag: ?config_mod.Variant, provider_flag: ?[]const u8) !void {
    const allocator = std.heap.page_allocator;

    var cfg = config_mod.Config{ .rules = .spanish, .player_white = .human, .player_black = .human };
    var cfg_loaded = true;
    cfg = config_mod.load(allocator, "config.json") catch |e| switch (e) {
        error.FileNotFound => blk: {
            cfg_loaded = false; // default config active, nothing to free
            break :blk cfg;
        },
        else => |err| return err,
    };
    if (rules_flag) |v| cfg.rules = v; // flag beats config.json

    const game = try game_mod.Game.initRules(allocator, cfg.rules);

    // State owns game: State.deinit() frees it. No errdefer here — a second
    // free on error return would double-free (state.deinit runs first).
    var state = State.init(allocator, cfg, cfg_loaded, game, provider_flag);
    defer state.deinit();

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, env_map, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    // SIGWINCH fallback for terminals without in-band resize; the loop also
    // posts an initial winsize on start, so the first frame is always sized.
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |key| {
                if (try handleKey(&state, key)) break;
            },
        }
        draw(&state, &vx);
        try vx.render(tty.writer());
    }
}

/// Map a vaxis key event to an action — same bindings as the pre-vaxis TUI:
/// arrows move the cursor, Enter selects/moves, Esc cancels, n/m/l/h/q act.
/// Returns true when the user quits.
fn handleKey(state: *State, key: vaxis.Key) !bool {
    if (key.matches('q', .{}) or key.matches('Q', .{})) return true;
    if (key.matches('c', .{ .ctrl = true })) return true; // Ctrl-C quits cleanly
    if (key.matches('n', .{}) or key.matches('N', .{})) {
        try newGame(state);
    } else if (key.matches('m', .{}) or key.matches('M', .{})) {
        try engineMove(state);
    } else if (key.matches('l', .{}) or key.matches('L', .{})) {
        try llmMove(state);
    } else if (key.matches('h', .{}) or key.matches('H', .{})) {
        state.msg = "Help: arrows+Enter selects/moves, Esc cancels";
    } else if (key.matches(vaxis.Key.enter, .{})) {
        try handleEnter(state);
    } else if (key.matches(vaxis.Key.escape, .{})) {
        clearSelection(state);
    } else if (key.matches(vaxis.Key.up, .{})) {
        moveCursor(state, .up);
    } else if (key.matches(vaxis.Key.down, .{})) {
        moveCursor(state, .down);
    } else if (key.matches(vaxis.Key.left, .{})) {
        moveCursor(state, .left);
    } else if (key.matches(vaxis.Key.right, .{})) {
        moveCursor(state, .right);
    }
    return false;
}

fn moveCursor(state: *State, d: Dir) void {
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
        state.msg = "Game over — n to restart";
        return;
    }
    const sq = squareAt(state.cursor_row, state.cursor_col) orelse {
        state.msg = "Invalid square";
        return;
    };
    if (state.selected) |sel| {
        if (state.targets[sq]) {
            const move = findMove(state.game, sel, sq) orelse {
                state.msg = "Move not found";
                return;
            };
            _ = state.game.applyMove(move);
            state.last_move = move;
            pushHistory(state, move);
            clearSelection(state);
        } else {
            state.msg = "Illegal target";
        }
    } else {
        const piece = state.game.board[sq];
        if (board_mod.pieceColor(piece) == state.game.turn) {
            state.selected = sq;
            updateTargets(state);
            if (!hasTargets(state)) {
                state.msg = "No moves for this piece";
                clearSelection(state);
            }
        } else {
            state.msg = "Select one of your pieces";
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
    // Preserve the current game's variant (rules don't change mid-session).
    const g = try game_mod.Game.initRules(state.allocator, state.game.rules);
    state.game.deinit();
    state.game = g;
    state.cursor_row = 0;
    state.cursor_col = 0;
    state.last_move = null;
    state.history.clear();
    clearSelection(state);
}

fn engineMove(state: *State) !void {
    state.msg = null;
    if (state.game.isGameOver()) return;
    const time_ms = minimaxTimeForTurn(state);
    const result = minimax.search(state.game.board, state.game.turn, time_ms, state.allocator, state.game.rules) catch |e| switch (e) {
        error.NoMoves => {
            state.msg = "No legal moves";
            return;
        },
        else => |err| return err,
    };
    _ = state.game.applyMove(result.move);
    state.last_move = result.move;
    pushHistory(state, result.move);
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
        state.msg = "No legal moves";
        return;
    }
    const resp = validation.requestValidMove(state.allocator, state.llm.?, state.game.board, moves.slice()) catch |e| switch (e) {
        error.InvalidMove => {
            state.msg = "LLM found no legal move";
            return;
        },
        error.MissingApiKey => {
            state.msg = "Missing API key (set the provider's env var)";
            return;
        },
        else => |err| return err,
    };
    defer state.allocator.free(resp.reasoning);
    _ = state.game.applyMove(resp.move);
    state.last_move = resp.move;
    pushHistory(state, resp.move);
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
    if (player == .llm) {
        // --provider flag beats the provider in config.json (like cli.zig).
        if (state.provider_flag) |p| return .{ .provider = p, .model = player.llm.model };
        return player.llm;
    }
    // provider_flag null → factory auto-detects from set *_API_KEY env vars.
    return .{ .provider = state.provider_flag, .model = "llama-3.3-70b-versatile" };
}

/// Append formatted text to a buffer, returning the new length (truncates
/// silently on overflow). Used to build one screen line piece by piece.
fn appendFmt(buf: []u8, len: usize, comptime fmt: []const u8, args: anytype) usize {
    const s = std.fmt.bufPrint(buf[len..], fmt, args) catch return len;
    return len + s.len;
}

/// Standard 1-32 notation number for a square (same mapping as the web UI,
/// verified against the 1981 Tinsley–Long record: 9-14 23-18 14x23 27x18).
/// The English standard puts black on 1-12; the TUI shows white at top
/// (rows 0-2), so the English numbering is flipped 180°. Spanish matches
/// the TUI orientation directly.
fn stdNum(sq: u8, rules: game_mod.Variant) u8 {
    return switch (rules) {
        .spanish => sq + 1,
        .english => (7 - sq / 4) * 4 + (sq % 4) + 1,
    };
}

/// "from-to" for quiet moves, "fromxto" for captures, in standard numbers.
fn moveNotation(buf: []u8, move: Move, rules: game_mod.Variant) []const u8 {
    const sep: u8 = if (move_mod.isCapture(move)) 'x' else '-';
    return std.fmt.bufPrint(buf, "{d}{c}{d}", .{ stdNum(move.from, rules), sep, stdNum(move.to, rules) }) catch "?";
}

/// "N. 11-15" for history entry i (0-based, oldest first).
fn historyEntry(buf: []u8, state: *State, i: usize) []const u8 {
    var mbuf: [12]u8 = undefined;
    const mn = moveNotation(&mbuf, state.history.items[i], state.game.rules);
    return std.fmt.bufPrint(buf, "{d:>2}. {s}", .{ i + 1, mn }) catch "?";
}

fn pushHistory(state: *State, move: Move) void {
    if (state.history.len >= state.history.items.len) return;
    _ = state.history.add(move);
}

/// One rendered line: writes cells into a vaxis window at a fixed row,
/// tracking the current column. Text goes through printSegment so multi-byte
/// graphemes (♔, —) are measured and written correctly.
const Line = struct {
    win: vaxis.Window,
    y: u16,
    x: u16 = 0,

    fn write(self: *Line, s: []const u8, style: VStyle) void {
        const r = self.win.printSegment(.{ .text = s, .style = style }, .{
            .row_offset = self.y,
            .col_offset = self.x,
            .wrap = .none,
        });
        self.x = r.col;
    }

    fn spaces(self: *Line, n: usize, style: VStyle) void {
        for (0..n) |_| {
            self.win.writeCell(self.x, self.y, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = style,
            });
            self.x += 1;
        }
    }
};

/// Write a 2-digit right-aligned number (1-32) using static digit slices —
/// no per-frame buffer, so the cells' grapheme pointers stay valid until the
/// frame is rendered (vaxis stores the slice, not a copy).
fn writeNum(line: *Line, num: u8, style: VStyle) void {
    if (num < 10) {
        line.write(" ", style);
        line.write("0123456789"[num .. num + 1], style);
    } else {
        line.write("0123456789"[num / 10 .. num / 10 + 1], style);
        line.write("0123456789"[num % 10 .. num % 10 + 1], style);
    }
}

/// Standard square number (2 digits) centered in a cell-width field.
fn drawCellNumber(line: *Line, num: u8, c: usize, bg: VColor) void {
    const pad = (c -| 2) / 2;
    const style = VStyle{ .fg = fg_idx, .bg = bg };
    line.spaces(pad, style);
    writeNum(line, num, style);
    line.spaces(c - 2 - pad, style);
}

/// Draw one content line of a cell holding a piece: a full-width circle built
/// from half/full blocks (▄/█/▀) — solid green for white, a green ring over
/// a dark fill for black. The standard number sits dim in the top-left corner
/// of the cell, and the king marker is overlaid on the middle row.
/// `cw` x `ch` is the cell interior, `cl` the current content line.
fn drawPiece(line: *Line, cw: usize, ch: usize, cl: usize, num: u8, king_glyph: []const u8, king_fg: VColor, outline: VColor, fill: VColor, fill_bg: VColor, bg: VColor) void {
    const d = cw; // the disc fills the full cell width
    if (d < 3) {
        // Too narrow for a circle: a plain block bar.
        line.write("█", .{ .fg = outline, .bg = bg });
        for (0..d) |_| line.write("█", .{ .fg = outline, .bg = bg });
        return;
    }
    if (cl == 0) {
        // Top bulge; the square number sits in the left corner.
        if (d >= 4) {
            writeNum(line, num, .{ .fg = fg_idx, .bg = bg });
            for (0..d - 3) |_| line.write("▄", .{ .fg = outline, .bg = bg });
            line.write(" ", .{ .fg = outline, .bg = bg });
        } else {
            line.write(" ", .{ .fg = outline, .bg = bg });
            for (0..d - 2) |_| line.write("▄", .{ .fg = outline, .bg = bg });
            line.write(" ", .{ .fg = outline, .bg = bg });
        }
        return;
    }
    if (cl == ch - 1) {
        // Bottom bulge of the circle.
        line.write(" ", .{ .fg = outline, .bg = bg });
        for (0..d - 2) |_| line.write("▀", .{ .fg = outline, .bg = bg });
        line.write(" ", .{ .fg = outline, .bg = bg });
        return;
    }
    // Middle rows: outline edges, fill interior, king marker at the center.
    const king_at = (d - 1) / 2;
    line.write("█", .{ .fg = outline, .bg = bg }); // left edge
    var i: usize = 1;
    while (i < d - 1) : (i += 1) {
        if (king_glyph.len > 0 and i == king_at) {
            line.write(king_glyph, .{ .fg = king_fg, .bg = fill_bg });
        } else {
            line.write("█", .{ .fg = fill, .bg = bg });
        }
    }
    line.write("█", .{ .fg = outline, .bg = bg }); // right edge
}

/// Full-screen draw. Adapts to the terminal: the move-history panel sits
/// beside the board when the terminal is wide enough, stacked below
/// otherwise, and is truncated to the available height.
fn draw(state: *State, vx: *vaxis.Vaxis) void {
    const win = vx.window();
    win.clear();

    const cols: usize = win.width;
    const rows: usize = win.height;

    var y: u16 = 0;

    const rules_name = if (state.game.rules == .spanish) "spanish" else "english";
    {
        var line = Line{ .win = win, .y = y };
        line.write("  Damas-Z TUI   Rules: ", .{ .fg = fg_status });
        line.write(rules_name, .{ .fg = fg_status });
        y += 1;
    }
    {
        var sbuf: [96]u8 = undefined;
        const slen = statusLine(state, &sbuf);
        var line = Line{ .win = win, .y = y };
        line.write(sbuf[0..slen], .{ .fg = fg_status });
        y += 1;
    }

    // Board of colored cells, no grid lines — the checkerboard comes from
    // the alternating cell tones (same green-on-dark family as the web).
    // Pieces fill the whole
    // cell: terminal chars are ~2x taller than wide, so a full-width disc
    // of `cell_h` lines reads as a circle in pixels.
    const panel_w: usize = 24;
    const side = cols >= 47; // min board + panel + margins
    const cell_h = @max(1, (rows -| 7) / 8); // board is 8*H lines + 7 fixed
    const c_budget = if (side) (cols -| (panel_w + 13)) / 8 else (cols -| 11) / 8;
    const cell_w: usize = @max(1, @min(2 * cell_h, c_budget));
    const board_w: usize = 2 + 8 * cell_w;
    const n = state.history.len;

    // Per-entry buffers for the history panel: vaxis stores grapheme slices,
    // so each rendered entry needs its own buffer that lives until render.
    var ebufs: [64][24]u8 = undefined;

    if (side) {
        // Panel header aligned to the panel column (board_w + margin).
        var line = Line{ .win = win, .y = y };
        line.spaces(board_w + 2, .{});
        line.write("Move history:", .{ .fg = fg_status });
        y += 1;
    } else {
        y += 1; // blank line
    }

    for (0..8) |row| {
        const mid = cell_h / 2;
        for (0..cell_h) |cl| {
            var line = Line{ .win = win, .y = y };
            if (cl == mid) {
                line.write("01234567"[row .. row + 1], .{ .fg = fg_status });
                line.write(" ", .{ .fg = fg_status });
            } else {
                line.write("  ", .{ .fg = fg_status });
            }
            for (0..8) |col| {
                const bg = cellBg(state, @intCast(row), @intCast(col));
                const piece = pieceAt(state.game.board, @intCast(row), @intCast(col));
                const sq = squareAt(@intCast(row), @intCast(col));
                if (sq) |s| {
                    const num = stdNum(s, state.game.rules);
                    if (piece == .empty) {
                        // Empty square: standard number, dim, on the top line.
                        if (cell_w >= 2 and cl == 0) {
                            drawCellNumber(&line, num, cell_w, bg);
                        } else {
                            line.spaces(cell_w, .{ .bg = bg });
                        }
                    } else {
                        // White = solid green circle; black = dark circle
                        // ringed in green (matches the web pieces).
                        const is_white = piece == .white_pawn or piece == .white_king;
                        const is_king = piece == .white_king or piece == .black_king;
                        const king: []const u8 = if (is_king) (if (is_white) "♔" else "♚") else "";
                        const outline: VColor = if (is_white) fg_piece else fg_piece;
                        const fill: VColor = if (is_white) fg_piece else fg_fill_black;
                        const fill_bg: VColor = if (is_white) bg_disc_white else bg_disc_black;
                        const king_fg: VColor = if (is_white) fg_dark else fg_piece;
                        drawPiece(&line, cell_w, cell_h, cl, num, king, king_fg, outline, fill, fill_bg, bg);
                    }
                } else {
                    line.spaces(cell_w, .{ .bg = bg });
                }
            }
            if (side and n > 0 and cl == mid) {
                // One history entry per board row, most recent at the bottom.
                const show = @min(n, 8);
                const start = n - show;
                if (row >= 8 - show) {
                    const e = historyEntry(&ebufs[row - (8 - show)], state, start + row - (8 - show));
                    if (@as(usize, line.x) + e.len + 2 <= cols) {
                        line.write("  ", .{ .fg = fg_idx });
                        line.write(e, .{ .fg = fg_idx });
                    }
                }
            }
            y += 1;
        }
    }

    // Column header aligned to the cells (number left-aligned in each cell).
    {
        var line = Line{ .win = win, .y = y };
        line.write("  ", .{ .fg = fg_status });
        for (0..8) |col| {
            // " {d:>2}" = 3 chars per column, matching the old TUI.
            line.write("  ", .{ .fg = fg_status });
            line.write("0123456789"[col .. col + 1], .{ .fg = fg_status });
            line.spaces(cell_w -| 3, .{});
        }
        y += 1;
    }
    y += 1; // blank line

    if (!side) {
        var line = Line{ .win = win, .y = y };
        line.write("  Move history:", .{ .fg = fg_status });
        y += 1;
        const room = rows -| (@as(usize, y) + 3); // leave the two footer lines + margin
        const show = @min(n, @min(room, ebufs.len));
        for (0..show) |k| {
            const e = historyEntry(&ebufs[k], state, n - show + k);
            var el = Line{ .win = win, .y = y };
            el.write("  ", .{ .fg = fg_status });
            el.write(e, .{ .fg = fg_status });
            y += 1;
        }
    }

    {
        var line = Line{ .win = win, .y = y };
        line.write("[n]ew  [m]achine  [l]LM  [h]elp  [q]uit", .{ .fg = fg_status });
        y += 1;
    }
    if (state.msg) |msg| {
        var line = Line{ .win = win, .y = y };
        line.write(msg, .{ .fg = fg_status });
    }
}

fn statusLine(state: *State, buf: []u8) usize {
    var len: usize = 0;
    const turn_name = if (state.game.turn == .white) "white" else "black";
    if (state.last_move) |m| {
        var mbuf: [12]u8 = undefined;
        const mn = moveNotation(&mbuf, m, state.game.rules);
        len = appendFmt(buf, len, "  Turn: {s}   Last: {s}", .{ turn_name, mn });
    } else {
        len = appendFmt(buf, len, "  Turn: {s}", .{turn_name});
    }
    if (state.game.isGameOver()) {
        if (state.game.winner()) |winner| {
            const win_name = if (winner == .white) "white" else "black";
            len = appendFmt(buf, len, "   Game over — {s} wins", .{win_name});
        } else {
            len = appendFmt(buf, len, "   Game over — draw", .{});
        }
    }
    return len;
}

fn cellBg(state: *State, row: u8, col: u8) VColor {
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

test "stdNum standard notation anchors" {
    // English: white at top (rows 0-2) holds 21-32, black 1-12. Anchors from
    // the 1981 Tinsley–Long record: 9-14 23-18 14x23 27x18.
    try std.testing.expectEqual(@as(u8, 11), stdNum(22, .english)); // (5,5) black front row
    try std.testing.expectEqual(@as(u8, 14), stdNum(17, .english));
    try std.testing.expectEqual(@as(u8, 23), stdNum(10, .english));
    try std.testing.expectEqual(@as(u8, 27), stdNum(6, .english));
    try std.testing.expectEqual(@as(u8, 18), stdNum(13, .english));
    try std.testing.expectEqual(@as(u8, 29), stdNum(0, .english)); // top-left double corner
    try std.testing.expectEqual(@as(u8, 4), stdNum(31, .english)); // bottom-right
    try std.testing.expectEqual(@as(u8, 1), stdNum(28, .english));
    try std.testing.expectEqual(@as(u8, 32), stdNum(3, .english));
    // Spanish: sq + 1, white at top on 1-12.
    try std.testing.expectEqual(@as(u8, 9), stdNum(8, .spanish));
    try std.testing.expectEqual(@as(u8, 13), stdNum(12, .spanish));
    try std.testing.expectEqual(@as(u8, 1), stdNum(0, .spanish));
    try std.testing.expectEqual(@as(u8, 32), stdNum(31, .spanish));
}
