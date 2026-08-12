//! Build anchor for damas-tui. Zig 0.16 requires the module root to contain
//! all imported source files; this file sits at the project root so that
//! apps/tui/main.zig can reach src/ with relative imports.

pub fn main() !void {
    try @import("apps/tui/main.zig").main();
}
