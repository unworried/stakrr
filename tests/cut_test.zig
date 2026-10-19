const std = @import("std");
const testing = std.testing;
const stack = @import("stakrr").stack;
const Git = @import("stakrr").git.Git;
const Repo = @import("support/repo.zig").Repo;

fn initialize(repo: *const Repo) ![]u8 {
    const base = try repo.commit("base");
    errdefer testing.allocator.free(base);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");
    return base;
}

fn expectRef(
    repo: *const Repo,
    ref_name: []const u8,
    expected: []const u8,
) !void {
    const actual = try repo.git.resolveCommit(ref_name);
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

fn expectNoRef(repo: *const Repo, ref_name: []const u8) !void {
    const result = try repo.git.run(&.{
        "show-ref", "--verify", "--quiet", ref_name,
    });
    defer repo.git.freeResult(result);
    try testing.expect(!result.term.success());
}

test "cut at HEAD creates the first layer without moving work" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try stack.cut(&repo.git, "p1", null);

    try expectRef(&repo, "refs/heads/main", base);
    try expectRef(&repo, "refs/heads/work", b);
    try expectRef(&repo, "refs/heads/stakrr/p1", b);
    try expectRef(&repo, "refs/stakrr/tip", b);

    const head = try repo.git.currentBranch();
    defer testing.allocator.free(head);

    try testing.expectEqualStrings("refs/heads/work", head);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.layers.len);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[0].commits);
    try testing.expectEqual(@as(usize, 0), snapshot.unstacked_commits);
}

test "cut at an earlier commit leaves rolling work untouched" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try stack.cut(&repo.git, "p1", "HEAD~1");

    try expectRef(&repo, "refs/heads/stakrr/p1", b);
    try expectRef(&repo, "refs/heads/work", c);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.unstacked_commits);
}

test "two sequential cuts create ordered boundaries" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    const d = try repo.commit("D");
    defer testing.allocator.free(d);

    try stack.cut(&repo.git, "p1", "HEAD~1");
    try stack.cut(&repo.git, "p2", null);

    try expectRef(&repo, "refs/heads/stakrr/p1", c);
    try expectRef(&repo, "refs/heads/stakrr/p2", d);
    try expectRef(&repo, "refs/stakrr/tip", d);
    try expectRef(&repo, "refs/heads/main", base);
    try expectRef(&repo, "refs/heads/work", d);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), snapshot.layers.len);

    try testing.expectEqualStrings(
        "refs/heads/stakrr/p1",
        snapshot.layers[0].ref_name,
    );

    try testing.expectEqualStrings(
        "refs/heads/stakrr/p2",
        snapshot.layers[1].ref_name,
    );

    try testing.expectEqual(@as(usize, 2), snapshot.layers[0].commits);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[1].commits);
    try testing.expectEqual(@as(usize, 0), snapshot.unstacked_commits);
}

test "cut rejects empty boundaries" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try testing.expectError(
        error.EmptyCut,
        stack.cut(&repo.git, "p1", null),
    );

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try stack.cut(&repo.git, "p1", null);

    try testing.expectError(
        error.EmptyCut,
        stack.cut(&repo.git, "p2", null),
    );

    try expectNoRef(&repo, "refs/heads/stakrr/p2");
}

test "cut rejects older and unrelated boundaries" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try stack.cut(&repo.git, "p1", null);

    try testing.expectError(
        error.InvalidCutBoundary,
        stack.cut(&repo.git, "p2", b),
    );

    try expectNoRef(&repo, "refs/heads/stakrr/p2");

    try repo.exec(&.{ "branch", "unrelated", "main" });
    try repo.exec(&.{ "switch", "-q", "unrelated" });

    const unrelated = try repo.commit("unrelated");
    defer testing.allocator.free(unrelated);

    try repo.exec(&.{ "switch", "-q", "work" });

    try testing.expectError(
        error.InvalidCutBoundary,
        stack.cut(&repo.git, "p2", unrelated),
    );
}

test "cut rejects duplicate or invalid layer names" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try stack.cut(&repo.git, "p1", null);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try testing.expectError(
        error.LayerExists,
        stack.cut(&repo.git, "p1", null),
    );

    // directory/file conflicts with an existing layer
    try testing.expectError(
        error.LayerExists,
        stack.cut(&repo.git, "p1/sub", null),
    );

    try expectRef(&repo, "refs/heads/stakrr/p1", b);
    try expectRef(&repo, "refs/stakrr/tip", b);

    try testing.expectError(
        error.InvalidLayerName,
        stack.cut(&repo.git, "../bad", null),
    );

    try testing.expectError(
        error.InvalidLayerName,
        stack.cut(&repo.git, "", null),
    );

    try testing.expectError(
        error.InvalidLayerName,
        stack.cut(&repo.git, "-x", null),
    );
}

test "cut rejects a non-work branch" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "main" });

    try testing.expectError(
        error.NotOnWorkBranch,
        stack.cut(&repo.git, "p1", null),
    );

    try expectNoRef(&repo, "refs/heads/stakrr/p1");
}

test "cut still works after the base moves" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "main" });
    const moved = try repo.commit("moved main");
    defer testing.allocator.free(moved);
    try repo.exec(&.{ "switch", "-q", "work" });

    try stack.cut(&repo.git, "p1", null);
    try expectRef(&repo, "refs/heads/stakrr/p1", b);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit(testing.allocator);

    try testing.expect(snapshot.base_moved);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[0].commits);
}

test "cut allows staged changes without changing the index" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.tmp.dir.writeFile(testing.io, .{
        .sub_path = "dirty.txt",
        .data = "staged work\n",
    });

    try repo.exec(&.{ "add", "dirty.txt" });

    const before = try repo.git.output(&.{
        "status", "--porcelain=v1",
    });
    defer testing.allocator.free(before);

    try stack.cut(&repo.git, "p1", null);

    const after = try repo.git.output(&.{
        "status", "--porcelain=v1",
    });
    defer testing.allocator.free(after);

    try testing.expectEqualStrings(before, after);
}

test "ref transaction aborts if work changes after inspection" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try testing.expectError(
        error.GitFailed,
        repo.git.createLayerRef(
            "refs/heads/stakrr/race",
            b,
            .{ .name = "refs/stakrr/anchor", .oid = base },
            .{ .name = "refs/heads/work", .oid = b },
            null,
        ),
    );

    try expectNoRef(&repo, "refs/heads/stakrr/race");
    try expectNoRef(&repo, "refs/stakrr/tip");
}

test "ref transaction rejects two cuts from the same old tip" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    const expected_base = Git.ExpectedRef{
        .name = "refs/stakrr/anchor",
        .oid = base,
    };

    const expected_work = Git.ExpectedRef{
        .name = "refs/heads/work",
        .oid = c,
    };

    try repo.git.createLayerRef(
        "refs/heads/stakrr/first",
        b,
        expected_base,
        expected_work,
        null,
    );

    try testing.expectError(
        error.GitFailed,
        repo.git.createLayerRef(
            "refs/heads/stakrr/second",
            c,
            expected_base,
            expected_work,
            null,
        ),
    );

    try expectNoRef(&repo, "refs/heads/stakrr/second");
    try expectRef(&repo, "refs/heads/stakrr/first", b);
    try expectRef(&repo, "refs/stakrr/tip", b);
}

test "cut rejects a side branch outside the rolling history" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "-c", "side", "main" });

    const side = try repo.commit("side commit");
    defer testing.allocator.free(side);

    try repo.exec(&.{ "switch", "-q", "work" });

    try testing.expectError(
        error.CutOutsideWork,
        stack.cut(&repo.git, "outside", side),
    );

    try expectNoRef(&repo, "refs/heads/stakrr/outside");
    try expectNoRef(&repo, "refs/stakrr/tip");
}
