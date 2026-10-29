//! Ref identity matters even when a symbolic ref resolves to the expected OID.
//! Discovery refuses symbolic refs before using their resolved values.
//! Publication races must fail with GitFailed while preserving the alias.
const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const layout = stakrr.layout;
const subject = "refs/heads/stakrr/models";
const publication_ref = "refs/stakrr/publication-test";
const Repo = @import("support/repo.zig").Repo;
const cli = @import("support/cli.zig");
const fixture = @import("support/edit_fixture.zig");

const victim = "refs/heads/victim";
const formats = [_][]const u8{ "sha1", "sha256" };

const Snapshot = @import("support/snapshot.zig").Snapshot;

fn expectSymbolic(repo: *const Repo, name: []const u8) !void {
    // for-each-ref omits dangling symbolic refs, so assert their identity too.
    try repo.expectOutput(&.{ "symbolic-ref", "--no-recurse", name }, victim);
}

fn expectAbsent(repo: *const Repo, name: []const u8) !void {
    try repo.expectNoRef(name);
    try testing.expect(!(try repo.git.check(&.{ "symbolic-ref", "--quiet", "--no-recurse", name }, 1)));
}

const driver = cli.runRefDriver;

fn expectDriverError(result: cli.Run, expected: anyerror) !void {
    try testing.expectEqual(@as(?u8, 1), result.code);
    try testing.expectEqualStrings(@errorName(expected), result.stderr);
}

fn expectDirect(repo: *const Repo, name: []const u8, oid: []const u8) !void {
    try repo.expectRef(name, oid);
    try testing.expect(!(try repo.git.check(&.{ "symbolic-ref", "--quiet", "--no-recurse", name }, 1)));
}

fn restore(repo: *const Repo, name: []const u8, oid: ?[]const u8) !void {
    if (oid) |value|
        try repo.exec(&.{ "update-ref", "--no-deref", name, value })
    else
        try repo.exec(&.{ "update-ref", "--no-deref", "-d", name });
}

fn alias(repo: *const Repo, name: []const u8, oid: ?[]const u8) !void {
    if (oid) |value| try repo.exec(&.{ "update-ref", victim, value });
    try repo.exec(&.{ "symbolic-ref", name, victim });
    try expectSymbolic(repo, name);
}

fn race(repo: *Repo, label: []const u8, name: []const u8) !void {
    try cli.installFaultShim(repo);
    try repo.env.put("STAKRR_TEST_SYMREF_LABEL", label);
    try repo.env.put("STAKRR_TEST_SYMREF_REF", name);
    try repo.env.put("STAKRR_TEST_SYMREF_TARGET", victim);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}.symref", .{repo.env.get("STAKRR_TEST_COUNTER").?});
    defer testing.allocator.free(marker);
    try repo.env.put("STAKRR_TEST_SYMREF_MARKER", marker);
}

fn expectRaceFired(repo: *const Repo) !void {
    const marker = try repo.tmp.dir.readFileAlloc(testing.io, repo.env.get("STAKRR_TEST_SYMREF_MARKER").?, testing.allocator, .limited(1024));
    defer testing.allocator.free(marker);
    try testing.expectEqualStrings(repo.env.get("STAKRR_TEST_SYMREF_LABEL").?, marker);
}

fn dirty(repo: *const Repo) !void {
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "tracked", .data = "staged work\n" });
    try repo.exec(&.{ "add", "tracked" });
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "tracked", .data = "unstaged work\n" });
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "untracked", .data = "untracked work\n" });
}

// Exercise both formats even when one fails, so a red regression does not
// hide the remaining cases in the matrix.
fn eachFormat(comptime run: anytype, args: anytype) !void {
    var failed = false;
    for (formats) |format| {
        @call(.auto, run, .{format} ++ args) catch |err| {
            std.debug.print("symbolic-ref case ({s}): {s}\n", .{ format, @errorName(err) });
            failed = true;
        };
    }
    if (failed) return error.TestUnexpectedResult;
}

test "ref publication returns StreamTooLong without crashing during pipe cleanup" {
    try publicationTransportFailure("stderr-overflow", error.StreamTooLong);
}

test "ref publication returns BrokenPipe without crashing during pipe cleanup" {
    try publicationTransportFailure("closed-stdin", error.BrokenPipe);
}

fn publicationTransportFailure(fault: []const u8, expected_error: anyerror) !void {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const old = try repo.commit("old");
        defer testing.allocator.free(old);
        const new = try repo.commit("new");
        defer testing.allocator.free(new);
        try restore(&repo, publication_ref, old);
        try dirty(&repo);
        try cli.installFaultShim(&repo);
        const marker = try std.fmt.allocPrint(testing.allocator, "{s}.transport-fault", .{repo.env.get("STAKRR_TEST_COUNTER").?});
        defer testing.allocator.free(marker);
        try repo.env.put("STAKRR_TEST_TRANSACTION_FAULT", fault);
        try repo.env.put("STAKRR_TEST_TRANSACTION_FAULT_MARKER", marker);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();

        // Isolate the API call in a child so a cleanup panic fails this test
        // without taking down the test runner or hiding the other regressions.
        const result = try driver(&repo, &.{ "update", old, new });
        defer result.deinit();
        const phase = try repo.tmp.dir.readFileAlloc(testing.io, marker, testing.allocator, .limited(32));
        defer testing.allocator.free(phase);
        try testing.expectEqualStrings("prepare\n", phase);
        try before.expectUnchanged(&repo);
        if (result.code == null) std.debug.print("ref publication terminated abnormally:\n{s}\n", .{result.stderr});
        try expectDriverError(result, expected_error);
        try expectAbsent(&repo, layout.transaction_ref);

        // The same request must succeed through real Git when the transport
        // fault is removed, ruling out an invalid transaction as the cause.
        _ = repo.env.swapRemove("STAKRR_TEST_TRANSACTION_FAULT");
        const control = try driver(&repo, &.{ "update", old, new });
        defer control.deinit();
        try testing.expectEqual(@as(?u8, 0), control.code);
        try testing.expectEqualStrings("", control.stderr);
        try expectDirect(&repo, publication_ref, new);
        try expectDirect(&repo, "refs/stakrr/unrelated", new);
    }
}

const PublicationCase = enum { verify, verify_absent, create, update, delete };

fn publication(kind: PublicationCase, inject: bool) !void {
    try eachFormat(publicationCase, .{ kind, inject, false });
}

fn publicationCase(format: []const u8, kind: PublicationCase, inject: bool, lock_probe: bool) !void {
    var repo = try Repo.initOptions(.{ .object_format = format });
    defer repo.deinit();
    const old = try repo.commit("old");
    defer testing.allocator.free(old);
    const new = try repo.commit("new");
    defer testing.allocator.free(new);
    const absent = kind == .create or kind == .verify_absent;
    const initial: ?[]const u8 = if (absent) null else old;
    try restore(&repo, publication_ref, initial);
    try dirty(&repo);
    if (lock_probe) {
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_LOCK_REF", publication_ref);
        const marker = try std.fmt.allocPrint(testing.allocator, "{s}.locked", .{repo.env.get("STAKRR_TEST_COUNTER").?});
        defer testing.allocator.free(marker);
        try repo.env.put("STAKRR_TEST_LOCK_MARKER", marker);
        try restore(&repo, victim, old);
    }
    if (inject) {
        try race(&repo, "test symbolic publication", publication_ref);
        try alias(&repo, publication_ref, initial);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        try restore(&repo, publication_ref, initial);
        const result = try driver(&repo, &.{ @tagName(kind), if (absent) "" else old, new });
        defer result.deinit();
        try expectRaceFired(&repo);
        try before.expectUnchanged(&repo);
        try expectSymbolic(&repo, publication_ref);
        if (initial) |oid| try expectDirect(&repo, victim, oid) else try expectAbsent(&repo, victim);
        try expectAbsent(&repo, "refs/stakrr/unrelated");
        try expectDriverError(result, error.GitFailed);
    } else {
        const result = try driver(&repo, &.{ @tagName(kind), if (absent) "" else old, new });
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 0), result.code);
        switch (kind) {
            .verify => try expectDirect(&repo, publication_ref, old),
            .verify_absent, .delete => try expectAbsent(&repo, publication_ref),
            .create, .update => try expectDirect(&repo, publication_ref, new),
        }
        try expectDirect(&repo, "refs/stakrr/unrelated", new);
    }
    try expectAbsent(&repo, layout.transaction_ref);
    if (lock_probe) {
        const status = try repo.tmp.dir.readFileAlloc(testing.io, repo.env.get("STAKRR_TEST_LOCK_MARKER").?, testing.allocator, .limited(32));
        defer testing.allocator.free(status);
        try testing.expect((try std.fmt.parseInt(u8, status, 10)) != 0);
        try expectDirect(&repo, victim, old);
    }
}

test "direct ref publication controls accept verify create update and delete" {
    for (std.enums.values(PublicationCase)) |kind| try publication(kind, false);
}

test "publication keeps every requested ref locked during type validation" {
    for (std.enums.values(PublicationCase)) |kind| try eachFormat(publicationCase, .{ kind, false, true });
}

test "verify refuses a symbolic ref substituted at publication" {
    try publication(.verify, true);
}

test "absence verification refuses a dangling symbolic ref substituted at publication" {
    try publication(.verify_absent, true);
}

test "create refuses a dangling symbolic ref substituted at publication" {
    try publication(.create, true);
}

test "update refuses a symbolic ref substituted at publication" {
    try publication(.update, true);
}

test "delete refuses a symbolic ref substituted at publication" {
    try publication(.delete, true);
}

fn setup(repo: *const Repo) !void {
    testing.allocator.free(try repo.initStack());
    testing.allocator.free(try repo.commit("models"));
    try stakrr.stack.cut(&repo.git, "models", null);
}

fn reset(repo: *const Repo, delete_layers: bool) !void {
    _ = try stakrr.stack.reset(&repo.git, .{ .delete_layers = delete_layers });
}

fn resetRef(name: []const u8) !void {
    var failed = false;
    for ([_]bool{ false, true }) |delete_layers| {
        for ([_]bool{ false, true }) |dangling| {
            eachFormat(resetRefCase, .{ name, delete_layers, dangling }) catch {
                std.debug.print("reset case (delete_layers={}, dangling={}) failed\n", .{ delete_layers, dangling });
                failed = true;
            };
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

fn resetRefCase(format: []const u8, name: []const u8, delete_layers: bool, dangling: bool) !void {
    var repo = try Repo.initOptions(.{ .object_format = format });
    defer repo.deinit();
    try setup(&repo);
    try dirty(&repo);
    const old = (try repo.readRef(name)).?;
    defer testing.allocator.free(old);
    try alias(&repo, name, if (dangling) null else old);
    var before = try Snapshot.capture(&repo);
    defer before.deinit();

    const result = reset(&repo, delete_layers);
    try before.expectUnchanged(&repo);
    try expectSymbolic(&repo, name);
    if (dangling) try expectAbsent(&repo, victim) else try expectDirect(&repo, victim, old);
    try expectAbsent(&repo, layout.transaction_ref);
    try testing.expectError(error.SymbolicRef, result);
}

test "reset refuses symbolic layer branches including dangling refs and kept layers" {
    try resetRef(subject);
}

test "reset refuses a symbolic tip including a dangling ref" {
    try resetRef(layout.state_ref);
}

test "init refuses a symbolic work branch without adopting its target" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const old = try repo.initWork();
        defer testing.allocator.free(old);
        try alias(&repo, "refs/heads/work", old);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        try testing.expectError(error.SymbolicRef, stakrr.stack.initStack(&repo.git, "main"));
        try before.expectUnchanged(&repo);
        try expectSymbolic(&repo, "refs/heads/work");
        try expectDirect(&repo, victim, old);
    }
}

test "reset refuses an orphan dangling symbolic layer without a record" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        try alias(&repo, "refs/heads/stakrr/orphan/nested", null);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        try testing.expectError(error.SymbolicRef, reset(&repo, true));
        try before.expectUnchanged(&repo);
        try expectSymbolic(&repo, "refs/heads/stakrr/orphan/nested");
        try expectAbsent(&repo, victim);
    }
}

test "prefix discovery preserves unrelated symbolic refs and supports packed refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try repo.exec(&.{ "pack-refs", "--all", "--prune" });
    try repo.exec(&.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/main" });
    try repo.exec(&.{ "symbolic-ref", "refs/heads/unrelated", "refs/heads/missing" });
    try reset(&repo, true);
    try repo.expectOutput(&.{ "symbolic-ref", "refs/remotes/origin/HEAD" }, "refs/heads/main");
    try repo.expectOutput(&.{ "symbolic-ref", "refs/heads/unrelated" }, "refs/heads/missing");
    try expectAbsent(&repo, subject);
}

test "reftable prefix discovery refuses safely while explicit ref transactions remain supported" {
    var repo = try Repo.init();
    defer repo.deinit();
    const old = try repo.commit("old");
    defer testing.allocator.free(old);
    const migrated = try repo.git.run(&.{ "refs", "migrate", "--ref-format=reftable" });
    defer repo.git.freeResult(migrated);
    if (!migrated.term.success()) {
        // refs migrate is unavailable on the older Git versions we support.
        if (std.mem.indexOf(u8, migrated.stderr, "not a git command") != null or
            std.mem.indexOf(u8, migrated.stderr, "unknown subcommand") != null)
            return error.SkipZigTest;
        return error.GitFailed;
    }
    try repo.exec(&.{ "symbolic-ref", "refs/heads/stakrr/orphan", "refs/heads/missing" });
    try testing.expectError(error.UnsupportedRefStorage, repo.git.listDirectRefs(layout.layer_prefix));
    var mutation = try @import("stakrr").mutation.begin(&repo.git, .refs);
    defer mutation.deinit();
    try mutation.publish(.{ .message = "reftable direct publication", .updates = &.{try repo.git.createRef("refs/stakrr/direct", old)} });
    try expectDirect(&repo, "refs/stakrr/direct", old);
    try repo.expectOutput(&.{ "symbolic-ref", "refs/heads/stakrr/orphan" }, "refs/heads/missing");
}

test "direct ref reads and branch commit queries reject direct and dangling symbolic aliases" {
    for (formats) |format| {
        for ([_]bool{ false, true }) |dangling| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            const old = try repo.commit("old");
            defer testing.allocator.free(old);
            try alias(&repo, subject, if (dangling) null else old);
            var diagnostics: stakrr.git.Diagnostics = .{};
            repo.git.diagnostics = &diagnostics;
            var before = try Snapshot.capture(&repo);
            defer before.deinit();

            try testing.expectError(error.SymbolicRef, repo.git.readDirectRef(try stakrr.git.RefName.init(subject)));
            try testing.expectError(error.SymbolicRef, repo.git.branchCommit(try stakrr.git.BranchRef.init(subject)));
            try testing.expectError(error.SymbolicRef, repo.git.listDirectRefs(layout.layer_prefix));
            try testing.expect(std.mem.indexOf(u8, diagnostics.stderr(), subject) != null);
            try testing.expect(std.mem.indexOf(u8, diagnostics.stderr(), victim) != null);
            try before.expectUnchanged(&repo);
            try expectSymbolic(&repo, subject);
            try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, old);
        }
    }
}

test "head preserves its immediate target while currentBranch refuses nested aliases" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const old = try repo.commit("old");
        defer testing.allocator.free(old);
        try repo.exec(&.{ "symbolic-ref", "refs/heads/alias", "refs/heads/main" });
        try repo.exec(&.{ "symbolic-ref", "refs/heads/outer", "refs/heads/alias" });
        try repo.exec(&.{ "symbolic-ref", "HEAD", "refs/heads/outer" });
        const head = (try repo.git.head()).?;
        defer testing.allocator.free(head);
        try testing.expectEqualStrings("refs/heads/outer", head);
        try testing.expectError(error.SymbolicRef, repo.git.currentBranchAlloc());
        try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, old);
        try repo.expectOutput(&.{ "symbolic-ref", "--no-recurse", "HEAD" }, "refs/heads/outer");
    }
}

test "init refuses a symbolic base without adopting its target or changing state" {
    for (formats) |format| {
        for ([_]bool{ false, true }) |dangling| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            const old = try repo.initWork();
            defer testing.allocator.free(old);
            try alias(&repo, "refs/heads/main", if (dangling) null else old);
            try dirty(&repo);
            var before = try Snapshot.capture(&repo);
            defer before.deinit();
            try testing.expectError(error.SymbolicRef, stakrr.stack.initStack(&repo.git, "main"));
            try before.expectUnchanged(&repo);
            try expectSymbolic(&repo, "refs/heads/main");
        }
    }
}

test "linked worktree discovery checks shared loose refs and ignores lock files" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const old = try repo.commit("old");
        defer testing.allocator.free(old);
        try restore(&repo, subject, old);
        try repo.exec(&.{ "worktree", "add", "-q", "-b", "linked", ".git/linked worktree" });
        const dir = try repo.tmp.dir.openDir(testing.io, ".git/linked worktree", .{});
        defer dir.close(testing.io);
        var git = repo.git;
        git.cwd = dir;
        try repo.tmp.dir.writeFile(testing.io, .{
            .sub_path = ".git/refs/heads/stakrr/probe.lock",
            .data = "ref: refs/heads/missing\n",
        });
        var refs = try git.listDirectRefs(layout.layer_prefix);
        defer refs.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), refs.refs.len);
        try testing.expectEqualStrings(subject, refs.refs[0].name.bytes);
        try testing.expectEqualStrings(old, refs.refs[0].oid.hex());
        try alias(&repo, "refs/heads/stakrr/nested/orphan", null);
        try testing.expectError(error.SymbolicRef, git.listDirectRefs(layout.layer_prefix));
        try expectSymbolic(&repo, "refs/heads/stakrr/nested/orphan");
    }
}

test "CLI reports the symbolic ref and target while preserving user work" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    try alias(&repo, layout.state_ref, null);
    try dirty(&repo);
    var before = try Snapshot.capture(&repo);
    defer before.deinit();
    const result = try cli.run(&repo, &.{"status"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "symbolic ref; direct ref required") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, layout.state_ref) != null);
    try before.expectUnchanged(&repo);
    try expectSymbolic(&repo, layout.state_ref);
}

test "reset refuses to delete the checked-out layer through branch aliases" {
    for (formats) |format| {
        for ([_]bool{ false, true }) |nested| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            try setup(&repo);
            try repo.exec(&.{ "switch", "-q", "stakrr/models" });
            try repo.exec(&.{ "symbolic-ref", "refs/heads/alias", subject });
            const head_target = if (nested) "refs/heads/outer-alias" else "refs/heads/alias";
            if (nested) try repo.exec(&.{ "symbolic-ref", head_target, "refs/heads/alias" });
            try repo.exec(&.{ "symbolic-ref", "HEAD", head_target });

            // Confirm the fixture has an indirect HEAD and Git considers the
            // managed layer checked out, rather than merely pointing at its OID.
            try repo.expectOutput(&.{ "symbolic-ref", "--no-recurse", "HEAD" }, head_target);
            try repo.expectOutput(&.{ "symbolic-ref", "HEAD" }, subject);
            const worktrees = try repo.git.outputRaw(&.{ "worktree", "list", "--porcelain", "-z" });
            defer testing.allocator.free(worktrees);
            try testing.expect(std.mem.indexOf(u8, worktrees, "branch " ++ subject ++ "\x00") != null);
            var before = try Snapshot.capture(&repo);
            defer before.deinit();

            try testing.expectError(error.LayerCheckedOut, reset(&repo, true));
            try before.expectUnchanged(&repo);
            try expectAbsent(&repo, layout.transaction_ref);

            // The aliases themselves must not prevent deletion once the layer
            // is no longer checked out.
            try repo.exec(&.{ "switch", "-q", "work" });
            try reset(&repo, true);
            try expectAbsent(&repo, subject);
            try repo.expectOutput(&.{ "symbolic-ref", "--no-recurse", "refs/heads/alias" }, subject);
        }
    }
}

test "reset preserves dirty work when another worktree owns a requested layer" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try setup(&repo);
        const path = "linked space\nbranch refs/heads/stakrr/fake";
        try repo.exec(&.{ "worktree", "add", "-q", path, "stakrr/models" });
        try dirty(&repo);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        const linked_head = try repo.git.outputRaw(&.{ "-C", path, "rev-parse", "HEAD" });
        defer testing.allocator.free(linked_head);

        try testing.expectError(error.BranchOccupied, reset(&repo, true));
        try before.expectUnchanged(&repo);
        const after_head = try repo.git.outputRaw(&.{ "-C", path, "rev-parse", "HEAD" });
        defer testing.allocator.free(after_head);
        try testing.expectEqualStrings(linked_head, after_head);
        const result = try cli.run(&repo, &.{ "reset", "--delete-layers" });
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 1), result.code);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "checked out in another worktree") != null);
        try before.expectUnchanged(&repo);

        // Refusal releases the shared lock, allowing retry after detaching.
        try repo.exec(&.{ "-C", path, "switch", "-q", "--detach" });
        try reset(&repo, true);
        try expectAbsent(&repo, subject);
        try repo.expectFile("tracked", "unstaged work\n");
        try repo.expectFile("untracked", "untracked work\n");
    }
}

test "reset distinguishes own and duplicate layer checkouts with separate Git directories" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try repo.exec(&.{ "init", "-q", "--separate-git-dir=.git-data space" });
        try setup(&repo);
        try repo.exec(&.{ "switch", "-q", "stakrr/models" });
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        try testing.expectError(error.LayerCheckedOut, reset(&repo, true));
        try before.expectUnchanged(&repo);
        try repo.exec(&.{ "switch", "-q", "work" });

        const path = ".git-data space/duplicate space\n";
        try repo.exec(&.{ "worktree", "add", "-q", path, "stakrr/models" });
        try repo.exec(&.{ "worktree", "add", "-q", "--force", ".git-data space/second", "stakrr/models" });
        try testing.expectError(error.BranchOccupied, reset(&repo, true));
        try repo.exec(&.{ "-C", path, "switch", "-q", "--detach" });
        // A second forced checkout must still block after the first detaches.
        try testing.expectError(error.BranchOccupied, reset(&repo, true));
        try repo.exec(&.{ "-C", ".git-data space/second", "switch", "-q", "--detach" });
        try reset(&repo, true);
        try expectAbsent(&repo, subject);
    }
}

test "reset checks layers from a linked worktree of a bare repository" {
    for (formats) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        testing.allocator.free(try repo.commit("seed"));
        try repo.exec(&.{ "clone", "--bare", "-q", ".", ".git/bare.git" });
        const metadata = try repo.tmp.dir.realPathFileAlloc(testing.io, ".git", testing.allocator);
        defer testing.allocator.free(metadata);
        const path = try std.fs.path.join(testing.allocator, &.{ metadata, "linked main\n" });
        defer testing.allocator.free(path);
        try repo.exec(&.{ "-C", ".git/bare.git", "worktree", "add", "-q", path, "main" });
        const dir = try repo.tmp.dir.openDir(testing.io, path, .{});
        defer dir.close(testing.io);
        // Borrow fixture ownership and use its existing helpers in this worktree.
        var view = repo;
        view.tmp.dir = dir;
        view.git.cwd = dir;
        try view.exec(&.{ "config", "user.name", "Stakrr Test" });
        try view.exec(&.{ "config", "user.email", "test@stakrr.local" });
        try view.exec(&.{ "config", "core.hooksPath", "/dev/null" });
        try view.exec(&.{ "config", "commit.gpgsign", "false" });
        try setup(&view);
        try view.exec(&.{ "switch", "-q", "stakrr/models" });
        var before = try Snapshot.capture(&view);
        defer before.deinit();
        try testing.expectError(error.LayerCheckedOut, reset(&view, true));
        try before.expectUnchanged(&view);
        try view.exec(&.{ "switch", "-q", "work" });
        try reset(&view, true);
        try expectAbsent(&view, subject);
    }
}

const RecoveryCase = enum { update_old, update_new, create_old, create_new, delete_old, delete_new, journal, journal_dangling };
const Change = struct { name: []const u8, old: ?[]const u8, new: ?[]const u8 };

fn recovery(kind: RecoveryCase, inject: bool, race_label: ?[]const u8) !void {
    try eachFormat(recoveryCase, .{ kind, inject, race_label });
}

fn recoveryCase(format: []const u8, kind: RecoveryCase, inject: bool, race_label: ?[]const u8) !void {
    var repo = try Repo.initOptions(.{ .object_format = format });
    defer repo.deinit();
    const old = try repo.commit("old");
    defer testing.allocator.free(old);
    const new = try repo.commit("new");
    defer testing.allocator.free(new);
    const creating = kind == .create_old or kind == .create_new;
    const deleting = kind == .delete_old or kind == .delete_new;
    const published = kind == .update_new or kind == .create_new or kind == .delete_new;
    const changes = [_]Change{
        .{ .name = subject, .old = if (creating) null else old, .new = if (deleting) null else new },
        .{ .name = "refs/stakrr/collateral", .old = old, .new = new },
    };
    const actual = if (published) changes[0].new else changes[0].old;
    try restore(&repo, subject, actual);
    // For cleanup races publication is already complete; cleanup must still
    // refuse a symbolic journal, without deleting its unrelated target.
    const cleanup = if (race_label) |label| std.mem.eql(u8, label, "stakrr: finish transaction") else false;
    try restore(&repo, "refs/stakrr/collateral", if (cleanup) new else old);
    const metadata = try std.json.Stringify.valueAlloc(testing.allocator, .{
        .version = @as(u8, 1),
        .label = "test symbolic recovery",
        .changes = &changes,
    }, .{});
    defer testing.allocator.free(metadata);
    const blob = try repo.git.writeBlob(metadata);
    defer testing.allocator.free(blob);
    const tree = try repo.git.writeTree(&.{.{ .name = "transaction.json", .oid = blob }});
    defer testing.allocator.free(tree);
    const saved = try repo.git.commitTree(tree, &.{ old, new }, "pending publication");
    defer testing.allocator.free(saved);
    try restore(&repo, layout.transaction_ref, saved);
    const journal = kind == .journal or kind == .journal_dangling or cleanup;
    const name = if (journal) layout.transaction_ref else subject;
    const initial: ?[]const u8 = if (kind == .journal_dangling) null else if (journal) saved else actual;

    if (inject) {
        if (race_label) |label| try race(&repo, label, name);
        try alias(&repo, name, initial);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        if (race_label != null) try restore(&repo, name, initial);

        const result = try driver(&repo, &.{"recover"});
        defer result.deinit();
        if (race_label != null) try expectRaceFired(&repo);
        try before.expectUnchanged(&repo);
        try expectSymbolic(&repo, name);
        if (initial) |oid| try expectDirect(&repo, victim, oid) else try expectAbsent(&repo, victim);
        if (kind != .journal_dangling)
            try repo.expectOutput(&.{ "rev-parse", "--verify", layout.transaction_ref }, saved);
        // The recovery contract treats an unexpected ref identity like an
        // unexpected OID (RefTransactionChanged).
        try expectDriverError(result, if (race_label == null) error.RefTransactionChanged else error.GitFailed);

        // Refusal must leave a usable intent. Repair only the substituted
        // ref, then let real recovery finish the original operation.
        _ = repo.env.swapRemove("STAKRR_TEST_SYMREF_LABEL");
        try restore(&repo, name, if (journal) saved else initial);
    }
    const recovered = try driver(&repo, &.{"recover"});
    defer recovered.deinit();
    try testing.expectEqual(@as(?u8, 0), recovered.code);
    if (changes[0].new) |oid| try expectDirect(&repo, subject, oid) else try expectAbsent(&repo, subject);
    try expectDirect(&repo, "refs/stakrr/collateral", new);
    try expectAbsent(&repo, layout.transaction_ref);
    if (inject) {
        if (initial) |oid| try expectDirect(&repo, victim, oid) else try expectAbsent(&repo, victim);
    }
}

test "direct recovery controls accept old new and absent values" {
    for (std.enums.values(RecoveryCase)) |kind| try recovery(kind, false, null);
}

test "recovery refuses a symbolic ref at the recorded old update value" {
    try recovery(.update_old, true, null);
}

test "recovery refuses a symbolic ref at the already published update value" {
    try recovery(.update_new, true, null);
}

test "recovery refuses a dangling symbolic ref where creation expected absence" {
    try recovery(.create_old, true, null);
}

test "recovery refuses a symbolic ref at the already published creation value" {
    try recovery(.create_new, true, null);
}

test "recovery refuses a symbolic ref awaiting deletion" {
    try recovery(.delete_old, true, null);
}

test "recovery refuses a dangling symbolic ref where deletion was already published" {
    try recovery(.delete_new, true, null);
}

test "recovery refuses a symbolic transaction journal" {
    try recovery(.journal, true, null);
}

test "recovery refuses a dangling symbolic transaction journal instead of treating it as absent" {
    try recovery(.journal_dangling, true, null);
}

test "recovery refuses symbolic substitution after comparing current refs" {
    try recovery(.update_old, true, "test symbolic recovery");
}

test "recovery cleanup refuses a transaction journal substituted before deletion" {
    try recovery(.update_new, true, "stakrr: finish transaction");
}

fn fix(repo: *const Repo) !void {
    var result = try stakrr.fix.fix(&repo.git, .{ .layer = "models", .how = .{ .message = "fix" } });
    defer result.deinit(testing.allocator);
}

fn fixRef(name: []const u8) !void {
    try eachFormat(fixRefCase, .{name});
}

fn fixRefCase(format: []const u8, name: []const u8) !void {
    var repo = try Repo.initOptions(.{ .object_format = format });
    defer repo.deinit();
    try fixture.setup(&repo);
    if (std.mem.eql(u8, name, layout.oplog_ref)) {
        try dirtyFix(&repo);
        try repo.write("model", "first fix\n");
        try repo.exec(&.{ "add", "model" });
        try fix(&repo); // Give the oplog a real completed checkpoint.
    }
    try dirtyFix(&repo);
    try testing.expect(!(try repo.git.check(&.{ "diff", "--cached", "--quiet" }, 1)));
    const old = (try repo.readRef(name)).?;
    defer testing.allocator.free(old);
    try alias(&repo, name, old);
    var before = try Snapshot.capture(&repo);
    defer before.deinit();

    const result = fix(&repo);
    try before.expectUnchanged(&repo);
    try expectSymbolic(&repo, name);
    try expectDirect(&repo, victim, old);
    try expectAbsent(&repo, layout.transaction_ref);
    try expectAbsent(&repo, layout.session_ref);
    try testing.expectError(error.SymbolicRef, result);
}

test "fix refuses symbolic layer branches" {
    try fixRef(subject);
}

test "fix refuses a symbolic tip" {
    try fixRef(layout.state_ref);
}

test "fix refuses a symbolic rolling branch" {
    try fixRef("refs/heads/work");
}

test "fix refuses a symbolic base branch" {
    try fixRef("refs/heads/main");
}

test "fix refuses a symbolic operation log" {
    try fixRef(layout.oplog_ref);
}

fn commandRace(is_fix: bool, name: []const u8, label: []const u8) !void {
    try eachFormat(commandRaceCase, .{ is_fix, name, label });
}

fn commandRaceCase(format: []const u8, is_fix: bool, name: []const u8, label: []const u8) !void {
    var repo = try Repo.initOptions(.{ .object_format = format });
    defer repo.deinit();
    try fixture.setup(&repo);
    try dirtyFix(&repo);
    const old = (try repo.readRef(name)).?;
    defer testing.allocator.free(old);
    try race(&repo, label, name);
    // The expected state includes the external writer's substitution.
    try alias(&repo, name, old);
    var before = try Snapshot.capture(&repo);
    defer before.deinit();
    try restore(&repo, name, old);

    const result = try driver(&repo, &.{if (is_fix) "fix" else "reset"});
    defer result.deinit();
    try expectRaceFired(&repo);
    try before.expectUnchanged(&repo);
    try expectSymbolic(&repo, name); // Proves the selected race actually ran.
    try expectDirect(&repo, victim, old);
    try expectAbsent(&repo, layout.transaction_ref);
    try expectDriverError(result, error.GitFailed);
}

test "reset refuses symbolic substitution after discovery before intent creation" {
    try commandRace(false, subject, "stakrr: prepare transaction");
}

test "reset refuses symbolic substitution after intent creation before publication" {
    try commandRace(false, subject, "stakrr: reset");
}

test "fix refuses symbolic substitution after discovery before intent creation" {
    try commandRace(true, subject, "stakrr: prepare transaction");
}

test "fix refuses symbolic substitution after intent creation before publication" {
    try commandRace(true, subject, "stakrr: fix");
}

test "fix refuses a guard becoming symbolic immediately before publication" {
    try commandRace(true, layout.state_ref, "stakrr: fix");
}

fn dirtyFix(repo: *const Repo) !void {
    try repo.write("model", "staged fix\n");
    try repo.exec(&.{ "add", "model" });
    try repo.write("tail", "unstaged work\n");
}
