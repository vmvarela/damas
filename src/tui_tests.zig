//! Test aggregator for the TUI (stdNum notation anchors).
//! Module root must be src/ (not src/runtime/) so that the `../core` imports
//! inside runtime/tui.zig resolve within the module path. vaxis is wired in
//! build.zig, same as the exe.

comptime {
    _ = @import("runtime/tui.zig");
}
