const std = @import("std");
const build_options = @import("build_options");
const stakrr = @import("stakrr");
const Git = stakrr.git.Git;
const Diagnostics = stakrr.git.Diagnostics;
const stack = stakrr.stack;
const term = @import("term.zig");
const Terminal = term.Terminal;

pub const Command = union(enum) {
    help,
    version,
    init: struct { base: []const u8 },
    status,
    cut: struct { name: []const u8, at: ?[]const u8 = null },
    reset: struct { delete_layers: bool = false },
    up,
    down,
};

pub const ParseError = error{ InvalidArguments, UnknownCommand };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const env = init.environ_map;

    const command = parseArgs(args) catch |err| fail(init.io, env, err, null);

    var stdout_buffer: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const out: Terminal = .{
        .writer = stdout,
        .mode = try term.detect(init.io, stdout_file, env),
    };

    var diagnostics: Diagnostics = .{};
    const git = Git{
        .allocator = allocator,
        .io = init.io,
        .diagnostics = &diagnostics,
    };

    runCommand(&git, out, command) catch |err| {
        stdout.flush() catch {};
        fail(init.io, env, err, &diagnostics);
    };
    try stdout.flush();
}

pub fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return .help;

    const command = args[1];
    const rest = args[2..];

    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h"))
        return .help;

    if (eql(command, "version") or eql(command, "--version")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .version;
    }

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

    if (eql(command, "reset")) {
        if (rest.len == 0) return .{ .reset = .{} };
        if (rest.len == 1 and eql(rest[0], "--delete-layers"))
            return .{ .reset = .{ .delete_layers = true } };
        return error.InvalidArguments;
    }

    if (eql(command, "up")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .up;
    }

    if (eql(command, "down")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .down;
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
    out: Terminal,
    command: Command,
) !void {
    const stdout = out.writer;
    switch (command) {
        .help => try printHelp(out),
        .version => try stdout.print("stakrr {s}\n", .{build_options.version}),
        .init => |options| {
            try stack.initStack(git, options.base);
            try stdout.writeAll("stack initialized on ");
            try term.styled(out, .accent, "{s}", .{options.base});
            try stdout.writeByte('\n');
        },
        .status => {
            var snapshot = try stack.inspect(git);
            defer snapshot.deinit(git.allocator);

            const current: ?[]u8 = git.currentBranch() catch |err| switch (err) {
                error.DetachedHead => null,
                else => return err,
            };
            defer if (current) |ref| git.allocator.free(ref);

            try printStatus(out, snapshot, current);
        },
        .cut => |options| {
            try stack.cut(git, options.name, options.at);
            try stdout.writeAll("created layer: ");
            try term.styled(out, .accent, "stakrr/{s}", .{options.name});
            try stdout.writeByte('\n');
        },
        .reset => |options| {
            const result = try stack.reset(git, options.delete_layers);
            try stdout.writeAll("stack reset\n");
            if (result.deleted_layers != 0)
                try stdout.print("deleted {d} layer {s}\n", .{
                    result.deleted_layers,
                    plural(result.deleted_layers, "branch", "branches"),
                });
            if (result.kept_layers != 0) {
                try term.styled(out, .warn, "kept {d} layer {s} under stakrr/", .{
                    result.kept_layers,
                    plural(result.kept_layers, "branch", "branches"),
                });
                try stdout.writeAll("; remove them or run 'stakrr reset --delete-layers' before re-initializing\n");
            }
        },
        .up => {
            if (!try stack.navigate(git, .up))
                try stdout.writeAll("already at top\n");
        },
        .down => {
            if (!try stack.navigate(git, .down))
                try stdout.writeAll("already at base\n");
        },
    }
}

/// report a failure on stderr and exit; never returns an error from main,
/// which would make Zig print the error name and a trace as well
fn fail(
    io: std.Io,
    env: *const std.process.Environ.Map,
    err: anyerror,
    diagnostics: ?*const Diagnostics,
) noreturn {
    var buffer: [2048]u8 = undefined;
    const stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    const errout: Terminal = .{
        .writer = stderr,
        .mode = term.detect(io, stderr_file, env) catch .no_color,
    };

    term.styled(errout, .err, "error:", .{}) catch {};
    if (userError(err)) |message| {
        stderr.print(" {s}\n", .{message}) catch {};
    } else {
        stderr.print(" unexpected failure ({s})\n", .{@errorName(err)}) catch {};
    }

    if (err == error.GitFailed) {
        if (diagnostics) |diag| {
            if (diag.len != 0) {
                term.styled(errout, .dim, "git:", .{}) catch {};
                stderr.print(" {s}\n", .{diag.stderr()}) catch {};
            }
        }
    }

    stderr.flush() catch {};

    const usage_error = err == error.InvalidArguments or err == error.UnknownCommand;
    std.process.exit(if (usage_error) 2 else 1);
}

const help_commands = [_]struct { name: []const u8, args: []const u8, about: []const u8 }{
    .{ .name = "init", .args = "--base <branch>", .about = "adopt current branch as rolling work" },
    .{ .name = "status", .args = "", .about = "display layers and unstacked commits" },
    .{ .name = "cut", .args = "<name> [--at <rev>]", .about = "create the next layer" },
    .{ .name = "reset", .args = "[--delete-layers]", .about = "forget the stack so it can be re-initialized" },
    .{ .name = "up", .args = "", .about = "switch toward rolling work" },
    .{ .name = "down", .args = "", .about = "switch toward the base" },
    .{ .name = "version", .args = "", .about = "print the stakrr version" },
    .{ .name = "help", .args = "", .about = "show this message" },
};

fn printHelp(out: Terminal) !void {
    const w = out.writer;
    try term.styled(out, .bold, "stakrr", .{});
    try term.styled(out, .dim, " {s} // ", .{build_options.version});
    try w.writeAll("downstack from a rolling branch\n\n");

    try term.styled(out, .dim, "usage:", .{});
    try w.writeAll(" stakrr <command> [options]\n\n");

    for (help_commands) |cmd| {
        const width = cmd.name.len + @as(usize, if (cmd.args.len != 0) 1 else 0) + cmd.args.len;
        try w.writeAll("  ");
        try term.styled(out, .accent, "{s}", .{cmd.name});
        if (cmd.args.len != 0) try w.print(" {s}", .{cmd.args});
        try w.splatByteAll(' ', 30 - width);
        try term.styled(out, .dim, "{s}", .{cmd.about});
        try w.writeByte('\n');
    }
}

fn userError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidArguments => "invalid arguments (run 'stakrr help')",
        error.UnknownCommand => "unknown command (run 'stakrr help')",
        error.NotInitialized => "stack not initialized (run 'stakrr init --base <branch>')",
        error.AlreadyInitialized => "stack already initialized (run 'stakrr reset' to start over)",
        error.ExistingStackRefs => "existing stakrr refs found (run 'stakrr reset --delete-layers' to remove them)",
        error.ReservedBranchNamespace => "base and work branches cannot use stakrr/",
        error.BaseEqualsWork => "base and work branches must differ",
        error.BaseNotFound => "base branch not found (it must be a local branch)",
        error.BaseNotAncestor => "base is not an ancestor of work",
        error.MergeCommitsUnsupported => "merge commits in the stack are unsupported",
        error.InvalidConfig => "stakrr state in git config is invalid (run 'stakrr reset')",
        error.UnsupportedConfigVersion => "stack was created by an incompatible stakrr version (run 'stakrr reset')",
        error.InvalidStack, error.InvalidLayerBoundary => "stack refs are inconsistent with the rolling branch (run 'stakrr reset' to start over)",
        error.NotOnWorkBranch => "cut must run on the rolling work branch",
        error.InvalidLayerName => "invalid layer name",
        error.LayerExists => "a layer with that name already exists or conflicts with one",
        error.LayerCheckedOut => "cannot delete layers while a layer branch is checked out",
        error.EmptyCut => "no new commits since previous layer",
        error.InvalidCutBoundary, error.CutOutsideWork => "revision is outside the next unstacked segment",
        error.GitFailed => "git command failed",
        error.GitTerminated => "git was terminated by a signal",
        error.InvalidRefName => "invalid Git branch name",
        error.InvalidOid => "invalid Git object id",
        error.NotGitRepository => "not inside a Git repository",
        error.NotWorkingTree => "not inside a Git working tree",
        error.DetachedHead => "detached HEAD is unsupported",
        error.InvalidGitConfig => "stakrr.state has multiple or empty values (run 'stakrr reset')",
        error.InvalidGitOutput => "unexpected output from git",
        error.StreamTooLong => "git output exceeded the size limit",
        error.FileNotFound => "git executable not found on PATH",
        error.OutOfMemory => "out of memory",
        error.NotOnStackBranch => "current branch is outside the configured stack",
        else => null,
    };
}

fn shortRef(ref_name: []const u8) []const u8 {
    const prefix = "refs/heads/";

    if (std.mem.startsWith(u8, ref_name, prefix))
        return ref_name[prefix.len..];

    return ref_name;
}

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// draw the stack top-down: rolling work, layers from highest to lowest,
/// then the base they were cut from
/// Draw the stack top-down, marking the checked-out branch with ▸.
fn printStatus(
    out: Terminal,
    snapshot: stack.Snapshot,
    current: ?[]const u8,
) !void {
    const w = out.writer;
    const base = shortRef(snapshot.config.base_ref);
    const work = shortRef(snapshot.config.work_ref);

    var width = @max(base.len, work.len);
    for (snapshot.layers) |layer|
        width = @max(width, shortRef(layer.ref_name).len);
    width += 3;

    try term.styled(out, .dim, "stack", .{});
    try w.print("  {s} → ", .{base});
    try term.styled(out, .accent, "{s}", .{work});
    try w.writeAll("\n\n");

    if (snapshot.base_moved) {
        try w.writeAll("  ");
        try term.styled(
            out,
            .warn,
            "warning: base moved since initialization; layers stay cut from the original base",
            .{},
        );
        try w.writeAll("\n\n");
    }

    try w.writeAll("  ");
    try term.styled(out, .accent, "{s} {s}", .{
        if (isCurrent(current, snapshot.config.work_ref)) "▸" else "│",
        work,
    });
    try w.splatByteAll(' ', width - work.len);
    try term.styled(out, .dim, "{d} unstacked", .{snapshot.unstacked_commits});
    try w.writeByte('\n');

    var i = snapshot.layers.len;
    while (i > 0) {
        i -= 1;
        const layer = snapshot.layers[i];
        const name = shortRef(layer.ref_name);
        const selected = isCurrent(current, layer.ref_name);

        try w.writeAll("  ");
        try term.styled(out, if (selected) .accent else .dim, "{s}", .{
            if (selected) "▸" else "│",
        });
        try w.print(" {s}", .{name});
        try w.splatByteAll(' ', width - name.len);
        try term.styled(out, .dim, "{d} {s}", .{
            layer.commits,
            plural(layer.commits, "commit", "commits"),
        });
        try w.writeByte('\n');
    }

    const base_selected = isCurrent(current, snapshot.config.base_ref);

    try w.writeAll("  ");
    try term.styled(out, if (base_selected) .accent else .dim, "{s}", .{
        if (base_selected) "▸" else "└",
    });
    try w.print(" {s}", .{base});
    try w.splatByteAll(' ', width - base.len);
    try term.styled(out, .dim, "base", .{});
    try w.writeByte('\n');

    try w.print("\n  {d} {s}\n", .{
        snapshot.layers.len,
        plural(snapshot.layers.len, "layer", "layers"),
    });
}

fn isCurrent(current: ?[]const u8, ref_name: []const u8) bool {
    return if (current) |ref| eql(ref, ref_name) else false;
}

const testing = std.testing;

test {
    _ = term;
}

test "every domain error has a user message" {
    inline for (@typeInfo(stack.Error).error_set.error_names.?) |name| {
        try testing.expect(userError(@field(anyerror, name)) != null);
    }
}

test "parseArgs: help and version" {
    try testing.expectEqual(Command.help, try parseArgs(&.{"stakrr"}));
    try testing.expectEqual(Command.help, try parseArgs(&.{ "stakrr", "--help" }));
    try testing.expectEqual(Command.version, try parseArgs(&.{ "stakrr", "--version" }));
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

test "parseArgs: status and reset" {
    try testing.expectEqual(Command.status, try parseArgs(&.{ "stakrr", "status" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "status", "x" }));

    try testing.expect(!(try parseArgs(&.{ "stakrr", "reset" })).reset.delete_layers);
    try testing.expect((try parseArgs(&.{ "stakrr", "reset", "--delete-layers" })).reset.delete_layers);
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "reset", "--force" }));
}
