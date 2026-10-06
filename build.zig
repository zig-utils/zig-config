const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    // Library module
    const lib_mod = b.addModule("zig_config", .{
        .root_source_file = b.path("src/zig-config.zig"),
        .target = target,
        .link_libc = true,
    });

    // Tests
    const tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // Individual test files (will be uncommented as they're created)
    // const test_files = [_][]const u8{
    //     "test/config_loader.test.zig",
    //     "test/file_loader.test.zig",
    //     "test/env_processor.test.zig",
    //     "test/merge.test.zig",
    //     "test/cache.test.zig",
    //     "test/validator.test.zig",
    //     "test/integration.test.zig",
    // };
    //
    // for (test_files) |test_file| {
    //     const test_exe = b.addTest(.{
    //         .root_source_file = b.path(test_file),
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     test_exe.root_module.addImport("zig_config", zig_config_module);
    //
    //     const run_test = b.addRunArtifact(test_exe);
    //     test_step.dependOn(&run_test.step);
    // }

    // Format check
    const fmt_check = b.addFmt(.{
        .paths = &.{fmtPath(b, "src")},
        .check = true,
    });

    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt_check.step);

    // Note: Documentation, benchmarks, and examples will be added in later phases
}

/// Zig 0.17 takes `addFmt` paths as LazyPaths; 0.15/0.16 take plain strings.
fn fmtPath(b: *std.Build, comptime path: []const u8) FmtPath {
    return if (FmtPath == std.Build.LazyPath) b.path(path) else path;
}

const FmtPath = @typeInfo(@FieldType(std.Build.Step.Fmt.Options, "paths")).pointer.child;
