const std = @import("std");
const build_options = @import("build_options");
const stakrr = @import("stakrr");
const Git = stakrr.git.Git;
const Diagnostics = stakrr.git.Diagnostics;
const stack = stakrr.stack;
const edit = stakrr.edit;
const fix = stakrr.fix;
const term = @import("term.zig");
const Terminal = term.Terminal;
const cli = @import("cli.zig");
const Command = cli.Command;
const render = @import("render.zig");
const shortRef = render.shortRef;
const plural = render.plural;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const env = init.environ_map;

    const command = cli.parseArgs(args) catch |err| fail(init.io, env, err, null, null);

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
        // best effort: a failed diagnosis still reports the original error
        const drift = if (err == error.EditStateChanged) edit.findDrift(&git) catch null else null;
        fail(init.io, env, err, &diagnostics, drift);
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
            // both views validate the repository before HEAD is read
            if (try edit.readStatus(git)) |view| {
                var status = view;
                defer status.deinit();
                const current = try git.head();
                defer if (current) |ref| git.allocator.free(ref);
                return render.printEditStatus(out, status, current);
            }
            var snapshot = try stack.inspect(git);
            defer snapshot.deinit();
            const current = try git.head();
            defer if (current) |ref| git.allocator.free(ref);
            try render.printStatus(out, snapshot, current);
        },
        .undo => {
            try edit.undo(git);
            try stdout.writeAll("undone; use 'stakrr undo' to undo this undo\n");
        },
        .go => |name| {
            try stack.go(git, name);
            try stdout.writeAll("switched to ");
            try term.styled(out, .accent, "stakrr/{s}", .{name});
            try stdout.writeByte('\n');
        },
        .log => {
            var log = try edit.readLog(git);
            defer log.deinit();
            try render.printLog(out, log);
        },
        .edit => |request| {
            edit.run(git, request) catch |err| switch (err) {
                error.NothingToRestack => return stdout.writeAll("nothing to restack\n"),
                else => return err,
            };
            if (request == .quit) {
                try stdout.writeAll("restack dropped; HEAD and branches left as they are\n" ++
                    "check the stack with 'stakrr status' (it may need 'stakrr reset')\n" ++
                    "retained: stakrr log (" ++ stakrr.layout.oplog_ref ++ ")\n");
                return;
            }
            const branch = try git.currentBranch();
            defer git.allocator.free(branch);
            try stdout.print("restack {s}; returned to ", .{if (request == .abort) "aborted" else "completed"});
            try term.styled(out, .accent, "{s}", .{shortRef(branch)});
            try stdout.writeByte('\n');
            if (request == .abort)
                try stdout.writeAll("retained edits: stakrr log (" ++ stakrr.layout.oplog_ref ++ ")\n");
        },
        .fix => |options| {
            var result = try fix.fix(git, options);
            defer result.deinit(git.allocator);
            try stdout.writeAll("fixed ");
            try term.styled(out, .accent, "stakrr/{s}", .{result.layer});
            try stdout.print("; replayed {d} {s}\n", .{ result.replayed, plural(result.replayed, "commit", "commits") });
        },
        .cut => |options| {
            try stack.cut(git, options.name, options.at);
            try stdout.writeAll("created layer: ");
            try term.styled(out, .accent, "stakrr/{s}", .{options.name});
            try stdout.writeByte('\n');
        },
        .reset => |options| {
            const result = try stack.reset(git, options);
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
                try stdout.writeAll(
                    "; remove them or run 'stakrr reset --delete-layers' before re-initializing\n",
                );
            }
        },
        .navigate => |direction| {
            if (!try stack.navigate(git, direction)) try stdout.writeAll(switch (direction) {
                .up => "already at top\n",
                .down => "already at base\n",
            });
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
    drift: ?edit.Drift,
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

    if (drift) |found| render.printDriftHints(errout, found) catch {};

    stderr.flush() catch {};

    std.process.exit(exitCode(err));
}

/// 1 generic failure, 2 usage, 3 replay conflict pending, 4 tree not clean enough
/// to proceed, 5 refs or HEAD moved outside stakrr
fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidArguments, error.UnknownCommand => 2,
        error.ReplayConflict => 3,
        error.DirtyWorkTree, error.IgnoredFilesPresent, error.GitOperationInProgress => 4,
        error.EditStateChanged => 5,
        else => 1,
    };
}

fn userError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MutationInProgress => "another stakrr mutation is running",
        error.EditInProgress => "a restack is pending " ++
            "(finish with 'stakrr continue' or 'stakrr abort')",
        error.BranchOccupied => "a required branch is checked out in another worktree",
        error.DirtyWorkTree => "preserve uncommitted changes before proceeding",
        error.IgnoredFilesPresent => "preserve and remove ignored files before replaying descendants",
        error.GitOperationInProgress => "finish the active Git operation before proceeding",
        error.NoEditSession => "no restack is pending",
        error.UnknownCut => "cut not found (use its short name)",
        error.StaleLayers => "a layer has commits that are not restacked yet (run 'stakrr restack')",
        error.NothingToRestack => "no layer has new commits to restack",
        error.MultipleStaleLayers => "more than one layer has new commits; " ++
            "restack handles one at a time, so reset the others to their recorded boundary",
        error.WrongEditWorktree => "this edit session belongs to another worktree",
        error.InvalidEditSession => "invalid edit checkpoint; " ++
            "leave it with 'stakrr quit', which retains it in the operation log",
        error.EditStateChanged => "Git refs or HEAD changed outside the edit workflow; " ++
            "restore them, or keep them and leave with 'stakrr quit'",
        error.ReplayConflict => "replay conflict: resolve files, git add them, then run 'stakrr continue'; " ++
            "preserve uncommitted work before 'stakrr abort'",
        error.NoUndo => "nothing to undo",
        error.NoLayers => "no layers yet (run 'stakrr cut <name>')",
        error.NothingStaged => "nothing staged (stage changes with 'git add' first)",
        error.FixConflict => "the staged changes conflict with the layer or a later commit; " ++
            "nothing was changed (resolve by hand with 'stakrr go <cut>')",
        error.FixDiverged => "replaying the staged changes would not reproduce your index; nothing was changed",
        error.InvalidEditedHistory => "edited cut must contain linear commits above its previous boundary",
        error.InvalidArguments => "invalid arguments (run 'stakrr help')",
        error.UnknownCommand => "unknown command (run 'stakrr help')",
        error.NotInitialized => "stack not initialized (run 'stakrr init --base <branch>')",
        error.AlreadyInitialized => "stack already initialized (run 'stakrr reset' to start over)",
        error.ExistingStackRefs => "existing stakrr refs found " ++
            "(run 'stakrr reset --delete-layers' to remove them)",
        error.ReservedBranchNamespace => "base and work branches cannot use stakrr/",
        error.BaseEqualsWork => "base and work branches must differ",
        error.BaseNotFound => "base branch not found (it must be a local branch)",
        error.BaseNotAncestor => "base is not an ancestor of work",
        error.MergeCommitsUnsupported => "merge commits in the stack are unsupported",
        error.InvalidConfig => "stakrr state in git config is invalid (run 'stakrr reset')",
        error.UnsupportedConfigVersion => "stack was created by an incompatible stakrr version " ++
            "(run 'stakrr reset')",
        error.InvalidStack, error.InvalidLayerBoundary => "stack refs are inconsistent with the rolling branch " ++
            "(run 'stakrr reset' to start over)",
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

const testing = std.testing;

test {
    _ = term;
    _ = cli;
    _ = render;
}

test "exit codes distinguish usage, conflict, dirty tree and drift" {
    try testing.expectEqual(@as(u8, 2), exitCode(error.InvalidArguments));
    try testing.expectEqual(@as(u8, 3), exitCode(error.ReplayConflict));
    try testing.expectEqual(@as(u8, 4), exitCode(error.DirtyWorkTree));
    try testing.expectEqual(@as(u8, 5), exitCode(error.EditStateChanged));
    try testing.expectEqual(@as(u8, 1), exitCode(error.GitFailed));
}

test "every domain error has a user message" {
    inline for (@typeInfo(stack.Error || edit.Error || fix.Error).error_set.error_names.?) |name| {
        try testing.expect(userError(@field(anyerror, name)) != null);
    }
}
