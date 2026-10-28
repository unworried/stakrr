const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("stakrr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "stakrr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stakrr", .module = mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    // A top level step for running all tests. Each run step is independent,
    // so they execute in parallel.
    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // end-to-end tests drive the built binary
    const cli_options = b.addOptions();
    cli_options.addOptionPath("exe_path", exe.getEmittedBin());
    const ref_driver = b.addExecutable(.{
        .name = "ref-test-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/support/ref_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "stakrr", .module = mod }},
        }),
    });
    cli_options.addOptionPath("ref_driver_path", ref_driver.getEmittedBin());

    const integration_tests = [_][]const u8{
        "tests/git_test.zig",
        "tests/stack_test.zig",
        "tests/cut_test.zig",
        "tests/reset_test.zig",
        "tests/cli_test.zig",
        "tests/symbolic_ref_test.zig",
    };

    for (integration_tests) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "stakrr", .module = mod },
                    .{ .name = "cli_options", .module = cli_options.createModule() },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
