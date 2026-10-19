const std = @import("std");
const testing = std.testing;

const stack = @import("stakrr").stack;

const support = @import("support/repo.zig");
const Repo = support.Repo;

fn setState(repo: *const Repo, state: []const u8) !void {
    try repo.exec(&.{
        "config",
        "--local",
        "--replace-all",
        "stakrr.state",
        state,
    });
}

/// returns the owned base oid. caller must free it
fn initialize(repo: *const Repo) ![]u8 {
    const base = try repo.commit("base");
    errdefer testing.allocator.free(base);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");

    return base;
}

fn addMerge(repo: *const Repo) !void {
    try repo.exec(&.{ "switch", "-q", "-c", "side", "main" });

    const side = try repo.commit("side change");
    defer testing.allocator.free(side);

    try repo.exec(&.{ "switch", "-q", "work" });

    const work = try repo.commit("work change");
    defer testing.allocator.free(work);

    // produce a merge commit without file conflicts
    try repo.exec(&.{
        "merge", "--no-ff",    "-s",   "ours",
        "-m",    "merge side", "side",
    });
}

fn expectNoState(repo: *const Repo) !void {
    const state = try repo.git.configGet("stakrr.state");
    defer if (state) |value| testing.allocator.free(value);
    try testing.expect(state == null);

    const anchor = try repo.git.readRef("refs/stakrr/anchor");
    defer if (anchor) |oid| testing.allocator.free(oid);
    try testing.expect(anchor == null);
}

test "loadConfig rejects missing state" {
    var repo = try Repo.init();
    defer repo.deinit();

    try testing.expectError(
        error.NotInitialized,
        stack.loadConfig(&repo.git),
    );
}

test "loadConfig parses initialized state" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    var config = try stack.loadConfig(&repo.git);
    defer config.deinit(repo.git.allocator);

    try testing.expectEqualStrings(
        "refs/heads/main",
        config.base_ref,
    );
    try testing.expectEqualStrings(
        "refs/heads/work",
        config.work_ref,
    );
    try testing.expectEqualStrings(
        base,
        config.anchor_oid,
    );
}

test "loadConfig rejects malformed state" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const cases = [_]struct {
        value: []const u8,
        expected: anyerror,
    }{
        .{
            .value = "v2 refs/heads/main refs/heads/work",
            .expected = error.UnsupportedConfigVersion,
        },
        .{
            .value = "v1 refs/heads/main",
            .expected = error.InvalidConfig,
        },
        // pre-release state stored the anchor inline as a fourth token
        .{
            .value = "v1 refs/heads/main refs/heads/work abc",
            .expected = error.InvalidConfig,
        },
        .{
            .value = "v1 main refs/heads/work",
            .expected = error.InvalidConfig,
        },
        .{
            .value = "v1 --output=x refs/heads/work",
            .expected = error.InvalidConfig,
        },
        .{
            .value = "v1 refs/heads/main refs/heads/main",
            .expected = error.InvalidConfig,
        },
    };

    for (cases) |case| {
        try setState(&repo, case.value);
        try testing.expectError(
            case.expected,
            stack.loadConfig(&repo.git),
        );
    }
}

test "loadConfig reports a missing anchor ref as an inconsistent stack" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try repo.exec(&.{ "update-ref", "-d", "refs/stakrr/anchor" });

    try testing.expectError(
        error.InvalidStack,
        stack.loadConfig(&repo.git),
    );
}

test "initStack records the anchor as a ref" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const anchor = (try repo.git.readRef("refs/stakrr/anchor")).?;
    defer testing.allocator.free(anchor);

    try testing.expectEqualStrings(base, anchor);
}

test "initStack accepts a full base ref" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "refs/heads/main");

    var config = try stack.loadConfig(&repo.git);
    defer config.deinit(repo.git.allocator);

    try testing.expectEqualStrings("refs/heads/main", config.base_ref);
}

test "initStack rejects a missing base" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });

    try testing.expectError(
        error.BaseNotFound,
        stack.initStack(&repo.git, "origin/main"),
    );
    try expectNoState(&repo);
}

test "initStack refuses repeated initialization" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try testing.expectError(
        error.AlreadyInitialized,
        stack.initStack(&repo.git, "main"),
    );

    // failed initialization must leave state intact
    var config = try stack.loadConfig(&repo.git);
    defer config.deinit(repo.git.allocator);

    try testing.expectEqualStrings(
        base,
        config.anchor_oid,
    );
}

test "initStack refuses a leftover anchor ref" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try repo.exec(&.{ "config", "--local", "--unset-all", "stakrr.state" });

    try testing.expectError(
        error.ExistingStackRefs,
        stack.initStack(&repo.git, "main"),
    );
}

test "initStack refuses to use work as base" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);

    try testing.expectError(
        error.BaseEqualsWork,
        stack.initStack(&repo.git, "main"),
    );
}

test "initStack refuses a non-ancestor base" {
    var repo = try Repo.init();
    defer repo.deinit();

    const a = try repo.commit("A");
    defer testing.allocator.free(a);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "main" });

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try repo.exec(&.{ "switch", "-q", "work" });

    try testing.expectError(
        error.BaseNotAncestor,
        stack.initStack(&repo.git, "main"),
    );

    try expectNoState(&repo);
}

test "initStack rejects merge commits" {
    var repo = try Repo.init();
    defer repo.deinit();

    const a = try repo.commit("base");
    defer testing.allocator.free(a);

    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try addMerge(&repo);

    try testing.expectError(
        error.MergeCommitsUnsupported,
        stack.initStack(&repo.git, "main"),
    );

    try expectNoState(&repo);
}

test "inspect reports layers, depths and unstacked commits" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    for ([_][]const u8{ "B", "C", "D", "E" }) |message| {
        const oid = try repo.commit(message);
        testing.allocator.free(oid);
    }

    try stack.cut(&repo.git, "p1", "HEAD~3");
    try stack.cut(&repo.git, "p2", "HEAD~1");

    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), snapshot.layers.len);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[0].depth);
    try testing.expectEqual(@as(usize, 1), snapshot.layers[0].commits);
    try testing.expectEqual(@as(usize, 3), snapshot.layers[1].depth);
    try testing.expectEqual(@as(usize, 2), snapshot.layers[1].commits);
    try testing.expectEqual(@as(usize, 1), snapshot.unstacked_commits);
    try testing.expect(!snapshot.base_moved);
}

test "inspect rejects a merge committed after init" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try addMerge(&repo);

    try testing.expectError(
        error.MergeCommitsUnsupported,
        stack.inspect(&repo.git),
    );
}

test "inspect rejects a tip guard without layers" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try repo.exec(&.{ "update-ref", "refs/stakrr/tip", base });

    try testing.expectError(
        error.InvalidStack,
        stack.inspect(&repo.git),
    );
}

test "inspect rejects a deleted layer (tip mismatch)" {
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

    try repo.exec(&.{ "branch", "-D", "stakrr/p2" });

    try testing.expectError(
        error.InvalidStack,
        stack.inspect(&repo.git),
    );
}

test "inspect rejects a foreign stakrr branch outside the rolling history" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    try repo.exec(&.{ "switch", "-q", "-c", "side", "main" });
    const side = try repo.commit("side");
    defer testing.allocator.free(side);
    try repo.exec(&.{ "branch", "stakrr/foreign", side });
    try repo.exec(&.{ "switch", "-q", "work" });

    try testing.expectError(
        error.InvalidStack,
        stack.inspect(&repo.git),
    );
}

test "inspect rejects two layers on the same commit" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);
    try stack.cut(&repo.git, "p1", null);
    try repo.exec(&.{ "branch", "stakrr/dup", b });

    try testing.expectError(
        error.InvalidLayerBoundary,
        stack.inspect(&repo.git),
    );
}

test "inspect rejects work rebased past the anchor" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try initialize(&repo);
    defer testing.allocator.free(base);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try repo.exec(&.{ "switch", "-q", "main" });
    try repo.exec(&.{ "commit", "-q", "--amend", "--allow-empty", "-m", "rewritten base" });
    try repo.exec(&.{ "switch", "-q", "work" });
    try repo.exec(&.{ "rebase", "-q", "--onto", "main", base });

    try testing.expectError(
        error.InvalidStack,
        stack.inspect(&repo.git),
    );
}
