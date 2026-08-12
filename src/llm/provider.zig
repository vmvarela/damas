//! LLM provider interface (vtable-based) and the shared prompt builder.

const std = @import("std");
const move_mod = @import("../core/move.zig");

pub const Move = move_mod.Move;

/// Input to a provider's move request.
pub const Request = struct {
    board_ascii: []const u8,
    legal_moves: []const Move,
    /// Retry hint appended to the prompt (empty on the first attempt).
    note: []const u8 = "",
};

/// A chosen move. `move` is the authoritative entry from `legal_moves`
/// (resolved by list number; captured set included). `reasoning` is allocated
/// with the request allocator and owned by the caller (may be empty).
pub const Response = struct {
    reasoning: []const u8,
    move: Move,
};

pub const LlmProvider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request_move: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: Request) anyerror!Response,
        /// Free provider state (no-op for stack-backed fakes).
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn request_move(self: LlmProvider, allocator: std.mem.Allocator, req: Request) anyerror!Response {
        return self.vtable.request_move(self.ctx, allocator, req);
    }

    /// Free provider state. Call once at shutdown, or not at all if the
    /// provider was built by `factory.fromConfig` for the program lifetime.
    pub fn deinit(self: LlmProvider) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Shared prompt: board ASCII + numbered legal-move list, a strict reply
/// instruction, and an optional retry note. Caller owns the result.
pub fn buildPrompt(
    allocator: std.mem.Allocator,
    board_ascii: []const u8,
    moves: []const Move,
    note: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Board (64 chars, row-major; . empty, w/W white pawn/king, b/B black pawn/king, space = light square):\n{s}\n\n", .{board_ascii});
    try w.print("Legal moves (index: from,to):\n", .{});
    for (moves, 0..) |m, i| {
        try w.print("{d}: {d},{d}{s}\n", .{ i, m.from, m.to, if (m.num_captured > 0) " (capture)" else "" });
    }
    try w.print("\nReply with ONLY compact JSON: {{\"move\": <number>}}. The number must be one of the legal move numbers above.", .{});
    if (note.len > 0) {
        try w.print("\n\n{s}", .{note});
    }
    return out.toOwnedSlice();
}

/// Parse an LLM's inner JSON reply — `{"move": <list number>, "reasoning": "..."}` —
/// resolving the number against `legal_moves`. Shared by openai and ollama.
/// Malformed JSON, a missing `move` field, or an out-of-range number ->
/// error.InvalidLlmResponse. The returned `move` is the authoritative entry
/// from `legal_moves` (captured set included); `reasoning` is caller-owned.
pub fn parseMoveJson(allocator: std.mem.Allocator, content: []const u8, legal_moves: []const Move) !Response {
    const Inner = struct {
        move: ?u32,
        reasoning: []const u8 = "",
    };
    var inner = std.json.parseFromSlice(Inner, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidLlmResponse;
    defer inner.deinit();

    const idx = inner.value.move orelse return error.InvalidLlmResponse;
    if (idx >= legal_moves.len) return error.InvalidLlmResponse;
    const m = legal_moves[@intCast(idx)];
    return .{
        .reasoning = try allocator.dupe(u8, inner.value.reasoning),
        .move = m,
    };
}
