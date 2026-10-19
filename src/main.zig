const std = @import("std");
const Git = @import("git.zig").Git;
const stack = @import("stack.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try printHelp(init.io);
        return;
    }
    if (std.mem.eql(u8, args[1], "--help") or
        std.mem.eql(u8, args[1], "help"))
    {
        try printHelp(init.io);
        return;
    }

    const git = Git{
        .allocator = allocator,
        .io = init.io,
    };

    runCommand(&git, init.io, allocator, args) catch |err| {
        if (userError(err)) |message| {
            try std.Io.File.stderr().writeStreamingAll(init.io, message);
            return error.CommandFailed;
        }
        return err;
    };
}

fn runCommand(
    git: *const Git,
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (std.mem.eql(u8, args[1], "init")) {
        if (args.len != 4 or
            !std.mem.eql(u8, args[2], "--base"))
        {
            return error.InvalidArguments;
        }

        try stack.initStack(git, args[3]);
        try std.Io.File.stdout().writeStreamingAll(io, "stack initialized\n");
    } else if (std.mem.eql(u8, args[1], "status")) {
        if (args.len != 2)
            return error.InvalidArguments;

        var snapshot = try stack.inspect(git);
        defer snapshot.deinit();

        try printStatus(io, allocator, snapshot);
    } else if (std.mem.eql(u8, args[1], "cut")) {
        if (args.len != 3 and
            !(args.len == 5 and std.mem.eql(u8, args[3], "--at")))
        {
            return error.InvalidArguments;
        }

        const revision: ?[]const u8 =
            if (args.len == 5) args[4] else null;

        try stack.cut(git, args[2], revision);
        const message = try std.fmt.allocPrint(
            allocator,
            "created layer: stakrr/{s}\n",
            .{args[2]},
        );
        try std.Io.File.stdout().writeStreamingAll(io, message);
    } else {
        return error.UnknownCommand;
    }
}

fn printHelp(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "usage: stakrr <command> [options]\n" ++
        "  init --base <branch>  adopt current branch as rolling work\n" ++
        "  status                display layers and unstacked commits\n" ++
        "  cut <name> [--at <rev>]  create the next layer\n" ++
        "  help                  show this message\n");
}

fn userError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidArguments => "error: invalid arguments (run 'stakrr help')\n",
        error.UnknownCommand => "error: unknown command (run 'stakrr help')\n",
        error.NotInitialized => "error: stack not initialized\n",
        error.AlreadyInitialised => "error: stack already initialized\n",
        error.ExistingStackRefs => "error: stale or existing stakrr refs found\n",
        error.ReservedBranchNamespace => "error: base and work branches cannot use stakrr/\n",
        error.BaseEqualsWork => "error: base and work branches must differ\n",
        error.BaseNotAncestor => "error: base is not an ancestor of work\n",
        error.MergeCommitsUnsupported => "error: merge commits in the stack are unsupported\n",
        error.InvalidStack, error.InvalidLayerBoundary => "error: stack refs are inconsistent\n",
        error.BaseMoved => "error: base branch moved since initialization\n",
        error.EmptyCut => "error: no new commits since previous layer\n",
        error.NotOnWorkBranch => "error: cut must run on the rolling work branch\n",
        error.InvalidLayerName => "error: invalid layer name\n",
        error.InvalidRefName => "error: invalid Git branch name\n",
        error.InvalidCutBoundary, error.CutOutsideWork => "error: revision is outside the next unstacked segment\n",
        error.GitFailed => "error: Git operation failed (refs may have changed)\n",
        error.DetachedHead => "error: detached HEAD is unsupported\n",
        else => null,
    };
}

fn shortRef(ref_name: []const u8) []const u8 {
    const prefix = "refs/heads/";

    if (std.mem.startsWith(u8, ref_name, prefix))
        return ref_name[prefix.len..];

    return ref_name;
}

fn printStatus(
    io: std.Io,
    allocator: std.mem.Allocator,
    snapshot: stack.Snapshot,
) !void {
    const stdout = std.Io.File.stdout();

    const header = try std.fmt.allocPrint(
        allocator,
        "stack: {s} → {s}\n\n",
        .{
            shortRef(snapshot.config.base_ref),
            shortRef(snapshot.config.work_ref),
        },
    );
    try stdout.writeStreamingAll(io, header);

    if (snapshot.base_moved) {
        try stdout.writeStreamingAll(
            io,
            "  warning: base moved since initialization\n\n",
        );
    }

    for (snapshot.layers) |layer| {
        const line = try std.fmt.allocPrint(
            allocator,
            "  {s}: {d} commit(s)\n",
            .{ shortRef(layer.ref_name), layer.commits },
        );

        try stdout.writeStreamingAll(io, line);
    }

    const work_line = try std.fmt.allocPrint(
        allocator,
        "  {s}: {d} unstacked commit(s)\n",
        .{
            shortRef(snapshot.config.work_ref),
            snapshot.unstacked_commits,
        },
    );
    try stdout.writeStreamingAll(io, work_line);

    const footer = try std.fmt.allocPrint(
        allocator,
        "\n  {d} layer(s)\n",
        .{snapshot.layers.len},
    );
    try stdout.writeStreamingAll(io, footer);
}
