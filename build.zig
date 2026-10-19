const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("stakrr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "stakrr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stakrr", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const git_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/git_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stakrr", .module = mod },
            },
        }),
    });
    const run_git_tests = b.addRunArtifact(git_tests);

    const stack_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/stack_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stakrr", .module = mod },
            },
        }),
    });
    const run_stack_tests = b.addRunArtifact(stack_tests);

    const cut_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cut_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stakrr", .module = mod },
            },
        }),
    });
    const run_cut_tests = b.addRunArtifact(cut_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_git_tests.step);
    test_step.dependOn(&run_stack_tests.step);
    test_step.dependOn(&run_cut_tests.step);
}
