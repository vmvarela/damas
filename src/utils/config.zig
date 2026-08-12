//! Player configuration: load JSON config and read API keys from the env.

const std = @import("std");
const builtin = @import("builtin");

pub const LlmConfig = struct {
    provider: []const u8,
    model: []const u8,
};

pub const PlayerConfig = union(enum) {
    llm: LlmConfig,
    minimax: struct { time_limit_ms: u32 },
    /// Human plays via the interactive stdin move-choice loop (CLI only).
    human,
};

pub const Config = struct {
    player_white: PlayerConfig,
    player_black: PlayerConfig,
};

/// Read and parse `path`. Strings in the returned Config are allocated with
/// `allocator` and owned by the caller.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const size = try reader.getSize();
    const data = try reader.interface.readAlloc(allocator, @intCast(size));
    defer allocator.free(data);
    return parse(allocator, data);
}

/// Parse config JSON. The `type` field selects the PlayerConfig tag; the
/// std.json default for `union(enum)` expects the tag as the object key, so
/// parse to `std.json.Value` and build the union manually. Strings in the
/// returned Config are allocated with `allocator` and owned by the caller.
pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Config {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const root = parsed.value.object;

    const white = try parsePlayer(allocator, root.get("player_white") orelse return error.InvalidConfig);
    errdefer freePlayerStrings(allocator, white);
    const black = try parsePlayer(allocator, root.get("player_black") orelse return error.InvalidConfig);
    return .{ .player_white = white, .player_black = black };
}

/// Free the strings owned by a parsed PlayerConfig (llm branch). No-op for
/// minimax/human. Shared with main.zig's CLI cleanup.
pub fn freePlayerStrings(allocator: std.mem.Allocator, p: PlayerConfig) void {
    switch (p) {
        .llm => |l| {
            allocator.free(l.provider);
            allocator.free(l.model);
        },
        else => {},
    }
}

fn parsePlayer(allocator: std.mem.Allocator, value: std.json.Value) !PlayerConfig {
    const obj = value.object;
    const tag = (obj.get("type") orelse return error.InvalidConfig).string;
    if (std.mem.eql(u8, tag, "llm")) {
        const provider_str = try allocator.dupe(u8, (obj.get("provider") orelse return error.InvalidConfig).string);
        errdefer allocator.free(provider_str);
        const model = try allocator.dupe(u8, (obj.get("model") orelse return error.InvalidConfig).string);
        return .{ .llm = .{ .provider = provider_str, .model = model } };
    }
    if (std.mem.eql(u8, tag, "minimax")) {
        const ms = (obj.get("time_limit_ms") orelse return error.InvalidConfig).integer;
        return .{ .minimax = .{ .time_limit_ms = std.math.cast(u32, ms) orelse return error.InvalidConfig } };
    }
    if (std.mem.eql(u8, tag, "human")) {
        return .{ .human = {} };
    }
    return error.InvalidConfig;
}

/// Environment variable as a borrowed slice into the process environment.
/// Null if unset. Unavailable on Windows (Environ.getPosix is POSIX-only);
/// use `apiKey` there.
pub fn getEnvPosix(name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    var count: usize = 0;
    while (std.c.environ[count]) |_| count += 1;
    const env: std.process.Environ = .{ .block = .{ .slice = std.c.environ[0..count :null] } };
    return std.process.Environ.getPosix(env, name);
}

/// Read an API key from the environment; error.MissingApiKey if unset.
/// Caller owns the returned memory.
pub fn apiKey(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        // PEB path: no C `environ` symbol needed.
        const env: std.process.Environ = .{ .block = .global };
        return env.getAlloc(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return error.MissingApiKey,
            else => |e| return e,
        };
    }
    const val = getEnvPosix(name) orelse return error.MissingApiKey;
    return allocator.dupe(u8, val);
}
