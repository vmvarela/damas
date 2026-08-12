//! damas-z: single binary entry — subcommands for the match CLI, the TUI,
//! and the web server (user requirement: "todo en un mismo binario, incluido
//! el servicio web"). Bare invocation = config-driven match (backward compat).

const std = @import("std");
const cli = @import("runtime/cli.zig");
const tui = @import("runtime/tui.zig");
const server = @import("runtime/websocket/server.zig");
const config_mod = @import("utils/config.zig");

const usage =
    \\damas-z — damas (checkers) engine
    \\  damas-z           partida config-driven (config.json: human|minimax|llm)
    \\  damas-z web       servicio web (frontend embebido + WebSocket) y abre el navegador
    \\  damas-z tui       terminal UI interactiva
    \\  damas-z help      esta ayuda
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // program name

    if (args.next()) |sub| {
        if (std.mem.eql(u8, sub, "web")) return web();
        if (std.mem.eql(u8, sub, "tui")) return tui.run();
        if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
    } else {
        return cli.runMatch(); // backward compat: bare damas-z = match
    }

    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}

/// Web mode: port from DZ_WS_PORT, default 8080.
fn web() !void {
    const val = config_mod.getEnvPosix("DZ_WS_PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, val, 10) catch 8080;
    server.serveWeb(port) catch |e| {
        // Friendly bind failure: the browser open would otherwise hit a dead
        // port and the user would get a raw error + traceback.
        std.debug.print("error: no se pudo abrir 127.0.0.1:{d}: {s} (puerto en uso?)\n", .{ port, @errorName(e) });
        std.process.exit(1);
    };
}
