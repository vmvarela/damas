//! OpenAI-compatible chat provider (also used for Groq).

const std = @import("std");
const provider = @import("provider.zig");
const http_util = @import("../utils/http.zig");

pub const LlmProvider = provider.LlmProvider;
pub const Request = provider.Request;
pub const Response = provider.Response;
pub const Move = provider.Move;

/// System prompt: the model must not narrate, only emit the JSON move reply.
const SYSTEM_PROMPT = "You are a checkers engine. Reply ONLY with compact JSON and nothing else.";

const State = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,

    fn deinit(self: *State) void {
        const a = self.allocator;
        a.free(self.api_key);
        a.free(self.model);
        a.free(self.base_url);
        a.destroy(self);
    }
};

/// Create a provider that owns copies of `api_key`, `model`, and `base_url`
/// (safe against per-request arenas). Call `factory.fromConfig` once at
/// program start; call `provider.deinit()` at shutdown.
pub fn init(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8, base_url: []const u8) LlmProvider {
    // ponytail: init cannot return an error (vtable-construction contract);
    // OOM at program-start config time panics.
    const state = allocator.create(State) catch @panic("OOM");
    state.* = .{
        .allocator = allocator,
        .api_key = allocator.dupe(u8, api_key) catch @panic("OOM"),
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

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
    defer allocator.free(url);

    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
    defer allocator.free(auth);

    const body = try buildChatBody(allocator, self.model, SYSTEM_PROMPT, prompt);
    defer allocator.free(body);

    const resp_body = try http_util.postJson(allocator, url, &.{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
    defer allocator.free(resp_body);

    return parseChatResponse(allocator, resp_body, req.legal_moves);
}

/// Build a /chat/completions request body: system + user messages, both
/// JSON-escaped via std.json.fmt. Returns valid JSON (caller owns).
pub fn buildChatBody(allocator: std.mem.Allocator, model: []const u8, system: []const u8, user: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"system\",\"content\":{f}}},{{\"role\":\"user\",\"content\":{f}}}],\"temperature\":0}}", .{ model, std.json.fmt(system, .{}), std.json.fmt(user, .{}) });
}

/// Parse a /chat/completions response into a move Response, resolving the
/// reply's move number against `legal_moves`.
/// Malformed JSON -> error.InvalidLlmResponse.
pub fn parseChatResponse(allocator: std.mem.Allocator, resp_body: []const u8, legal_moves: []const Move) !Response {
    const ChatResp = struct {
        choices: []const struct { message: struct { content: []const u8 } },
    };
    var parsed = std.json.parseFromSlice(ChatResp, allocator, resp_body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidLlmResponse;
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.InvalidLlmResponse;
    return provider.parseMoveJson(allocator, parsed.value.choices[0].message.content, legal_moves);
}

const vtable = LlmProvider.VTable{ .requestMove = requestMove, .deinit = stateDeinit };
