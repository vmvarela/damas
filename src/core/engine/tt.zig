//! Transposition table for the search: fixed-size array indexed by
//! `key & (size - 1)`, overwrite replacement (simplest policy; a two-tier
//! or depth-preferred replacement could improve hit rate later).

const std = @import("std");
const move_mod = @import("../move.zig");

pub const Move = move_mod.Move;

pub const TTFlag = enum(u8) { exact, lower_bound, upper_bound };

pub const TTEntry = struct {
    key: u64,
    depth: u8,
    score: i32,
    flag: TTFlag,
    move: Move,
};

pub const TranspositionTable = struct {
    entries: []TTEntry,
    allocator: std.mem.Allocator,

    /// `size` must be a power of two.
    pub fn init(allocator: std.mem.Allocator, size: usize) !TranspositionTable {
        const entries = try allocator.alloc(TTEntry, size);
        @memset(entries, undefined);
        return .{ .entries = entries, .allocator = allocator };
    }

    pub fn deinit(self: *TranspositionTable) void {
        self.allocator.free(self.entries);
    }

    /// Entry for `key`, or null if absent (or overwritten by a collision).
    pub fn get(self: *const TranspositionTable, key: u64) ?TTEntry {
        const e = self.entries[key & (self.entries.len - 1)];
        if (e.key == key) return e;
        return null;
    }

    pub fn put(self: *TranspositionTable, entry: TTEntry) void {
        self.entries[entry.key & (self.entries.len - 1)] = entry;
    }

    pub fn clear(self: *TranspositionTable) void {
        @memset(self.entries, undefined);
    }
};

test "put/get round-trip" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1 << 8);
    defer tt.deinit();
    const e = TTEntry{
        .key = 42,
        .depth = 5,
        .score = 123,
        .flag = .exact,
        .move = Move{ .from = 1, .to = 2, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    };
    tt.put(e);
    const got = tt.get(42);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u8, 5), got.?.depth);
    try std.testing.expectEqual(@as(i32, 123), got.?.score);
    try std.testing.expectEqual(TTFlag.exact, got.?.flag);
    try std.testing.expectEqual(@as(u8, 1), got.?.move.from);
}

test "collision: different key at same index not returned" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1 << 8);
    defer tt.deinit();
    tt.put(.{
        .key = 42,
        .depth = 1,
        .score = 1,
        .flag = .exact,
        .move = Move{ .from = 1, .to = 2, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    });
    // 298 & 255 == 42 & 255, but keys differ.
    try std.testing.expect(tt.get(298) == null);
}

test "clear empties the table" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1 << 8);
    defer tt.deinit();
    tt.put(.{
        .key = 7,
        .depth = 1,
        .score = 1,
        .flag = .exact,
        .move = Move{ .from = 1, .to = 2, .captured = [_]u8{0} ** 12, .num_captured = 0 },
    });
    tt.clear();
    try std.testing.expect(tt.get(7) == null);
}
