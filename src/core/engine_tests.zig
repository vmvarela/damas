//! Test aggregator for engine modules.
//! Module root must be src/core/ (not src/core/engine/) so that the
//! `../` imports inside engine files resolve.

comptime {
    _ = @import("engine/zobrist.zig");
    _ = @import("engine/tt.zig");
    _ = @import("engine/timer.zig");
    _ = @import("engine/minimax.zig");
    _ = @import("game.zig");
    _ = @import("player.zig");
}
