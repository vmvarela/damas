const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Run steps only make sense for the native target (cross binaries
    // can't execute on the build host).
    const native = target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag;

    // The static lib is the universal cross-target artifact: c_api.zig
    // imports core only (no llm/http/config), so `zig build
    // -Dtarget=aarch64-linux` and `-Dtarget=wasm32-wasi` build the lib alone
    // (nit 9: llm/config/cli/ws are host-only).
    const lib = b.addLibrary(.{
        .name = "damas",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            // timer.zig's clock_gettime needs the C library on wasi; on the
            // host this is a no-op for the archive. c_api consumers already
            // link libc (C ABI test).
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);
    b.installFile("include/damas.h", "include/damas.h");
    // ponytail: -femit-h regenerates the header from c_api.zig when the ABI
    // changes; the manual include/damas.h copy is fine for now.

    // Host-only executables: the CLI reads stdin (std.posix.read) and makes
    // LLM HTTP calls; the WS server binds a loopback socket. Neither
    // cross-compiles, so both are skipped for non-native targets.
    if (native) {
        // CLI: config-driven match (human/minimax/llm, SPEC §7).
        const cli = b.addExecutable(.{
            .name = "damas",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(cli);

        // Headless WebSocket server (SPEC §5); port from DZ_WS_PORT.
        // Module rooted at src/ws_main.zig (src/), not the entry file's
        // dir: server.zig uses relative imports (../../core/*) that only
        // resolve inside a src/-rooted module.
        const ws = b.addExecutable(.{
            .name = "damas-ws",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ws_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(ws);

        // Terminal UI app (SPEC §2). The real code lives in apps/tui/main.zig,
        // but Zig 0.16 requires the module root to contain all imported source
        // files, so the executable root is the project-root anchor tui_root.zig.
        const tui = b.addExecutable(.{
            .name = "damas-tui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tui_root.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(tui);
    }

    const test_step = b.step("test", "Run core, C API, LLM, and WebSocket tests");

    // Core Zig tests (engine + game + player).
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/engine_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (native) test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // LLM layer tests (config, validation, prompt building) — no network.
    // Module root at src/ so llm/ and utils/ imports resolve within the
    // module path.
    const llm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/llm_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (native) test_step.dependOn(&b.addRunArtifact(llm_tests).step);

    // WebSocket runtime tests (SPEC §5 protocol dispatch) — no sockets;
    // handleMessage is exercised directly with a fake LLM provider.
    const ws_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ws_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (native) test_step.dependOn(&b.addRunArtifact(ws_tests).step);

    // C API test: compile test/c_api_test.c against the static lib.
    const c_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_module.addCSourceFile(.{ .file = b.path("test/c_api_test.c"), .flags = &.{} });
    c_module.addIncludePath(b.path("include"));
    c_module.linkLibrary(lib);
    const c_test = b.addExecutable(.{ .name = "c_api_test", .root_module = c_module });
    if (native) test_step.dependOn(&b.addRunArtifact(c_test).step);
}