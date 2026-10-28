const std = @import("std");
const testing = std.testing;
const stack = @import("stakrr").stack;
const Repo = @import("support/repo.zig").Repo;

test "reset refuses symbolic stakrr refs without changing refs or config" {
    for ([_][]const u8{ "refs/stakrr/anchor", "refs/stakrr/tip", "refs/heads/stakrr/p1" }) |ref_name| {
        var repo = try Repo.init();
        defer repo.deinit();

        const base = try repo.initStack();
        defer testing.allocator.free(base);
        const b = try repo.commit("B");
        defer testing.allocator.free(b);
        try stack.cut(&repo.git, "p1", null);

        // Ref identity must survive refusal, even when the OID matches.
        try repo.exec(&.{ "symbolic-ref", ref_name, "refs/heads/work" });
        const delete_layers = std.mem.startsWith(u8, ref_name, "refs/heads/");
        const refs = try repo.git.outputRaw(&.{ "for-each-ref", "--format=%(refname)%09%(objectname)%09%(symref)" });
        defer testing.allocator.free(refs);
        const config = try repo.git.outputRaw(&.{ "config", "--local", "--null", "--list" });
        defer testing.allocator.free(config);
        try testing.expectError(error.SymbolicRef, stack.reset(&repo.git, delete_layers));
        const refs_after = try repo.git.outputRaw(&.{ "for-each-ref", "--format=%(refname)%09%(objectname)%09%(symref)" });
        defer testing.allocator.free(refs_after);
        const config_after = try repo.git.outputRaw(&.{ "config", "--local", "--null", "--list" });
        defer testing.allocator.free(config_after);
        try testing.expectEqualStrings(refs, refs_after);
        try testing.expectEqualStrings(config, config_after);

        const work = try repo.git.readRef("refs/heads/work");
        defer if (work) |value| testing.allocator.free(value);
        try testing.expect(work != null);
        try testing.expectEqualStrings(b, work.?);
        const main = try repo.git.readRef("refs/heads/main");
        defer if (main) |value| testing.allocator.free(value);
        try testing.expect(main != null);
        try testing.expectEqualStrings(base, main.?);
        try repo.expectOutput(&.{ "symbolic-ref", "--no-recurse", ref_name }, "refs/heads/work");
        const state = try repo.git.configGet(stack.state_key);
        defer if (state) |value| testing.allocator.free(value);
        try testing.expect(state != null);
    }
}

test "reset on an uninitialized repository reports NotInitialized" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);

    try testing.expectError(
        error.NotInitialized,
        stack.reset(&repo.git, false),
    );
}

test "reset keeps layers by default and blocks re-init until they go" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);

    const result = try stack.reset(&repo.git, false);
    try testing.expectEqual(@as(usize, 1), result.kept_layers);
    try testing.expectEqual(@as(usize, 0), result.deleted_layers);

    try testing.expect(try repo.hasRef("refs/heads/stakrr/p1"));
    try repo.expectNoRef("refs/stakrr/tip");
    try repo.expectNoRef("refs/stakrr/anchor");

    try testing.expectError(
        error.NotInitialized,
        stack.inspect(&repo.git),
    );
    try testing.expectError(
        error.ExistingStackRefs,
        stack.initStack(&repo.git, "main"),
    );
}

test "reset --delete-layers allows a clean re-init" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);
    try stack.cut(&repo.git, "p2", null);

    const result = try stack.reset(&repo.git, true);
    try testing.expectEqual(@as(usize, 2), result.deleted_layers);
    try repo.expectNoRef("refs/heads/stakrr/p1");
    try repo.expectNoRef("refs/heads/stakrr/p2");

    // the rolling branch is untouched
    const work = (try repo.git.readRef("refs/heads/work")).?;
    defer testing.allocator.free(work);
    try testing.expectEqualStrings(c, work);

    try stack.initStack(&repo.git, "main");
}

test "reset recovers from corrupt and outdated state" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    // duplicate values make configGet fail; reset must not depend on it
    try repo.exec(&.{ "config", "--local", "--add", "stakrr.state", "v1 garbage" });

    try testing.expectError(
        error.InvalidGitConfig,
        stack.inspect(&repo.git),
    );

    _ = try stack.reset(&repo.git, false);
    try stack.initStack(&repo.git, "main");
}

test "reset refuses to delete a checked-out layer" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);

    try repo.exec(&.{ "switch", "-q", "stakrr/p1" });

    try testing.expectError(
        error.LayerCheckedOut,
        stack.reset(&repo.git, true),
    );
    try testing.expect(try repo.hasRef("refs/stakrr/anchor"));
}

test "reset refuses to delete a layer checked out in another worktree" {
    for ([_]bool{ false, true }) |detached| {
        var repo = try Repo.init();
        defer repo.deinit();

        const base = try repo.initStack();
        defer testing.allocator.free(base);
        const b = try repo.commit("B");
        defer testing.allocator.free(b);
        try stack.cut(&repo.git, "p1", null);

        // Newlines in paths must not be confused with porcelain fields.
        try repo.exec(&.{ "worktree", "add", "-q", "linked\nbranch refs/heads/stakrr/other", "stakrr/p1" });
        if (detached) try repo.exec(&.{ "switch", "-q", "--detach", "HEAD" });

        try testing.expectError(error.BranchOccupied, stack.reset(&repo.git, true));

        // Refusal must leave both the shared state and the linked HEAD intact.
        var snapshot = try stack.inspect(&repo.git);
        defer snapshot.deinit();
        try testing.expectEqual(@as(usize, 1), snapshot.layers.len);
        const linked_head = try repo.git.output(&.{ "-C", "linked\nbranch refs/heads/stakrr/other", "rev-parse", "HEAD" });
        defer testing.allocator.free(linked_head);
        try testing.expectEqualStrings(b, linked_head);
    }
}

test "reset can keep a layer checked out in another worktree" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);
    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);
    try repo.exec(&.{ "worktree", "add", "-q", "linked", "stakrr/p1" });

    const result = try stack.reset(&repo.git, false);
    try testing.expectEqual(@as(usize, 1), result.kept_layers);
    const linked_head = try repo.git.output(&.{ "-C", "linked", "rev-parse", "HEAD" });
    defer testing.allocator.free(linked_head);
    try testing.expectEqualStrings(b, linked_head);
}

test "reset allows another worktree on an unrelated branch" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.initStack();
    defer testing.allocator.free(base);
    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);
    // A path can contain text that looks like a branch field in non-NUL output.
    const path = "linked\nbranch refs/heads/stakrr/fake";
    try repo.exec(&.{ "worktree", "add", "-q", path, "main" });

    const result = try stack.reset(&repo.git, true);
    try testing.expectEqual(@as(usize, 1), result.deleted_layers);
    try repo.expectNoRef("refs/heads/stakrr/p1");
    const linked_head = try repo.git.output(&.{ "-C", path, "rev-parse", "HEAD" });
    defer testing.allocator.free(linked_head);
    try testing.expectEqualStrings(base, linked_head);
}
