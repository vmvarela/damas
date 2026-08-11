//! Search time limit. `time_limit_ms == 0` means no limit.
//!
//! Zig 0.16-dev moved the clock API into `std.Io`; this module uses the same
//! underlying syscall the stdlib itself uses (std.posix.system.clock_gettime
//! with CLOCK_MONOTONIC / UPTIME_RAW via std.posix.CLOCK.awake) so the engine
//! stays independent of the Io event-loop machinery.

const std = @import("std");
const builtin = @import("builtin");

pub const Timer = struct {
    deadline_ms: i64,

    pub fn init(time_limit_ms: u32) Timer {
        if (time_limit_ms == 0) return .{ .deadline_ms = std.math.maxInt(i64) };
        return .{ .deadline_ms = nowMillis() + time_limit_ms };
    }

    pub fn expired(self: Timer) bool {
        return nowMillis() >= self.deadline_ms;
    }
};

fn nowMillis() i64 {
    // Same mapping the stdlib uses (std.Io.Threaded.clockToPosix): UPTIME_RAW
    // on darwin-family, MONOTONIC elsewhere.
    const clock_id: std.posix.clockid_t = switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(clock_id, &ts);
    if (std.posix.errno(rc) != .SUCCESS) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

test "timer does not expire with a large limit" {
    const t = Timer.init(1000);
    try std.testing.expect(!t.expired());
}

test "timer expires after a 1ms limit" {
    const t = Timer.init(1);
    // ponytail: busy-wait — sleep APIs removed from std in this dev build;
    // 2ms busy loop is fine for a test.
    const start = nowMillis();
    while (nowMillis() - start < 2) {}
    try std.testing.expect(t.expired());
}

test "zero limit never expires" {
    const t = Timer.init(0);
    const start = nowMillis();
    while (nowMillis() - start < 2) {}
    try std.testing.expect(!t.expired());
}
