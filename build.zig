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

    // Host-only executable: the TUI needs raw-mode stdin, the match CLI reads
    // stdin and makes LLM HTTP calls, and the web mode binds a loopback
    // socket and embeds apps/web/*. None of that cross-compiles, so the exe
    // is skipped for non-native targets (the lib above stays universal).
    // The module is rooted at the repo root (damas_root.zig) so the
    // @embedFile of apps/web/* resolves within the package path — see
    // src/runtime/web_assets.zig for why a src/-rooted module can't do that.
    if (native) {
        const damas = b.addExecutable(.{
            .name = "damas",
            .root_module = b.createModule(.{
                .root_source_file = b.path("damas_root.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(damas);
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