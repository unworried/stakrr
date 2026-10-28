const std = @import("std");
const layout = @import("stakrr").layout;
const testing = std.testing;
const stack = @import("stakrr").stack;
const Repo = @import("support/repo.zig").Repo;

test "cut at HEAD creates the first layer without moving work" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try stack.cut(&repo.git, "p1", null);

    try repo.expectRef("refs/heads/main", base);
    try repo.expectRef("refs/heads/work", b);
    try repo.expectRef("refs/heads/stakrr/p1", b);
    try repo.expectRef(layout.tip_ref, b);

    const head = try repo.git.currentBranchAlloc();
    defer testing.allocator.free(head);

    try testing.expectEqualStrings("refs/heads/work", head);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 1), snapshot.layers.len);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[0].commits);
    try testing.expectEqual(@as(usize, 0), snapshot.unstacked_commits);
}

test "cut at an earlier commit leaves rolling work untouched" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try stack.cut(&repo.git, "p1", "HEAD~1");

    try repo.expectRef("refs/heads/stakrr/p1", b);
    try repo.expectRef("refs/heads/work", c);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 1), snapshot.unstacked_commits);
}

test "two sequential cuts create ordered boundaries" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    const d = try repo.commit("D");
    defer testing.allocator.free(d);

    try stack.cut(&repo.git, "p1", "HEAD~1");
    try stack.cut(&repo.git, "p2", null);

    try repo.expectRef("refs/heads/stakrr/p1", c);
    try repo.expectRef("refs/heads/stakrr/p2", d);
    try repo.expectRef(layout.tip_ref, d);
    try repo.expectRef("refs/heads/main", base);
    try repo.expectRef("refs/heads/work", d);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();

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

    const base = try repo.initStack();
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

    try repo.expectNoRef("refs/heads/stakrr/p2");
}

test "cut rejects older and unrelated boundaries" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
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

    try repo.expectNoRef("refs/heads/stakrr/p2");

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

    const base = try repo.initStack();
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

    try repo.expectRef("refs/heads/stakrr/p1", b);
    try repo.expectRef(layout.tip_ref, b);

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

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "main" });

    try testing.expectError(
        error.NotOnWorkBranch,
        stack.cut(&repo.git, "p1", null),
    );

    try repo.expectNoRef("refs/heads/stakrr/p1");
}

test "cut still works after the base moves" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "main" });
    const moved = try repo.commit("moved main");
    defer testing.allocator.free(moved);
    try repo.exec(&.{ "switch", "-q", "work" });

    try stack.cut(&repo.git, "p1", null);
    try repo.expectRef("refs/heads/stakrr/p1", b);

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();

    try testing.expect(snapshot.base_moved);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[0].commits);
}

test "cut allows staged changes without changing the index" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
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

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    var mutation = try repo.git.beginStackMutation();
    defer mutation.deinit();
    try testing.expectError(
        error.GitFailed,
        stack.createLayerRef(&mutation, .{
            .layer = try repo.git.expectedRef("refs/heads/stakrr/race", b),
            .anchor = try repo.git.expectedRef(layout.anchor_ref, base),
            .work = try repo.git.expectedRef("refs/heads/work", b),
        }),
    );

    try repo.expectNoRef("refs/heads/stakrr/race");
    try repo.expectNoRef(layout.tip_ref);
}

test "ref transaction aborts if the stack is reset after inspection" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    _ = try stack.reset(&repo.git, .{});

    var mutation = try repo.git.beginStackMutation();
    defer mutation.deinit();
    try testing.expectError(
        error.GitFailed,
        stack.createLayerRef(&mutation, .{
            .layer = try repo.git.expectedRef("refs/heads/stakrr/race", b),
            .anchor = try repo.git.expectedRef(layout.anchor_ref, base),
            .work = try repo.git.expectedRef("refs/heads/work", b),
        }),
    );

    try repo.expectNoRef("refs/heads/stakrr/race");
}

test "ref transaction rejects two cuts from the same old tip" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    var mutation = try repo.git.beginStackMutation();
    defer mutation.deinit();
    const expected_base = try repo.git.expectedRef(layout.anchor_ref, base);

    const expected_work = try repo.git.expectedRef("refs/heads/work", c);

    try stack.createLayerRef(&mutation, .{
        .layer = try repo.git.expectedRef("refs/heads/stakrr/first", b),
        .anchor = expected_base,
        .work = expected_work,
    });

    try testing.expectError(
        error.GitFailed,
        stack.createLayerRef(&mutation, .{
            .layer = try repo.git.expectedRef("refs/heads/stakrr/second", c),
            .anchor = expected_base,
            .work = expected_work,
        }),
    );

    try repo.expectNoRef("refs/heads/stakrr/second");
    try repo.expectRef("refs/heads/stakrr/first", b);
    try repo.expectRef(layout.tip_ref, b);
}

test "cut rejects a side branch outside the rolling history" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
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

    try repo.expectNoRef("refs/heads/stakrr/outside");
    try repo.expectNoRef(layout.tip_ref);
}
