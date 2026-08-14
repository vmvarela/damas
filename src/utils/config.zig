//! Player configuration: load JSON config and read API keys from the env.

const std = @import("std");
const builtin = @import("builtin");
const rules_mod = @import("../core/rules.zig");

pub const Variant = rules_mod.Variant;

pub const LlmConfig = struct {
    /// null = auto-detect from set *_API_KEY env vars (factory.detectProvider).
    provider: ?[]const u8,
    model: []const u8,
};

pub const PlayerConfig = union(enum) {
    llm: LlmConfig,
    minimax: struct { time_limit_ms: u32 },
    /// Human plays via the interactive stdin move-choice loop (CLI only).
    human,
};

pub const Config = struct {
    rules: Variant,
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
    if (parsed.value != .object) return error.InvalidConfig;
    const root = parsed.value.object;

    const white = try parsePlayer(allocator, root.get("player_white") orelse return error.InvalidConfig);
    errdefer freePlayerStrings(allocator, white);
    const black = try parsePlayer(allocator, root.get("player_black") orelse return error.InvalidConfig);
    // Optional "rules" field; missing or unknown values fall back to Spanish
    // (the project default) so existing configs (and typos) keep working.
    var variant: Variant = .spanish;
    if (root.get("rules")) |v| {
        if (v == .string) variant = parseVariant(v.string);
    }
    return .{ .rules = variant, .player_white = white, .player_black = black };
}

/// Map a rule-name string to a Variant; anything other than "english" (and
/// null) falls back to Spanish. Shared with the WebSocket server's new_game.
pub fn parseVariant(s: []const u8) Variant {
    if (std.mem.eql(u8, s, "english")) return .english;
    return .spanish;
}

/// Free the strings owned by a parsed PlayerConfig (llm branch). No-op for
/// minimax/human. Shared with main.zig's CLI cleanup.
pub fn freePlayerStrings(allocator: std.mem.Allocator, p: PlayerConfig) void {
    switch (p) {
        .llm => |l| {
            if (l.provider) |prov| allocator.free(prov);
            allocator.free(l.model);
        },
        else => {},
    }
}

fn parsePlayer(allocator: std.mem.Allocator, value: std.json.Value) !PlayerConfig {
    if (value != .object) return error.InvalidConfig;
    const obj = value.object;
    const type_val = obj.get("type") orelse return error.InvalidConfig;
    if (type_val != .string) return error.InvalidConfig;
    const tag = type_val.string;
    if (std.mem.eql(u8, tag, "llm")) {
        var provider_str: ?[]const u8 = null;
        if (obj.get("provider")) |pv| {
            if (pv != .string) return error.InvalidConfig;
            provider_str = try allocator.dupe(u8, pv.string);
            errdefer allocator.free(provider_str.?);
        }
        const model_val = obj.get("model") orelse return error.InvalidConfig;
        if (model_val != .string) return error.InvalidConfig;
        const model = try allocator.dupe(u8, model_val.string);
        return .{ .llm = .{ .provider = provider_str, .model = model } };
    }
    if (std.mem.eql(u8, tag, "minimax")) {
        const ms_val = obj.get("time_limit_ms") orelse return error.InvalidConfig;
        if (ms_val != .integer) return error.InvalidConfig;
        const ms = ms_val.integer;
        return .{ .minimax = .{ .time_limit_ms = std.math.cast(u32, ms) orelse return error.InvalidConfig } };
    }
    if (std.mem.eql(u8, tag, "human")) {
        return .{ .human = {} };
    }
    return error.InvalidConfig;
}

/// Process environment captured once at main() from `init.environ_map` /
/// `init.minimal.environ`. libc-free: `std.c.environ` breaks musl
/// cross-compiles (no libc linked). Null in tests (env reads return null).
var g_env_map: ?*const std.process.Environ.Map = null;
var g_environ: ?std.process.Environ = null;

/// Called from main() before any env read or spawn.
pub fn setProcessEnv(map: *const std.process.Environ.Map, environ: std.process.Environ) void {
    g_env_map = map;
    g_environ = environ;
}

/// Environment variable as a borrowed slice into the process environment.
/// Null if unset. Cross-platform via the Environ.Map captured at main().
pub fn getEnvPosix(name: []const u8) ?[]const u8 {
    const map = g_env_map orelse return null;
    return map.get(name);
}

/// Process environ value (for spawning children with the parent's env).
/// Null if main() hasn't called setProcessEnv yet.
pub fn processEnviron() ?std.process.Environ {
    return g_environ;
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
