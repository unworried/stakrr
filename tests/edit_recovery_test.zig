//! Named crash boundaries and recovery against real Git repositories.
const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const edit = stakrr.edit;
const layout = stakrr.layout;
const cli = @import("support/cli.zig");
const Repo = @import("support/repo.zig").Repo;
const fixture = @import("support/edit_fixture.zig");

fn inject(repo: *const Repo, command: []const u8, fault: []const u8) !void {
    try repo.env.put("STAKRR_TEST_FAULT", fault);
    const result = try cli.run(repo, &.{command});
    defer result.deinit();
    try result.expectKilled();
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}.fired", .{repo.env.get("STAKRR_TEST_COUNTER").?});
    defer testing.allocator.free(marker);
    try repo.expectFile(marker, fault);
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
}
fn paused(repo: *const Repo) !void {
    try fixture.setup(repo);
    try fixture.correctModels(repo);
    try cli.installFaultShim(repo);
    try inject(repo, "restack", "after:detaching:1");
}

test "named replay, workspace, checkout and archival boundaries resume exactly once" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for ([_][]const u8{
            "detaching:1",  "workspace-create:1", "replay:1",          "pick:1",      "replay:2",   "replay:3",    "replay:4",           "pick:2",             "pick:3",
            "publishing:1", "publishing:2",       "checkout-detach:1", "switching:1", "checkout:1", "switching:2", "workspace-unlock:1", "workspace-remove:1", "archive:1",
        }) |boundary| {
            var repo = try Repo.init();
            defer repo.deinit();
            try fixture.setup(&repo);
            try fixture.correctModels(&repo);
            try cli.installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ side, boundary });
            defer testing.allocator.free(fault);
            try inject(&repo, "restack", fault);
            if (std.mem.eql(u8, fault, "before:detaching:1")) {
                try cli.expectSuccess(&repo, &.{"restack"});
            } else if (std.mem.eql(u8, fault, "after:archive:1")) {
                try fixture.noSession(&repo);
                try cli.expectSuccess(&repo, &.{"continue"});
            } else try cli.expectSuccess(&repo, &.{"continue"});
            try fixture.noSession(&repo);
            try fixture.valid(&repo);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
            try repo.expectOutput(&.{ "log", "--format=%s", "--reverse", "main..work" }, "models\ncorrection\napi\ndelete obsolete\nrolling");
            try repo.expectNoRef(layout.transaction_ref);
        }
    }
}

test "named abort restoration and archival boundaries retain edited commits" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for ([_][]const u8{ "aborting:1", "aborting:2", "checkout-detach:1", "aborted:1", "checkout:1", "aborted:2", "workspace-remove:1", "archive:1" }) |boundary| {
            var repo = try Repo.init();
            defer repo.deinit();
            try paused(&repo);
            const edited = try repo.git.resolveCommitAlloc("stakrr/models");
            defer testing.allocator.free(edited);
            const recorded = try fixture.boundary(&repo, "models");
            defer testing.allocator.free(recorded);
            const fault = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ side, boundary });
            defer testing.allocator.free(fault);
            try inject(&repo, "abort", fault);
            if (try repo.hasRef(layout.session_ref)) {
                try cli.expectSuccess(&repo, &.{"abort"});
            } else try cli.expectSuccess(&repo, &.{"continue"}); // finish pending archive intent
            try repo.expectRef("refs/heads/stakrr/models", recorded);
            try fixture.expectRecoverable(&repo, edited);
            try fixture.noSession(&repo);
            try fixture.valid(&repo);
        }
    }
}

test "conflicts resume from original worktree or managed workspace without touching original files" {
    for ([_]bool{ false, true }) |from_workspace| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.conflictSetup(&repo);
        const original = try repo.git.resolveCommitAlloc("HEAD");
        defer testing.allocator.free(original);
        const result = try cli.run(&repo, &.{"restack"});
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 3), result.code);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "workspace: ") != null);
        try repo.expectFile("shared", "edited\n");
        try repo.expectOutput(&.{ "rev-parse", "HEAD" }, original);
        try repo.expectOutput(&.{ "status", "--porcelain" }, "");
        var workspace = try fixture.workspace(&repo);
        defer workspace.tmp.dir.close(testing.io);
        try workspace.write("shared", "resolved\n");
        try workspace.exec(&.{ "add", "shared" });
        const resumed = try cli.runAt(&repo, &.{"continue"}, if (from_workspace) workspace.tmp.dir else repo.tmp.dir);
        defer resumed.deinit();
        if (resumed.code != 0) std.debug.print("resume: {s}\n", .{resumed.stderr});
        try testing.expectEqual(@as(?u8, 0), resumed.code);
        try repo.expectOutput(&.{ "show", "work:shared" }, "resolved");
        try fixture.validConflict(&repo);
        try fixture.noSession(&repo);
    }
}

fn replaceCheckpoint(repo: *const Repo, value: std.json.Value) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const git = repo.git.withAllocator(arena.allocator());
    var entries: std.ArrayList(stakrr.git.Git.TreeEntry) = .empty;
    try entries.append(git.allocator, .{ .name = "session.json", .oid = try git.writeBlob(try std.json.Stringify.valueAlloc(git.allocator, value, .{})) });
    if (value.object.get("progress")) |progress| if (progress == .object) {
        if (progress.object.get("plan_oid")) |oid| if (oid == .string) {
            try entries.append(git.allocator, .{ .name = "plan", .oid = oid.string });
        };
    };
    const oid = try git.commitTree(try git.writeTree(entries.items), &.{}, "test corrupt progress");
    try git.exec(&.{ "update-ref", layout.session_ref, oid });
}

test "malformed progress, invalid IDs and altered replay plans refuse before mutation" {
    for ([_][]const u8{ "version", "id", "before_manifest", "manifest", "edited_oid", "plan_oid", "plan_len", "next", "active", "workspace", "node" }) |field| {
        var repo = try Repo.init();
        defer repo.deinit();
        try paused(&repo);
        const oid = (try repo.readRef(layout.session_ref)).?;
        defer testing.allocator.free(oid);
        const raw = try fixture.checkpointJson(&repo, oid);
        defer testing.allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const a = parsed.arena.allocator();
        if (std.mem.eql(u8, field, "plan_oid")) {
            const blob = try repo.git.writeBlob("missing commits\n");
            defer testing.allocator.free(blob);
            try parsed.value.object.getPtr("progress").?.object.put(a, field, .{ .string = try a.dupe(u8, blob) });
        } else if (std.mem.eql(u8, field, "plan_len") or std.mem.eql(u8, field, "next")) {
            try parsed.value.object.getPtr("progress").?.object.put(a, field, .{ .integer = 999 });
        } else if (std.mem.eql(u8, field, "active") or std.mem.eql(u8, field, "version")) {
            try parsed.value.object.put(a, field, .{ .integer = 999 });
        } else if (std.mem.eql(u8, field, "node")) {
            try parsed.value.object.getPtr("nodes").?.array.items[0].object.put(a, "original_oid", .{ .string = "0000000000000000000000000000000000000000" });
        } else try parsed.value.object.put(a, field, .{ .string = "invalid" });
        try replaceCheckpoint(&repo, parsed.value);
        const before = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(before);
        for ([_]edit.Request{ .continue_edit, .abort }) |request| {
            try testing.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
            try repo.expectOutput(&.{"show-ref"}, before);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
            try repo.expectOutput(&.{ "status", "--porcelain" }, "");
        }
        try edit.run(&repo.git, .quit);
        try fixture.noSession(&repo);
    }
}

test "quit refuses active workspace pick and preserves workspace files after Git quit" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    var workspace = try fixture.workspace(&repo);
    defer workspace.tmp.dir.close(testing.io);
    try testing.expectError(error.GitOperationInProgress, edit.run(&repo.git, .quit));
    try workspace.exec(&.{ "cherry-pick", "--quit" });
    const before = try workspace.git.outputRaw(&.{ "diff", "--binary" });
    defer testing.allocator.free(before);
    try edit.run(&repo.git, .quit);
    try fixture.noSession(&repo);
    try workspace.expectOutput(&.{ "diff", "--binary" }, std.mem.trimEnd(u8, before, "\r\n"));
    try workspace.write("precious", "preserved\n");
    try workspace.expectFile("precious", "preserved\n");
}

test "corrupt checkpoints archive without interpreting them and retain raw objects" {
    for ([_][]const u8{ "blob", "commit" }) |kind| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const git = repo.git.withAllocator(arena.allocator());
        const blob = try git.writeBlob("corrupt progress");
        const oid = if (std.mem.eql(u8, kind, "blob")) blob else try git.commitTree(try git.writeTree(&.{.{ .name = "session.json", .oid = blob }}), &.{}, "corrupt session");
        try git.exec(&.{ "update-ref", layout.session_ref, oid });
        try edit.run(&repo.git, .quit);
        try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
        try repo.exec(&.{ "gc", "--prune=now" });
        try repo.exec(&.{ "cat-file", "-e", oid });
        try repo.exec(&.{ "fsck", "--no-reflogs", "--full" });
        try fixture.noSession(&repo);
    }
}

test "branch occupancy or dirty invocation at final publication retains replay for continuation" {
    for ([_]bool{ false, true }) |dirty| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        try fixture.correctModels(&repo);
        try cli.installFaultShim(&repo);
        try inject(&repo, "restack", "after:publishing:1");
        const manifest = (try repo.readRef(layout.state_ref)).?;
        defer testing.allocator.free(manifest);
        if (dirty) {
            try repo.write("precious", "user work\n");
            try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .continue_edit));
            try repo.expectFile("precious", "user work\n");
            try repo.tmp.dir.deleteFile(testing.io, "precious");
        } else {
            const other = try fixture.linked(&repo, "occupied", "stakrr/api");
            defer other.cwd.?.close(testing.io);
            try testing.expectError(error.BranchOccupied, edit.run(&repo.git, .continue_edit));
            try other.exec(&.{ "switch", "--quiet", "--detach" });
        }
        try repo.expectRef(layout.state_ref, manifest);
        try cli.expectSuccess(&repo, &.{"continue"});
        try fixture.valid(&repo);
    }
}

test "workspace cleanup preserves ignored and unexpected files and resumes after preservation" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try fixture.correctModels(&repo);
    try cli.installFaultShim(&repo);
    try inject(&repo, "restack", "after:switching:1");
    var workspace = try fixture.workspace(&repo);
    defer workspace.tmp.dir.close(testing.io);
    try workspace.exec(&.{ "config", "core.excludesFile", "info/exclude" });
    try workspace.write("precious", "unexpected\n");
    try testing.expectError(error.WorkspaceCleanupPending, edit.run(&repo.git, .continue_edit));
    try workspace.expectFile("precious", "unexpected\n");
    try workspace.tmp.dir.deleteFile(testing.io, "precious");
    try cli.expectSuccess(&repo, &.{"continue"});
    try fixture.noSession(&repo);
}

test "operation log shows completed records and active checkpoints after restart" {
    var repo = try Repo.init();
    defer repo.deinit();
    try paused(&repo);
    const raw = try fixture.checkpointJson(&repo, layout.session_ref);
    defer testing.allocator.free(raw);
    var metadata = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer metadata.deinit();
    try testing.expectEqual(@as(i64, 1), metadata.value.object.get("version").?.integer);
    var active = try edit.readLog(&repo.git);
    defer active.deinit();
    try testing.expect(active.steps.len != 0);
    try cli.expectSuccess(&repo, &.{"continue"});
    var log = try edit.readLog(&repo.git);
    defer log.deinit();
    try testing.expectEqualStrings("stakrr: restack", log.steps[0].label);
    try testing.expect(log.steps.len > 2);
    try testing.expect(log.steps[0].moves.len != 0);
}

test "abort restores original refs after publication checkout and workspace removal interruptions" {
    for ([_][]const u8{ "after:switching:1", "after:checkout:1", "after:workspace-remove:1" }) |fault| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        const boundary = try fixture.boundary(&repo, "models");
        defer testing.allocator.free(boundary);
        const work = try repo.git.resolveCommitAlloc("work");
        defer testing.allocator.free(work);
        try fixture.correctModels(&repo);
        try cli.installFaultShim(&repo);
        try inject(&repo, "restack", fault);
        try cli.expectSuccess(&repo, &.{"abort"});
        try repo.expectRef("refs/heads/stakrr/models", boundary);
        try repo.expectRef("refs/heads/work", work);
        try fixture.valid(&repo);
        try fixture.noSession(&repo);
    }
}

test "conflict checkpoint interruptions preserve invocation and resume the recorded pick" {
    for ([_][]const u8{ "before:conflict:1", "after:conflict:1" }) |fault| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.conflictSetup(&repo);
        try cli.installFaultShim(&repo);
        try inject(&repo, "restack", fault);
        try repo.expectFile("shared", "edited\n");
        try repo.expectOutput(&.{ "status", "--porcelain" }, "");
        var workspace = try fixture.workspace(&repo);
        defer workspace.tmp.dir.close(testing.io);
        try workspace.write("shared", "resolved\n");
        try workspace.exec(&.{ "add", "shared" });
        try cli.expectSuccess(&repo, &.{"continue"});
        try fixture.validConflict(&repo);
    }
}

test "foreign workspace lock ownership refuses replay without changing managed state" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try fixture.correctModels(&repo);
    try cli.installFaultShim(&repo);
    try inject(&repo, "restack", "after:replay:1");
    var status = (try edit.readStatus(&repo.git)).?;
    defer status.deinit();
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    try repo.exec(&.{ "worktree", "unlock", status.workspace });
    try repo.exec(&.{ "worktree", "lock", "--reason", "foreign ownership", status.workspace });
    try testing.expectError(error.WorkspaceChanged, edit.run(&repo.git, .continue_edit));
    try repo.expectOutput(&.{"show-ref"}, refs);
    try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    try repo.exec(&.{ "worktree", "unlock", status.workspace });
    const reason = try std.fmt.allocPrint(testing.allocator, "stakrr {s}", .{status.session_id});
    defer testing.allocator.free(reason);
    try repo.exec(&.{ "worktree", "lock", "--reason", reason, status.workspace });
    try cli.expectSuccess(&repo, &.{"continue"});
    try fixture.valid(&repo);
}
