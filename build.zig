const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const test_step = b.step("test", "Run core tests and C API test");

    // Core Zig tests (engine + game + player).
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/engine_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(c_test).step);
}