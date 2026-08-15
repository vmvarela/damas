const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version: release CI injects from git tag with -Dversion=X.Y.Z; the
    // exe prints it via `damas --version`.
    const version = b.option(
        []const u8,
        "version",
        "Override version string (default: dev)",
    ) orelse "dev";

    // Run steps only make sense for the native target (cross binaries
    // can't execute on the build host).
    const native = target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag;

    // The exe compiles for every target; only the test *runs* are gated on
    // native. The module is rooted at the repo root (damas_root.zig) so the
    // @embedFile of apps/web/* resolves within the package path — see
    // src/runtime/web_assets.zig for why a src/-rooted module can't do that.
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
    // libvaxis is a dependency of the exe module only.
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
    for ([_][]const u8{ "index.html", "style.css", "app.js", "manifest.webmanifest", "sw.js", "icon-192.png", "icon-512.png", "icon-maskable-512.png" }) |asset| {
        web_step.dependOn(&b.addInstallFile(b.path(b.fmt("apps/web/{s}", .{asset})), b.fmt("web/{s}", .{asset})).step);
    }

    const test_step = b.step("test", "Run core, LLM, and WebSocket tests");

    // Core Zig tests (engine + game).
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

    // WebSocket server process tests (browser-launch zombie reaping). Rooted
    // at the repo root via a test anchor: server.zig's @embedFile of
    // apps/web/* (through web_assets.zig) escapes a src/-rooted module — see
    // damas_root.zig for the same constraint.
    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("server_tests_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (native) test_step.dependOn(&b.addRunArtifact(server_tests).step);

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
