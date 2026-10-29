const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const fix = stakrr.fix;
const layout = stakrr.layout;
const Repo = @import("support/repo.zig").Repo;
const fixture = @import("support/edit_fixture.zig");
const cli = @import("support/cli.zig");

fn positions(repo: *const Repo) ![]u8 {
    return repo.git.output(&.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/", layout.tip_ref });
}

fn stage(repo: *const Repo, path: []const u8, data: []const u8) !void {
    try repo.write(path, data);
    try repo.exec(&.{ "add", path });
}

fn expectUnchanged(repo: *const Repo, before: []const u8) !void {
    const after = try positions(repo);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "fix adds a commit to a lower layer and replays everything above it" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    var before = try repo.git.listDirectRefs(layout.branch_prefix);
    defer before.deinit(testing.allocator);
    try stage(&repo, "model", "fixed\n");

    var result = try fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "tweak model" } });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("models", result.layer);
    try testing.expectEqual(@as(usize, 3), result.replayed);

    try repo.expectOutput(&.{ "rev-list", "--count", "main..stakrr/models" }, "2");
    try repo.expectOutput(&.{ "log", "-1", "--format=%s", "stakrr/models" }, "tweak model");
    try repo.expectOutput(&.{ "show", "stakrr/models:model" }, "fixed");
    // descendants keep their messages and now carry the fix
    try repo.expectOutput(&.{ "log", "-1", "--format=%s", "stakrr/api" }, "delete obsolete");
    try repo.expectOutput(&.{ "show", "stakrr/api:model" }, "fixed");
    try repo.expectOutput(&.{ "show", "work:model" }, "fixed");
    try repo.expectOutput(&.{ "log", "-1", "--format=%s", "work" }, "rolling");
    try repo.expectOutput(&.{ "rev-list", "--count", "stakrr/api..work" }, "1");
    // the staged change now lives in history, so nothing is left staged
    try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    try fixture.noSession(&repo);
    try fixture.valid(&repo);

    // A fix has just one checkpoint, so its moves must be available even
    // when there is no previous operation to compare with.
    var log = try stakrr.edit.readLog(&repo.git);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 1), log.steps.len);
    try testing.expectEqual(@as(usize, 3), log.steps[0].moves.len);
    for (log.steps[0].moves) |move| {
        try testing.expect(!std.mem.eql(u8, move.before, move.after));
        try repo.expectRef(move.name, move.after);
        const old = for (before.refs) |ref| {
            if (std.mem.eql(u8, ref.name.bytes, move.name)) break ref.oid;
        } else return error.TestExpectedRef;
        try testing.expectEqualStrings(old.hex(), move.before);
    }
}

test "fix log starts from the actual refs after work between operations" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try stage(&repo, "model", "first fix\n");
    var first = try fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "first" } });
    defer first.deinit(testing.allocator);

    try repo.write("tail", "new rolling work\n");
    try repo.commitAll("new work");
    const old_work = try repo.git.resolveCommitAlloc("work");
    defer testing.allocator.free(old_work);
    try stage(&repo, "model", "second fix\n");
    var second = try fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "second" } });
    defer second.deinit(testing.allocator);

    var log = try stakrr.edit.readLog(&repo.git);
    defer log.deinit();
    for (log.steps[0].moves) |move| {
        if (!std.mem.eql(u8, move.name, "refs/heads/work")) continue;
        try testing.expectEqualStrings(old_work, move.before);
        try repo.expectRef(move.name, move.after);
        return;
    }
    return error.TestExpectedRef;
}

test "fix amends the last commit of a layer and keeps its message" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try stage(&repo, "model", "fixed\n");

    var result = try fix.fix(&repo.git, .{ .layer = "models", .how = .amend });
    defer result.deinit(testing.allocator);

    try repo.expectOutput(&.{ "rev-list", "--count", "main..stakrr/models" }, "1");
    try repo.expectOutput(&.{ "log", "-1", "--format=%s", "stakrr/models" }, "models");
    try repo.expectOutput(&.{ "show", "stakrr/models:model" }, "fixed");
    try repo.expectOutput(&.{ "show", "work:model" }, "fixed");
    try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    try fixture.valid(&repo);
}

test "fix targets the highest layer by default" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const models = try repo.git.resolveCommitAlloc("stakrr/models");
    defer testing.allocator.free(models);
    try stage(&repo, "api", "fixed api\n");

    var result = try fix.fix(&repo.git, .{ .how = .{ .message = "tweak api" } });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("api", result.layer);
    try testing.expectEqual(@as(usize, 1), result.replayed);
    try repo.expectRef("refs/heads/stakrr/models", models);
    try repo.expectOutput(&.{ "show", "stakrr/api:api" }, "fixed api");
}

test "fix leaves unstaged edits alone" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try stage(&repo, "model", "fixed\n");
    try repo.write("tail", "dirty\n");

    var result = try fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "tweak model" } });
    defer result.deinit(testing.allocator);

    try repo.expectOutput(&.{ "status", "--porcelain" }, " M tail");
    try repo.expectOutput(&.{ "show", "work:tail" }, "rolling");
}

test "undo reverses a fix" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const before = try positions(&repo);
    defer testing.allocator.free(before);
    try stage(&repo, "model", "fixed\n");

    var result = try fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "tweak model" } });
    defer result.deinit(testing.allocator);
    try cli.expectSuccess(&repo, &.{"undo"});

    try expectUnchanged(&repo, before);
    try fixture.valid(&repo);
}

test "a conflicting fix changes nothing" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    // a later commit rewrites the same file, so the fix cannot be moved below it
    try repo.write("model", "rolling edit\n");
    try repo.commitAll("touch model");
    const before = try positions(&repo);
    defer testing.allocator.free(before);
    try stage(&repo, "model", "staged\n");

    try testing.expectError(
        error.FixConflict,
        fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "tweak model" } }),
    );

    try expectUnchanged(&repo, before);
    try repo.expectOutput(&.{ "status", "--porcelain" }, "M  model");
    try repo.expectNoRef(layout.oplog_ref);
}

test "fix refuses without staged changes, a layer, or the work branch" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const before = try positions(&repo);
    defer testing.allocator.free(before);

    try testing.expectError(
        error.NothingStaged,
        fix.fix(&repo.git, .{ .how = .{ .message = "x" } }),
    );

    try stage(&repo, "model", "fixed\n");
    try testing.expectError(
        error.UnknownCut,
        fix.fix(&repo.git, .{ .layer = "nope", .how = .{ .message = "x" } }),
    );

    try repo.exec(&.{ "stash", "-q" });
    try repo.exec(&.{ "switch", "-q", "stakrr/models" });
    try stage(&repo, "model", "fixed\n");
    try testing.expectError(
        error.NotOnWorkBranch,
        fix.fix(&repo.git, .{ .how = .{ .message = "x" } }),
    );
    try repo.exec(&.{ "restore", "--staged", "--worktree", "model" });
    try repo.exec(&.{ "switch", "-q", "work" });
    try expectUnchanged(&repo, before);
}

test "fix is blocked while a restack is pending" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, stakrr.edit.run(&repo.git, .restack));

    try testing.expectError(
        error.EditInProgress,
        fix.fix(&repo.git, .{ .how = .{ .message = "x" } }),
    );
}

test "cli: fix reports the layer and the replayed commits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try stage(&repo, "model", "fixed\n");

    const run = try cli.run(&repo, &.{ "fix", "models", "-m", "tweak model" });
    defer run.deinit();
    try testing.expectEqual(@as(?u8, 0), run.code);
    try testing.expectEqualStrings("fixed stakrr/models; replayed 3 commits\n", run.stdout);

    const empty = try cli.run(&repo, &.{ "fix", "models", "--amend" });
    defer empty.deinit();
    try testing.expectEqual(@as(?u8, 1), empty.code);
    try testing.expect(std.mem.indexOf(u8, empty.stderr, "nothing staged") != null);
}

test "fix refuses while a layer has commits that are not restacked" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try fixture.on(&repo, "models");
    try repo.write("model", "committed on the layer\n");
    try repo.commitAll("extra");
    try repo.exec(&.{ "switch", "-q", "work" });
    const before = try positions(&repo);
    defer testing.allocator.free(before);
    try stage(&repo, "api", "fixed api\n");

    try testing.expectError(
        error.StaleLayers,
        fix.fix(&repo.git, .{ .layer = "api", .how = .{ .message = "x" } }),
    );
    try expectUnchanged(&repo, before);
}

test "fix sees staged files outside cwd with diff.relative enabled" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try stage(&repo, "model", "fixed\n");
    try repo.exec(&.{ "config", "diff.relative", "true" });
    try repo.tmp.dir.createDir(testing.io, "subdir", .default_dir);
    const subdir = try repo.tmp.dir.openDir(testing.io, "subdir", .{});
    defer subdir.close(testing.io);
    var git = repo.git;
    git.cwd = subdir;

    var result = try fix.fix(&git, .{ .layer = "models", .how = .{ .message = "fix model" } });
    defer result.deinit(testing.allocator);
    try repo.expectOutput(&.{ "show", "work:model" }, "fixed");
    try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    try fixture.valid(&repo);
}

test "fix explains unsupported merge-tree options without publishing refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try stage(&repo, "model", "fixed\n");
    const before = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(before);
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_OLD_MERGE_TREE", "1");

    const result = try cli.run(&repo, &.{ "fix", "models", "-m", "fix model" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 1), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Git 2.40") != null);
    try repo.expectOutput(&.{"show-ref"}, before);
    try repo.expectOutput(&.{ "status", "--porcelain" }, "M  model");
}
