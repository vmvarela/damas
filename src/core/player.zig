//! Player configuration. Minimal data holder — no behavior yet.
//! minimax uses time_limit_ms; llm uses provider + model.

const std = @import("std");

pub const PlayerKind = enum { human, minimax, llm };

pub const Player = struct {
    kind: PlayerKind,
    name: []const u8,
    time_limit_ms: u32,
    provider: []const u8,
    model: []const u8,
};

test "default player construction" {
    const p = Player{
        .kind = .human,
        .name = "Alice",
        .time_limit_ms = 0,
        .provider = "",
        .model = "",
    };
    try std.testing.expectEqual(PlayerKind.human, p.kind);
    try std.testing.expectEqualStrings("Alice", p.name);
    try std.testing.expectEqual(@as(u32, 0), p.time_limit_ms);
    try std.testing.expectEqualStrings("", p.provider);
    try std.testing.expectEqualStrings("", p.model);
}
