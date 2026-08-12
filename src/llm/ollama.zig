//! Ollama provider: local HTTP API, no auth.

const std = @import("std");
const provider = @import("provider.zig");
const http_util = @import("../utils/http.zig");

pub const LlmProvider = provider.LlmProvider;
pub const Request = provider.Request;
pub const Response = provider.Response;
pub const Move = provider.Move;

const State = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    base_url: []const u8,

    fn deinit(self: *State) void {
        const a = self.allocator;
        a.free(self.model);
        a.free(self.base_url);
        a.destroy(self);
    }
};

/// Create a provider that owns copies of `model` and `base_url` (safe
/// against per-request arenas). Call `factory.fromConfig` once at program
/// start; call `provider.deinit()` at shutdown.
pub fn init(allocator: std.mem.Allocator, model: []const u8, base_url: []const u8) LlmProvider {
    // ponytail: init cannot return an error (vtable-construction contract);
    // OOM at program-start config time panics.
    const state = allocator.create(State) catch @panic("OOM");
    state.* = .{
        .allocator = allocator,
        .model = allocator.dupe(u8, model) catch @panic("OOM"),
        .base_url = allocator.dupe(u8, base_url) catch @panic("OOM"),
    };
    return .{ .ctx = state, .vtable = &vtable };
}

fn stateDeinit(ctx: *anyopaque) void {
    const self: *State = @ptrCast(@alignCast(ctx));
    self.deinit();
}

fn requestMove(ctx: *anyopaque, allocator: std.mem.Allocator, req: Request) anyerror!Response {
    const self: *State = @ptrCast(@alignCast(ctx));

    const prompt = try provider.buildPrompt(allocator, req.board_ascii, req.legal_moves, req.note);
    defer allocator.free(prompt);

    const url = try std.fmt.allocPrint(allocator, "{s}/api/generate", .{self.base_url});
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(allocator,
        "{{\"model\":\"{s}\",\"prompt\":{f},\"stream\":false,\"format\":\"json\"}}",
        .{ self.model, std.json.fmt(prompt, .{}) });
    defer allocator.free(body);

    const resp_body = try http_util.postJson(allocator, url, &.{
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
    defer allocator.free(resp_body);

    return parseGenerateResponse(allocator, resp_body, req.legal_moves);
}

/// Parse an /api/generate response into a move Response, resolving the
/// reply's move number against `legal_moves`.
/// Malformed JSON -> error.InvalidLlmResponse.
pub fn parseGenerateResponse(allocator: std.mem.Allocator, resp_body: []const u8, legal_moves: []const Move) !Response {
    const GenResp = struct { response: []const u8 };
    var parsed = std.json.parseFromSlice(GenResp, allocator, resp_body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidLlmResponse;
    defer parsed.deinit();
    return provider.parseMoveJson(allocator, parsed.value.response, legal_moves);
}

const vtable = LlmProvider.VTable{ .request_move = requestMove, .deinit = stateDeinit };
