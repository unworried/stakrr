const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const edit = stakrr.edit;
const layout = stakrr.layout;
const Repo = @import("support/repo.zig").Repo;
const fixture = @import("support/edit_fixture.zig");
const cli = @import("support/cli.zig");

fn positions(repo: *const Repo) ![]u8 {
    return repo.git.output(&.{ "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/", layout.tip_ref, layout.record_prefix });
}

fn finishEdit(repo: *const Repo) !void {
    try fixture.correctModels(repo);
    try edit.run(&repo.git, .restack);
}

test "undo of a completed edit and undo of undo restore exact refs in both object formats" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try fixture.setup(&repo);
        try testing.expectError(error.NoUndo, edit.undo(&repo.git));
        const before = try positions(&repo);
        defer testing.allocator.free(before);
        try finishEdit(&repo);
        const after = try positions(&repo);
        defer testing.allocator.free(after);
        try testing.expect(!std.mem.eql(u8, before, after));
        try cli.expectSuccess(&repo, &.{"undo"});
        const undone = try positions(&repo);
        defer testing.allocator.free(undone);
        try testing.expectEqualStrings(before, undone);
        try fixture.noSession(&repo);
        try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
        try edit.undo(&repo.git);
        const redone = try positions(&repo);
        defer testing.allocator.free(redone);
        try testing.expectEqualStrings(after, redone);
        try fixture.valid(&repo);
    }
}

test "global undo refuses drift dirty work active sessions and occupied branches" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try finishEdit(&repo);
    const oplog = (try repo.git.readRef(layout.oplog_ref)).?;
    defer testing.allocator.free(oplog);
    const models = try repo.git.resolveCommit("stakrr/models");
    defer testing.allocator.free(models);
    try repo.exec(&.{ "update-ref", "refs/heads/stakrr/models", "main" });
    const drifted = try positions(&repo);
    defer testing.allocator.free(drifted);
    try testing.expectError(error.EditStateChanged, edit.undo(&repo.git));
    const unchanged = try positions(&repo);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualStrings(drifted, unchanged);
    try repo.expectRef(layout.oplog_ref, oplog);
    try fixture.noSession(&repo);
    try repo.exec(&.{ "update-ref", "refs/heads/stakrr/models", models });
    try repo.write("precious", "untracked\n");
    try testing.expectError(error.DirtyWorkTree, edit.undo(&repo.git));
    try repo.tmp.dir.deleteFile(testing.io, "precious");
    const other = try fixture.linked(&repo, "occupied", "stakrr/models");
    defer other.cwd.?.close(testing.io);
    try testing.expectError(error.BranchOccupied, edit.undo(&repo.git));
    try other.exec(&.{ "switch", "-q", "--detach" });
    // a conflicted restack is an active session, which excludes undo
    try fixture.on(&repo, "models");
    try repo.write("obsolete", "corrected then deleted\n");
    try repo.commitAll("correct obsolete");
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try testing.expectError(error.EditInProgress, edit.undo(&repo.git));
    try repo.exec(&.{ "rm", "-q", "obsolete" });
    try repo.exec(&.{ "commit", "-q", "--no-edit" });
    try edit.run(&repo.git, .abort);
    try edit.undo(&repo.git); // an aborted session does not hide the completed edit
}

test "v2 journal retains checkpoints plans and edited commits through immediate pruning" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try fixture.correctModels(&repo);
    const correction = try repo.git.resolveCommit("stakrr/models");
    defer testing.allocator.free(correction);
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:1");
    const killed = try cli.run(&repo, &.{"restack"});
    defer killed.deinit();
    try testing.expect(killed.code != 0);
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const plan = try repo.git.output(&.{ "rev-parse", "refs/stakrr/edit:plan" });
    defer testing.allocator.free(plan);
    try repo.expectOutput(&.{ "cat-file", "-t", checkpoint }, "commit");
    try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
    try repo.exec(&.{ "gc", "--prune=now" });
    try repo.expectOutput(&.{ "cat-file", "-t", plan }, "blob");
    try cli.expectSuccess(&repo, &.{"continue"});
    try edit.undo(&repo.git);
    try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
    try repo.exec(&.{ "gc", "--prune=now" });
    try repo.expectOutput(&.{ "cat-file", "-t", correction }, "commit");
    try repo.expectOutput(&.{ "cat-file", "-t", checkpoint }, "commit");
    try repo.expectOutput(&.{ "cat-file", "-t", plan }, "blob");
    try edit.undo(&repo.git);
    try repo.expectOutput(&.{ "show", "work:model" }, "corrected");
}

test "log lists timestamps branch moves and rescue commits across completed sessions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const empty = try cli.run(&repo, &.{"log"});
    defer empty.deinit();
    try testing.expectEqualStrings("no edit history\n", empty.stdout);
    try finishEdit(&repo);
    try edit.undo(&repo.git);
    var log = try edit.readLog(&repo.git);
    defer log.deinit();
    try testing.expect(log.steps.len > 5);
    try testing.expectEqualStrings("stakrr: undo edit", log.steps[0].label);
    var moved_models = false;
    var moved_work = false;
    for (log.steps) |step| {
        try testing.expect(step.time.len >= 20 and step.time[10] == 'T');
        try testing.expect(stakrr.git.isOid(step.rescue));
        for (step.moves) |move| {
            try testing.expect(!std.mem.eql(u8, move.before, move.after));
            if (std.mem.eql(u8, move.name, "refs/heads/stakrr/models")) moved_models = true;
            if (std.mem.eql(u8, move.name, "refs/heads/work")) moved_work = true;
        }
    }
    try testing.expect(moved_models and moved_work);
    const output = try cli.run(&repo, &.{"log"});
    defer output.deinit();
    try testing.expectEqual(@as(?u8, 0), output.code);
    try testing.expect(std.mem.indexOf(u8, output.stdout, " → ") != null);
    try testing.expect(std.mem.indexOf(u8, output.stdout, "; rescue ") != null);
}

test "undo restoration resumes around every boundary transaction" {
    for ([_][]const u8{ "before:1", "after:1", "before:2", "after:2", "before:archive", "after:archive" }) |fault| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        const before = try positions(&repo);
        defer testing.allocator.free(before);
        try finishEdit(&repo);
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_FAULT", fault);
        const killed = try cli.run(&repo, &.{"undo"});
        defer killed.deinit();
        try testing.expect(killed.code != 0);
        _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
        if (std.mem.eql(u8, fault, "before:1")) {
            try cli.expectSuccess(&repo, &.{"undo"});
        } else if (!std.mem.eql(u8, fault, "after:archive")) {
            try cli.expectSuccess(&repo, &.{"continue"});
        }
        const restored = try positions(&repo);
        defer testing.allocator.free(restored);
        try testing.expectEqualStrings(before, restored);
        try fixture.noSession(&repo);
        try fixture.valid(&repo);
        try edit.undo(&repo.git);
        try repo.expectOutput(&.{ "show", "work:model" }, "corrected");
    }
}

test "restack archives its final checkpoint atomically" {
    for ([_][]const u8{ "before:archive", "after:archive" }) |fault| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        try fixture.correctModels(&repo);
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_FAULT", fault);
        const killed = try cli.run(&repo, &.{"restack"});
        defer killed.deinit();
        try testing.expect(killed.code != 0);
        _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
        if (std.mem.eql(u8, fault, "before:archive")) {
            try repo.expectNoRef(layout.oplog_ref);
            try cli.expectSuccess(&repo, &.{"continue"});
        }
        try fixture.noSession(&repo);
        try repo.expectOutput(&.{ "cat-file", "-t", layout.oplog_ref }, "commit");
        var log = try edit.readLog(&repo.git);
        defer log.deinit();
        try testing.expect(log.steps.len != 0);
    }
}

test "abort and quit archive their final checkpoints atomically" {
    for ([_][]const u8{ "abort", "quit" }) |command| {
        for ([_][]const u8{ "before:archive", "after:archive" }) |fault| {
            var repo = try Repo.init();
            defer repo.deinit();
            try fixture.conflictSetup(&repo);
            try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
            // a committed resolution leaves nothing for either command to refuse
            try repo.write("shared", "resolved\n");
            try repo.exec(&.{ "add", "shared" });
            try repo.exec(&.{ "commit", "-q", "--no-edit" });
            try cli.installFaultShim(&repo);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const args: []const []const u8 = &.{command};
            const killed = try cli.run(&repo, args);
            defer killed.deinit();
            try testing.expect(killed.code != 0);
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            if (std.mem.eql(u8, fault, "before:archive")) {
                try repo.expectNoRef(layout.oplog_ref);
                try cli.expectSuccess(&repo, args);
            }
            try fixture.noSession(&repo);
            try repo.expectOutput(&.{ "cat-file", "-t", layout.oplog_ref }, "commit");
            var log = try edit.readLog(&repo.git);
            defer log.deinit();
            try testing.expect(log.steps.len != 0);
        }
    }
}
