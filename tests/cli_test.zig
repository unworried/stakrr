const std = @import("std");
const testing = std.testing;
const exe_path = @import("cli_options").exe_path;
const Repo = @import("support/repo.zig").Repo;

const Run = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// run the built stakrr binary inside the test repository
fn stakrr(repo: *const Repo, args: []const []const u8) !Run {
    return stakrrAt(repo, args, repo.tmp.dir);
}

fn stakrrAt(repo: *const Repo, args: []const []const u8, cwd: std.Io.Dir) !Run {
    // the build passes a path relative to the build root; the child runs
    // inside the temp repository, so resolve it first
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, exe_path, testing.allocator);
    defer testing.allocator.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, exe);
    try argv.appendSlice(testing.allocator, args);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .environ_map = repo.env,
    });

    return .{
        .code = switch (result.term) {
            .exited => |code| code,
            else => return error.Terminated,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn setup(repo: *const Repo) !void {
    const base = try repo.commit("base");
    testing.allocator.free(base);
    try repo.exec(&.{ "switch", "-q", "-c", "work" });
}

test "cli: full init, cut, status, reset flow" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(u8, 0), init.code);
    try testing.expectEqualStrings("", init.stderr);

    const b = try repo.commit("B");
    testing.allocator.free(b);

    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    try testing.expectEqual(@as(u8, 0), cut.code);
    try testing.expectEqualStrings("created layer: stakrr/p1\n", cut.stdout);

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(u8, 0), status.code);
    try testing.expectEqualStrings(
        \\stack  main → work
        \\
        \\  ▸ work        0 unstacked
        \\  │ stakrr/p1   1 commit
        \\  └ main        base
        \\
        \\  1 layer
        \\
    , status.stdout);

    const reset = try stakrr(&repo, &.{ "reset", "--delete-layers" });
    defer reset.deinit();
    try testing.expectEqual(@as(u8, 0), reset.code);
    try testing.expectEqualStrings("stack reset\ndeleted 1 layer branch\n", reset.stdout);

    const again = try stakrr(&repo, &.{ "init", "--base=main" });
    defer again.deinit();
    try testing.expectEqual(@as(u8, 0), again.code);
}

test "cli: navigate between work, layers and base without moving their refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(u8, 0), init.code);
    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    try testing.expectEqual(@as(u8, 0), cut.code);
    const before = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(before);

    const steps = [_]struct { command: []const u8, branch: []const u8, stdout: []const u8 = "" }{
        .{ .command = "up", .branch = "work", .stdout = "already at top\n" },
        .{ .command = "down", .branch = "stakrr/p1" },
        .{ .command = "down", .branch = "main" },
        .{ .command = "down", .branch = "main", .stdout = "already at base\n" },
        .{ .command = "up", .branch = "stakrr/p1" },
        .{ .command = "up", .branch = "work" },
    };
    for (steps) |step| {
        const result = try stakrr(&repo, &.{step.command});
        defer result.deinit();
        try testing.expectEqual(@as(u8, 0), result.code);
        try testing.expectEqualStrings(step.stdout, result.stdout);
        try testing.expectEqualStrings("", result.stderr);
        const branch = try repo.git.output(&.{ "branch", "--show-current" });
        defer testing.allocator.free(branch);
        try testing.expectEqualStrings(step.branch, branch);
        const after = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
    }
}

test "cli: status renders a detached HEAD without selecting a branch" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(u8, 0), init.code);
    try repo.exec(&.{ "switch", "--detach", "-q", "HEAD" });

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(u8, 0), status.code);
    try testing.expectEqualStrings("", status.stderr);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "stack  main → work") != null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "▸") == null);
}

test "cli: failures print one clean message and exit non-zero" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(u8, 1), status.code);
    try testing.expectEqualStrings(
        "error: stack not initialized (run 'stakrr init --base <branch>')\n",
        status.stderr,
    );

    const usage = try stakrr(&repo, &.{ "cut", "a", "b" });
    defer usage.deinit();
    try testing.expectEqual(@as(u8, 2), usage.code);
    try testing.expect(std.mem.startsWith(u8, usage.stderr, "error: invalid arguments"));
}

test "cli: git failures include git's stderr" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();

    const b = try repo.commit("B");
    testing.allocator.free(b);

    const cut = try stakrr(&repo, &.{ "cut", "p1", "--at", "does-not-exist" });
    defer cut.deinit();
    try testing.expectEqual(@as(u8, 1), cut.code);
    try testing.expect(std.mem.startsWith(u8, cut.stderr, "error: git command failed\ngit: "));
}

test "cli: CLICOLOR_FORCE colours output unless NO_COLOR is set" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    try repo.env.put("CLICOLOR_FORCE", "1");
    const forced = try stakrr(&repo, &.{"status"});
    defer forced.deinit();
    try testing.expect(std.mem.startsWith(u8, forced.stderr, "\x1b[1m\x1b[31merror:\x1b[0m "));

    try repo.env.put("NO_COLOR", "1");
    const plain = try stakrr(&repo, &.{"status"});
    defer plain.deinit();
    try testing.expect(std.mem.startsWith(u8, plain.stderr, "error: "));
}

test "cli: help aligns the command list" {
    var repo = try Repo.init();
    defer repo.deinit();

    const help = try stakrr(&repo, &.{"help"});
    defer help.deinit();
    try testing.expectEqual(@as(u8, 0), help.code);
    try testing.expect(std.mem.startsWith(u8, help.stdout, "stakrr "));
    try testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "\n  cut <name> [--at <rev>]       create the next layer\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "\n  status                        display layers and unstacked commits\n",
    ) != null);
}

test "cli: version" {
    var repo = try Repo.init();
    defer repo.deinit();

    const version = try stakrr(&repo, &.{"--version"});
    defer version.deinit();
    try testing.expectEqual(@as(u8, 0), version.code);
    try testing.expect(std.mem.startsWith(u8, version.stdout, "stakrr "));
}

test "cli: mutation lock is shared across worktrees and leaves user state unchanged" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        try repo.exec(&.{ "worktree", "add", "-q", "linked", "main" });
        var linked = try repo.tmp.dir.openDir(testing.io, "linked", .{});
        defer linked.close(testing.io);

        const init = try stakrr(&repo, &.{ "init", "--base", "main" });
        defer init.deinit();
        try testing.expectEqual(@as(u8, 0), init.code);
        const commit = try repo.commit("layer");
        defer testing.allocator.free(commit);
        const cut = try stakrr(&repo, &.{ "cut", "p1" });
        defer cut.deinit();
        try testing.expectEqual(@as(u8, 0), cut.code);
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "user-file", .data = "staged work\n" });
        try repo.exec(&.{ "add", "user-file" });
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "user-file", .data = "unstaged work\n" });
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "untracked", .data = "keep me\n" });

        const before_refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(before_refs);
        const before_config = try repo.git.output(&.{ "config", "--local", "--list" });
        defer testing.allocator.free(before_config);
        const before_status = try repo.git.output(&.{ "status", "--porcelain=v1", "-z" });
        defer testing.allocator.free(before_status);
        const before_index = try repo.git.output(&.{"write-tree"});
        defer testing.allocator.free(before_index);

        {
            const guard = try repo.tmp.dir.createFile(testing.io, ".git/stakrr.lock", .{
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            });
            defer guard.close(testing.io);
            const commands = [_][]const []const u8{
                &.{ "init", "--base", "main" },
                &.{ "cut", "p2" },
                &.{ "reset", "--delete-layers" },
                &.{"up"},
                &.{"down"},
            };
            for ([_]std.Io.Dir{ repo.tmp.dir, linked }) |cwd| {
                for (commands) |args| {
                    const result = try stakrrAt(&repo, args, cwd);
                    defer result.deinit();
                    try testing.expectEqual(@as(u8, 1), result.code);
                    try testing.expectEqualStrings("", result.stdout);
                    try testing.expectEqualStrings("error: another stakrr mutation is running\n", result.stderr);
                }
                const status = try stakrrAt(&repo, &.{"status"}, cwd);
                defer status.deinit();
                try testing.expectEqual(@as(u8, 0), status.code);
            }
        }

        const after_refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(after_refs);
        try testing.expectEqualStrings(before_refs, after_refs);
        const after_config = try repo.git.output(&.{ "config", "--local", "--list" });
        defer testing.allocator.free(after_config);
        try testing.expectEqualStrings(before_config, after_config);
        const after_status = try repo.git.output(&.{ "status", "--porcelain=v1", "-z" });
        defer testing.allocator.free(after_status);
        try testing.expectEqualStrings(before_status, after_status);
        const after_index = try repo.git.output(&.{"write-tree"});
        defer testing.allocator.free(after_index);
        try testing.expectEqualStrings(before_index, after_index);
        for ([_]struct { path: []const u8, contents: []const u8 }{
            .{ .path = "user-file", .contents = "unstaged work\n" },
            .{ .path = "untracked", .contents = "keep me\n" },
        }) |file| {
            const contents = try repo.tmp.dir.readFileAlloc(testing.io, file.path, testing.allocator, .limited(1024));
            defer testing.allocator.free(contents);
            try testing.expectEqualStrings(file.contents, contents);
        }
        const head = try repo.git.currentBranch();
        defer testing.allocator.free(head);
        try testing.expectEqualStrings("refs/heads/work", head);
        const linked_head = try repo.git.output(&.{ "-C", "linked", "symbolic-ref", "HEAD" });
        defer testing.allocator.free(linked_head);
        try testing.expectEqualStrings("refs/heads/main", linked_head);

        // A failed mutation must release the lock, and the persistent file
        // must not prevent a later successful mutation.
        const failed_locked = try stakrr(&repo, &.{ "cut", "p1" });
        defer failed_locked.deinit();
        try testing.expectEqual(@as(u8, 1), failed_locked.code);
        try testing.expect(std.mem.indexOf(u8, failed_locked.stderr, "already exists") != null);
        const reset = try stakrr(&repo, &.{ "reset", "--delete-layers" });
        defer reset.deinit();
        try testing.expectEqual(@as(u8, 0), reset.code);
        const again = try stakrr(&repo, &.{ "init", "--base", "main" });
        defer again.deinit();
        try testing.expectEqual(@as(u8, 0), again.code);
        try repo.tmp.dir.access(testing.io, ".git/stakrr.lock", .{});
    }
}

test "cli: mutation lock preserves a separate Git directory path ending in a newline" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.exec(&.{ "init", "-q", "--separate-git-dir", "storage\n" });
    // Git's pointer-file parser trims trailing newlines, so address this
    // directory through the environment to preserve its actual name.
    const git_dir = try repo.tmp.dir.realPathFileAlloc(testing.io, "storage\n", testing.allocator);
    defer testing.allocator.free(git_dir);
    try repo.env.put("GIT_DIR", git_dir);
    {
        const guard = try repo.tmp.dir.createFile(testing.io, "storage\n/stakrr.lock", .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        defer guard.close(testing.io);
        const blocked = try stakrr(&repo, &.{ "init", "--base", "main" });
        defer blocked.deinit();
        try testing.expectEqual(@as(u8, 1), blocked.code);
        try testing.expectEqualStrings("error: another stakrr mutation is running\n", blocked.stderr);
    }
    const result = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer result.deinit();
    try testing.expectEqual(@as(u8, 0), result.code);
}
