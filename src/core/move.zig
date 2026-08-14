//! Move representation and a fixed-capacity move list (no allocator).

const std = @import("std");

/// A complete move. For a multi-jump chain, `from` is the starting square,
/// `to` the final landing square, and `captured` lists the squares of the
/// captured pieces in the order they were taken. Non-capture moves have
/// `num_captured == 0`.
/// extern: fixed layout, kept ABI-stable; compiler-checks the layout.
pub const Move = extern struct {
    from: u8,
    to: u8,
    captured: [12]u8,
    num_captured: u8,
};

/// Fixed-capacity list of moves. Capacity 256 covers every legal move in any
/// position (checkers branching factor is far below this).
pub const MoveList = struct {
    items: [256]Move = undefined,
    len: usize = 0,

    /// Append a move; returns false if the list is full.
    pub fn add(self: *MoveList, move: Move) bool {
        if (self.len >= self.items.len) return false;
        self.items[self.len] = move;
        self.len += 1;
        return true;
    }

    pub fn clear(self: *MoveList) void {
        self.len = 0;
    }

    pub fn slice(self: *const MoveList) []const Move {
        return self.items[0..self.len];
    }

    /// Mutable slice — used by move ordering (sort in place).
    pub fn mutSlice(self: *MoveList) []Move {
        return self.items[0..self.len];
    }
};

pub fn isCapture(move: Move) bool {
    return move.num_captured > 0;
}

test "MoveList add/clear/slice" {
    var list = MoveList{};
    try std.testing.expectEqual(@as(usize, 0), list.len);
    try std.testing.expectEqual(@as(usize, 0), list.slice().len);

    const m1 = Move{ .from = 9, .to = 18, .captured = [_]u8{13} ** 12, .num_captured = 1 };
    const m2 = Move{ .from = 9, .to = 13, .captured = [_]u8{0} ** 12, .num_captured = 0 };

    try std.testing.expect(list.add(m1));
    try std.testing.expect(list.add(m2));
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(usize, 2), list.slice().len);
    try std.testing.expectEqual(@as(u8, 9), list.slice()[0].from);
    try std.testing.expectEqual(@as(u8, 13), list.slice()[1].to);
    try std.testing.expect(isCapture(list.slice()[0]));
    try std.testing.expect(!isCapture(list.slice()[1]));

    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.len);
    try std.testing.expectEqual(@as(usize, 0), list.slice().len);
}
