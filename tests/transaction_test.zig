const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const Repo = @import("support/repo.zig").Repo;
const cli = @import("support/cli.zig");
const fixture = @import("support/edit_fixture.zig");
const intent_ref = stakrr.layout.transaction_ref;

fn setup(repo: *const Repo) !void {
    testing.allocator.free(try repo.initStack());
    testing.allocator.free(try repo.commit("layer"));
    try stakrr.stack.cut(&repo.git, "p1", null);
    testing.allocator.free(try repo.commit("tail"));
}

test "cut CAS refusal after intent creation does not leave recovery pending" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        var before = try repo.git.listDirectRefs("refs/");
        defer before.deinit(testing.allocator);
        const old = try repo.git.resolveCommitAlloc("work");
        defer testing.allocator.free(old);
        const tree = try repo.git.output(&.{ "rev-parse", "work^{tree}" });
        defer testing.allocator.free(tree);
        const raced = try repo.git.commitTree(tree, &.{old}, "concurrent commit");
        defer testing.allocator.free(raced);
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_RACE_LABEL", "stakrr: cut");
        try repo.env.put("STAKRR_TEST_RACE_REF", "refs/heads/work");
        try repo.env.put("STAKRR_TEST_RACE_NEW", raced);
        try repo.env.put("STAKRR_TEST_RACE_OLD", old);

        const refused = try cli.run(&repo, &.{ "cut", "rolling" });
        defer refused.deinit();
        try testing.expectEqual(@as(?u8, 1), refused.code);
        try testing.expect(std.mem.indexOf(u8, refused.stderr, "refs/heads/work") != null);
        _ = repo.env.swapRemove("STAKRR_TEST_RACE_LABEL");
        for (before.refs) |ref| {
            try repo.expectRef(ref.name.bytes, if (std.mem.eql(u8, ref.name.bytes, "refs/heads/work")) raced else ref.oid.hex());
        }
        try repo.expectNoRef("refs/heads/stakrr/rolling");
        try repo.expectNoRef(intent_ref);
        try expectSuccess(&repo, &.{"status"});
        try expectSuccess(&repo, &.{ "cut", "rolling" });
        try repo.expectRef("refs/heads/stakrr/rolling", raced);
        try repo.expectNoRef(intent_ref);
    }
}

test "partial ref transactions recover in normal bare separate and linked repositories" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        for ([_]enum { normal, bare, separate, linked }{ .normal, .bare, .separate, .linked }) |kind| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            var cwd: ?std.Io.Dir = null;
            defer if (cwd) |dir| dir.close(testing.io);
            switch (kind) {
                .normal => {},
                .bare => {
                    try repo.exec(&.{ "init", "--bare", "-q", "--object-format", format, ".git/bare.git" });
                    cwd = try repo.tmp.dir.openDir(testing.io, ".git/bare.git", .{});
                    repo.git.cwd = cwd;
                    try repo.exec(&.{ "config", "user.name", "Stakrr Test" });
                    try repo.exec(&.{ "config", "user.email", "test@stakrr.local" });
                },
                .separate => try repo.exec(&.{ "init", "-q", "--separate-git-dir=.git-data" }),
                .linked => {
                    testing.allocator.free(try repo.commit("seed"));
                    try repo.exec(&.{ "worktree", "add", "-q", "-b", "linked", ".git/linked" });
                    cwd = try repo.tmp.dir.openDir(testing.io, ".git/linked", .{});
                    repo.git.cwd = cwd;
                },
            }
            const blob = try repo.git.writeBlob("retained bytes\x00\xff");
            defer testing.allocator.free(blob);
            const tree = try repo.git.writeTree(&.{.{ .name = "data", .oid = blob }});
            defer testing.allocator.free(tree);
            const old = try repo.git.commitTree(tree, &.{}, "old");
            defer testing.allocator.free(old);
            const new = try repo.git.commitTree(tree, &.{old}, "new");
            defer testing.allocator.free(new);
            try repo.exec(&.{ "update-ref", "refs/heads/a", old });
            try repo.exec(&.{ "update-ref", "refs/stakrr/remove", old });
            const Change = struct { name: []const u8, old: ?[]const u8, new: ?[]const u8 };
            const metadata = try std.json.Stringify.valueAlloc(testing.allocator, .{
                .version = @as(u8, 1),
                .label = "test partial",
                .changes = &[_]Change{
                    .{ .name = "refs/heads/a", .old = old, .new = new },
                    .{ .name = "refs/stakrr/blob", .old = null, .new = blob },
                    .{ .name = "refs/stakrr/remove", .old = old, .new = null },
                },
            }, .{});
            defer testing.allocator.free(metadata);
            const data = try repo.git.writeBlob(metadata);
            defer testing.allocator.free(data);
            const saved_tree = try repo.git.writeTree(&.{
                .{ .name = "transaction.json", .oid = data },
                .{ .name = blob, .oid = blob },
            });
            defer testing.allocator.free(saved_tree);
            const intent = try repo.git.commitTree(saved_tree, &.{ old, new }, "test partial");
            defer testing.allocator.free(intent);
            try repo.exec(&.{ "update-ref", intent_ref, intent });
            // Git stopped after publishing only the first of the three changes.
            try repo.exec(&.{ "update-ref", "refs/heads/a", new, old });
            try repo.expectRef("refs/heads/a", new);
            try testing.expect(try repo.hasRef(intent_ref));
            try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
            try repo.exec(&.{ "gc", "--prune=now" });
            var mutation = try @import("stakrr").mutation.begin(&repo.git, .refs);
            defer mutation.deinit();
            try testing.expect(mutation.recovered);
            try repo.expectRef("refs/heads/a", new);
            try repo.expectRef("refs/stakrr/blob", blob);
            try repo.expectNoRef("refs/stakrr/remove");
            try repo.expectNoRef(intent_ref);
            try repo.exec(&.{ "fsck", "--no-reflogs" });
        }
    }
}

const expectSuccess = cli.expectSuccess;

fn interrupt(repo: *Repo, args: []const []const u8, label: []const u8, count: []const u8) !void {
    try cli.installFaultShim(repo);
    try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", label);
    try repo.env.put("STAKRR_TEST_PARTIAL_WRITES", count);
    const stopped = try cli.run(repo, args);
    defer stopped.deinit();
    if (repo.env.get("STAKRR_TEST_PARTIAL_EXIT") != null)
        try testing.expectEqual(@as(?u8, 1), stopped.code)
    else
        try stopped.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
    try testing.expect(try repo.hasRef(intent_ref));
}

test "cut resumes before its first write after partial publication and after interrupted cleanup" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        for ([_][]const u8{ "0", "1", "2", "cleanup" }) |phase| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            try setup(&repo);
            const head = try repo.git.resolveCommitAlloc("HEAD");
            defer testing.allocator.free(head);
            try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "dirty", .data = "staged\n" });
            try repo.exec(&.{ "add", "dirty" });
            const index = try repo.git.output(&.{"write-tree"});
            defer testing.allocator.free(index);
            try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "dirty", .data = "unstaged\n" });
            try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "untracked", .data = "keep\n" });
            const cleanup = std.mem.eql(u8, phase, "cleanup");
            try interrupt(&repo, &.{ "cut", "rolling" }, if (cleanup) "stakrr: finish transaction" else "stakrr: cut", if (cleanup) "0" else phase);
            const refs = try repo.git.output(&.{"show-ref"});
            defer testing.allocator.free(refs);
            const status = try cli.run(&repo, &.{"status"});
            defer status.deinit();
            // A fully published operation awaiting cleanup is safe to inspect.
            try testing.expectEqual(@as(?u8, 0), status.code);
            try repo.expectOutput(&.{"show-ref"}, refs);
            try expectSuccess(&repo, &.{"up"});
            try repo.expectNoRef(intent_ref);
            try repo.expectRef("refs/heads/stakrr/rolling", head);
            try fixture.expectBoundary(&repo, "rolling", head);
            try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, head);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/work");
            try repo.expectOutput(&.{"write-tree"}, index);
            var snapshot = try stakrr.stack.inspect(&repo.git);
            defer snapshot.deinit();
            try testing.expectEqual(@as(usize, 2), snapshot.layers.len);
            try repo.expectFile("dirty", "unstaged\n");
            try repo.expectFile("untracked", "keep\n");
        }
    }
}

test "failure after preparation retains intent for partially published refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.env.put("STAKRR_TEST_PARTIAL_EXIT", "1");
    try repo.env.put("STAKRR_TEST_PARTIAL_STATUS", "128");
    try interrupt(&repo, &.{ "cut", "rolling" }, "stakrr: cut", "1");
    const head = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(head);
    // The manifest was the first write; the layer branch is still absent.
    try repo.expectNoRef("refs/heads/stakrr/rolling");
    try expectSuccess(&repo, &.{"up"});
    try repo.expectNoRef(intent_ref);
    try fixture.expectBoundary(&repo, "rolling", head);
}

test "recovery refuses unexpected values without changing refs and succeeds after repair" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const head = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(head);
    try interrupt(&repo, &.{ "cut", "rolling" }, "stakrr: cut", "1");
    try repo.exec(&.{ "update-ref", "refs/heads/work", "main" });
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    const refused = try cli.run(&repo, &.{"up"});
    defer refused.deinit();
    try testing.expectEqual(@as(?u8, 5), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "unexpected refs") != null);
    try repo.expectOutput(&.{"show-ref"}, refs);
    try repo.exec(&.{ "update-ref", "refs/heads/work", head });
    try expectSuccess(&repo, &.{"up"});
    try repo.expectNoRef(intent_ref);
}

test "reset recovery protects own and linked checkouts before completing deletions" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        try interrupt(&repo, &.{ "reset", "--delete-layers" }, "stakrr: reset", "1");
        try repo.exec(&.{ "switch", "-q", "stakrr/p1" });
        const refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(refs);
        const own = try cli.run(&repo, &.{ "reset", "--delete-layers" });
        defer own.deinit();
        try testing.expectEqual(@as(?u8, 1), own.code);
        try testing.expect(std.mem.indexOf(u8, own.stderr, "cannot delete layers") != null);
        try repo.expectOutput(&.{"show-ref"}, refs);
        try repo.exec(&.{ "switch", "-q", "work" });
        try repo.exec(&.{ "worktree", "add", "-q", ".git/occupied space\n", "stakrr/p1" });
        const linked = try cli.run(&repo, &.{ "reset", "--delete-layers" });
        defer linked.deinit();
        try testing.expectEqual(@as(?u8, 1), linked.code);
        try testing.expect(std.mem.indexOf(u8, linked.stderr, "another worktree") != null);
        try repo.expectOutput(&.{"show-ref"}, refs);
        try repo.exec(&.{ "-C", ".git/occupied space\n", "switch", "-q", "--detach" });
        try expectSuccess(&repo, &.{ "reset", "--delete-layers" });
        try repo.expectNoRef(intent_ref);
        try repo.expectNoRef("refs/heads/stakrr/p1");
        try repo.expectNoRef(stakrr.layout.state_ref);
    }
}

test "recovery preserves Git owned lock files and retries after their removal" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try interrupt(&repo, &.{ "cut", "rolling" }, "stakrr: cut", "0");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/refs/stakrr/state.lock", .data = "owned by Git\n" });
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    const refused = try cli.run(&repo, &.{"up"});
    defer refused.deinit();
    try testing.expectEqual(@as(?u8, 1), refused.code);
    try repo.expectOutput(&.{"show-ref"}, refs);
    try repo.expectFile(".git/refs/stakrr/state.lock", "owned by Git\n");
    try repo.tmp.dir.deleteFile(testing.io, ".git/refs/stakrr/state.lock");
    try expectSuccess(&repo, &.{"up"});
    try repo.expectNoRef(intent_ref);
}

test "recovery refuses active Git operations before changing branches" {
    for ([_][]const u8{ "CHERRY_PICK_HEAD", "MERGE_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer" }) |name| {
        var repo = try Repo.init();
        defer repo.deinit();
        try setup(&repo);
        const head = try repo.git.resolveCommitAlloc("HEAD");
        defer testing.allocator.free(head);
        try interrupt(&repo, &.{ "cut", "rolling" }, "stakrr: cut", "0");
        const path = try repo.git.path(&.{ "rev-parse", "--git-path", name });
        defer testing.allocator.free(path);
        const directory = std.mem.startsWith(u8, name, "rebase-") or std.mem.eql(u8, name, "sequencer");
        if (directory)
            try repo.tmp.dir.createDir(testing.io, path, .default_dir)
        else
            try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = head });
        const refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(refs);
        const refused = try cli.run(&repo, &.{"up"});
        defer refused.deinit();
        try testing.expectEqual(@as(?u8, 4), refused.code);
        try testing.expect(std.mem.indexOf(u8, refused.stderr, "finish the active Git operation") != null);
        try repo.expectOutput(&.{"show-ref"}, refs);
        if (directory)
            try repo.tmp.dir.deleteDir(testing.io, path)
        else
            try repo.tmp.dir.deleteFile(testing.io, path);
        try expectSuccess(&repo, &.{"up"});
        try repo.expectNoRef(intent_ref);
    }
}

test "corrupt intent is preserved by status and mutations" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const blob = try repo.git.writeBlob("invalid transaction\n");
    defer testing.allocator.free(blob);
    try repo.exec(&.{ "update-ref", intent_ref, blob });
    const refs = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(refs);
    for ([_][]const u8{ "status", "up", "reset" }) |command| {
        const result = try cli.run(&repo, &.{command});
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 1), result.code);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "invalid interrupted ref transaction") != null);
        try repo.expectOutput(&.{"show-ref"}, refs);
    }
}

const driver = cli.runRefDriver;

test "production intent retains commits trees blobs and exact annotated tag bytes through pruning" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        testing.allocator.free(try repo.commit("seed"));
        const blob = try repo.git.writeBlob("retained binary\x00\xff");
        defer testing.allocator.free(blob);
        const tree = try repo.git.writeTree(&.{.{ .name = "payload", .oid = blob }});
        defer testing.allocator.free(tree);
        const old = try repo.git.commitTree(tree, &.{}, "old root");
        defer testing.allocator.free(old);
        const new = try repo.git.commitTree(tree, &.{old}, "new tip");
        defer testing.allocator.free(new);
        const raw_tag = try std.fmt.allocPrint(testing.allocator, "object {s}\ntype commit\ntag retained\ntagger Test <test@example.test> 1234567890 +0000\n\nretained tag bytes\n", .{new});
        defer testing.allocator.free(raw_tag);
        const tag = try repo.git.inputOutput(&.{ "hash-object", "-w", "-t", "tag", "--stdin" }, raw_tag);
        defer testing.allocator.free(tag);
        try repo.exec(&.{ "update-ref", "refs/stakrr/commit", old });
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", "test retained objects");
        try repo.env.put("STAKRR_TEST_PARTIAL_WRITES", "0");
        const stopped = try driver(&repo, &.{ "retain", old, new, blob, tree, tag });
        defer stopped.deinit();
        try stopped.expectKilled();
        try testing.expect(try repo.hasRef(intent_ref));
        _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
        try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
        try repo.exec(&.{ "gc", "--prune=now" });
        const absent = try repo.git.run(&.{ "cat-file", "-e", tag });
        defer repo.git.freeResult(absent);
        try testing.expect(!absent.term.success());

        const recovered = try driver(&repo, &.{"recover"});
        defer recovered.deinit();
        if (recovered.code != 0) std.debug.print("recovery: {s}\n", .{recovered.stderr});
        try testing.expectEqual(@as(?u8, 0), recovered.code);
        try repo.expectNoRef(intent_ref);
        try repo.expectRef("refs/stakrr/commit", new);
        try repo.expectRef("refs/stakrr/blob", blob);
        try repo.expectRef("refs/stakrr/tree", tree);
        try repo.expectRef("refs/tags/retained", tag);
        const actual_tag = try repo.git.outputRaw(&.{ "cat-file", "tag", tag });
        defer testing.allocator.free(actual_tag);
        try testing.expectEqualStrings(raw_tag, actual_tag);
        try repo.exec(&.{ "fsck", "--no-reflogs" });
    }
}

test "journal rejects duplicate ref names and its reserved namespace without publication" {
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try repo.commit("seed");
    defer testing.allocator.free(head);
    var mutation = try @import("stakrr").mutation.begin(&repo.git, .refs);
    defer mutation.deinit();
    try testing.expectError(error.InvalidRefName, mutation.publish(.{ .message = "duplicate", .updates = &.{
        try repo.git.createRef("refs/stakrr/same", head),
        try repo.git.createRef("refs/stakrr/same", head),
    } }));
    for ([_][]const u8{ intent_ref, intent_ref ++ "/nested" }) |name| {
        try testing.expectError(error.InvalidRefName, mutation.publish(.{ .message = "reserved", .updates = &.{
            try repo.git.createRef(name, head),
            try repo.git.createRef("refs/stakrr/other", head),
        } }));
    }
    try repo.expectNoRef(intent_ref);
    try repo.expectNoRef("refs/stakrr/same");
    try repo.expectNoRef("refs/stakrr/other");
    try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, head);
}

test "reset recovery refuses to delete the caller's checked-out layer" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try fixture.setup(&repo);
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", "stakrr: reset");
        try repo.env.put("STAKRR_TEST_PARTIAL_WRITES", "1");
        const stopped = try cli.run(&repo, &.{ "reset", "--delete-layers" });
        defer stopped.deinit();
        try stopped.expectKilled();
        _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
        try testing.expect(try repo.hasRef(intent_ref));

        try repo.exec(&.{ "switch", "-q", "stakrr/models" });
        const refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(refs);
        const head = try repo.git.resolveCommitAlloc("HEAD");
        defer testing.allocator.free(head);
        const index = try repo.git.output(&.{"write-tree"});
        defer testing.allocator.free(index);
        const refused = try cli.run(&repo, &.{"continue"});
        defer refused.deinit();
        try testing.expectEqual(@as(?u8, 1), refused.code);
        try testing.expect(std.mem.indexOf(u8, refused.stderr, "checked out") != null);
        try repo.expectOutput(&.{"show-ref"}, refs);
        try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, head);
        try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, "refs/heads/stakrr/models");
        try repo.expectOutput(&.{"write-tree"}, index);
        try repo.expectOutput(&.{ "status", "--porcelain" }, "");

        try repo.exec(&.{ "switch", "-q", "work" });
        try cli.expectSuccess(&repo, &.{"continue"});
        try repo.expectNoRef(intent_ref);
        try repo.expectNoRef("refs/heads/stakrr/models");
        try repo.expectNoRef("refs/heads/stakrr/api");
        try repo.expectOutput(&.{ "status", "--porcelain" }, "");
        try repo.expectNoRef(stakrr.layout.state_ref);
    }
}

test "restack and archival recover after partial publication" {
    for ([_][]const u8{ "stakrr: checkpoint switching", "stakrr: restack" }) |label| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        try fixture.correctModels(&repo);
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", label);
        try repo.env.put("STAKRR_TEST_PARTIAL_WRITES", if (std.mem.eql(u8, label, "stakrr: restack")) "1" else "2");
        const stopped = try cli.run(&repo, &.{"restack"});
        defer stopped.deinit();
        try stopped.expectKilled();
        _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");

        if (try repo.hasRef(stakrr.layout.session_ref)) {
            try cli.expectSuccess(&repo, &.{"continue"});
        } else {
            // The session deletion was published before the oplog update.
            try cli.expectSuccess(&repo, &.{"continue"});
        }
        try repo.expectOutput(&.{ "show", "work:model" }, "corrected");
        try fixture.valid(&repo);
        try fixture.noSession(&repo);
        try repo.expectNoRef(intent_ref);
    }
}

test "cut publication does not require a configured author identity" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        for ([_]bool{ false, true }) |with_files| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            if (with_files) try fixture.setup(&repo) else try setup(&repo);
            try repo.exec(&.{ "config", "--unset", "user.name" });
            try repo.exec(&.{ "config", "--unset", "user.email" });
            try repo.exec(&.{ "config", "user.useConfigOnly", "true" });
            try cli.expectSuccess(&repo, &.{ "cut", "rolling" });
            try repo.expectNoRef(intent_ref);
            var snapshot = try stakrr.stack.inspect(&repo.git);
            defer snapshot.deinit();
            try testing.expectEqual(@as(usize, if (with_files) 3 else 2), snapshot.layers.len);
        }
    }
}

test "separate Git directories allow own branches and reject forced duplicate checkouts" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try repo.exec(&.{ "init", "-q", "-b", "main", "--object-format", format, "--separate-git-dir=.git/separate storage", "worktree" });
        const dir = try repo.tmp.dir.openDir(testing.io, "worktree", .{});
        defer dir.close(testing.io);
        // Borrow the fixture's ownership, changing only its working directory.
        var view = repo;
        view.tmp.dir = dir;
        view.git.cwd = dir;
        try view.exec(&.{ "config", "user.name", "Stakrr Test" });
        try view.exec(&.{ "config", "user.email", "test@stakrr.local" });
        try view.exec(&.{ "config", "core.hooksPath", "/dev/null" });
        try view.exec(&.{ "config", "commit.gpgsign", "false" });
        try fixture.setup(&view);
        try view.write("model", "fixed\n");
        try view.exec(&.{ "add", "model" });
        var fixed = try stakrr.fix.fix(&view.git, .{ .layer = "models", .how = .{ .message = "fix" } });
        defer fixed.deinit(testing.allocator);
        try fixture.correctModels(&view);
        try cli.expectSuccess(&view, &.{"restack"});
        try fixture.valid(&view);

        const metadata = try repo.tmp.dir.realPathFileAlloc(testing.io, ".git", testing.allocator);
        defer testing.allocator.free(metadata);
        const path = try std.fs.path.join(testing.allocator, &.{ metadata, "duplicate" });
        defer testing.allocator.free(path);
        try fixture.correctModels(&view);
        try view.exec(&.{ "worktree", "add", "-q", "--force", path, "work" });
        const before = try view.git.output(&.{"show-ref"});
        defer testing.allocator.free(before);
        try testing.expectError(error.BranchOccupied, stakrr.edit.run(&view.git, .restack));
        try view.expectOutput(&.{"show-ref"}, before);
        try fixture.noSession(&view);
    }
}

test "Git failure after preparation keeps intent for partially published refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const old = try repo.git.resolveCommitAlloc("refs/heads/stakrr/models");
    defer testing.allocator.free(old);
    try repo.write("model", "fixed\n");
    try repo.exec(&.{ "add", "model" });
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", "stakrr: fix");
    try repo.env.put("STAKRR_TEST_PARTIAL_EXIT", "1");
    try repo.env.put("STAKRR_TEST_PARTIAL_STATUS", "128");
    const stopped = try cli.run(&repo, &.{ "fix", "models", "-m", "fix" });
    defer stopped.deinit();
    try testing.expectEqual(@as(?u8, 1), stopped.code);
    _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
    try testing.expect(try repo.hasRef(intent_ref));
    const published = try repo.git.resolveCommitAlloc("refs/heads/stakrr/models");
    defer testing.allocator.free(published);
    try testing.expect(!std.mem.eql(u8, old, published));
    try fixture.expectBoundary(&repo, "models", old);

    try cli.expectSuccess(&repo, &.{"continue"});
    try repo.expectNoRef(intent_ref);
    try repo.expectOutput(&.{ "show", "work:model" }, "fixed");
    try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    try fixture.valid(&repo);
}

test "partial ref recovery refuses unexpected values without changing any refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try repo.write("model", "fixed\n");
    try repo.exec(&.{ "add", "model" });
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", "stakrr: fix");
    const stopped = try cli.run(&repo, &.{ "fix", "models", "-m", "fix" });
    defer stopped.deinit();
    try stopped.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
    try repo.exec(&.{ "update-ref", "refs/heads/work", "main" });
    const before = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(before);

    const refused = try cli.run(&repo, &.{"continue"});
    defer refused.deinit();
    try testing.expectEqual(@as(?u8, 5), refused.code);
    try repo.expectOutput(&.{"show-ref"}, before);
    try testing.expect(try repo.hasRef(intent_ref));
}

test "status and log report partial publication without repairing it" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try repo.write("model", "fixed\n");
    try repo.exec(&.{ "add", "model" });
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", "stakrr: fix");
    const stopped = try cli.run(&repo, &.{ "fix", "models", "-m", "fix" });
    defer stopped.deinit();
    try stopped.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
    const before = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(before);
    for ([_][]const u8{ "status", "log" }) |command| {
        const result = try cli.run(&repo, &.{command});
        defer result.deinit();
        try testing.expectEqual(@as(?u8, if (std.mem.eql(u8, command, "status")) 0 else 1), result.code);
        try testing.expect(std.mem.indexOf(u8, if (result.code == 0) result.stdout else result.stderr, "stakrr continue") != null);
        try repo.expectOutput(&.{"show-ref"}, before);
    }
    try cli.expectSuccess(&repo, &.{"continue"});
    try repo.expectNoRef(intent_ref);
    try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    try fixture.valid(&repo);
}

test "publication resumes before its first write and after interrupted cleanup" {
    for ([_][]const u8{ "stakrr: fix", "stakrr: finish transaction" }) |label| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        try repo.write("model", "fixed\n");
        try repo.exec(&.{ "add", "model" });
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", label);
        try repo.env.put("STAKRR_TEST_PARTIAL_WRITES", "0");
        const stopped = try cli.run(&repo, &.{ "fix", "models", "-m", "fix" });
        defer stopped.deinit();
        try stopped.expectKilled();
        try testing.expect(try repo.hasRef(intent_ref));
        _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");

        const resumed = try cli.run(&repo, &.{"continue"});
        defer resumed.deinit();
        try testing.expectEqual(@as(?u8, 0), resumed.code);
        try testing.expectEqualStrings("interrupted operation completed\n", resumed.stdout);
        try repo.expectNoRef(intent_ref);
        try repo.expectOutput(&.{ "show", "work:model" }, "fixed");
        try fixture.valid(&repo);
        try fixture.noSession(&repo);
    }
}

test "recovery preserves Git locks and refuses branches occupied in another worktree" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try repo.write("model", "fixed\n");
    try repo.exec(&.{ "add", "model" });
    try cli.installFaultShim(&repo);
    try repo.env.put("STAKRR_TEST_PARTIAL_LABEL", "stakrr: fix");
    const stopped = try cli.run(&repo, &.{ "fix", "models", "-m", "fix" });
    defer stopped.deinit();
    try stopped.expectKilled();
    _ = repo.env.swapRemove("STAKRR_TEST_PARTIAL_LABEL");
    const before = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(before);
    const other = try fixture.linked(&repo, "occupied", "stakrr/api");
    defer other.cwd.?.close(testing.io);
    const occupied = try cli.run(&repo, &.{"continue"});
    defer occupied.deinit();
    try testing.expectEqual(@as(?u8, 1), occupied.code);
    try testing.expect(std.mem.indexOf(u8, occupied.stderr, "another worktree") != null);
    try repo.expectOutput(&.{"show-ref"}, before);
    try other.exec(&.{ "switch", "-q", "--detach" });

    const path = try repo.git.path(&.{ "rev-parse", "--git-path", "refs/stakrr/state.lock" });
    defer testing.allocator.free(path);
    try repo.write(path, "owned by Git\n");
    const locked = try cli.run(&repo, &.{"continue"});
    defer locked.deinit();
    try testing.expectEqual(@as(?u8, 1), locked.code);
    try repo.expectOutput(&.{"show-ref"}, before);
    const bytes = try repo.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("owned by Git\n", bytes);
    try repo.tmp.dir.deleteFile(testing.io, path);
    try cli.expectSuccess(&repo, &.{"continue"});
    try repo.expectNoRef(intent_ref);
    try fixture.valid(&repo);
}

test "corrupt publication intent is preserved without changing other refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const blob = try repo.git.writeBlob("invalid transaction\n");
    defer testing.allocator.free(blob);
    try repo.exec(&.{ "update-ref", intent_ref, blob });
    const before = try repo.git.output(&.{"show-ref"});
    defer testing.allocator.free(before);
    for ([_][]const u8{ "continue", "quit", "reset" }) |command| {
        const result = try cli.run(&repo, &.{command});
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 1), result.code);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "invalid interrupted ref transaction") != null);
        try repo.expectOutput(&.{"show-ref"}, before);
    }
}

test "fix and restack work in linked worktrees of bare repositories" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        testing.allocator.free(try repo.commit("seed"));
        try repo.exec(&.{ "clone", "--bare", "-q", ".", ".git/bare.git" });
        const metadata = try repo.tmp.dir.realPathFileAlloc(testing.io, ".git", testing.allocator);
        defer testing.allocator.free(metadata);
        const path = try std.fs.path.join(testing.allocator, &.{ metadata, "linked-main" });
        defer testing.allocator.free(path);
        try repo.exec(&.{ "-C", ".git/bare.git", "worktree", "add", "-q", path, "main" });
        const dir = try repo.tmp.dir.openDir(testing.io, path, .{});
        defer dir.close(testing.io);
        var view = repo;
        view.tmp.dir = dir;
        view.git.cwd = dir;
        try view.exec(&.{ "config", "user.name", "Stakrr Test" });
        try view.exec(&.{ "config", "user.email", "test@stakrr.local" });
        try view.exec(&.{ "config", "core.hooksPath", "/dev/null" });
        try view.exec(&.{ "config", "commit.gpgsign", "false" });
        try fixture.setup(&view);
        try view.write("model", "fixed\n");
        try view.exec(&.{ "add", "model" });
        var fixed = try stakrr.fix.fix(&view.git, .{ .layer = "models", .how = .{ .message = "fix" } });
        defer fixed.deinit(testing.allocator);
        try fixture.correctModels(&view);
        try cli.expectSuccess(&view, &.{"restack"});
        try view.expectOutput(&.{ "show", "work:model" }, "corrected");
        try fixture.valid(&view);
    }
}
