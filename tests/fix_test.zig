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
    const models = try repo.git.resolveCommit("stakrr/models");
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
