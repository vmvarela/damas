//! Terminal UI for damas (SPEC §2). Full-screen ANSI checkers board with
//! keyboard cursor selection, engine/LLM helpers, and raw-mode input.

const std = @import("std");
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

const esc = "\x1b[";
const clear = esc ++ "2J" ++ esc ++ "H";
const hide_cursor = esc ++ "?25l";
const show_cursor = esc ++ "?25h";
const alt_on = esc ++ "?1049h";
const alt_off = esc ++ "?1049l";
const reset = esc ++ "0m";

// True-color palette matching the web UI: dark board, bright green pieces
// and accents. White = solid bright-green discs, black = near-black discs
// ringed in bright green (same as the web's filled vs outlined circles).
const bg_dark = esc ++ "48;2;14;33;17m"; // #0e2111 playable square
const bg_light = esc ++ "48;2;18;43;22m"; // #122b16 non-playable square
const bg_selected = esc ++ "48;2;45;105;55m"; // selected square
const bg_target = esc ++ "48;2;28;72;36m"; // legal target
const bg_cursor = esc ++ "48;2;40;60;44m"; // cursor
const fg_piece_white = esc ++ "38;2;0;255;59;1m"; // #00ff3b solid white pieces
const fg_piece_black = esc ++ "38;2;0;255;59m"; // #00ff3b black pieces' outline
const fg_fill_black = esc ++ "38;2;15;35;18m"; // #0f2312 black pieces' fill
const fg_status = esc ++ "38;2;0;255;59m"; // #00ff3b accent text
const fg_idx = esc ++ "38;2;0;179;71m"; // #00b347 square numbers
const fg_dark = esc ++ "38;2;8;18;10m"; // near-black king markers on white discs
const bg_disc_white = esc ++ "48;2;0;255;59m"; // white disc fill
const bg_disc_black = esc ++ "48;2;15;35;18m"; // black disc fill
const fg_grid = esc ++ "38;2;7;23;11m"; // #07170b subtle grid lines

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
    /// Applied moves, oldest first; rendered with standard 1-32 notation.
    history: move_mod.MoveList,
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
            .history = .{},
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

/// Run the TUI. `rules_flag` (from `--rules`) overrides the variant in
/// config.json (and the English default when no config is present).
pub fn run(rules_flag: ?config_mod.Variant) !void {
    const allocator = std.heap.page_allocator;

    var cfg = config_mod.Config{ .rules = .english, .player_white = .human, .player_black = .human };
    var cfg_loaded = false;
    cfg = config_mod.load(allocator, "config.json") catch |e| switch (e) {
        error.FileNotFound => cfg,
        else => |err| return err,
    };
    cfg_loaded = true;
    if (rules_flag) |v| cfg.rules = v; // flag beats config.json

    const game = try game_mod.Game.initRules(allocator, cfg.rules);

    // State owns game: State.deinit() frees it. No errdefer here — a second
    // free on error return would double-free (state.deinit runs first).
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
                'h', 'H' => state.msg = "Help: arrows+Enter selects/moves, Esc cancels",
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
        var got: usize = 0;
        while (got < seq.len) {
            const nr = std.posix.read(0, seq[got..]) catch break;
            if (nr == 0) break;
            got += nr;
        }
        if (got >= 2 and seq[0] == '[') {
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
        if (got == 1 and seq[0] != '[') state.pending = seq[0];
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
            state.msg = "Missing API key (GROQ_API_KEY)";
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
    if (player == .llm) return player.llm;
    return .{ .provider = "groq", .model = "llama-3.3-70b-versatile" };
}

/// Append formatted text to a buffer, returning the new length (truncates
/// silently on overflow). Used to build one screen line piece by piece.
fn appendFmt(buf: []u8, len: usize, comptime fmt: []const u8, args: anytype) usize {
    const s = std.fmt.bufPrint(buf[len..], fmt, args) catch return len;
    return len + s.len;
}

/// Store one rendered line in the screen buffer.
fn putLine(screen: *[200][2048]u8, lens: *[200]usize, ln: *usize, comptime fmt: []const u8, args: anytype) void {
    if (ln.* >= screen.len) return;
    const s = std.fmt.bufPrint(&screen[ln.*], fmt, args) catch &[_]u8{};
    lens[ln.*] = s.len;
    ln.* += 1;
}

/// Append `n` spaces to a buffer, returning the new length.
fn appendSpaces(buf: []u8, len: usize, n: usize) usize {
    var l = len;
    for (0..n) |_| l = appendFmt(buf, l, " ", .{});
    return l;
}

/// Append the standard square number (2 digits) centered in a cell-width
/// field.
fn appendCellNumber(buf: []u8, len: usize, num: u8, c: usize) usize {
    var l = len;
    const pad = (c -| 2) / 2;
    l = appendSpaces(buf, l, pad);
    l = appendFmt(buf, l, "{d:>2}", .{num});
    l = appendSpaces(buf, l, c - 2 - pad);
    return l;
}

/// Append one content line of a cell holding a piece: a disc (3 lines tall)
/// with the number above it when the cell is tall enough, or a bare glyph
/// Append one content line of a cell holding a piece: a full-width circle
/// built from half/full blocks (▄/█/▀) — solid for white, a green ring over
/// a dark fill for black. The standard number sits dim in the top-left
/// corner of the cell, and the king marker is overlaid on the middle row.
/// `cw` x `ch` is the cell interior, `cl` the current content line.
fn appendPiece(buf: []u8, len: usize, cw: usize, ch: usize, cl: usize, num: u8, king_glyph: []const u8, king_fg: []const u8, outline: []const u8, fill: []const u8, fill_bg: []const u8) usize {
    var l = len;
    const d = cw; // the disc fills the full cell width
    if (d < 3) {
        // Too narrow for a circle: a plain block bar.
        l = appendFmt(buf, l, "{s}", .{outline});
        for (0..d) |_| l = appendFmt(buf, l, "{s}", .{"█"});
        return l;
    }
    if (cl == 0) {
        // Top bulge; the square number sits in the left corner.
        if (d >= 4) {
            l = appendFmt(buf, l, "{s}{d:>2}{s}", .{ fg_idx, num, outline });
            for (0..d - 3) |_| l = appendFmt(buf, l, "{s}", .{"▄"});
            l = appendFmt(buf, l, " ", .{});
        } else {
            l = appendFmt(buf, l, "{s} ", .{outline});
            for (0..d - 2) |_| l = appendFmt(buf, l, "{s}", .{"▄"});
            l = appendFmt(buf, l, " ", .{});
        }
        return l;
    }
    if (cl == ch - 1) {
        // Bottom bulge of the circle.
        l = appendFmt(buf, l, "{s} ", .{outline});
        for (0..d - 2) |_| l = appendFmt(buf, l, "{s}", .{"▀"});
        l = appendFmt(buf, l, " ", .{});
        return l;
    }
    // Middle rows: outline edges, fill interior, king marker at the center.
    const king_at = (d - 1) / 2;
    l = appendFmt(buf, l, "{s}█{s}", .{ outline, fill }); // left edge + fill color
    var i: usize = 1;
    while (i < d - 1) : (i += 1) {
        if (king_glyph.len > 0 and i == king_at) {
            l = appendFmt(buf, l, "{s}{s}{s}{s}", .{ king_fg, fill_bg, king_glyph, reset });
            l = appendFmt(buf, l, "{s}", .{fill}); // resume fill after the king cell
        } else {
            l = appendFmt(buf, l, "█", .{});
        }
    }
    l = appendFmt(buf, l, "{s}█", .{outline}); // right edge
    return l;
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

const TermSize = struct { rows: u16, cols: u16 };

/// Terminal size via TIOCGWINSZ; null when not a tty (fall back to 24x80).
fn termSize() ?TermSize {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(0, @intCast(std.posix.T.IOCGWINSZ), @intFromPtr(&ws));
    if (rc < 0 or ws.row == 0 or ws.col == 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
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

/// Full-screen draw. Adapts to the terminal: the move-history panel sits
/// beside the board when the terminal is wide enough, stacked below
/// otherwise, and is truncated to the available height.
fn draw(state: *State) void {
    const term = termSize() orelse TermSize{ .rows = 24, .cols = 80 };
    const cols: usize = @min(term.cols, 160);
    const rows: usize = term.rows;

    var screen: [200][2048]u8 = undefined;
    var lens: [200]usize = undefined;
    var ln: usize = 0;

    const rules_name = if (state.game.rules == .spanish) "spanish" else "english";
    putLine(&screen, &lens, &ln, "  Damas-Z TUI   Rules: {s}", .{rules_name});
    statusLine(state, &screen, &lens, &ln);

    // Board of colored cells, no grid lines — the checkerboard comes from
    // the alternating cell tones (matching the web). Pieces fill the whole
    // cell: terminal chars are ~2x taller than wide, so a full-width disc
    // of `cell_h` lines reads as a circle in pixels.
    const panel_w: usize = 24;
    const side = cols >= 47; // min board + panel + margins
    const cell_h = @max(1, (rows -| 7) / 8); // board is 8*H lines + 7 fixed
    const c_budget = if (side) (cols -| (panel_w + 13)) / 8 else (cols -| 11) / 8;
    const cell_w: usize = @max(1, @min(2 * cell_h, c_budget));
    const board_w: usize = 2 + 8 * cell_w;
    const n = state.history.len;

    if (side) {
        // Panel header aligned to the panel column (board_w + margin).
        var line: [2048]u8 = undefined;
        var len: usize = 0;
        for (0..board_w + 2) |_| len = appendFmt(&line, len, " ", .{});
        len = appendFmt(&line, len, "Move history:", .{});
        len = appendFmt(&line, len, "{s}", .{reset});
        lens[ln] = len;
        @memcpy(screen[ln][0..len], line[0..len]);
        ln += 1;
    } else {
        putLine(&screen, &lens, &ln, "", .{});
    }

    for (0..8) |row| {
        const mid = cell_h / 2;
        for (0..cell_h) |cl| {
            var line: [2048]u8 = undefined;
            var len: usize = 0;
            var plain: usize = 0;
            if (cl == mid) {
                len = appendFmt(&line, len, "{d} ", .{row});
            } else {
                len = appendFmt(&line, len, "  ", .{});
            }
            plain += 2;
            for (0..8) |col| {
                const bg = cellBg(state, @intCast(row), @intCast(col));
                const piece = pieceAt(state.game.board, @intCast(row), @intCast(col));
                len = appendFmt(&line, len, "{s}", .{bg});
                const sq = squareAt(@intCast(row), @intCast(col));
                if (sq) |s| {
                    const num = stdNum(s, state.game.rules);
                    if (piece == .empty) {
                        // Empty square: standard number, dim, on the top line.
                        if (cell_w >= 2 and cl == 0) {
                            len = appendCellNumber(&line, len, num, cell_w);
                        } else {
                            len = appendSpaces(&line, len, cell_w);
                        }
                    } else {
                        // White = solid green circle; black = dark circle
                        // ringed in green (matches the web pieces).
                        const is_white = piece == .white_pawn or piece == .white_king;
                        const is_king = piece == .white_king or piece == .black_king;
                        const king: []const u8 = if (is_king) (if (is_white) "♔" else "♚") else "";
                        const outline: []const u8 = if (is_white) fg_piece_white else fg_piece_black;
                        const fill: []const u8 = if (is_white) fg_piece_white else fg_fill_black;
                        const fill_bg: []const u8 = if (is_white) bg_disc_white else bg_disc_black;
                        const king_fg: []const u8 = if (is_white) fg_dark else fg_piece_black;
                        len = appendPiece(&line, len, cell_w, cell_h, cl, num, king, king_fg, outline, fill, fill_bg);
                    }
                } else {
                    len = appendSpaces(&line, len, cell_w);
                }
                len = appendFmt(&line, len, "{s}", .{reset});
                plain += cell_w;
            }
            if (side and n > 0 and cl == mid) {
                // One history entry per board row, most recent at the bottom.
                const show = @min(n, 8);
                const start = n - show;
                if (row >= 8 - show) {
                    var ebuf: [24]u8 = undefined;
                    const e = historyEntry(&ebuf, state, start + row - (8 - show));
                    if (plain + e.len + 2 <= cols) len = appendFmt(&line, len, "{s}  {s}{s}", .{ fg_idx, e, reset });
                }
            }
            lens[ln] = len;
            @memcpy(screen[ln][0..len], line[0..len]);
            ln += 1;
        }
    }

    // Column header aligned to the cells (number left-aligned in each cell).
    {
        var line: [2048]u8 = undefined;
        var len: usize = 0;
        len = appendFmt(&line, len, "  ", .{});
        for (0..8) |col| {
            len = appendFmt(&line, len, " {d:>2}", .{col});
            for (0..cell_w -| 3) |_| len = appendFmt(&line, len, " ", .{});
        }
        lens[ln] = len;
        @memcpy(screen[ln][0..len], line[0..len]);
        ln += 1;
    }
    putLine(&screen, &lens, &ln, "", .{});

    if (!side) {
        putLine(&screen, &lens, &ln, "  Move history:", .{});
        const room = rows -| (ln + 3); // leave the two footer lines + margin
        const show = @min(n, room);
        for (n - show..n) |i| {
            var ebuf: [24]u8 = undefined;
            const e = historyEntry(&ebuf, state, i);
            putLine(&screen, &lens, &ln, "  {s}", .{e});
        }
    }

    putLine(&screen, &lens, &ln, "[n]ew  [m]achine  [l]LM  [h]elp  [q]uit", .{});
    if (state.msg) |msg| putLine(&screen, &lens, &ln, "{s}", .{msg});

    std.debug.print("{s}{s}", .{ clear, fg_status });
    for (0..@min(ln, rows)) |i| {
        std.debug.print("{s}\n", .{screen[i][0..lens[i]]});
    }
    std.debug.print("{s}", .{reset});
}

fn statusLine(state: *State, screen: *[200][2048]u8, lens: *[200]usize, ln: *usize) void {
    var buf: [96]u8 = undefined;
    var len: usize = 0;
    const turn_name = if (state.game.turn == .white) "white" else "black";
    if (state.last_move) |m| {
        var mbuf: [12]u8 = undefined;
        const mn = moveNotation(&mbuf, m, state.game.rules);
        len = appendFmt(&buf, len, "  Turn: {s}   Last: {s}", .{ turn_name, mn });
    } else {
        len = appendFmt(&buf, len, "  Turn: {s}", .{turn_name});
    }
    if (state.game.isGameOver()) {
        const winner = state.game.winner().?;
        const win_name = if (winner == .white) "white" else "black";
        len = appendFmt(&buf, len, "   Game over — {s} wins", .{win_name});
    }
    putLine(screen, lens, ln, "{s}", .{buf[0..len]});
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
