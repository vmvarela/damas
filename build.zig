const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Run steps only make sense for the native target (cross binaries
    // can't execute on the build host).
    const native = target.result.cpu.arch == builtin.cpu.arch and
        target.result.os.tag == builtin.os.tag;

    const lib = b.addLibrary(.{
        .name = "damas",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);
    b.installFile("include/damas.h", "include/damas.h");

    // CLI: human vs minimax.
    const cli = b.addExecutable(.{
        .name = "damas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);

    const test_step = b.step("test", "Run core tests and C API test");

    // Core Zig tests (engine + game + player).
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/engine_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (native) test_step.dependOn(&b.addRunArtifact(core_tests).step);

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