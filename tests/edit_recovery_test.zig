//! Recovery after process death and corrupt checkpoints, driven through the
//! CLI with support/git_fault.sh.
const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const edit = stakrr.edit;
const layout = stakrr.layout;
const cli = @import("support/cli.zig");
const Repo = @import("support/repo.zig").Repo;
const fixture = @import("support/edit_fixture.zig");
const setup = fixture.setup;
const conflictSetup = fixture.conflictSetup;
const valid = fixture.valid;
const noSession = fixture.noSession;
const expectRecoverable = fixture.expectRecoverable;
const linked = fixture.linked;
const on = fixture.on;

fn replaceCheckpoint(repo: *const Repo, value: std.json.Value) ![]u8 {
    const raw = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(raw);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const git = repo.git.withAllocator(arena.allocator());
    var entries: std.ArrayList(stakrr.git.Git.TreeEntry) = .empty;
    try entries.append(git.allocator, .{ .name = "session.json", .oid = try git.writeBlob(raw) });
    if (value.object.get("plan_oid")) |plan| {
        if (plan == .string) try entries.append(git.allocator, .{ .name = "plan", .oid = plan.string });
    }
    const oid = try repo.git.commitTree(try git.writeTree(entries.items), &.{}, "test checkpoint");
    errdefer testing.allocator.free(oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, oid });
    return oid;
}

const correct = fixture.correctModels;

/// restack from models, killed right after its first checkpoint
fn pausedBeforeDetach(repo: *Repo) !void {
    try setup(repo);
    try on(repo, "models");
    try repo.write("model", "corrected\n");
    try repo.commitAll("correction");
    try cli.installFaultShim(repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:1");
    const stopped = try cli.run(repo, &.{"restack"});
    defer stopped.deinit();
    try stopped.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
}

fn expectInvalidCheckpointUnchanged(repo: *const Repo, oid: []const u8) !void {
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try repo.expectOutput(&.{"show-ref"}, refs);
        try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
        try repo.expectOutput(&.{ "status", "--porcelain=v1" }, "");
        try repo.expectRef(layout.session_ref, oid);
        try repo.expectOutput(&.{ "show", "HEAD:model" }, "corrected");
    }
}

test "replay resumes after process death on either side of every ref checkpoint" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for (1..8) |checkpoint| {
            var repo = try Repo.init();
            defer repo.deinit();
            try setup(&repo);
            try correct(&repo);
            try cli.installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(testing.allocator, "{s}:{d}", .{ side, checkpoint });
            defer testing.allocator.free(fault);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const killed = try cli.run(&repo, &.{"restack"});
            defer killed.deinit();
            try killed.expectKilled();
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            if (checkpoint == 1 and std.mem.eql(u8, side, "before")) {
                // nothing was journaled, so the restack simply starts over
                try cli.expectSuccess(&repo, &.{"restack"});
            } else {
                try cli.expectSuccess(&repo, &.{"continue"});
            }
            try noSession(&repo);
            try valid(&repo);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
            try repo.expectOutput(&.{ "show", "work:model" }, "corrected");
            try repo.expectOutput(
                &.{ "log", "--format=%s", "--reverse", "main..work" },
                "models\ncorrection\napi\ndelete obsolete\nrolling",
            );
        }
    }
}

test "a successful cherry-pick interrupted before journaling is incorporated exactly once" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try correct(&repo);
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "pick");
    const killed = try cli.run(&repo, &.{"restack"});
    defer killed.deinit();
    try killed.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    try cli.expectSuccess(&repo, &.{"continue"});
    try repo.expectOutput(
        &.{ "log", "--format=%s", "--reverse", "main..work" },
        "models\ncorrection\napi\ndelete obsolete\nrolling",
    );
    try noSession(&repo);
}

test "conflicts continue after restarting the CLI process" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const conflict = try cli.run(&repo, &.{"restack"});
    defer conflict.deinit();
    try testing.expectEqual(@as(?u8, 3), conflict.code);
    const status = try cli.run(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 0), status.code);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "models (conflict)") != null);
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try cli.expectSuccess(&repo, &.{"continue"});
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    try noSession(&repo);
}

test "abort and its restoration transaction resume after process death" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for (1..3) |checkpoint| {
            var repo = try Repo.init();
            defer repo.deinit();
            try conflictSetup(&repo);
            const models = try repo.git.resolveCommitAlloc(layout.record_prefix ++ "models");
            defer testing.allocator.free(models);
            const api = try repo.git.resolveCommitAlloc("stakrr/api");
            defer testing.allocator.free(api);
            const work = try repo.git.resolveCommitAlloc("work");
            defer testing.allocator.free(work);
            const edited = try repo.git.resolveCommitAlloc("HEAD");
            defer testing.allocator.free(edited);
            try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
            // a committed resolution leaves nothing for abort to refuse
            try repo.write("shared", "resolved\n");
            try repo.exec(&.{ "add", "shared" });
            try repo.exec(&.{ "commit", "-q", "--no-edit" });
            const resolution = try repo.git.resolveCommitAlloc("HEAD");
            defer testing.allocator.free(resolution);
            try cli.installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(testing.allocator, "{s}:{d}", .{ side, checkpoint });
            defer testing.allocator.free(fault);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const killed = try cli.run(&repo, &.{"abort"});
            defer killed.deinit();
            try killed.expectKilled();
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            try cli.expectSuccess(&repo, &.{"abort"});
            // the stack is back where it was; the layer's new commit stays recoverable
            try repo.expectRef("refs/heads/stakrr/models", models);
            try repo.expectRef("refs/heads/stakrr/api", api);
            try repo.expectRef("refs/heads/work", work);
            try expectRecoverable(&repo, edited);
            try expectRecoverable(&repo, resolution);
            try noSession(&repo);
            try fixture.validConflict(&repo);
        }
    }
}

test "branch occupancy appearing during replay blocks publication" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const work = try repo.git.resolveCommitAlloc("work");
    defer testing.allocator.free(work);
    try correct(&repo);
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:6");
    const killed = try cli.run(&repo, &.{"restack"});
    defer killed.deinit();
    try killed.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    const other = try linked(&repo, "linked", "work");
    defer other.cwd.?.close(testing.io);
    try testing.expectError(error.BranchOccupied, edit.run(&repo.git, .continue_edit));
    try repo.expectRef("refs/heads/work", work);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "session validation rejects extra layers and corrupt checkpoints" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.exec(&.{ "branch", "stakrr/extra", "HEAD" });
    try testing.expectError(error.EditStateChanged, edit.run(&repo.git, .continue_edit));
    try repo.exec(&.{ "branch", "-D", "stakrr/extra" });
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
    const bad = try repo.git.writeBlob("{}");
    defer testing.allocator.free(bad);
    try repo.exec(&.{ "update-ref", layout.session_ref, bad });
    try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, .abort));
    try testing.expectError(error.EditInProgress, stack.reset(&repo.git, .{ .delete_layers = true }));
}

test "continue and abort reject an inconsistent replay plan before changing Git state" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });

    const checkpoint = (try repo.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try fixture.checkpointJson(&repo, checkpoint);
    defer testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    parsed.value.object.getPtr("plan_len").?.integer += 1;
    const invalid_oid = try replaceCheckpoint(&repo, parsed.value);
    defer testing.allocator.free(invalid_oid);

    const head = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(head);
    const picking = (try repo.git.cherryPickHeadAlloc()).?;
    defer testing.allocator.free(picking);
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, head);
        try repo.expectOutput(&.{ "rev-parse", "--verify", "CHERRY_PICK_HEAD" }, picking);
        try repo.expectRef(layout.session_ref, invalid_oid);
    }
    try repo.exec(&.{ "update-ref", layout.session_ref, checkpoint });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
}

test "every checkpoint phase rejects inconsistent state before changing Git" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const checkpoint = (try repo.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try fixture.checkpointJson(&repo, checkpoint);
    defer testing.allocator.free(raw);
    const phases = [_][]const u8{
        "switching",
        "detaching",
        "replay",
        "conflict",
        "publishing",
        "aborting",
        "aborted",
    };
    for (phases) |phase| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
        defer parsed.deinit();
        const object = &parsed.value.object;
        object.getPtr("phase").?.* = .{ .string = phase };
        if (std.mem.eql(u8, phase, "switching")) {
            object.getPtr("active").?.* = .{ .integer = 999 };
        } else if (std.mem.eql(u8, phase, "detaching")) {
            object.getPtr("next").?.* = .{ .integer = 1 };
        } else if (std.mem.eql(u8, phase, "replay")) {
            object.getPtr("plan_oid").?.* = .null;
            object.getPtr("plan_len").?.* = .{ .integer = 0 };
        } else if (std.mem.eql(u8, phase, "conflict")) {
            object.getPtr("next").?.* = object.get("plan_len").?;
        } else if (std.mem.eql(u8, phase, "publishing")) {
            object.getPtr("next").?.* = .{ .integer = 0 };
        } else if (std.mem.eql(u8, phase, "aborting")) {
            object.getPtr("plan_oid").?.* = .null;
        } else {
            object.getPtr("id").?.* = .{
                .string = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            };
        }
        const invalid = try replaceCheckpoint(&repo, parsed.value);
        defer testing.allocator.free(invalid);
        try expectInvalidCheckpointUnchanged(&repo, invalid);
    }
    try repo.exec(&.{ "update-ref", layout.session_ref, checkpoint });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
}

test "invalid replay plans are rejected before detach and before a clean abort" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const checkpoint = (try repo.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try fixture.checkpointJson(&repo, checkpoint);
    defer testing.allocator.free(raw);
    for ([_]enum { length, reverse, duplicate, malformed, extra }{ .length, .reverse, .duplicate, .malformed, .extra }) |corruption| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
        defer parsed.deinit();
        if (corruption != .length) {
            const oid = parsed.value.object.get("plan_oid").?.string;
            const plan = try repo.git.output(&.{ "cat-file", "blob", oid });
            defer testing.allocator.free(plan);
            var commits: std.ArrayList([]const u8) = .empty;
            defer commits.deinit(testing.allocator);
            var lines = std.mem.tokenizeScalar(u8, plan, '\n');
            while (lines.next()) |line| try commits.append(testing.allocator, line);
            switch (corruption) {
                .reverse => std.mem.reverse([]const u8, commits.items),
                .duplicate => commits.items[0] = commits.items[1],
                .malformed => commits.items[0] = "not-an-oid",
                .extra => try commits.append(testing.allocator, commits.items[0]),
                .length => unreachable,
            }
            const changed = try std.mem.join(testing.allocator, "\n", commits.items);
            defer testing.allocator.free(changed);
            const bad_plan = try repo.git.writeBlob(changed);
            defer testing.allocator.free(bad_plan);
            parsed.value.object.getPtr("plan_oid").?.* = .{ .string = bad_plan };
            const invalid = try replaceCheckpoint(&repo, parsed.value);
            defer testing.allocator.free(invalid);
            try expectInvalidCheckpointUnchanged(&repo, invalid);
        } else {
            parsed.value.object.getPtr("plan_len").?.integer += 1;
            const invalid = try replaceCheckpoint(&repo, parsed.value);
            defer testing.allocator.free(invalid);
            try expectInvalidCheckpointUnchanged(&repo, invalid);
        }
    }
    try repo.exec(&.{ "update-ref", layout.session_ref, checkpoint });
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "replay plans cannot omit a commit between cut boundaries" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const checkpoint = (try repo.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try fixture.checkpointJson(&repo, checkpoint);
    defer testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    const object = &parsed.value.object;
    const plan = try repo.git.outputRaw(&.{ "cat-file", "blob", object.get("plan_oid").?.string });
    defer testing.allocator.free(plan);
    // The first API commit is inside the cut; later commits still include
    // every cut boundary, so boundary-only validation would accept this plan.
    const first_newline = std.mem.indexOfScalar(u8, plan, '\n').?;
    const shortened = try repo.git.writeBlob(plan[first_newline + 1 ..]);
    defer testing.allocator.free(shortened);
    object.getPtr("plan_oid").?.* = .{ .string = shortened };
    object.getPtr("plan_len").?.integer -= 1;
    const invalid = try replaceCheckpoint(&repo, parsed.value);
    defer testing.allocator.free(invalid);
    try expectInvalidCheckpointUnchanged(&repo, invalid);
    try repo.exec(&.{ "update-ref", layout.session_ref, checkpoint });
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "restarted detach refuses newly created ignored files without changing state" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    try repo.write(".git/info/exclude", "precious\n");
    try repo.write("precious", "ignored data\n");
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .continue_edit));
    try repo.expectOutput(&.{"show-ref"}, refs);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    try repo.expectFile("precious", "ignored data\n");
    try repo.tmp.dir.deleteFile(testing.io, "precious");
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}

test "checkout hooks cannot bypass the ignored-file replay guard" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try correct(&repo);
    try repo.write(".git/info/exclude", "api\n");
    try repo.tmp.dir.createDir(testing.io, ".git/checkout-hooks", .default_dir);
    try repo.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git/checkout-hooks/post-checkout",
        .data = "#!/bin/sh\nprintf 'ignored from checkout hook\\n' > api\n",
        .flags = .{ .permissions = .executable_file },
    });
    try repo.exec(&.{ "config", "core.hooksPath", ".git/checkout-hooks" });
    const work = try repo.git.resolveCommitAlloc("work");
    defer testing.allocator.free(work);
    try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .restack));
    try repo.expectRef("refs/heads/work", work);
    try repo.expectFile("api", "ignored from checkout hook\n");
    try repo.exec(&.{ "config", "core.hooksPath", "/dev/null" });
    try repo.tmp.dir.deleteFile(testing.io, "api");
    try edit.run(&repo.git, .continue_edit);
    try repo.expectOutput(&.{ "show", "work:api" }, "api");
    try noSession(&repo);
}

test "an unrelated commit checkpoint reports invalid session without changing refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const commit_oid = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(commit_oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, commit_oid });
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    try testing.expectError(error.InvalidEditSession, edit.readStatus(&repo.git));
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try repo.expectOutput(&.{"show-ref"}, refs);
    }
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
}

test "quit drops only the journal of drifted and corrupt sessions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.NoEditSession, edit.run(&repo.git, .quit));
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    // a committed resolution leaves no pick for quit to refuse
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try repo.exec(&.{ "commit", "-q", "--no-edit" });
    try repo.exec(&.{ "branch", "-f", "stakrr/api", "main" });
    try testing.expectError(error.EditStateChanged, edit.run(&repo.git, .abort));
    const head = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(head);
    const checkpoint = (try repo.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const branches = try repo.git.output(&.{ "for-each-ref", "refs/heads/" });
    defer testing.allocator.free(branches);

    try edit.run(&repo.git, .quit);
    try noSession(&repo);
    try repo.expectOutput(&.{ "for-each-ref", "refs/heads/" }, branches);
    try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, head);
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, "");
    try expectRecoverable(&repo, head);
    try expectRecoverable(&repo, checkpoint);

    const corrupt = try repo.git.writeBlob("not a checkpoint");
    defer testing.allocator.free(corrupt);
    try repo.exec(&.{ "update-ref", layout.session_ref, corrupt });
    try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, .abort));
    try cli.expectSuccess(&repo, &.{"quit"});
    try noSession(&repo);
    try expectRecoverable(&repo, corrupt);
}

test "quit refuses while a replay pick is in progress" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    const checkpoint = (try repo.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    try testing.expectError(error.GitOperationInProgress, edit.run(&repo.git, .quit));
    try repo.expectRef(layout.session_ref, checkpoint);
}

test "invalid checkpoint object IDs refuse resume and remain quittable" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try pausedBeforeDetach(&repo);
        const checkpoint = (try repo.readRef(layout.session_ref)).?;
        defer testing.allocator.free(checkpoint);
        const raw = try fixture.checkpointJson(&repo, checkpoint);
        defer testing.allocator.free(raw);
        const zero: [64]u8 = @splat('0');
        const other: [64]u8 = @splat('a');
        const other_len: usize = if (checkpoint.len == 40) 64 else 40;
        for ([_][]const u8{ zero[0..checkpoint.len], other[0..other_len] }) |invalid| {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
            defer parsed.deinit();
            parsed.value.object.getPtr("nodes").?.array.items[0].object.getPtr("original_oid").?.* = .{ .string = invalid };
            const corrupt = try replaceCheckpoint(&repo, parsed.value);
            defer testing.allocator.free(corrupt);
            try testing.expectError(error.InvalidEditSession, edit.readStatus(&repo.git));
            try expectInvalidCheckpointUnchanged(&repo, corrupt);

            // Quit must preserve dirty user work while retaining the corrupt checkpoint.
            try repo.write("user-file", "staged\n");
            try repo.exec(&.{ "add", "user-file" });
            try repo.write("user-file", "unstaged\n");
            const index = try repo.git.output(&.{"write-tree"});
            defer testing.allocator.free(index);
            const branches = try repo.git.output(&.{ "for-each-ref", "refs/heads/" });
            defer testing.allocator.free(branches);
            try cli.expectSuccess(&repo, &.{"quit"});
            try noSession(&repo);
            try repo.expectOutput(&.{"write-tree"}, index);
            try repo.expectOutput(&.{ "for-each-ref", "refs/heads/" }, branches);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
            try repo.expectFile("user-file", "unstaged\n");
            try expectRecoverable(&repo, corrupt);
            // Restore the fixture's clean state for the next corrupt checkpoint.
            try repo.exec(&.{ "restore", "--staged", "user-file" });
            try repo.tmp.dir.deleteFile(testing.io, "user-file");
        }
    }
}

test "log rejects zero and wrong-format checkpoint history links" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const git = repo.git.withAllocator(arena.allocator());
        const head = try repo.commit("base");
        defer testing.allocator.free(head);
        const rescue = try git.writeBlob(head);
        const zero: [64]u8 = @splat('0');
        const other: [64]u8 = @splat('a');
        const other_len: usize = if (head.len == 40) 64 else 40;
        for ([_][]const u8{ zero[0..head.len], other[0..other_len] }) |invalid| {
            const tree = try git.writeTree(&.{
                .{ .name = "rescue", .oid = rescue },
                .{ .name = "previous", .oid = try git.writeBlob(invalid) },
            });
            const checkpoint = try git.commitTree(tree, &.{head}, "corrupt history link");
            try repo.exec(&.{ "update-ref", layout.oplog_ref, checkpoint });
            try testing.expectError(error.InvalidEditSession, edit.readLog(&repo.git));
            try repo.expectRef(layout.oplog_ref, checkpoint);
        }
    }
}

test "pending restack status offers continue without conflict instructions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const result = try cli.run(&repo, &.{"status"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "(detaching) → stakrr/models") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\n  stakrr continue\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\nreplay 0/3 done\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "  stakrr quit leaves") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "resolve conflicts") == null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "recovery:") == null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "worktree:") == null);
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}
