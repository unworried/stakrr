const std = @import("std");
const stakrr = @import("stakrr");
const Git = stakrr.git.Git;
const stack = stakrr.stack;

pub const Command = union(enum) {
    help,
    init: struct { base: []const u8 },
    status,
    cut: struct { name: []const u8, at: ?[]const u8 = null },
};

pub const ParseError = error{ InvalidArguments, UnknownCommand };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const git = Git{
        .allocator = allocator,
        .io = init.io,
    };

    run(&git, stdout, args) catch |err| {
        stdout.flush() catch {};
        if (userError(err)) |message| {
            try std.Io.File.stderr().writeStreamingAll(init.io, message);
            return error.CommandFailed;
        }
        return err;
    };
    try stdout.flush();
}

fn run(git: *const Git, stdout: *std.Io.Writer, args: []const []const u8) !void {
    try runCommand(git, stdout, try parseArgs(args));
}

pub fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return .help;

    const command = args[1];
    const rest = args[2..];

    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h"))
        return .help;

    if (eql(command, "init")) {
        if (rest.len == 2 and eql(rest[0], "--base"))
            return .{ .init = .{ .base = try value(rest[1]) } };
        if (rest.len == 1 and std.mem.startsWith(u8, rest[0], "--base="))
            return .{ .init = .{ .base = try value(rest[0]["--base=".len..]) } };
        return error.InvalidArguments;
    }

    if (eql(command, "status")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .status;
    }

    if (eql(command, "cut")) {
        var name: ?[]const u8 = null;
        var at: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const arg = rest[i];
            if (eql(arg, "--at")) {
                i += 1;
                if (at != null or i == rest.len) return error.InvalidArguments;
                at = try value(rest[i]);
            } else if (std.mem.startsWith(u8, arg, "--at=")) {
                if (at != null) return error.InvalidArguments;
                at = try value(arg["--at=".len..]);
            } else if (name == null) {
                name = try value(arg);
            } else {
                return error.InvalidArguments;
            }
        }
        return .{ .cut = .{
            .name = name orelse return error.InvalidArguments,
            .at = at,
        } };
    }

    return error.UnknownCommand;
}

/// option values and positionals must be non-empty and not look like flags
fn value(arg: []const u8) ParseError![]const u8 {
    if (arg.len == 0 or arg[0] == '-') return error.InvalidArguments;
    return arg;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn runCommand(
    git: *const Git,
    stdout: *std.Io.Writer,
    command: Command,
) !void {
    switch (command) {
        .help => try printHelp(stdout),
        .init => |options| {
            try stack.initStack(git, options.base);
            try stdout.writeAll("stack initialized\n");
        },
        .status => {
            var snapshot = try stack.inspect(git);
            defer snapshot.deinit(git.allocator);

            try printStatus(stdout, snapshot);
        },
        .cut => |options| {
            try stack.cut(git, options.name, options.at);
            try stdout.print("created layer: stakrr/{s}\n", .{options.name});
        },
    }
}

fn printHelp(stdout: *std.Io.Writer) !void {
    try stdout.writeAll("usage: stakrr <command> [options]\n" ++
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
        error.AlreadyInitialized => "error: stack already initialized\n",
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

fn printStatus(stdout: *std.Io.Writer, snapshot: stack.Snapshot) !void {
    try stdout.print("stack: {s} → {s}\n\n", .{
        shortRef(snapshot.config.base_ref),
        shortRef(snapshot.config.work_ref),
    });

    if (snapshot.base_moved) {
        try stdout.writeAll(
            "  warning: base moved since initialization\n\n",
        );
    }

    for (snapshot.layers) |layer| {
        try stdout.print("  {s}: {d} commit(s)\n", .{
            shortRef(layer.ref_name),
            layer.commits,
        });
    }

    try stdout.print("  {s}: {d} unstacked commit(s)\n", .{
        shortRef(snapshot.config.work_ref),
        snapshot.unstacked_commits,
    });

    try stdout.print("\n  {d} layer(s)\n", .{snapshot.layers.len});
}

const testing = std.testing;

test "parseArgs: help" {
    try testing.expectEqual(Command.help, try parseArgs(&.{"stakrr"}));
    try testing.expectEqual(Command.help, try parseArgs(&.{ "stakrr", "--help" }));
    try testing.expectError(error.UnknownCommand, parseArgs(&.{ "stakrr", "nope" }));
}

test "parseArgs: init" {
    const a = try parseArgs(&.{ "stakrr", "init", "--base", "main" });
    try testing.expectEqualStrings("main", a.init.base);

    const b = try parseArgs(&.{ "stakrr", "init", "--base=main" });
    try testing.expectEqualStrings("main", b.init.base);

    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "init" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "init", "--base", "--x" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "init", "--base=" }));
}

test "parseArgs: cut accepts --at in any position" {
    const a = try parseArgs(&.{ "stakrr", "cut", "p1" });
    try testing.expectEqualStrings("p1", a.cut.name);
    try testing.expect(a.cut.at == null);

    const b = try parseArgs(&.{ "stakrr", "cut", "--at", "HEAD~1", "p1" });
    try testing.expectEqualStrings("p1", b.cut.name);
    try testing.expectEqualStrings("HEAD~1", b.cut.at.?);

    const c = try parseArgs(&.{ "stakrr", "cut", "p1", "--at=HEAD~2" });
    try testing.expectEqualStrings("HEAD~2", c.cut.at.?);

    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut", "p1", "p2" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut", "p1", "--at" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut", "--bad" }));
}

test "parseArgs: status" {
    try testing.expectEqual(Command.status, try parseArgs(&.{ "stakrr", "status" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "status", "x" }));
}
