const std = @import("std");
const layout = @import("stakrr").layout;
const t = std.testing;
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const edit = stakrr.edit;
const Repo = @import("support/repo.zig").Repo;

fn write(repo: *const Repo, path: []const u8, data: []const u8) !void {
    try repo.tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = data });
}
fn commit(repo: *const Repo, message: []const u8) !void {
    try repo.exec(&.{ "add", "-A" });
    const oid = try repo.commit(message);
    t.allocator.free(oid);
}
fn setup(repo: *const Repo) !void {
    try write(repo, "shared", "base\n");
    try commit(repo, "base");
    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");
    try write(repo, "model", "original\n");
    try write(repo, "obsolete", "delete me\n");
    try commit(repo, "models");
    try stack.cut(&repo.git, "models", null);
    try write(repo, "api", "api\n");
    try commit(repo, "api");
    try repo.exec(&.{ "rm", "-q", "obsolete" });
    try commit(repo, "delete obsolete");
    try stack.cut(&repo.git, "api", null);
    try write(repo, "tail", "rolling\n");
    try commit(repo, "rolling");
}
fn outputEquals(repo: *const Repo, args: []const []const u8, expected: []const u8) !void {
    const actual = try repo.git.output(args);
    defer t.allocator.free(actual);
    try t.expectEqualStrings(expected, actual);
}
fn refEquals(repo: *const Repo, ref: []const u8, expected: []const u8) !void {
    try outputEquals(repo, &.{ "rev-parse", ref }, expected);
}
fn noSession(repo: *const Repo) !void {
    const session = try repo.git.readRef(layout.session_ref);
    defer if (session) |oid| t.allocator.free(oid);
    try t.expect(session == null);
}
fn expectRecoverable(repo: *const Repo, oid: []const u8) !void {
    const refs = try repo.git.output(
        &.{ "for-each-ref", "--format=%(objectname)", layout.recovery_prefix },
    );
    defer t.allocator.free(refs);
    try t.expect(std.mem.indexOf(u8, refs, oid) != null);
}
fn valid(repo: *const Repo) !void {
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    try t.expectEqual(@as(usize, 2), snapshot.layers.len);
    try t.expectEqualStrings("refs/heads/stakrr/models", snapshot.layers[0].ref_name);
    try t.expectEqualStrings("refs/heads/stakrr/api", snapshot.layers[1].ref_name);
    try t.expectEqual(@as(usize, 1), snapshot.unstacked_commits);
}

test "edit unchanged cuts never replay; unknown cuts leave no session" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    var before = try repo.git.listRefs("refs/heads/stakrr/");
    defer before.deinit(t.allocator);
    const work = try repo.git.resolveCommit("work");
    defer t.allocator.free(work);
    try t.expectError(error.NoEditSession, edit.run(&repo.git, .{ .jump = null }));
    try t.expectError(error.NoEditSession, edit.run(&repo.git, .continue_edit));
    try t.expectError(error.UnknownCut, edit.run(&repo.git, .{ .jump = "missing" }));
    try noSession(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try t.expectError(error.UnknownCut, edit.run(&repo.git, .{ .jump = "missing" }));
    try t.expectError(error.NoPendingEdit, edit.run(&repo.git, .continue_edit));
    try edit.run(&repo.git, .{ .jump = "api" });
    try edit.run(&repo.git, .{ .jump = null });
    var after = try repo.git.listRefs("refs/heads/stakrr/");
    defer after.deinit(t.allocator);
    try t.expectEqualStrings(before.raw, after.raw);
    try refEquals(&repo, "work", work);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try noSession(&repo);
}

test "correction commits replay in order and preserve upper deletions and rolling work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "fixed\n");
    try commit(&repo, "fix validation");
    const correction = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(correction);
    try edit.run(&repo.git, .{ .jump = "api" });
    try refEquals(&repo, "stakrr/models", correction);
    try outputEquals(&repo, &.{ "show", "HEAD:model" }, "fixed");
    const deleted = try repo.git.run(&.{ "cat-file", "-e", "HEAD:obsolete" });
    defer repo.git.freeResult(deleted);
    try t.expect(!deleted.term.success());
    try write(&repo, "api", "corrected api\n");
    try commit(&repo, "correct api");
    try edit.run(&repo.git, .{ .jump = null });
    try outputEquals(
        &repo,
        &.{ "log", "--format=%s", "--reverse", "main..work" },
        "models\nfix validation\napi\ndelete obsolete\ncorrect api\nrolling",
    );
    try outputEquals(&repo, &.{ "show", "work:tail" }, "rolling");
    try outputEquals(&repo, &.{ "show", "work:api" }, "corrected api");
    try valid(&repo);
    try noSession(&repo);
}

test "amend of a cut survives replay in sha1 and sha256 repositories" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        try edit.run(&repo.git, .{ .jump = "models" });
        try write(&repo, "model", "amended\n");
        try repo.exec(&.{ "add", "model" });
        try repo.exec(&.{ "commit", "-q", "--amend", "--no-edit" });
        const amended = try repo.git.resolveCommit("HEAD");
        defer t.allocator.free(amended);
        try edit.run(&repo.git, .{ .jump = null });
        try refEquals(&repo, "stakrr/models", amended);
        try outputEquals(&repo, &.{ "show", "work:model" }, "amended");
        try valid(&repo);
        try noSession(&repo);
    }
}

test "abort restores the initial stack across multiple incorporated jumps and retains edits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    var initial = try repo.git.listRefs("refs/heads/stakrr/");
    defer initial.deinit(t.allocator);
    const work = try repo.git.resolveCommit("work");
    defer t.allocator.free(work);
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "edit 1\n");
    try commit(&repo, "edit 1");
    const first = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(first);
    try edit.run(&repo.git, .{ .jump = "api" });
    try write(&repo, "api", "edit 2\n");
    try commit(&repo, "edit 2");
    const second = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(second);
    try edit.run(&repo.git, .abort);
    var actual = try repo.git.listRefs("refs/heads/stakrr/");
    defer actual.deinit(t.allocator);
    try t.expectEqualStrings(initial.raw, actual.raw);
    try refEquals(&repo, "work", work);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
    try expectRecoverable(&repo, first);
    try expectRecoverable(&repo, second);
    try valid(&repo);
    try noSession(&repo);
}

test "dirty work is never stashed committed or discarded by transitions or abort" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try write(&repo, "untracked", "precious\n");
    try t.expectError(error.DirtyWorkTree, edit.run(&repo.git, .{ .jump = "models" }));
    try noSession(&repo);
    try commit(&repo, "save untracked");
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "precious\n");
    try repo.exec(&.{ "add", "model" });
    const before = try repo.git.output(&.{ "status", "--porcelain=v1" });
    defer t.allocator.free(before);
    try t.expectError(error.DirtyWorkTree, edit.run(&repo.git, .{ .jump = "api" }));
    try t.expectError(error.DirtyWorkTree, edit.run(&repo.git, .abort));
    try outputEquals(&repo, &.{ "status", "--porcelain=v1" }, before);
    try outputEquals(&repo, &.{ "show", ":model" }, "precious");
}

fn conflictSetup(repo: *const Repo) !void {
    try setup(repo);
    // Add a top cut changing a line also changed by the edit below it.
    try write(repo, "shared", "upper\n");
    try commit(repo, "upper shared");
    try stack.cut(&repo.git, "conflict", null);
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(repo, "shared", "edited\n");
    try commit(repo, "edit shared");
}

test "conflicted replay persists destination and continues a staged resolution" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const old_work = try repo.git.resolveCommit("work");
    defer t.allocator.free(old_work);
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = "api" }));
    try refEquals(&repo, "work", old_work); // no partial publication
    try t.expectError(error.EditNeedsContinue, edit.run(&repo.git, .{ .jump = null }));
    try t.expectError(error.DirtyWorkTree, edit.run(&repo.git, .abort));
    var session_status = (try edit.readStatus(&repo.git)).?;
    defer session_status.deinit();
    try t.expectEqual(.conflict, session_status.phase);
    try t.expectEqualStrings(
        "refs/heads/stakrr/models",
        session_status.branches[session_status.active],
    );
    try t.expectEqualStrings("refs/heads/stakrr/api", session_status.destination);
    try write(&repo, "shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .continue_edit);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/api");
    try outputEquals(&repo, &.{ "show", "work:shared" }, "resolved");
    try edit.run(&repo.git, .{ .jump = null });
    try noSession(&repo);
}

test "abort after a conflict preserves committed resolutions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try write(&repo, "shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try repo.exec(&.{ "commit", "-q", "--no-edit" });
    const resolution = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(resolution);
    try edit.run(&repo.git, .abort);
    try expectRecoverable(&repo, resolution);
    try noSession(&repo);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
}

test "empty conflict resolutions are retained as commits" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .continue_edit);
    try outputEquals(&repo, &.{ "show", "work:shared" }, "edited");
    try noSession(&repo);
}

test "active sessions reject every competing stakrr mutation" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try t.expectError(error.EditInProgress, stack.cut(&repo.git, "new", null));
    try t.expectError(error.EditInProgress, stack.reset(&repo.git, .{ .delete_layers = true }));
    try t.expectError(error.EditInProgress, stack.initStack(&repo.git, "main"));
    try t.expectError(error.EditInProgress, stack.navigate(&repo.git, .up));
    try t.expectError(error.EditInProgress, stack.navigate(&repo.git, .down));
    try edit.run(&repo.git, .abort);
}

test "external changes to nonactive refs and invalid edited histories are rejected" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.exec(&.{ "branch", "-f", "stakrr/api", "main" });
    try t.expectError(error.EditStateChanged, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "branch", "-f", "stakrr/api", layout.tip_ref });
    try repo.exec(&.{ "reset", "--hard", "main" });
    try t.expectError(error.InvalidEditedHistory, edit.run(&repo.git, .{ .jump = null }));
    try edit.run(&repo.git, .abort);
    try valid(&repo);
}

fn linked(repo: *const Repo, path: []const u8, branch: []const u8) !stakrr.git.Git {
    const metadata_path = try std.fmt.allocPrint(t.allocator, ".git/{s}", .{path});
    defer t.allocator.free(metadata_path);
    try repo.exec(&.{ "worktree", "add", "-q", metadata_path, branch });
    const dir = try repo.tmp.dir.openDir(t.io, metadata_path, .{});
    var git = repo.git;
    git.cwd = dir;
    return git;
}

test "linked worktree occupancy is checked before starting and before publishing" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const path = "linked space\nnewline";
    const other = try linked(&repo, path, "stakrr/api");
    defer other.cwd.?.close(t.io);
    try t.expectError(error.BranchOccupied, edit.run(&repo.git, .{ .jump = "models" }));
    try noSession(&repo);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "fixed\n");
    try commit(&repo, "correction");
    try other.exec(&.{ "switch", "-q", "stakrr/api" });
    const work = try repo.git.resolveCommit("work");
    defer t.allocator.free(work);
    try t.expectError(error.BranchOccupied, edit.run(&repo.git, .{ .jump = null }));
    try refEquals(&repo, "work", work);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .{ .jump = null });
    try valid(&repo);
}

test "sessions belong to one worktree and share the mutation guard" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const other = try linked(&repo, "linked", "main");
    defer other.cwd.?.close(t.io);
    try edit.run(&repo.git, .{ .jump = "models" });
    try t.expectError(error.WrongEditWorktree, edit.run(&other, .abort));
    try t.expectError(error.WrongEditWorktree, edit.run(&other, .continue_edit));
    try t.expectError(error.EditInProgress, stack.reset(&other, .{}));
    try edit.run(&repo.git, .abort);
}

test "the common directory lock excludes mutations from every worktree" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const other = try linked(&repo, "linked", "main");
    defer other.cwd.?.close(t.io);
    const common = try repo.git.output(
        &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" },
    );
    defer t.allocator.free(common);
    const path = try std.fs.path.join(t.allocator, &.{ common, "stakrr.lock" });
    defer t.allocator.free(path);
    const guard = try std.Io.Dir.cwd().createFile(t.io, path, .{
        .truncate = false,
        .lock = .exclusive,
    });
    defer guard.close(t.io);
    try t.expectError(error.MutationInProgress, edit.run(&repo.git, .{ .jump = "models" }));
    try t.expectError(error.MutationInProgress, stack.reset(&other, .{ .delete_layers = true }));
    try t.expectError(error.MutationInProgress, stack.cut(&repo.git, "new", null));
    try noSession(&repo);
}

test "editing a top cut also moves coincident rolling work and returns to a layer origin" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try stack.cut(&repo.git, "tail", null);
    try repo.exec(&.{ "switch", "-q", "stakrr/models" });
    try edit.run(&repo.git, .{ .jump = "tail" });
    try write(&repo, "tail", "amended tail\n");
    try repo.exec(&.{ "add", "tail" });
    try repo.exec(&.{ "commit", "-q", "--amend", "--no-edit" });
    const amended = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(amended);
    try edit.run(&repo.git, .{ .jump = null });
    try refEquals(&repo, "work", amended);
    try refEquals(&repo, layout.tip_ref, amended);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    try t.expectEqual(@as(usize, 0), snapshot.unstacked_commits);
}

test "ignored files that a checkout would overwrite remain intact" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.exec(&.{ "config", "--local", "core.excludesFile", ".git/info/exclude" });
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, ".git/info/exclude", "tail\n");
    try write(&repo, "tail", "precious ignored work\n");
    try t.expectError(error.GitFailed, edit.run(&repo.git, .{ .jump = null }));
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    const contents = try repo.tmp.dir.readFileAlloc(t.io, "tail", t.allocator, .limited(1024));
    defer t.allocator.free(contents);
    try t.expectEqualStrings("precious ignored work\n", contents);
}

test "replay preserves ignored files and directory contents before writing incoming paths" {
    for ([_]bool{ false, true }) |directory| {
        var repo = try Repo.init();
        defer repo.deinit();
        try setup(&repo);
        try edit.run(&repo.git, .{ .jump = "models" });
        try write(&repo, "model", "fixed\n");
        try commit(&repo, "correction");
        try write(&repo, ".git/info/exclude", "tail\nunrelated\n");
        if (directory) try repo.tmp.dir.createDir(t.io, "tail", .default_dir);
        const path = if (directory) "tail/precious\nfile" else "tail";
        try write(&repo, path, "precious ignored work\n");
        try write(&repo, "unrelated", "unrelated ignored work\n");
        // Invoke below the root while the threatened files live outside cwd.
        try repo.tmp.dir.createDir(t.io, "subdir", .default_dir);
        const subdir = try repo.tmp.dir.openDir(t.io, "subdir", .{});
        defer subdir.close(t.io);
        const root = repo.git.cwd;
        repo.git.cwd = subdir;
        defer repo.git.cwd = root;
        const work = try repo.git.resolveCommit("work");
        defer t.allocator.free(work);
        try t.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
        try refEquals(&repo, "work", work);
        const contents = try repo.tmp.dir.readFileAlloc(t.io, path, t.allocator, .limited(1024));
        defer t.allocator.free(contents);
        try t.expectEqualStrings("precious ignored work\n", contents);
        try repo.tmp.dir.deleteFile(t.io, path);
        if (directory) try repo.tmp.dir.deleteDir(t.io, "tail");
        try t.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
        try repo.tmp.dir.deleteFile(t.io, "unrelated");
        try edit.run(&repo.git, .{ .jump = null });
        try outputEquals(&repo, &.{ "show", "work:tail" }, "rolling");

        try valid(&repo);
        try noSession(&repo);
    }
}

test "conflict continuation rejects untracked files outside the current directory" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try write(&repo, "shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try write(&repo, "precious", "untracked work\n");
    try repo.tmp.dir.createDir(t.io, "subdir", .default_dir);
    const subdir = try repo.tmp.dir.openDir(t.io, "subdir", .{});
    defer subdir.close(t.io);
    const root = repo.git.cwd;
    repo.git.cwd = subdir;
    defer repo.git.cwd = root;
    const head = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(head);
    const picking = try repo.git.resolveCommit("CHERRY_PICK_HEAD");
    defer t.allocator.free(picking);
    try t.expectError(error.DirtyWorkTree, edit.run(&repo.git, .continue_edit));
    try refEquals(&repo, "HEAD", head);
    try refEquals(&repo, "CHERRY_PICK_HEAD", picking);
    try repo.tmp.dir.deleteFile(t.io, "precious");
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}

test "directory rename replay refuses ignored merge destinations before detaching" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.exec(&.{ "config", "merge.directoryRenames", "true" });
    try write(&repo, ".gitignore", "new/b\n");
    try commit(&repo, "base");
    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");
    try repo.tmp.dir.createDir(t.io, "old", .default_dir);
    try write(&repo, "old/a", "a\n");
    try commit(&repo, "layer");
    try stack.cut(&repo.git, "one", null);
    try write(&repo, "old/b", "incoming\n");
    try commit(&repo, "tail");
    try edit.run(&repo.git, .{ .jump = "one" });
    try repo.exec(&.{ "mv", "old", "new" });
    try commit(&repo, "rename directory");
    try write(&repo, "new/b", "precious ignored data\n");
    const refs = try repo.git.output(&.{"show-ref"});
    defer t.allocator.free(refs);
    try t.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
    try outputEquals(&repo, &.{"show-ref"}, refs);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/one");
    try outputEquals(&repo, &.{ "status", "--porcelain=v1" }, "");
    const contents = try repo.tmp.dir.readFileAlloc(t.io, "new/b", t.allocator, .limited(1024));
    defer t.allocator.free(contents);
    try t.expectEqualStrings("precious ignored data\n", contents);
    try repo.tmp.dir.deleteFile(t.io, "new/b");
    try edit.run(&repo.git, .{ .jump = null });
    try outputEquals(&repo, &.{ "show", "work:new/b" }, "incoming");
    try noSession(&repo);
}

test "unchanged cuts can navigate with unrelated ignored files" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try write(&repo, ".git/info/exclude", "unrelated\n");
    try write(&repo, "unrelated", "ignored\n");
    try edit.run(&repo.git, .{ .jump = "models" });
    try edit.run(&repo.git, .{ .jump = "api" });
    try edit.run(&repo.git, .{ .jump = null });
    try noSession(&repo);
}

fn cli(repo: *const Repo, args: []const []const u8) !std.process.RunResult {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(t.io, @import("cli_options").exe_path, t.allocator);
    defer t.allocator.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.append(t.allocator, exe);
    try argv.appendSlice(t.allocator, args);
    return std.process.run(t.allocator, t.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = repo.tmp.dir },
        .environ_map = repo.env,
    });
}

fn installFaultShim(repo: *const Repo) !void {
    const result = try std.process.run(t.allocator, t.io, .{
        .argv = &.{ "/bin/sh", "-c", "command -v git" },
        .environ_map = repo.env,
    });
    defer repo.git.freeResult(result);
    try t.expect(result.term.success());
    try repo.env.put("STAKRR_TEST_GIT", std.mem.trimEnd(u8, result.stdout, "\r\n"));
    try repo.tmp.dir.createDir(t.io, ".git/test-bin", .default_dir);
    try repo.tmp.dir.writeFile(t.io, .{
        .sub_path = ".git/test-bin/git",
        .data = @embedFile("support/git_fault.sh"),
        .flags = .{ .permissions = .executable_file },
    });
    const dir = try repo.tmp.dir.realPathFileAlloc(t.io, ".git/test-bin", t.allocator);
    defer t.allocator.free(dir);
    const path = try std.fmt.allocPrint(t.allocator, "{s}:{s}", .{ dir, repo.env.get("PATH").? });
    defer t.allocator.free(path);
    try repo.env.put("PATH", path);
    try repo.env.put("STAKRR_TEST_COUNTER", ".git/test-fault-count");
}

fn assertCliSuccess(repo: *const Repo, args: []const []const u8) !void {
    const result = try cli(repo, args);
    defer repo.git.freeResult(result);
    if (!result.term.success()) std.debug.print("stakrr stderr: {s}\n", .{result.stderr});
    try t.expect(result.term.success());
}

test "replay resumes after process death on either side of every ref checkpoint" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for (1..8) |checkpoint| {
            var repo = try Repo.init();
            defer repo.deinit();
            try setup(&repo);
            try edit.run(&repo.git, .{ .jump = "models" });
            try write(&repo, "model", "fixed\n");
            try commit(&repo, "correction");
            try installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(t.allocator, "{s}:{d}", .{ side, checkpoint });
            defer t.allocator.free(fault);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const killed = try cli(&repo, &.{"edit"});
            defer repo.git.freeResult(killed);
            try t.expect(!killed.term.success());
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            if (checkpoint == 1 and std.mem.eql(u8, side, "before")) {
                try assertCliSuccess(&repo, &.{"edit"});
            } else {
                try assertCliSuccess(&repo, &.{ "edit", "--continue" });
            }
            try noSession(&repo);
            try valid(&repo);
            try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
            try outputEquals(&repo, &.{ "show", "work:model" }, "fixed");
            try outputEquals(
                &repo,
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
    try write(&repo, "model", "fixed\n");
    try commit(&repo, "correction");
    try installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "pick");
    const killed = try cli(&repo, &.{"edit"});
    defer repo.git.freeResult(killed);
    try t.expect(!killed.term.success());
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    try assertCliSuccess(&repo, &.{ "edit", "--continue" });
    try outputEquals(
        &repo,
        &.{ "log", "--format=%s", "--reverse", "main..work" },
        "models\ncorrection\napi\ndelete obsolete\nrolling",
    );
    try noSession(&repo);
}

test "conflicts continue after restarting the CLI process" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    const conflict = try cli(&repo, &.{ "edit", "api" });
    defer repo.git.freeResult(conflict);
    try t.expect(!conflict.term.success());
    const status = try cli(&repo, &.{"status"});
    defer repo.git.freeResult(status);
    try t.expect(status.term.success());
    try t.expect(std.mem.indexOf(u8, status.stdout, "models (conflict)") != null);
    try write(&repo, "shared", "resolved\n");
    try repo.exec(&.{ "add", "shared" });
    try assertCliSuccess(&repo, &.{ "edit", "--continue" });
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/api");
    try assertCliSuccess(&repo, &.{"edit"});
    try noSession(&repo);
}

test "abort and its restoration transaction resume after process death" {
    for ([_][]const u8{ "before", "after" }) |side| {
        for (1..3) |checkpoint| {
            var repo = try Repo.init();
            defer repo.deinit();
            try setup(&repo);
            var refs = try repo.git.listRefs("refs/heads/stakrr/");
            defer refs.deinit(t.allocator);
            const work = try repo.git.resolveCommit("work");
            defer t.allocator.free(work);
            try edit.run(&repo.git, .{ .jump = "models" });
            try write(&repo, "model", "edit one\n");
            try commit(&repo, "edit one");
            const first = try repo.git.resolveCommit("HEAD");
            defer t.allocator.free(first);
            try edit.run(&repo.git, .{ .jump = "api" });
            try write(&repo, "api", "edit two\n");
            try commit(&repo, "edit two");
            const second = try repo.git.resolveCommit("HEAD");
            defer t.allocator.free(second);
            try installFaultShim(&repo);
            const fault = try std.fmt.allocPrint(t.allocator, "{s}:{d}", .{ side, checkpoint });
            defer t.allocator.free(fault);
            try repo.env.put("STAKRR_TEST_FAULT", fault);
            const killed = try cli(&repo, &.{ "edit", "--abort" });
            defer repo.git.freeResult(killed);
            try t.expect(!killed.term.success());
            _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
            try assertCliSuccess(&repo, &.{ "edit", "--abort" });
            var restored = try repo.git.listRefs("refs/heads/stakrr/");
            defer restored.deinit(t.allocator);
            try t.expectEqualStrings(refs.raw, restored.raw);
            try refEquals(&repo, "work", work);
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
    defer t.allocator.free(work);
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "fixed\n");
    try commit(&repo, "correction");
    try installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:6");
    const killed = try cli(&repo, &.{"edit"});
    defer repo.git.freeResult(killed);
    try t.expect(!killed.term.success());
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    const other = try linked(&repo, "linked", "work");
    defer other.cwd.?.close(t.io);
    try t.expectError(error.BranchOccupied, edit.run(&repo.git, .continue_edit));
    try refEquals(&repo, "work", work);
    try other.exec(&.{ "switch", "-q", "--detach" });
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "a clean empty conflict resolution can abort without discarding work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
}

test "session validation rejects extra layers and corrupt checkpoints" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.exec(&.{ "branch", "stakrr/extra", "HEAD" });
    try t.expectError(error.EditStateChanged, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "branch", "-D", "stakrr/extra" });
    try edit.run(&repo.git, .abort);
    const bad = try repo.git.writeBlob("{}");
    defer t.allocator.free(bad);
    try repo.exec(&.{ "update-ref", layout.session_ref, bad });
    try t.expectError(error.InvalidEditSession, edit.run(&repo.git, .abort));
    try t.expectError(error.EditInProgress, stack.reset(&repo.git, .{ .delete_layers = true }));
}

test "a later edit below an incorporated upper correction preserves both" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "api" });
    try write(&repo, "api", "corrected api\n");
    try commit(&repo, "fix api");
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "corrected model\n");
    try commit(&repo, "fix models");
    try edit.run(&repo.git, .{ .jump = null });
    try outputEquals(&repo, &.{ "show", "work:model" }, "corrected model");
    try outputEquals(&repo, &.{ "show", "work:api" }, "corrected api");
    try outputEquals(
        &repo,
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
    try write(&repo, "obsolete", "corrected then deleted\n");
    try commit(&repo, "correct obsolete");
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "rm", "obsolete" });
    try edit.run(&repo.git, .continue_edit);
    const result = try repo.git.run(&.{ "cat-file", "-e", "work:obsolete" });
    defer repo.git.freeResult(result);
    try t.expect(!result.term.success());
    try valid(&repo);
}

test "continue and abort reject an inconsistent replay plan before changing Git state" {
    var repo = try Repo.init();
    defer repo.deinit();
    try conflictSetup(&repo);
    try t.expectError(error.ReplayConflict, edit.run(&repo.git, .{ .jump = null }));
    try repo.exec(&.{ "checkout", "--ours", "shared" });
    try repo.exec(&.{ "add", "shared" });

    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer t.allocator.free(checkpoint);
    const raw = try repo.git.output(&.{ "cat-file", "blob", checkpoint });
    defer t.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
    defer parsed.deinit();
    parsed.value.object.getPtr("plan_len").?.integer += 1;
    const invalid = try std.json.Stringify.valueAlloc(t.allocator, parsed.value, .{});
    defer t.allocator.free(invalid);
    const invalid_oid = try repo.git.writeBlob(invalid);
    defer t.allocator.free(invalid_oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, invalid_oid });

    const head = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(head);
    const picking = (try repo.git.readRef("CHERRY_PICK_HEAD")).?;
    defer t.allocator.free(picking);
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try t.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try refEquals(&repo, "HEAD", head);
        try refEquals(&repo, "CHERRY_PICK_HEAD", picking);
        try refEquals(&repo, layout.session_ref, invalid_oid);
    }
    try repo.exec(&.{ "update-ref", layout.session_ref, checkpoint });
    try edit.run(&repo.git, .abort);
    try noSession(&repo);
}

fn replaceCheckpoint(repo: *const Repo, value: std.json.Value) ![]u8 {
    const raw = try std.json.Stringify.valueAlloc(t.allocator, value, .{});
    defer t.allocator.free(raw);
    const oid = try repo.git.writeBlob(raw);
    errdefer t.allocator.free(oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, oid });
    return oid;
}

fn pausedBeforeDetach(repo: *Repo) !void {
    try setup(repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(repo, "model", "corrected\n");
    try commit(repo, "correction");
    try installFaultShim(repo);
    try repo.env.put("STAKRR_TEST_FAULT", "after:1");
    const stopped = try cli(repo, &.{"edit"});
    defer repo.git.freeResult(stopped);
    try t.expect(!stopped.term.success());
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    try outputEquals(repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
}

fn expectInvalidCheckpointUnchanged(repo: *const Repo, oid: []const u8) !void {
    const refs = try repo.git.output(&.{"show-ref"});
    defer t.allocator.free(refs);
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try t.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try outputEquals(repo, &.{"show-ref"}, refs);
        try outputEquals(repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
        try outputEquals(repo, &.{ "status", "--porcelain=v1" }, "");
        try refEquals(repo, layout.session_ref, oid);
        try outputEquals(repo, &.{ "show", "HEAD:model" }, "corrected");
    }
}

test "every checkpoint phase rejects inconsistent state before changing Git" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const checkpoint = (try repo.git.readRef(layout.session_ref)).?;
    defer t.allocator.free(checkpoint);
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", checkpoint });
    defer t.allocator.free(raw);
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
        var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
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
        defer t.allocator.free(invalid);
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
    defer t.allocator.free(checkpoint);
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", checkpoint });
    defer t.allocator.free(raw);
    for ([_]bool{ false, true }) |reverse| {
        var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
        defer parsed.deinit();
        if (reverse) {
            const oid = parsed.value.object.get("plan_oid").?.string;
            const plan = try repo.git.output(&.{ "cat-file", "blob", oid });
            defer t.allocator.free(plan);
            var commits: std.ArrayList([]const u8) = .empty;
            defer commits.deinit(t.allocator);
            var lines = std.mem.tokenizeScalar(u8, plan, '\n');
            while (lines.next()) |line| try commits.append(t.allocator, line);
            std.mem.reverse([]const u8, commits.items);
            const reversed = try std.mem.join(t.allocator, "\n", commits.items);
            defer t.allocator.free(reversed);
            const bad_plan = try repo.git.writeBlob(reversed);
            defer t.allocator.free(bad_plan);
            parsed.value.object.getPtr("plan_oid").?.* = .{ .string = bad_plan };
            const invalid = try replaceCheckpoint(&repo, parsed.value);
            defer t.allocator.free(invalid);
            try expectInvalidCheckpointUnchanged(&repo, invalid);
        } else {
            parsed.value.object.getPtr("plan_len").?.integer += 1;
            const invalid = try replaceCheckpoint(&repo, parsed.value);
            defer t.allocator.free(invalid);
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
    defer t.allocator.free(checkpoint);
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", checkpoint });
    defer t.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
    defer parsed.deinit();
    const object = &parsed.value.object;
    const plan = try repo.git.outputRaw(&.{ "cat-file", "blob", object.get("plan_oid").?.string });
    defer t.allocator.free(plan);
    // The first API commit is inside the cut; later commits still include
    // every cut boundary, so boundary-only validation would accept this plan.
    const first_newline = std.mem.indexOfScalar(u8, plan, '\n').?;
    const shortened = try repo.git.writeBlob(plan[first_newline + 1 ..]);
    defer t.allocator.free(shortened);
    object.getPtr("plan_oid").?.* = .{ .string = shortened };
    object.getPtr("plan_len").?.integer -= 1;
    const invalid = try replaceCheckpoint(&repo, parsed.value);
    defer t.allocator.free(invalid);
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
    try write(&repo, ".git/info/exclude", "precious\n");
    try write(&repo, "precious", "ignored data\n");
    const refs = try repo.git.output(&.{"show-ref"});
    defer t.allocator.free(refs);
    try t.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .continue_edit));
    try outputEquals(&repo, &.{"show-ref"}, refs);
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
    const bytes = try repo.tmp.dir.readFileAlloc(t.io, "precious", t.allocator, .limited(1024));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("ignored data\n", bytes);
    try repo.tmp.dir.deleteFile(t.io, "precious");
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}

test "checkout hooks cannot bypass the ignored-file replay guard" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try edit.run(&repo.git, .{ .jump = "models" });
    try write(&repo, "model", "fixed\n");
    try commit(&repo, "correction");
    try write(&repo, ".git/info/exclude", "api\n");
    try repo.tmp.dir.createDir(t.io, ".git/checkout-hooks", .default_dir);
    try repo.tmp.dir.writeFile(t.io, .{
        .sub_path = ".git/checkout-hooks/post-checkout",
        .data = "#!/bin/sh\nprintf 'ignored from checkout hook\\n' > api\n",
        .flags = .{ .permissions = .executable_file },
    });
    try repo.exec(&.{ "config", "core.hooksPath", ".git/checkout-hooks" });
    const work = try repo.git.resolveCommit("work");
    defer t.allocator.free(work);
    try t.expectError(error.IgnoredFilesPresent, edit.run(&repo.git, .{ .jump = null }));
    try refEquals(&repo, "work", work);
    const bytes = try repo.tmp.dir.readFileAlloc(t.io, "api", t.allocator, .limited(1024));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("ignored from checkout hook\n", bytes);
    try repo.exec(&.{ "config", "core.hooksPath", "/dev/null" });
    try repo.tmp.dir.deleteFile(t.io, "api");
    try edit.run(&repo.git, .continue_edit);
    try outputEquals(&repo, &.{ "show", "work:api" }, "api");
    try noSession(&repo);
}

test "legacy v1 switching checkpoints may retain a completed replay plan" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const before = try repo.git.outputRaw(&.{ "cat-file", "blob", layout.session_ref });
    defer t.allocator.free(before);
    var original = try std.json.parseFromSlice(std.json.Value, t.allocator, before, .{});
    defer original.deinit();
    try repo.env.put("STAKRR_TEST_FAULT", "after:7");
    const stopped = try cli(&repo, &.{ "edit", "--continue" });
    defer repo.git.freeResult(stopped);
    try t.expect(!stopped.term.success());
    _ = repo.env.swapRemove("STAKRR_TEST_FAULT");
    const raw = try repo.git.outputRaw(&.{ "cat-file", "blob", layout.session_ref });
    defer t.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("switching", parsed.value.object.get("phase").?.string);
    // Older versions left this completed plan in the switching checkpoint,
    // even though its old boundary OIDs no longer match the published nodes.
    for ([_][]const u8{ "plan_oid", "plan_len" }) |field|
        parsed.value.object.getPtr(field).?.* = original.value.object.get(field).?;
    parsed.value.object.getPtr("next").?.* = original.value.object.get("plan_len").?;
    const head = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(head);
    parsed.value.object.getPtr("before").?.* = .{ .string = head };
    const legacy = try replaceCheckpoint(&repo, parsed.value);
    defer t.allocator.free(legacy);
    try edit.run(&repo.git, .continue_edit);
    try valid(&repo);
    try noSession(&repo);
}

test "a non-blob edit checkpoint reports invalid session without changing refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const commit_oid = try repo.git.resolveCommit("HEAD");
    defer t.allocator.free(commit_oid);
    try repo.exec(&.{ "update-ref", layout.session_ref, commit_oid });
    const refs = try repo.git.output(&.{"show-ref"});
    defer t.allocator.free(refs);
    try t.expectError(error.InvalidEditSession, edit.readStatus(&repo.git));
    for ([_]edit.Request{ .continue_edit, .abort }) |request| {
        try t.expectError(error.InvalidEditSession, edit.run(&repo.git, request));
        try outputEquals(&repo, &.{"show-ref"}, refs);
    }
    try outputEquals(&repo, &.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
}

test "pending edit status offers continue without conflict instructions" {
    var repo = try Repo.init();
    defer repo.deinit();
    try pausedBeforeDetach(&repo);
    const result = try cli(&repo, &.{"status"});
    defer repo.git.freeResult(result);
    try t.expect(result.term.success());
    try t.expect(std.mem.indexOf(u8, result.stdout, "(detaching) → work") != null);
    try t.expect(std.mem.indexOf(u8, result.stdout, "\n  stakrr edit --continue\n") != null);
    try t.expect(std.mem.indexOf(u8, result.stdout, "resolve conflicts") == null);
    try t.expect(std.mem.indexOf(u8, result.stdout, "recovery:") == null);
    try t.expect(std.mem.indexOf(u8, result.stdout, "worktree:") == null);
    try edit.run(&repo.git, .continue_edit);
    try noSession(&repo);
}
