//! damas: single binary entry — subcommands for the match CLI, the TUI,
//! and the web server (user requirement: "todo en un mismo binario, incluido
//! el servicio web"). Bare invocation = config-driven match (backward compat).

const std = @import("std");
const cli = @import("runtime/cli.zig");
const tui = @import("runtime/tui.zig");
const server = @import("runtime/websocket/server.zig");
const config_mod = @import("utils/config.zig");
const build_options = @import("build_options");

const usage =
    \\damas — damas (checkers) engine
    \\  damas           partida config-driven (config.json: human|minimax|llm)
    \\  damas web       servicio web (frontend embebido + WebSocket) y abre el navegador
    \\  damas tui       terminal UI interactiva
    \\  damas help      esta ayuda
    \\  --rules english|spanish  variante de reglas (default: config.json / spanish;
    \\                    en web, default del selector). Se acepta antes o despues del subcomando.
    \\  --provider <name>  provider OpenAI-compatible (default: auto-detect por env / config.json)
    \\
;

pub fn main(init: std.process.Init) !void {
    // Capture the process environment once (libc-free: std.c.environ breaks
    // musl cross-compiles). All env reads + spawns go through config.zig.
    config_mod.setProcessEnv(init.environ_map, init.minimal.environ);
    // initAllocator: cross-platform (Windows needs an allocator for the
    // command line; on posix it's the same as init). deinit is a no-op on
    // posix.
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator);
    defer args.deinit();
    _ = args.next(); // program name

    var sub: ?[]const u8 = null;
    var rules_flag: ?config_mod.Variant = null;
    var provider_flag: ?[]const u8 = null;

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--rules")) {
            const val = args.next() orelse {
                std.debug.print("error: --rules requiere un valor (english|spanish)\n", .{});
                std.debug.print("{s}", .{usage});
                std.process.exit(1);
            };
            rules_flag = strictVariant(val) orelse {
                std.debug.print("error: variante invalida \"{s}\" (english|spanish)\n", .{val});
                std.debug.print("{s}", .{usage});
                std.process.exit(1);
            };
            continue;
        }
        if (std.mem.eql(u8, a, "--provider")) {
            provider_flag = args.next() orelse {
                std.debug.print("error: --provider requiere un valor\n", .{});
                std.debug.print("{s}", .{usage});
                std.process.exit(1);
            };
            continue;
        }
        if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("damas {s}\n", .{build_options.version});
            return;
        }
        // Unknown flag (typo like `--runes`) must fail loudly, not be silently
        // dropped when the subcommand is already fixed.
        if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("error: flag desconocido \"{s}\"\n", .{a});
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        // First non-flag argument is the subcommand (help/-h/--help included).
        if (sub == null) sub = a;
    }

    if (sub) |s| {
        if (std.mem.eql(u8, s, "web")) return web(rules_flag, provider_flag);
        if (std.mem.eql(u8, s, "tui")) return tui.run(init.io, init.environ_map, rules_flag, provider_flag);
        if (std.mem.eql(u8, s, "help") or std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
    } else {
        return cli.runMatch(rules_flag, provider_flag); // backward compat: bare damas = match
    }

    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}

/// Strict flag parsing: anything other than "english"/"spanish" is an error
/// (no silent fallback — unlike the config parser, which tolerates typos).
fn strictVariant(s: []const u8) ?config_mod.Variant {
    if (std.mem.eql(u8, s, "english")) return .english;
    if (std.mem.eql(u8, s, "spanish")) return .spanish;
    return null;
}

/// Web mode: port from DZ_WS_PORT, default 8080. The flag (if any) becomes
/// the server's default variant for new games without an explicit "rules".
fn web(rules_flag: ?config_mod.Variant, provider_flag: ?[]const u8) !void {
    const val = config_mod.getEnvPosix("DZ_WS_PORT") orelse "8080";
    const port = std.fmt.parseInt(u16, val, 10) catch 8080;
    const default_rules = rules_flag orelse .spanish;
    server.serveWeb(port, default_rules, provider_flag) catch |e| {
        // Friendly bind failure: the browser open would otherwise hit a dead
        // port and the user would get a raw error + traceback.
        std.debug.print("error: no se pudo abrir 127.0.0.1:{d}: {s} (puerto en uso?)\n", .{ port, @errorName(e) });
        std.process.exit(1);
    };
}
