const std = @import("std");
const stakrr = @import("stakrr");
const Git = stakrr.git.Git;
const Diagnostics = stakrr.git.Diagnostics;
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

    const command = parseArgs(args) catch |err| fail(init.io, err, null);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var diagnostics: Diagnostics = .{};
    const git = Git{
        .allocator = allocator,
        .io = init.io,
        .diagnostics = &diagnostics,
    };

    runCommand(&git, stdout, command) catch |err| {
        stdout.flush() catch {};
        fail(init.io, err, &diagnostics);
    };
    try stdout.flush();
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
            try stdout.print("stack initialized on {s}\n", .{options.base});
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

/// report a failure on stderr and exit; never returns an error from main,
/// which would make Zig print the error name and a trace as well
fn fail(io: std.Io, err: anyerror, diagnostics: ?*const Diagnostics) noreturn {
    var buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;

    if (userError(err)) |message| {
        stderr.print("error: {s}\n", .{message}) catch {};
    } else {
        stderr.print("error: unexpected failure ({s})\n", .{@errorName(err)}) catch {};
    }

    if (err == error.GitFailed) {
        if (diagnostics) |diag| {
            if (diag.len != 0) stderr.print("git: {s}\n", .{diag.stderr()}) catch {};
        }
    }

    stderr.flush() catch {};

    const usage_error = err == error.InvalidArguments or err == error.UnknownCommand;
    std.process.exit(if (usage_error) 2 else 1);
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
        error.InvalidArguments => "invalid arguments (run 'stakrr help')",
        error.UnknownCommand => "unknown command (run 'stakrr help')",
        error.NotInitialized => "stack not initialized (run 'stakrr init --base <branch>')",
        error.AlreadyInitialized => "stack already initialized",
        error.ExistingStackRefs => "stale or existing stakrr refs found",
        error.ReservedBranchNamespace => "base and work branches cannot use stakrr/",
        error.BaseEqualsWork => "base and work branches must differ",
        error.BaseNotAncestor => "base is not an ancestor of work",
        error.MergeCommitsUnsupported => "merge commits in the stack are unsupported",
        error.InvalidConfig => "stakrr state in git config is invalid",
        error.UnsupportedConfigVersion => "stack was created by an incompatible stakrr version",
        error.InvalidStack, error.InvalidLayerBoundary => "stack refs are inconsistent",
        error.BaseMoved => "base branch moved since initialization",
        error.NotOnWorkBranch => "cut must run on the rolling work branch",
        error.InvalidLayerName => "invalid layer name",
        error.LayerExists => "a layer with that name already exists or conflicts with one",
        error.EmptyCut => "no new commits since previous layer",
        error.InvalidCutBoundary, error.CutOutsideWork => "revision is outside the next unstacked segment",
        error.GitFailed => "git command failed",
        error.GitTerminated => "git was terminated by a signal",
        error.InvalidRefName => "invalid Git branch name",
        error.InvalidOid => "invalid Git object id",
        error.NotGitRepository => "not inside a Git repository",
        error.NotWorkingTree => "not inside a Git working tree",
        error.DetachedHead => "detached HEAD is unsupported",
        error.InvalidGitConfig => "stakrr.state has multiple or empty values",
        error.InvalidGitOutput => "unexpected output from git",
        error.StreamTooLong => "git output exceeded the size limit",
        error.FileNotFound => "git executable not found on PATH",
        error.OutOfMemory => "out of memory",
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

test "every domain error has a user message" {
    inline for (@typeInfo(stack.Error).error_set.error_names.?) |name| {
        try testing.expect(userError(@field(anyerror, name)) != null);
    }
}

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
