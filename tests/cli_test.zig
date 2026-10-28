const std = @import("std");
const testing = std.testing;
const Repo = @import("support/repo.zig").Repo;
const cli = @import("support/cli.zig");
const stakrr = cli.run;
const stakrrAt = cli.runAt;

fn setup(repo: *const Repo) !void {
    testing.allocator.free(try repo.initWork());
}

test "cli: bare repositories reject worktree commands without changing refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.exec(&.{ "config", "core.bare", "true" });
    const commands = [_][]const []const u8{
        &.{ "init", "--base", "main" }, &.{ "cut", "p1" },
        &.{"status"},                   &.{"reset"},
        &.{ "go", "p1" },               &.{"up"},
        &.{"down"},                     &.{"restack"},
        &.{"continue"},                 &.{"abort"},
        &.{"quit"},                     &.{"undo"},
        &.{"log"},
    };
    for (commands) |args| {
        const result = try stakrr(&repo, args);
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 1), result.code);
        try testing.expectEqualStrings("error: not inside a Git working tree\n", result.stderr);
    }
    try repo.expectOutput(&.{ "for-each-ref", "--format=%(refname)" }, "");
    const help = try stakrr(&repo, &.{"help"});
    defer help.deinit();
    try testing.expectEqual(@as(?u8, 0), help.code);
}

test "cli: full init, cut, status, reset flow" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(?u8, 0), init.code);
    try testing.expectEqualStrings("", init.stderr);

    const b = try repo.commit("B");
    testing.allocator.free(b);

    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    try testing.expectEqual(@as(?u8, 0), cut.code);
    try testing.expectEqualStrings("created layer: stakrr/p1\n", cut.stdout);

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 0), status.code);
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
    try testing.expectEqual(@as(?u8, 0), reset.code);
    try testing.expectEqualStrings("stack reset\ndeleted 1 layer branch\n", reset.stdout);

    const again = try stakrr(&repo, &.{ "init", "--base=main" });
    defer again.deinit();
    try testing.expectEqual(@as(?u8, 0), again.code);
}

test "cli: failures print one clean message and exit non-zero" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 1), status.code);
    try testing.expectEqualStrings(
        "error: stack not initialized (run 'stakrr init --base <branch>')\n",
        status.stderr,
    );

    const usage = try stakrr(&repo, &.{ "cut", "a", "b" });
    defer usage.deinit();
    try testing.expectEqual(@as(?u8, 2), usage.code);
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
    try testing.expectEqual(@as(?u8, 1), cut.code);
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
    try testing.expectEqual(@as(?u8, 0), help.code);
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
    try testing.expectEqual(@as(?u8, 0), version.code);
    try testing.expect(std.mem.startsWith(u8, version.stdout, "stakrr "));
}

test "cli: navigation and status follow the checked-out branch" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(?u8, 0), init.code);

    const down = try stakrr(&repo, &.{"down"});
    defer down.deinit();
    try testing.expectEqual(@as(?u8, 0), down.code);
    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 0), status.code);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "▸ main") != null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "▸ work") == null);

    const base = try stakrr(&repo, &.{"down"});
    defer base.deinit();
    try testing.expectEqualStrings("already at base\n", base.stdout);
    const up = try stakrr(&repo, &.{"up"});
    defer up.deinit();
    try testing.expectEqual(@as(?u8, 0), up.code);
    const top = try stakrr(&repo, &.{"up"});
    defer top.deinit();
    try testing.expectEqualStrings("already at top\n", top.stdout);

    try repo.exec(&.{ "switch", "-q", "--detach" });
    const detached = try stakrr(&repo, &.{"status"});
    defer detached.deinit();
    try testing.expectEqual(@as(?u8, 0), detached.code);
    try testing.expect(std.mem.indexOf(u8, detached.stdout, "▸") == null);
}

test "cli: restack confirmations and status share terminal conventions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    const oid = try repo.commit("layer");
    testing.allocator.free(oid);
    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    const started = try stakrr(&repo, &.{ "go", "p1" });
    defer started.deinit();
    try testing.expectEqual(@as(?u8, 0), started.code);
    try testing.expectEqualStrings("switched to stakrr/p1\n", started.stdout);
    const idle = try stakrr(&repo, &.{"restack"});
    defer idle.deinit();
    try testing.expectEqual(@as(?u8, 0), idle.code);
    try testing.expectEqualStrings("nothing to restack\n", idle.stdout);

    // a commit on the layer makes it stale until restacked
    const extra = try repo.commit("extra");
    testing.allocator.free(extra);
    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expect(std.mem.indexOf(u8, status.stdout, "stakrr/p1   1 commit  stale\n") != null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "stakrr restack replays what sits above them\n") != null);
    try repo.env.put("CLICOLOR_FORCE", "1");
    const colored = try stakrr(&repo, &.{"status"});
    defer colored.deinit();
    try testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b[36m") != null);
    try repo.env.put("NO_COLOR", "1");
    const plain = try stakrr(&repo, &.{"status"});
    defer plain.deinit();
    try testing.expectEqualStrings(status.stdout, plain.stdout);
    const finished = try stakrr(&repo, &.{"restack"});
    defer finished.deinit();
    try testing.expectEqualStrings("restack completed; returned to stakrr/p1\n", finished.stdout);
    const settled = try stakrr(&repo, &.{"status"});
    defer settled.deinit();
    try testing.expect(std.mem.indexOf(u8, settled.stdout, "stale") == null);
}

test "cli: conflict status shows detached replay and a resolution hint" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "shared", .data = "lower\n" });
    try repo.exec(&.{ "add", "shared" });
    const lower = try repo.commit("lower");
    testing.allocator.free(lower);
    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "shared", .data = "upper\n" });
    try repo.exec(&.{ "add", "shared" });
    const upper = try repo.commit("upper");
    defer testing.allocator.free(upper);
    const started = try stakrr(&repo, &.{ "go", "p1" });
    defer started.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "shared", .data = "edited\n" });
    try repo.exec(&.{ "add", "shared" });
    const edited = try repo.commit("edited");
    testing.allocator.free(edited);
    const conflict = try stakrr(&repo, &.{"restack"});
    defer conflict.deinit();
    try testing.expectEqual(@as(?u8, 3), conflict.code);
    try testing.expectEqualStrings("", conflict.stdout);
    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 0), status.code);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "stack  main → work\nedit   stakrr/p1 (conflict) → stakrr/p1\nreplay 1/1 stopped at {s} upper\n\n" ++
            "  │ work\n  │ stakrr/p1   conflict\n  └ main        base\n\n  1 layer\n\n" ++
            "  resolve conflicts, git add, then stakrr continue\n" ++
            "  to give up, commit the resolution, then stakrr abort\n",
        .{upper[0..7]},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, status.stdout);

    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    const aborted = try stakrr(&repo, &.{"abort"});
    defer aborted.deinit();
    try testing.expectEqualStrings(
        "restack aborted; returned to stakrr/p1\nretained edits: stakrr log (refs/stakrr/oplog)\n",
        aborted.stdout,
    );
}

test "cli: navigate between work, layers and base without moving their refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(?u8, 0), init.code);
    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    try testing.expectEqual(@as(?u8, 0), cut.code);
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
        try testing.expectEqual(@as(?u8, 0), result.code);
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
    try testing.expectEqual(@as(?u8, 0), init.code);
    try repo.exec(&.{ "switch", "--detach", "-q", "HEAD" });

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 0), status.code);
    try testing.expectEqualStrings("", status.stderr);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "stack  main → work") != null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "▸") == null);
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
        try testing.expectEqual(@as(?u8, 0), init.code);
        const commit = try repo.commit("layer");
        defer testing.allocator.free(commit);
        const cut = try stakrr(&repo, &.{ "cut", "p1" });
        defer cut.deinit();
        try testing.expectEqual(@as(?u8, 0), cut.code);
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
                    try testing.expectEqual(@as(?u8, 1), result.code);
                    try testing.expectEqualStrings("", result.stdout);
                    try testing.expectEqualStrings("error: another stakrr mutation is running\n", result.stderr);
                }
                const status = try stakrrAt(&repo, &.{"status"}, cwd);
                defer status.deinit();
                try testing.expectEqual(@as(?u8, 0), status.code);
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
        try testing.expectEqual(@as(?u8, 1), failed_locked.code);
        try testing.expect(std.mem.indexOf(u8, failed_locked.stderr, "already exists") != null);
        const reset = try stakrr(&repo, &.{ "reset", "--delete-layers" });
        defer reset.deinit();
        try testing.expectEqual(@as(?u8, 0), reset.code);
        const again = try stakrr(&repo, &.{ "init", "--base", "main" });
        defer again.deinit();
        try testing.expectEqual(@as(?u8, 0), again.code);
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
        try testing.expectEqual(@as(?u8, 1), blocked.code);
        try testing.expectEqualStrings("error: another stakrr mutation is running\n", blocked.stderr);
    }
    const result = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
}
