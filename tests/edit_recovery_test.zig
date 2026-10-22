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

fn replaceCheckpoint(repo: *const Repo, value: std.json.Value) ![]u8 {
    const raw = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(raw);
    const oid = try repo.git.writeBlob(raw);
    errdefer testing.allocator.free(oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, oid });
    return oid;
}

fn pausedBeforeDetach(repo: *Repo) !void {
    try setup(repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "corrected\n");
    try repo.commitAll("correction");
    try cli.installFaultShim(repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:1");
    const stopped = try cli.run(repo, &.{"edit"});
    defer stopped.deinit();
    try testing.expect(stopped.code != 0);
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
            try edit.run(&repo.git, .{ .jump = "models" });
            try repo.write("model", "fixed\n");
            try repo.commitAll("correction");
            try cli.installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(testing.allocator, "{s}:{d}", .{ side, checkpoint });
            defer testing.allocator.free(fault);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const killed = try cli.run(&repo, &.{"edit"});
            defer killed.deinit();
            try testing.expect(killed.code != 0);
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            if (checkpoint == 1 and std.mem.eql(u8, side, "before")) {
                try cli.expectSuccess(&repo, &.{"edit"});
            } else {
                try cli.expectSuccess(&repo, &.{ "edit", "--continue" });
            }
            try noSession(&repo);
            try valid(&repo);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
            try repo.expectOutput(&.{ "show", "work:model" }, "fixed");
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
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "fixed\n");
    try repo.commitAll("correction");
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "pick");
    const killed = try cli.run(&repo, &.{"edit"});
    defer killed.deinit();
    try testing.expect(killed.code != 0);
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    try cli.expectSuccess(&repo, &.{ "edit", "--continue" });
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
    const conflict = try cli.run(&repo, &.{ "edit", "api" });
    defer conflict.deinit();
    try testing.expect(conflict.code != 0);
    const status = try cli.run(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(?u8, 0), status.code);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "models (conflict)") != null);
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try cli.expectSuccess(&repo, &.{ "edit", "--continue" });
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/api");
    try cli.expectSuccess(&repo, &.{"edit"});
    try noSession(&repo);
}

test "abort and its restoration transaction resume after process death" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for (1..3) |checkpoint| {
            var repo = try Repo.init();
            defer repo.deinit();
            try setup(&repo);
            var refs = try repo.git.listRefs("refs/heads/stakrr/");
            defer refs.deinit(testing.allocator);
            const work = try repo.git.resolveCommit("work");
            defer testing.allocator.free(work);
            try edit.run(&repo.git, .{ .jump = "models" });
            try repo.write("model", "edit one\n");
            try repo.commitAll("edit one");
            const first = try repo.git.resolveCommit("HEAD");
            defer testing.allocator.free(first);
            try edit.run(&repo.git, .{ .jump = "api" });
            try repo.write("api", "edit two\n");
            try repo.commitAll("edit two");
            const second = try repo.git.resolveCommit("HEAD");
            defer testing.allocator.free(second);
            try cli.installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(testing.allocator, "{s}:{d}", .{ side, checkpoint });
            defer testing.allocator.free(fault);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const killed = try cli.run(&repo, &.{ "edit", "--abort" });
            defer killed.deinit();
            try testing.expect(killed.code != 0);
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            try cli.expectSuccess(&repo, &.{ "edit", "--abort" });
            var restored = try repo.git.listRefs("refs/heads/stakrr/");
            defer restored.deinit(testing.allocator);
            try testing.expectEqualStrings(refs.raw, restored.raw);
            try repo.expectRef("work", work);
            try expectRecoverable(&repo, first);
            try expectRecoverable(&repo, second);
            try noSession(&repo);
            try valid(&repo);
        }
    }
}

test "branch occupancy appearing during replay blocks publication" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "fixed\n");
    try repo.commitAll("correction");
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:6");
    const killed = try cli.run(&repo, &.{"edit"});
    defer killed.deinit();
    try testing.expect(killed.code != 0);
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    const other = try linked(&repo, "linked", "work");
    defer other.cwd.?.close(testing.io);
    try testing.expectError(error.BranchOccupied, edit.run(&repo.git, .continue_edit));
    try repo.expectRef("work", work);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "session validation rejects extra layers and corrupt checkpoints" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.exec(&.{ "branch", "stakrr/extra", "HEAD" });
    try testing.expectError(error.EditStateChanged, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "branch", "-D", "stakrr/extra" });
    try edit.run(&repo.git, .abort);
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
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });

    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try repo.git.output(&.{ "cat-file", "blob", checkpoint });
    defer testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    parsed.value.object.getPtr("plan_len").?.integer += 1;
    const invalid = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(invalid);
    const invalid_oid = try repo.git.writeBlob(invalid);
    defer testing.allocator.free(invalid_oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, invalid_oid });

    const head = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(head);
    const picking = (try repo.git.readRef("CHERRY_PICK_HEAD")).?;
    defer testing.allocator.free(picking);
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try repo.expectRef("HEAD", head);
        try repo.expectRef("CHERRY_PICK_HEAD", picking);
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
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", checkpoint });
    defer testing.allocator.free(raw);
    const phases = [_][]const u8{
        "switching",
        "editing",
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
            object.getPtr("destination").?.* = .{ .integer = 999 };
        } else if (std.mem.eql(u8, phase, "editing")) {
            object.getPtr("plan_oid").?.* = .null;
            object.getPtr("plan_len").?.* = .{ .integer = 0 };
            // Finishing was requested; editing must instead target its active cut.
            object.getPtr("destination").?.* = .null;
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
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", checkpoint });
    defer testing.allocator.free(raw);
    for ([_]bool{ false, true }) |reverse| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
        defer parsed.deinit();
        if (reverse) {
            const oid = parsed.value.object.get("plan_oid").?.string;
            const plan = try repo.git.output(&.{ "cat-file", "blob", oid });
            defer testing.allocator.free(plan);
            var commits: std.ArrayList([]const u8) = .empty;
            defer commits.deinit(testing.allocator);
            var lines = std.mem.tokenizeScalar(u8, plan, '\n');
            while (lines.next()) |line| try commits.append(testing.allocator, line);
            std.mem.reverse([]const u8, commits.items);
            const reversed = try std.mem.join(testing.allocator, "\n", commits.items);
            defer testing.allocator.free(reversed);
            const bad_plan = try repo.git.writeBlob(reversed);
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
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", checkpoint });
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
    const bytes = try repo.tmp.dir.readFileAlloc(testing.io, "precious", testing.allocator, .limited(1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("ignored data\n", bytes);
    try repo.tmp.dir.deleteFile(testing.io, "precious");
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}

test "checkout hooks cannot bypass the ignored-file replay guard" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "fixed\n");
    try repo.commitAll("correction");
    try repo.write(".git/info/exclude", "api\n");
    try repo.tmp.dir.createDir(testing.io, ".git/checkout-hooks", .default_dir);
    try repo.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git/checkout-hooks/post-checkout",
        .data = "#!/bin/sh\nprintf 'ignored from checkout hook\\n' > api\n",
        .flags = .{ .permissions = .executable_file },
    });
    try repo.exec(&.{ "config", "core.hooksPath", ".git/checkout-hooks" });
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
    try repo.expectRef("work", work);
    const bytes = try repo.tmp.dir.readFileAlloc(testing.io, "api", testing.allocator, .limited(1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("ignored from checkout hook\n", bytes);
    try repo.exec(&.{ "config", "core.hooksPath", "/dev/null" });
    try repo.tmp.dir.deleteFile(testing.io, "api");
    try edit.run(&repo.git, .continue_edit);
    try repo.expectOutput(&.{ "show", "work:api" }, "api");
    try noSession(&repo);
}

test "legacy v1 switching checkpoints may retain a completed replay plan" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const before = try repo.git.outputRaw(&.{ "cat-file", "blob", layout.session_ref });
    defer testing.allocator.free(before);
    var original = try std.json.parseFromSlice(std.json.Value, testing.allocator, before, .{});
    defer original.deinit();
    try repo.env.put("STAKRR_TEST_FAULT", "after:7");
    const stopped = try cli.run(&repo, &.{ "edit", "--continue" });
    defer stopped.deinit();
    try testing.expect(stopped.code != 0);
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", layout.session_ref });
    defer testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("switching", parsed.value.object.get("phase").?.string);
    // Older versions left this completed plan in the switching checkpoint,
    // even though its old boundary OIDs no longer match the published nodes.
    for ([_][]const u8{ "plan_oid", "plan_len" }) |field|
        parsed.value.object.getPtr(field).?.* = original.value.object.get(field).?;
    parsed.value.object.getPtr("next").?.* = original.value.object.get("plan_len").?;
    const head = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(head);
    parsed.value.object.getPtr("before").?.* = .{ .string = head };
    const legacy = try replaceCheckpoint(&repo, parsed.value);
    defer testing.allocator.free(legacy);
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "a non-blob edit checkpoint reports invalid session without changing refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const commit_oid = try repo.git.resolveCommit("HEAD");
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
    try setup(&repo);
    try testing.expectError(error.NoEditSession, edit.run(&repo.git, .quit));
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "corrected\n");
    try repo.commitAll("correction");
    try repo.exec(&.{ "branch", "-f", "stakrr/api", "main" });
    try testing.expectError(error.EditStateChanged, edit.run(&repo.git, .abort));
    const head = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(head);
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    const branches = try repo.git.output(&.{ "for-each-ref", "refs/heads/" });
    defer testing.allocator.free(branches);

    try edit.run(&repo.git, .quit);
    try noSession(&repo);
    try repo.expectOutput(&.{ "for-each-ref", "refs/heads/" }, branches);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, "");
    try expectRecoverable(&repo, head);
    try expectRecoverable(&repo, checkpoint);

    const corrupt = try repo.git.writeBlob("not a checkpoint");
    defer testing.allocator.free(corrupt);
    try repo.exec(&.{ "update-ref", layout.session_ref, corrupt });
    try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, .abort));
    try cli.expectSuccess(&repo, &.{ "edit", "--quit" });
    try noSession(&repo);
    try expectRecoverable(&repo, corrupt);
}

test "quit refuses while a replay pick is in progress" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = "api" }));
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer testing.allocator.free(checkpoint);
    try testing.expectError(error.GitOperationInProgress, edit.run(&repo.git, .quit));
    try repo.expectRef(layout.session_ref, checkpoint);
}

test "pending edit status offers continue without conflict instructions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const result = try cli.run(&repo, &.{"status"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "(detaching) → work") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "\n  stakrr edit --continue\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "resolve conflicts") == null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "recovery:") == null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "worktree:") == null);
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}
