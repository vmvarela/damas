const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version: release CI injects from git tag with -Dversion=X.Y.Z
    // (sql-pipe pattern); the exe prints it via `damas --version`.
    const version = b.option(
        []const u8,
        "version",
        "Override version string (default: dev)",
    ) orelse "dev";

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

    // The exe compiles for every target (the lib above stays universal too);
    // only the test *runs* are gated on native. The module is rooted at the
    // repo root (damas_root.zig) so the @embedFile of apps/web/* resolves
    // within the package path — see src/runtime/web_assets.zig for why a
    // src/-rooted module can't do that.
    const damas = b.addExecutable(.{
        .name = "damas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("damas_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    damas.root_module.addOptions("build_options", build_options);
    // libvaxis is a dependency of the exe module only — the static lib stays
    // universal (core-only, no tty).
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    damas.root_module.addImport("vaxis", vaxis.module("vaxis"));
    b.installArtifact(damas);

    // WASM standalone module: exports the protocol ABI (src/wasm_api.zig)
    // for the browser build. Rooted at src/ (protocol imports live under
    // src/). entry disabled + rdynamic keeps only the exported symbols;
    // ReleaseSmall keeps the download lean.
    const web_step = b.step("web", "Build the WASM module and copy web assets");
    const wasm = b.addExecutable(.{
        .name = "damas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_api.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    web_step.dependOn(&b.addInstallFile(wasm.getEmittedBin(), "web/damas.wasm").step);
    for ([_][]const u8{ "index.html", "style.css", "app.js" }) |asset| {
        web_step.dependOn(&b.addInstallFile(b.path(b.fmt("apps/web/{s}", .{asset})), b.fmt("web/{s}", .{asset})).step);
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

    // WASM ABI tests (src/wasm_api.zig): the round-trip test runs natively;
    // the wasm32 branch of timer.zig (dz_now_ms) is never referenced here.
    const wasm_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (native) test_step.dependOn(&b.addRunArtifact(wasm_api_tests).step);

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

    // TUI tests (stdNum notation): module root at src/ so tui.zig's `../core`
    // imports resolve; tui.zig imports vaxis, so the test module needs the
    // same import wiring as the exe.
    const tui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tui_tests.root_module.addImport("vaxis", vaxis.module("vaxis"));
    if (native) test_step.dependOn(&b.addRunArtifact(tui_tests).step);
}