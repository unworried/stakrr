const std = @import("std");
const build_options = @import("build_options");
const stakrr = @import("stakrr");
const Git = stakrr.git.Git;
const Diagnostics = stakrr.git.Diagnostics;
const stack = stakrr.stack;
const edit = stakrr.edit;
const term = @import("term.zig");
const Terminal = term.Terminal;

pub const Command = union(enum) {
    help,
    version,
    init: struct { base: []const u8 },
    status,
    cut: struct { name: []const u8, at: ?[]const u8 = null },
    reset: stack.ResetOptions,
    up,
    down,
    edit: edit.Request,
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

    if (eql(command, "edit")) {
        if (rest.len == 0) return .{ .edit = .{ .jump = null } };
        if (rest.len != 1) return error.InvalidArguments;
        if (eql(rest[0], "--continue")) return .{ .edit = .continue_edit };
        if (eql(rest[0], "--abort")) return .{ .edit = .abort };
        return .{ .edit = .{ .jump = try value(rest[0]) } };
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
            if (try printEditStatus(git, out)) return;
            var snapshot = try stack.inspect(git);
            defer snapshot.deinit();

            const current = try git.head();
            defer if (current) |ref| git.allocator.free(ref);

            try printStatus(out, snapshot, current);
        },
        .edit => |request| {
            try edit.run(git, request);
            var status = try edit.readStatus(git);
            defer if (status) |*view| view.deinit();
            if (status) |view| {
                try stdout.writeAll("editing ");
                try term.styled(out, .accent, "{s}", .{shortRef(view.branches[view.active])});
            } else {
                const branch = try git.currentBranch();
                defer git.allocator.free(branch);
                try stdout.print("edit {s}; returned to ", .{if (request == .abort) "aborted" else "completed"});
                try term.styled(out, .accent, "{s}", .{shortRef(branch)});
            }
            try stdout.writeByte('\n');
            if (request == .abort)
                try stdout.writeAll("retained edits: git for-each-ref " ++ stakrr.layout.recovery_prefix ++ "\n");
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
    .{
        .name = "edit",
        .args = "[<cut>|--continue|--abort]",
        .about = "edit a cut and replay descendants",
    },
    .{
        .name = "reset",
        .args = "[--delete-layers]",
        .about = "forget the stack so it can be re-initialized",
    },
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
        try w.splatByteAll(' ', @max(30, width + 2) - width);
        try term.styled(out, .dim, "{s}", .{cmd.about});
        try w.writeByte('\n');
    }
}

fn userError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MutationInProgress => "another stakrr mutation is running",
        error.EditInProgress => "an edit session is active " ++
            "(finish with 'stakrr edit' or 'stakrr edit --abort')",
        error.BranchOccupied => "a required branch is checked out in another worktree",
        error.DirtyWorkTree => "preserve uncommitted changes before proceeding",
        error.IgnoredFilesPresent => "preserve and remove ignored files before replaying descendants",
        error.GitOperationInProgress => "finish the active Git operation before proceeding",
        error.NoEditSession => "no edit session is active",
        error.UnknownCut => "cut not found (use its short name)",
        error.WrongEditWorktree => "this edit session belongs to another worktree",
        error.InvalidEditSession => "invalid edit checkpoint; " ++
            "keep refs/stakrr/edit and recovery refs for recovery",
        error.EditStateChanged => "Git refs or HEAD changed outside the edit workflow; " ++
            "preserve work before recovery",
        error.ReplayConflict => "replay conflict: resolve files, git add them, then run 'stakrr edit --continue'; " ++
            "preserve uncommitted work before '--abort'",
        error.NoPendingEdit => "no transition is pending (use 'stakrr edit [<cut>]' to leave the active cut)",
        error.EditNeedsContinue => "use 'stakrr edit --continue' to complete the pending transition",
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

fn printEditStatus(git: *const Git, out: Terminal) !bool {
    var status = (try edit.readStatus(git)) orelse return false;
    defer status.deinit();
    const w = out.writer;
    const current = try git.head();
    defer if (current) |ref| git.allocator.free(ref);
    try printStackHeader(out, status.base, status.branches[status.branches.len - 1]);
    try term.styled(out, .dim, "edit", .{});
    try w.writeAll("   ");
    try term.styled(out, .accent, "{s}", .{shortRef(status.branches[status.active])});
    if (status.phase != .editing)
        try w.print(" ({s}) → {s}", .{ @tagName(status.phase), shortRef(status.destination) });
    try w.writeAll("\n\n");
    var width = shortRef(status.base).len;
    for (status.branches) |ref| width = @max(width, shortRef(ref).len);
    width += 3;
    var i = status.branches.len;
    while (i > 0) {
        i -= 1;
        try printStackRow(out, status.branches[i], isCurrent(current, status.branches[i]), false, if (i == status.active) width else 0);
        if (i == status.active)
            try term.styled(out, if (status.phase == .conflict) .warn else .dim, "{s}", .{@tagName(status.phase)});
        try w.writeByte('\n');
    }
    try printStackRow(out, status.base, isCurrent(current, status.base), true, width);
    try term.styled(out, .dim, "base", .{});
    try w.print("\n\n  {d} {s}\n", .{ status.branches.len - 1, plural(status.branches.len - 1, "layer", "layers") });
    if (status.phase == .conflict) {
        try w.writeAll("\n  resolve conflicts, git add, then stakrr edit --continue\n");
    } else if (status.phase != .editing) {
        try w.writeAll("\n  stakrr edit --continue\n");
    }
    return true;
}

fn printStackHeader(out: Terminal, base: []const u8, work: []const u8) !void {
    try term.styled(out, .dim, "stack", .{});
    try out.writer.print("  {s} → ", .{shortRef(base)});
    try term.styled(out, .accent, "{s}", .{shortRef(work)});
    try out.writer.writeByte('\n');
}

/// Shared branch markers and column alignment for ordinary and edit status.
fn printStackRow(out: Terminal, ref: []const u8, selected: bool, base: bool, width: usize) !void {
    const name = shortRef(ref);
    try out.writer.writeAll("  ");
    try term.styled(out, if (selected) .accent else .dim, "{s}", .{
        if (selected) "▸" else if (base) "└" else "│",
    });
    try out.writer.print(" {s}", .{name});
    if (width > name.len) try out.writer.splatByteAll(' ', width - name.len);
}

const shortRef = stakrr.layout.shortBranch;

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

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

    try printStackHeader(out, snapshot.config.base_ref, snapshot.config.work_ref);
    try w.writeByte('\n');

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

    try printStackRow(out, snapshot.config.work_ref, isCurrent(current, snapshot.config.work_ref), false, width);
    try term.styled(out, .dim, "{d} unstacked", .{snapshot.unstacked_commits});
    try w.writeByte('\n');

    var i = snapshot.layers.len;
    while (i > 0) {
        i -= 1;
        const layer = snapshot.layers[i];
        try printStackRow(out, layer.ref_name, isCurrent(current, layer.ref_name), false, width);
        try term.styled(out, .dim, "{d} {s}", .{
            layer.commits,
            plural(layer.commits, "commit", "commits"),
        });
        try w.writeByte('\n');
    }

    try printStackRow(out, snapshot.config.base_ref, isCurrent(current, snapshot.config.base_ref), true, width);
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
    inline for (@typeInfo(stack.Error || edit.Error).error_set.error_names.?) |name| {
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
    try testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "stakrr", "init", "--base", "--x" }),
    );
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
    try testing.expect(
        (try parseArgs(&.{ "stakrr", "reset", "--delete-layers" })).reset.delete_layers,
    );
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "reset", "--force" }));
}

test "parseArgs: edit transitions are mutually exclusive" {
    try testing.expect((try parseArgs(&.{ "stakrr", "edit" })).edit.jump == null);
    try testing.expectEqualStrings(
        "models",
        (try parseArgs(&.{ "stakrr", "edit", "models" })).edit.jump.?,
    );
    try testing.expectEqual(
        edit.Request.continue_edit,
        (try parseArgs(&.{ "stakrr", "edit", "--continue" })).edit,
    );
    try testing.expectEqual(
        edit.Request.abort,
        (try parseArgs(&.{ "stakrr", "edit", "--abort" })).edit,
    );
    try testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "stakrr", "edit", "models", "--abort" }),
    );
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "edit", "--unknown" }));
}
