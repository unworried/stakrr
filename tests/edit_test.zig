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
const correctModels = fixture.correctModels;

test "restack without new commits changes nothing" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    var before = try repo.git.listRefs("refs/heads/stakrr/");
    defer before.deinit(testing.allocator);
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try testing.expectError(error.NothingToRestack, edit.run(&repo.git, .restack));
    try testing.expectError(error.NoEditSession, edit.run(&repo.git, .continue_edit));
    try testing.expectError(error.NoEditSession, edit.run(&repo.git, .abort));
    try testing.expectError(error.UnknownCut, stack.go(&repo.git, "missing"));
    try stack.go(&repo.git, "api");
    try testing.expectError(error.NothingToRestack, edit.run(&repo.git, .restack));
    var after = try repo.git.listRefs("refs/heads/stakrr/");
    defer after.deinit(testing.allocator);
    try testing.expectEqualStrings(before.raw, after.raw);
    try repo.expectRef("work", work);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/api");
    try noSession(&repo);
}

test "correction commits replay in order and preserve upper deletions and rolling work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try on(&repo, "models");
    try repo.write("model", "fixed\n");
    try repo.commitAll("fix validation");
    const correction = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(correction);
    try repo.exec(&.{ "switch", "-q", "work" });
    try edit.run(&repo.git, .restack);
    try repo.expectRef("stakrr/models", correction);
    try repo.expectOutput(&.{ "show", "stakrr/api:model" }, "fixed");
    const deleted = try repo.git.run(&.{ "cat-file", "-e", "stakrr/api:obsolete" });
    defer repo.git.freeResult(deleted);
    try testing.expect(!deleted.term.success());
    try on(&repo, "api");
    try repo.write("api", "corrected api\n");
    try repo.commitAll("correct api");
    try repo.exec(&.{ "switch", "-q", "work" });
    try edit.run(&repo.git, .restack);
    try repo.expectOutput(
        &.{ "log", "--format=%s", "--reverse", "main..work" },
        "models\nfix validation\napi\ndelete obsolete\ncorrect api\nrolling",
    );
    try repo.expectOutput(&.{ "show", "work:tail" }, "rolling");
    try repo.expectOutput(&.{ "show", "work:api" }, "corrected api");
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try valid(&repo);
    try noSession(&repo);
}

test "amend of a cut survives replay in sha1 and sha256 repositories" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        try on(&repo, "models");
        try repo.write("model", "amended\n");
        try repo.exec(&.{ "add", "model" });
        try repo.exec(&.{ "commit", "-q", "--amend", "--no-edit" });
        const amended = try repo.git.resolveCommit("HEAD");
        defer testing.allocator.free(amended);
        try edit.run(&repo.git, .restack);
        try repo.expectRef("stakrr/models", amended);
        try repo.expectOutput(&.{ "show", "work:model" }, "amended");
        // restacking from the edited layer leaves it checked out
        try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
        try valid(&repo);
        try noSession(&repo);
    }
}

test "abort restores the initial stack and retains the edited commit" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const edited = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(edited);
    const recorded = try repo.git.resolveCommit(layout.record_prefix ++ "models");
    defer testing.allocator.free(recorded);
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    var layers = try repo.git.listRefs("refs/stakrr/layers/");
    defer layers.deinit(testing.allocator);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
    // the stack is back at its recorded positions; the layer's new commit stays
    // reachable through the operation log
    try repo.expectRef("stakrr/models", recorded);
    try repo.expectRef("work", work);
    var after = try repo.git.listRefs("refs/stakrr/layers/");
    defer after.deinit(testing.allocator);
    try testing.expectEqualStrings(layers.raw, after.raw);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    try expectRecoverable(&repo, edited);
    try noSession(&repo);
    try valid3(&repo);
}

fn valid3(repo: *const Repo) !void {
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    for (snapshot.layers) |layer| try testing.expect(!layer.stale());
}

test "dirty work is never stashed committed or discarded by a restack" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try correctModels(&repo);
    try repo.write("untracked", "precious\n");
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .restack));
    try noSession(&repo);
    try repo.exec(&.{ "add", "untracked" });
    const before = try repo.git.output(&.{ "status", "--porcelain=v1" });
    defer testing.allocator.free(before);
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .restack));
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, before);
    try repo.expectOutput(&.{ "show", ":untracked" }, "precious");
}

test "a conflicted replay waits for a staged resolution and continues it" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const old_work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(old_work);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.expectRef("work", old_work); // no partial publication
    try testing.expectError(error.EditInProgress, edit.run(&repo.git, .restack));
    try testing.expectError(error.DirtyWorkTree, edit.run(&repo.git, .abort));
    var session_status = (try edit.readStatus(&repo.git)).?;
    defer session_status.deinit();
    try testing.expectEqual(.conflict, session_status.phase);
    try testing.expectEqualStrings(
        "refs/heads/stakrr/models",
        session_status.branches[session_status.active],
    );
    try testing.expectEqualStrings("refs/heads/stakrr/models", session_status.destination);
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .continue_edit);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    try repo.expectOutput(&.{ "show", "work:shared" }, "resolved");
    try noSession(&repo);
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, "");
}

test "abort after a conflict preserves committed resolutions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.write("shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try repo.exec(&.{ "commit", "-q", "--no-edit" });
    const resolution = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(resolution);
    try edit.run(&repo.git, .abort);
    try expectRecoverable(&repo, resolution);
    try noSession(&repo);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
}

test "empty conflict resolutions are retained as commits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .continue_edit);
    try repo.expectOutput(&.{ "show", "work:shared" }, "edited");
    try noSession(&repo);
}

test "a pending restack rejects every competing stakrr mutation" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try testing.expectError(error.EditInProgress, stack.cut(&repo.git, "new", null));
    try testing.expectError(error.EditInProgress, stack.reset(&repo.git, .{ .delete_layers = true }));
    try testing.expectError(error.EditInProgress, stack.initStack(&repo.git, "main"));
    try testing.expectError(error.EditInProgress, stack.go(&repo.git, "api"));
    try testing.expectError(error.EditInProgress, stack.navigate(&repo.git, .up));
    try testing.expectError(error.EditInProgress, edit.undo(&repo.git));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
}

test "an invalid edited history is rejected without a session" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try on(&repo, "models");
    try repo.exec(&.{ "reset", "-q", "--hard", "main" });
    try testing.expectError(error.InvalidEditedHistory, edit.run(&repo.git, .restack));
    try noSession(&repo);
    try valid(&repo);
}

test "two changed layers are refused until only one differs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try on(&repo, "models");
    try repo.write("model", "one\n");
    try repo.commitAll("one");
    try on(&repo, "api");
    try repo.write("api", "two\n");
    try repo.commitAll("two");
    try testing.expectError(error.MultipleStaleLayers, edit.run(&repo.git, .restack));
    try noSession(&repo);
}

test "refs changed during a conflict are rejected and named" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try testing.expect(try edit.findDrift(&repo.git) == null);
    const api = try repo.git.resolveCommit("stakrr/api");
    defer testing.allocator.free(api);
    const base = try repo.git.resolveCommit("main");
    defer testing.allocator.free(base);

    try repo.exec(&.{ "branch", "-f", "stakrr/api", "main" });
    const moved = try cli.run(&repo, &.{"continue"});
    defer moved.deinit();
    try testing.expectEqual(@as(?u8, 5), moved.code);
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

    // a recorded boundary that moved is drift too
    const record = layout.record_prefix ++ "api";
    try repo.exec(&.{ "update-ref", record, base, api });
    var recorded = (try edit.findDrift(&repo.git)).?;
    defer recorded.deinit();
    try testing.expectEqualStrings(record, recorded.name);
    try testing.expectEqualStrings(api, recorded.expected.?);
    try repo.exec(&.{ "update-ref", record, api, base });

    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
    try valid3(&repo);
}

test "linked worktree occupancy is checked before starting" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const path = "linked space\nnewline";
    const other = try linked(&repo, path, "stakrr/api");
    defer other.cwd.?.close(testing.io);
    try correctModels(&repo);
    const work = try repo.git.resolveCommit("work");
    defer testing.allocator.free(work);
    try testing.expectError(error.BranchOccupied, edit.run(&repo.git, .restack));
    try noSession(&repo);
    try repo.expectRef("work", work);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .restack);
    try valid(&repo);
}

test "sessions belong to one worktree and share the mutation guard" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const other = try linked(&repo, "linked", "main");
    defer other.cwd.?.close(testing.io);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try testing.expectError(error.WrongEditWorktree, edit.run(&other, .abort));
    try testing.expectError(error.WrongEditWorktree, edit.run(&other, .continue_edit));
    try testing.expectError(error.WrongEditWorktree, edit.run(&other, .quit));
    try testing.expectError(error.EditInProgress, stack.navigate(&other, .up));
    try testing.expectError(error.EditInProgress, stack.reset(&other, .{}));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
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
    try testing.expectError(error.MutationInProgress, edit.run(&repo.git, .restack));
    try testing.expectError(error.MutationInProgress, stack.reset(&other, .{ .delete_layers = true }));
    try testing.expectError(error.MutationInProgress, stack.cut(&repo.git, "new", null));
    try noSession(&repo);
}

test "restacking a top cut also moves coincident rolling work and returns to its origin" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try stack.cut(&repo.git, "tail", null);
    try on(&repo, "tail");
    try repo.write("tail", "amended tail\n");
    try repo.exec(&.{ "add", "tail" });
    try repo.exec(&.{ "commit", "-q", "--amend", "--no-edit" });
    const amended = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(amended);
    try on(&repo, "models");
    try edit.run(&repo.git, .restack);
    try repo.expectRef("work", amended);
    try repo.expectRef(layout.tip_ref, amended);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 0), snapshot.unstacked_commits);
    try testing.expect(!snapshot.layers[2].stale());
}

test "navigation refuses to overwrite ignored files" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.exec(&.{ "config", "--local", "core.excludesFile", ".git/info/exclude" });
    try on(&repo, "models");
    try repo.write(".git/info/exclude", "tail\n");
    try repo.write("tail", "precious ignored work\n");
    try testing.expect(try stack.navigate(&repo.git, .up));
    try testing.expectError(error.GitFailed, stack.navigate(&repo.git, .up));
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/api");
    const contents = try repo.tmp.dir.readFileAlloc(testing.io, "tail", testing.allocator, .limited(1024));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("precious ignored work\n", contents);
}

test "replay preserves ignored files and directory contents before writing incoming paths" {
    for ([_]bool{ false, true }) |directory| {
        var repo = try Repo.init();
        defer repo.deinit();
        try setup(&repo);
        // stay on models, where the rolling-only `tail` is not a tracked path
        try on(&repo, "models");
        try repo.write("model", "corrected\n");
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
        try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .restack));
        try repo.expectRef("work", work);
        try noSession(&repo);
        const contents = try repo.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("precious ignored work\n", contents);
        try repo.tmp.dir.deleteFile(testing.io, path);
        if (directory) try repo.tmp.dir.deleteDir(testing.io, "tail");
        try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .restack));
        try repo.tmp.dir.deleteFile(testing.io, "unrelated");
        try edit.run(&repo.git, .restack);
        try repo.expectOutput(&.{ "show", "work:tail" }, "rolling");

        try valid(&repo);
        try noSession(&repo);
    }
}

test "conflict continuation rejects untracked files outside the current directory" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
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
    try on(&repo, "one");
    try repo.exec(&.{ "mv", "old", "new" });
    try repo.commitAll("rename directory");
    try repo.exec(&.{ "switch", "-q", "work" });
    try repo.tmp.dir.createDir(testing.io, "new", .default_dir);
    try repo.write("new/b", "precious ignored data\n");
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    try testing.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .restack));
    try repo.expectOutput(&.{"show-ref"}, refs);
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try repo.expectOutput(&.{ "status", "--porcelain=v1" }, "");
    const contents = try repo.tmp.dir.readFileAlloc(testing.io, "new/b", testing.allocator, .limited(1024));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("precious ignored data\n", contents);
    try repo.tmp.dir.deleteFile(testing.io, "new/b");
    try edit.run(&repo.git, .restack);
    try repo.expectOutput(&.{ "show", "work:new/b" }, "incoming");
    try noSession(&repo);
}

test "navigation works with unrelated ignored files" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.write(".git/info/exclude", "unrelated\n");
    try repo.write("unrelated", "ignored\n");
    try stack.go(&repo.git, "models");
    try stack.go(&repo.git, "api");
    try testing.expect(try stack.navigate(&repo.git, .up));
    try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try noSession(&repo);
}

test "a clean empty conflict resolution can abort without discarding work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
}

test "a later change below an earlier upper correction preserves both" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try on(&repo, "api");
    try repo.write("api", "corrected api\n");
    try repo.commitAll("fix api");
    try repo.exec(&.{ "switch", "-q", "work" });
    try edit.run(&repo.git, .restack);
    try on(&repo, "models");
    try repo.write("model", "corrected model\n");
    try repo.commitAll("fix models");
    try repo.exec(&.{ "switch", "-q", "work" });
    try edit.run(&repo.git, .restack);
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
    try on(&repo, "models");
    try repo.write("obsolete", "corrected then deleted\n");
    try repo.commitAll("correct obsolete");
    try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
    try repo.exec(&.{ "rm", "obsolete" });
    try edit.run(&repo.git, .continue_edit);
    const result = try repo.git.run(&.{ "cat-file", "-e", "work:obsolete" });
    defer repo.git.freeResult(result);
    try testing.expect(!result.term.success());
    try valid(&repo);
}
