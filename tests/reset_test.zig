const std = @import("std");
const testing = std.testing;
const stack = @import("stakrr").stack;
const Repo = @import("support/repo.zig").Repo;

fn initialize(repo: *const Repo) ![]u8 {
    const base = try repo.commit("base");
    errdefer testing.allocator.free(base);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");
    return base;
}

fn refExists(repo: *const Repo, ref_name: []const u8) !bool {
    const oid = try repo.git.readRef(ref_name);
    defer if (oid) |value| testing.allocator.free(value);
    return oid != null;
}

test "reset on an uninitialized repository reports NotInitialized" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);

    try testing.expectError(
        error.NotInitialized,
        stack.reset(&repo.git, .{}),
    );
}

test "reset keeps layers by default and blocks re-init until they go" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);

    const result = try stack.reset(&repo.git, .{});
    try testing.expectEqual(@as(usize, 1), result.kept_layers);
    try testing.expectEqual(@as(usize, 0), result.deleted_layers);

    try testing.expect(try refExists(&repo, "refs/heads/stakrr/p1"));
    try testing.expect(!try refExists(&repo, "refs/stakrr/tip"));
    try testing.expect(!try refExists(&repo, "refs/stakrr/anchor"));

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

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);
    try stack.cut(&repo.git, "p2", null);

    const result = try stack.reset(&repo.git, .{ .delete_layers = true });
    try testing.expectEqual(@as(usize, 2), result.deleted_layers);
    try testing.expect(!try refExists(&repo, "refs/heads/stakrr/p1"));
    try testing.expect(!try refExists(&repo, "refs/heads/stakrr/p2"));

    // the rolling branch is untouched
    const work = (try repo.git.readRef("refs/heads/work")).?;
    defer testing.allocator.free(work);
    try testing.expectEqualStrings(c, work);

    try stack.initStack(&repo.git, "main");
}

test "reset recovers from corrupt and outdated state" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    // duplicate values make configGet fail; reset must not depend on it
    try repo.exec(&.{ "config", "--local", "--add", "stakrr.state", "v1 garbage" });

    try testing.expectError(
        error.InvalidGitConfig,
        stack.inspect(&repo.git),
    );

    _ = try stack.reset(&repo.git, .{});
    try stack.initStack(&repo.git, "main");
}

test "reset refuses to delete a checked-out layer" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);

    try repo.exec(&.{ "switch", "-q", "stakrr/p1" });

    try testing.expectError(
        error.LayerCheckedOut,
        stack.reset(&repo.git, .{ .delete_layers = true }),
    );
    try testing.expect(try refExists(&repo, "refs/stakrr/anchor"));
}

test "reset refuses layers occupied in linked worktrees without changing any state" {
    var repo = try Repo.init();
    defer repo.deinit();
    const base = try initialize(&repo);
    defer testing.allocator.free(base);
    const layer = try repo.commit("layer");
    defer testing.allocator.free(layer);
    try stack.cut(&repo.git, "p1", null);
    const path = "linked space\nnewline";
    try repo.exec(&.{ "worktree", "add", "-q", path, "stakrr/p1" });

    try testing.expectError(error.BranchOccupied, stack.reset(&repo.git, .{ .delete_layers = true }));
    for ([_][]const u8{ "refs/stakrr/anchor", "refs/stakrr/tip", "refs/heads/stakrr/p1" }) |ref|
        try testing.expect(try refExists(&repo, ref));
    const config = (try repo.git.configGet(stack.state_key)).?;
    defer testing.allocator.free(config);
    try testing.expectEqualStrings("v1 refs/heads/main refs/heads/work", config);
    const head = try repo.git.output(&.{ "-C", path, "rev-parse", "HEAD" });
    defer testing.allocator.free(head);
    try testing.expectEqualStrings(layer, head);
    const status = try repo.git.output(&.{ "-C", path, "status", "--porcelain=v1" });
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
    try repo.exec(&.{ "-C", path, "switch", "-q", "--detach" });
    _ = try stack.reset(&repo.git, .{ .delete_layers = true });
}
