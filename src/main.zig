const std = @import("std");
const build_options = @import("build_options");
const stakrr = @import("stakrr");
const Git = stakrr.git.Git;
const Diagnostics = stakrr.git.Diagnostics;
const stack = stakrr.stack;
const term = @import("term.zig");
const Terminal = term.Terminal;
const cli = @import("cli.zig");
const Command = cli.Command;
const render = @import("render.zig");
const plural = render.plural;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const env = init.environ_map;

    const command = cli.parseArgs(args) catch |err| fail(init.io, env, err, null);

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

fn runCommand(
    git: *const Git,
    out: Terminal,
    command: Command,
) !void {
    const stdout = out.writer;
    switch (command) {
        .help => try render.printHelp(out),
        .version => try stdout.print("stakrr {s}\n", .{build_options.version}),
        .init => |options| {
            try stack.initStack(git, options.base);
            try stdout.writeAll("stack initialized on ");
            try term.styled(out, .accent, "{s}", .{options.base});
            try stdout.writeByte('\n');
        },
        .status => {
            var snapshot = try stack.inspect(git);
            defer snapshot.deinit();

            const current = try git.head();
            defer if (current) |ref| git.allocator.free(ref);

            try render.printStatus(out, snapshot, current);
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
        error.MutationInProgress => "another stakrr mutation is running",
        error.NotOnStackBranch => "current branch is outside the configured stack",
        else => null,
    };
}

const testing = std.testing;

test {
    _ = term;
    _ = cli;
    _ = render;
}

test "every domain error has a user message" {
    inline for (@typeInfo(stack.Error).error_set.error_names.?) |name| {
        try testing.expect(userError(@field(anyerror, name)) != null);
    }
}
