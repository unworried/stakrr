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

test "edit unchanged cuts never replay; unknown cuts leave no session" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    var before = try repo.git.listRefs("refs/heads/stakrr/");
    defer before.deinit(testing.allocator);
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try testing.expectError(error.NoEditSession, edit.run(&repo.git, .{ .jump = null }));
    try testing.expectError(error.NoEditSession, edit.run(&repo.git, .continue_edit));
    try testing.expectError(error.UnknownCut, edit.run(&repo.git, .{ .jump = "missing" }));
    try noSession(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try testing.expectError(error.UnknownCut, edit.run(&repo.git, .{ .jump = "missing" }));
    try testing.expectError(error.NoPendingEdit, edit.run(&repo.git, .continue_edit));
    try edit.run(&repo.git, .{ .jump = "api" });
    try edit.run(&repo.git, .{ .jump = null });
    var after = try repo.git.listRefs("refs/heads/stakrr/");
    defer after.deinit(testing.allocator);
    try testing.expectEqualStrings(before.raw, after.raw);
    try repo.expectRef("work", work);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try noSession(&repo);
}

test "correction commits replay in order and preserve upper deletions and rolling work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "fixed\n");
    try repo.commitAll("fix validation");
    const correction = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(correction);
    try edit.run(&repo.git, .{ .jump = "api" });
    try repo.expectRef("stakrr/models", correction);
    try repo.expectOutput(&.{ "show", "HEAD:model" }, "fixed");
    const deleted = try repo.git.run(&.{ "cat-file", "-e", "HEAD:obsolete" });
    defer repo.git.freeResult(deleted);
    try testing.expect(!deleted.term.success());
    try repo.write("api", "corrected api\n");
    try repo.commitAll("correct api");
    try edit.run(&repo.git, .{ .jump = null });
    try repo.expectOutput(
        &.{ "log", "--format=%s", "--reverse", "main..work" },
        "models\nfix validation\napi\ndelete obsolete\ncorrect api\nrolling",
    );
    try repo.expectOutput(&.{ "show", "work:tail" }, "rolling");
    try repo.expectOutput(&.{ "show", "work:api" }, "corrected api");
    try valid(&repo);
    try noSession(&repo);
}

test "amend of a cut survives replay in sha1 and sha256 repositories" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        try edit.run(&repo.git, .{ .jump = "models" });
        try repo.write("model", "amended\n");
        try repo.exec(&.{ "add", "model" });
        try repo.exec(&.{ "commit", "-q", "--amend", "--no-edit" });
        const amended = try repo.git.resolveCommit("HEAD");
        defer testing.allocator.free(amended);
        try edit.run(&repo.git, .{ .jump = null });
        try repo.expectRef("stakrr/models", amended);
        try repo.expectOutput(&.{ "show", "work:model" }, "amended");
        try valid(&repo);
        try noSession(&repo);
    }
}

test "abort restores the initial stack across multiple incorporated jumps and retains edits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    var initial = try repo.git.listRefs("refs/heads/stakrr/");
    defer initial.deinit(testing.allocator);
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "edit 1\n");
    try repo.commitAll("edit 1");
    const first = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(first);
    try edit.run(&repo.git, .{ .jump = "api" });
    try repo.write("api", "edit 2\n");
    try repo.commitAll("edit 2");
    const second = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(second);
    try edit.run(&repo.git, .abort);
    var actual = try repo.git.listRefs("refs/heads/stakrr/");
    defer actual.deinit(testing.allocator);
    try testing.expectEqualStrings(initial.raw, actual.raw);
    try repo.expectRef("work", work);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try expectRecoverable(&repo, first);
    try expectRecoverable(&repo, second);
    try valid(&repo);
    try noSession(&repo);
}

test "dirty work is never stashed committed or discarded by transitions or abort" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.write("untracked", "precious\n");
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .{ .jump = "models" }));
    try noSession(&repo);
    try repo.commitAll("save untracked");
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "precious\n");
    try repo.exec(&.{ "add", "model" });
    const before = try repo.git.output(&.{ "status", "--porcelain=v1" });
    defer testing.allocator.free(before);
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .{ .jump = "api" }));
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .abort));
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, before);
    try repo.expectOutput(&.{ "show", ":model" }, "precious");
}

test "conflicted replay persists destination and continues a staged resolution" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const old_work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(old_work);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = "api" }));
    try repo.expectRef("work", old_work); // no partial publication
    try testing.expectError(error.EditNeedsContinue, edit.run(&repo.git, .{ .jump = null }));
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .abort));
    var session_status = (try edit.readStatus(&repo.git)).?;
    defer session_status.deinit();
    try testing.expectEqual(.conflict, session_status.phase);
    try testing.expectEqualStrings(
        "refs/heads/stakrr/models",
        session_status.branches[session_status.active],
    );
    try testing.expectEqualStrings("refs/heads/stakrr/api", session_status.destination);
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .continue_edit);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/api");
    try repo.expectOutput(&.{ "show", "work:shared" }, "resolved");
    try edit.run(&repo.git, .{ .jump = null });
    try noSession(&repo);
}

test "abort after a conflict preserves committed resolutions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try repo.exec(&.{ "commit", "-q", "--no-edit" });
    const resolution = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(resolution);
    try edit.run(&repo.git, .abort);
    try expectRecoverable(&repo, resolution);
    try noSession(&repo);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
}

test "empty conflict resolutions are retained as commits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .continue_edit);
    try repo.expectOutput(&.{ "show", "work:shared" }, "edited");
    try noSession(&repo);
}

test "active sessions reject every competing stakrr mutation" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try testing.expectError(error.EditInProgress, stack.cut(&repo.git, "new", null));
    try testing.expectError(error.EditInProgress, stack.reset(&repo.git, .{ .delete_layers = true }));
    try testing.expectError(error.EditInProgress, stack.initStack(&repo.git, "main"));
    try testing.expectError(error.EditInProgress, stack.navigate(&repo.git, .up));
    try testing.expectError(error.EditInProgress, stack.navigate(&repo.git, .down));
    try edit.run(&repo.git, .abort);
}

test "external changes to nonactive refs and invalid edited histories are rejected" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.exec(&.{ "branch", "-f", "stakrr/api", "main" });
    try testing.expectError(error.EditStateChanged, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "branch", "-f", "stakrr/api", layout.tip_ref });
    try repo.exec(&.{ "reset", "--hard", "main" });
    try testing.expectError(error.InvalidEditedHistory, edit.run(&repo.git, .{ .jump = null }));
    try edit.run(&repo.git, .abort);
    try valid(&repo);
}

test "state changes name the drifted ref or HEAD and how to restore it" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try testing.expect(try edit.findDrift(&repo.git) == null);
    const api = try repo.git.resolveCommit("stakrr/api");
    defer testing.allocator.free(api);
    const base = try repo.git.resolveCommit("main");
    defer testing.allocator.free(base);

    try repo.exec(&.{ "branch", "-f", "stakrr/api", "main" });
    const moved = try cli.run(&repo, &.{"edit"});
    defer moved.deinit();
    try testing.expectEqual(@as(?u8, 1), moved.code);
    const keep = try std.fmt.allocPrint(testing.allocator, "git branch rescue/stakrr/api {s}", .{base});
    defer testing.allocator.free(keep);
    const restore = try std.fmt.allocPrint(testing.allocator, "git update-ref refs/heads/stakrr/api {s} {s}", .{ api, base });
    defer testing.allocator.free(restore);
    for ([_][]const u8{ keep, restore }) |line| {
        try testing.expect(std.mem.indexOf(u8, moved.stderr, line) != null);
    }
    try repo.exec(&.{ "update-ref", "refs/heads/stakrr/api", api, base });

    try repo.exec(&.{ "branch", "-q", "-D", "stakrr/api" });
    var missing = (try edit.findDrift(&repo.git)).?;
    defer missing.deinit();
    try testing.expectEqualStrings("refs/heads/stakrr/api", missing.name);
    try testing.expectEqualStrings(api, missing.expected.?);
    try testing.expect(missing.actual == null);
    try repo.exec(&.{ "update-ref", "refs/heads/stakrr/api", api });

    try repo.exec(&.{ "switch", "-q", "work" });
    var head = (try edit.findDrift(&repo.git)).?;
    defer head.deinit();
    try testing.expectEqualStrings("HEAD", head.name);
    try testing.expectEqualStrings("refs/heads/stakrr/models", head.expected.?);
    try testing.expectEqualStrings("refs/heads/work", head.actual.?);
    try testing.expectError(error.EditStateChanged, edit.run(&repo.git, .{ .jump = null }));

    try repo.exec(&.{ "switch", "-q", "stakrr/models" });
    try edit.run(&repo.git, .abort);
    try valid(&repo);
}

test "linked worktree occupancy is checked before starting and before publishing" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const path = "linked space\nnewline";
    const other = try linked(&repo, path, "stakrr/api");
    defer other.cwd.?.close(testing.io);
    try testing.expectError(error.BranchOccupied, edit.run(&repo.git, .{ .jump = "models" }));
    try noSession(&repo);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "fixed\n");
    try repo.commitAll("correction");
    try other.exec(&.{ "switch", "-q", "stakrr/api" });
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try testing.expectError(error.BranchOccupied, edit.run(&repo.git, .{ .jump = null }));
    try repo.expectRef("work", work);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .{ .jump = null });
    try valid(&repo);
}

test "sessions belong to one worktree and share the mutation guard" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const other = try linked(&repo, "linked", "main");
    defer other.cwd.?.close(testing.io);
    try edit.run(&repo.git, .{ .jump = "models" });
    try testing.expectError(error.WrongEditWorktree, edit.run(&other, .abort));
    try testing.expectError(error.WrongEditWorktree, edit.run(&other, .continue_edit));
    try testing.expectError(error.EditInProgress, stack.reset(&other, .{}));
    try edit.run(&repo.git, .abort);
}

test "the common directory lock excludes mutations from every worktree" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const other = try linked(&repo, "linked", "main");
    defer other.cwd.?.close(testing.io);
    const common = try repo.git.output(
        &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" },
    );
    defer testing.allocator.free(common);
    const path = try std.fs.path.join(testing.allocator, &.{ common, "stakrr.lock" });
    defer testing.allocator.free(path);
    const guard = try std.Io.Dir.cwd().createFile(testing.io, path, .{
        .truncate = false,
        .lock = .exclusive,
    });
    defer guard.close(testing.io);
    try testing.expectError(error.MutationInProgress, edit.run(&repo.git, .{ .jump = "models" }));
    try testing.expectError(error.MutationInProgress, stack.reset(&other, .{ .delete_layers = true }));
    try testing.expectError(error.MutationInProgress, stack.cut(&repo.git, "new", null));
    try noSession(&repo);
}

test "editing a top cut also moves coincident rolling work and returns to a layer origin" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try stack.cut(&repo.git, "tail", null);
    try repo.exec(&.{ "switch", "-q", "stakrr/models" });
    try edit.run(&repo.git, .{ .jump = "tail" });
    try repo.write("tail", "amended tail\n");
    try repo.exec(&.{ "add", "tail" });
    try repo.exec(&.{ "commit", "-q", "--amend", "--no-edit" });
    const amended = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(amended);
    try edit.run(&repo.git, .{ .jump = null });
    try repo.expectRef("work", amended);
    try repo.expectRef(layout.tip_ref, amended);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 0), snapshot.unstacked_commits);
}

test "ignored files that a checkout would overwrite remain intact" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.exec(&.{ "config", "--local", "core.excludesFile", ".git/info/exclude" });
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write(".git/info/exclude", "tail\n");
    try repo.write("tail", "precious ignored work\n");
    try testing.expectError(error.GitFailed, edit.run(&repo.git, .{ .jump = null }));
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    const contents = try repo.tmp.dir.readFileAlloc(testing.io, "tail", testing.allocator, .limited(1024));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("precious ignored work\n", contents);
}

test "replay preserves ignored files and directory contents before writing incoming paths" {
    for ([_]bool{ false, true }) |directory| {
        var repo = try Repo.init();
        defer repo.deinit();
        try setup(&repo);
        try edit.run(&repo.git, .{ .jump = "models" });
        try repo.write("model", "fixed\n");
        try repo.commitAll("correction");
        try repo.write(".git/info/exclude", "tail\nunrelated\n");
        if (directory) try repo.tmp.dir.createDir(testing.io, "tail", .default_dir);
        const path = if (directory) "tail/precious\nfile" else "tail";
        try repo.write(path, "precious ignored work\n");
        try repo.write("unrelated", "unrelated ignored work\n");
        // Invoke below the root while the threatened files live outside cwd.
        try repo.tmp.dir.createDir(testing.io, "subdir", .default_dir);
        const subdir = try repo.tmp.dir.openDir(testing.io, "subdir", .{});
        defer subdir.close(testing.io);
        const root = repo.git.cwd;
        repo.git.cwd = subdir;
        defer repo.git.cwd = root;
        const work = try repo.git.resolveCommit("work");
        defer testing.allocator.free(work);
        try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
        try repo.expectRef("work", work);
        const contents = try repo.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("precious ignored work\n", contents);
        try repo.tmp.dir.deleteFile(testing.io, path);
        if (directory) try repo.tmp.dir.deleteDir(testing.io, "tail");
        try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
        try repo.tmp.dir.deleteFile(testing.io, "unrelated");
        try edit.run(&repo.git, .{ .jump = null });
        try repo.expectOutput(&.{ "show", "work:tail" }, "rolling");

        try valid(&repo);
        try noSession(&repo);
    }
}

test "conflict continuation rejects untracked files outside the current directory" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try repo.write("precious", "untracked work\n");
    try repo.tmp.dir.createDir(testing.io, "subdir", .default_dir);
    const subdir = try repo.tmp.dir.openDir(testing.io, "subdir", .{});
    defer subdir.close(testing.io);
    const root = repo.git.cwd;
    repo.git.cwd = subdir;
    defer repo.git.cwd = root;
    const head = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(head);
    const picking = try repo.git.resolveCommit("CHERRY_PICK_HEAD");
    defer testing.allocator.free(picking);
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .continue_edit));
    try repo.expectRef("HEAD", head);
    try repo.expectRef("CHERRY_PICK_HEAD", picking);
    try repo.tmp.dir.deleteFile(testing.io, "precious");
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}

test "directory rename replay refuses ignored merge destinations before detaching" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.exec(&.{ "config", "merge.directoryRenames", "true" });
    try repo.write(".gitignore", "new/b\n");
    try repo.commitAll("base");
    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");
    try repo.tmp.dir.createDir(testing.io, "old", .default_dir);
    try repo.write("old/a", "a\n");
    try repo.commitAll("layer");
    try stack.cut(&repo.git, "one", null);
    try repo.write("old/b", "incoming\n");
    try repo.commitAll("tail");
    try edit.run(&repo.git, .{ .jump = "one" });
    try repo.exec(&.{ "mv", "old", "new" });
    try repo.commitAll("rename directory");
    try repo.write("new/b", "precious ignored data\n");
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
    try repo.expectOutput(&.{"show-ref"}, refs);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/one");
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, "");
    const contents = try repo.tmp.dir.readFileAlloc(testing.io, "new/b", testing.allocator, .limited(1024));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("precious ignored data\n", contents);
    try repo.tmp.dir.deleteFile(testing.io, "new/b");
    try edit.run(&repo.git, .{ .jump = null });
    try repo.expectOutput(&.{ "show", "work:new/b" }, "incoming");
    try noSession(&repo);
}

test "unchanged cuts can navigate with unrelated ignored files" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.write(".git/info/exclude", "unrelated\n");
    try repo.write("unrelated", "ignored\n");
    try edit.run(&repo.git, .{ .jump = "models" });
    try edit.run(&repo.git, .{ .jump = "api" });
    try edit.run(&repo.git, .{ .jump = null });
    try noSession(&repo);
}

test "a clean empty conflict resolution can abort without discarding work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
}

test "a later edit below an incorporated upper correction preserves both" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "api" });
    try repo.write("api", "corrected api\n");
    try repo.commitAll("fix api");
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("model", "corrected model\n");
    try repo.commitAll("fix models");
    try edit.run(&repo.git, .{ .jump = null });
    try repo.expectOutput(&.{ "show", "work:model" }, "corrected model");
    try repo.expectOutput(&.{ "show", "work:api" }, "corrected api");
    try repo.expectOutput(
        &.{ "log", "--format=%s", "--reverse", "main..work" },
        "models\nfix models\napi\ndelete obsolete\nfix api\nrolling",
    );
    try valid(&repo);
}

test "modify delete conflict can resolve to a deletion without resurrecting the file" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("obsolete", "corrected then deleted\n");
    try repo.commitAll("correct obsolete");
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "rm", "obsolete" });
    try edit.run(&repo.git, .continue_edit);
    const result = try repo.git.run(&.{ "cat-file", "-e", "work:obsolete" });
    defer repo.git.freeResult(result);
    try testing.expect(!result.term.success());
    try valid(&repo);
}
