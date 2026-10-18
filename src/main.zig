const std = @import("std");
const Git = @import("git.zig").Git;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 4 or
        !std.mem.eql(u8, args[1], "init") or
        !std.mem.eql(u8, args[2], "--base"))
    {
        try std.Io.File.stderr().writeStreamingAll(
            init.io,
            "usage: stakrr init --base <branch>\n",
        );
        return error.InvalidArguments;
    }

    const git = Git{
        .allocator = allocator,
        .io = init.io,
    };

    initStack(&git, allocator, args[3]) catch |err| {
        std.log.err("initialisation failed: {s}", .{
            @errorName(err),
        });
        return err;
    };
}

fn initStack(
    git: *const Git,
    allocator: std.mem.Allocator,
    base_name: []const u8,
) !void {
    // 1. require standard working tree
    try git.ensureWorkTree();

    // 2. refuse existing initialisation
    const existing = try git.run(&.{
        "config", "--local", "--get", "stakrr.state",
    });
    defer git.free(existing);

    switch (existing.term) {
        .exited => |code| switch (code) {
            0 => return error.AlreadyInitialised,
            1 => {},
            else => return error.GitFailed,
        },
        else => return error.GitTerminated,
    }

    // 3. identify rolling branch and base
    const work_ref = try git.currentBranch();

    const base_ref = try std.fmt.allocPrint(
        allocator,
        "refs/heads/{s}",
        .{base_name},
    );

    // validate the base as a git branch ref
    _ = try git.output(&.{
        "check-ref-format",
        base_ref,
    });

    if (std.mem.eql(u8, work_ref, base_ref))
        return error.BaseEqualsWork;

    // 4. resolve both branch tips
    const base_oid = try git.resolveCommit(base_ref);
    const work_oid = try git.resolveCommit(work_ref);

    // 5. check ancestry
    if (!try git.isAncestor(base_oid, work_oid))
        return error.BaseNotAncestor;

    // 6. reject merge commits for m1
    const range = try std.fmt.allocPrint(
        allocator,
        "{s}..{s}",
        .{ base_oid, work_oid },
    );

    const merges = try git.output(&.{
        "rev-list",
        "--min-parents=2",
        range,
    });

    if (merges.len != 0)
        return error.MergeCommitsUnsupported;

    // 7. persist the initialisation metadata
    const state = try std.fmt.allocPrint(
        allocator,
        "v1 {s} {s} {s}",
        .{ base_ref, work_ref, base_oid },
    );

    _ = try git.output(&.{
        "config",
        "--local",
        "--add",
        "stakrr.state",
        state,
    });

    std.log.info("initialised: {s} -> {s}", .{
        base_ref,
        work_ref,
    });
}
