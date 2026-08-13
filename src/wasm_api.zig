//! Standalone WASM ABI for the damas protocol (SPEC §5). The JS side writes
//! the request JSON into dz_req_ptr() (≤ dz_req_cap() bytes), calls
//! dz_handle(len), and reads the response from the returned ptr<<32|len.
//! The response lives in a per-message arena and is valid until the next
//! dz_handle call. No LLM in the browser: ConnState.build_provider stays
//! null, so request_llm answers "LLM provider unavailable".

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("runtime/protocol.zig");
const game_mod = @import("core/game.zig");

/// Backing allocator: wasm_allocator in the browser build; page_allocator in
/// the native test (std.heap.wasm_allocator is a compile error on non-wasm
/// non-single-threaded hosts).
const backing = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

/// Request buffer — JS writes the frame here before dz_handle.
var req_buf: [4096]u8 = undefined;

/// Per-message arena over `backing`; reset at the top of dz_handle (which is
/// also what invalidates the previous response).
var arena: std.heap.ArenaAllocator = undefined;

/// Global game, allocated directly from `backing` so it survives the
/// per-message arena resets.
var game: *game_mod.Game = undefined;

/// Protocol connection state. build_provider stays null — LLM unavailable in
/// the browser build (product decision).
var conn: protocol.ConnState = .{};

/// Rules default for new_game without a "rules" field, from dz_init
/// (0 = english, 1 = spanish, anything else = english).
var default_rules: game_mod.Variant = .english;

/// Most recent response (arena-owned, valid until the next dz_handle call).
/// The wasm32 ABI encodes it as ptr<<32|len; the native test reads the slice
/// directly because 64-bit pointers don't fit that layout.
var last_resp: []u8 = &.{};

/// Initialize the module: pick the default rules and create the game.
export fn dz_init(rules: u8) void {
    default_rules = if (rules == 1) .spanish else .english;
    arena = std.heap.ArenaAllocator.init(backing);
    game = game_mod.Game.initRules(backing, default_rules) catch unreachable;
    conn = .{};
}

/// Pointer to the request buffer.
export fn dz_req_ptr() [*]u8 {
    return &req_buf;
}

/// Request buffer capacity in bytes.
export fn dz_req_cap() usize {
    return req_buf.len;
}

/// Handle one request frame (req_buf[0..len]). Returns the response JSON
/// packed as ptr<<32|len (wasm32 pointers are 32-bit, so the shift is lossless
/// there); 0 if len overflows the buffer or allocation fails.
export fn dz_handle(len: usize) u64 {
    if (len > req_buf.len) return 0;
    _ = arena.reset(.retain_capacity);
    last_resp = protocol.handleMessage(
        arena.allocator(),
        game,
        &conn,
        req_buf[0..len],
        default_rules,
    ) catch return 0;
    // wasm32 pointers are 32-bit, so ptr<<32|len is lossless there. On a
    // 64-bit host the shift would drop bits (UB per Zig spec); the native
    // test only asserts the length, so return just that.
    if (builtin.cpu.arch.isWasm())
        return (@as(u64, @intCast(@intFromPtr(last_resp.ptr))) << 32) | @as(u64, last_resp.len);
    return @as(u64, last_resp.len);
}

const board_mod = @import("core/board.zig");

/// Wire fields the round-trip test asserts on (same shape as ws_tests.zig).
const State = struct {
    board: [64]u8,
    turn: board_mod.Color,
    over: bool,
    @"error": ?[]const u8,
};

test "wasm ABI round-trip: new_game then make_move" {
    dz_init(0);
    defer conn = .{};

    const req1 = "{\"action\":\"new_game\"}";
    @memcpy(req_buf[0..req1.len], req1);
    const r1 = dz_handle(req1.len);
    try std.testing.expect(r1 != 0);
    try std.testing.expectEqual(@as(u64, last_resp.len), r1 & 0xffffffff);
    var s1 = try std.json.parseFromSlice(State, std.testing.allocator, last_resp, .{ .ignore_unknown_fields = true });
    defer s1.deinit();
    try std.testing.expectEqualSlices(u8, &board_mod.boardToAscii(board_mod.initialBoard()), &s1.value.board);
    try std.testing.expectEqual(board_mod.Color.white, s1.value.turn);
    try std.testing.expect(!s1.value.over);
    try std.testing.expect(s1.value.@"error" == null);

    // (2,0)->(3,1): squares 8 and 12 — a legal English opening move.
    const req2 = "{\"action\":\"make_move\",\"from\":8,\"to\":12}";
    @memcpy(req_buf[0..req2.len], req2);
    const r2 = dz_handle(req2.len);
    try std.testing.expect(r2 != 0);
    try std.testing.expectEqual(@as(u64, last_resp.len), r2 & 0xffffffff);
    var s2 = try std.json.parseFromSlice(State, std.testing.allocator, last_resp, .{ .ignore_unknown_fields = true });
    defer s2.deinit();
    try std.testing.expect(s2.value.@"error" == null);
    try std.testing.expectEqual(board_mod.Color.black, s2.value.turn);
}
