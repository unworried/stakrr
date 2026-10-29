const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const layout = stakrr.layout;
const Repo = @import("support/repo.zig").Repo;
const fixture = @import("support/edit_fixture.zig");
const cli = @import("support/cli.zig");
const Snapshot = @import("support/snapshot.zig").Snapshot;

fn replaceRaw(repo: *const Repo, raw: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const git = repo.git.withAllocator(arena.allocator());
    const oid = try git.commitTree(try git.writeTree(&.{.{ .name = "stack.json", .oid = try git.writeBlob(raw) }}), &.{}, "test malformed manifest");
    try git.exec(&.{ "update-ref", layout.state_ref, oid });
}

test "one authoritative manifest preserves declared order and boundaries as live tips move" {
    var repo = try Repo.init();
    defer repo.deinit();
    const base = try repo.initStack();
    defer testing.allocator.free(base);
    testing.allocator.free(try repo.commit("first"));
    try stack.cut(&repo.git, "z-first", null);
    testing.allocator.free(try repo.commit("second"));
    try stack.cut(&repo.git, "a-second", null);
    const manifest = (try repo.readRef(layout.state_ref)).?;
    defer testing.allocator.free(manifest);
    const raw = try repo.git.outputRaw(&.{ "show", layout.state_ref ++ ":stack.json" });
    defer testing.allocator.free(raw);
    try fixture.on(&repo, "z-first");
    testing.allocator.free(try repo.commit("moved"));
    var view = try stack.observe(&repo.git);
    defer view.deinit();
    try testing.expectEqualStrings("refs/heads/stakrr/z-first", view.layers[0].branch);
    try testing.expectEqualStrings("refs/heads/stakrr/a-second", view.layers[1].branch);
    try testing.expect(view.layers[0].stale.?);
    try testing.expectEqual(@as(usize, 1), view.layers[0].commits.?);
    try repo.expectRef(layout.state_ref, manifest);
    try repo.expectOutput(&.{ "show", layout.state_ref ++ ":stack.json" }, raw);
    try repo.expectOutput(&.{ "for-each-ref", "--format=%(refname)", "refs/stakrr/" }, layout.state_ref);
}

test "status renders missing and symbolic branches with available evidence and refuses mutation" {
    for ([_]bool{ false, true }) |symbolic| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        if (symbolic) try repo.exec(&.{ "symbolic-ref", "refs/heads/stakrr/api", "refs/heads/missing" }) else try repo.exec(&.{ "update-ref", "-d", "refs/heads/stakrr/api" });
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        var view = try stack.observe(&repo.git);
        defer view.deinit();
        try testing.expectEqual(@as(usize, 2), view.layers.len);
        try testing.expect(view.layers[1].branch_oid == null);
        try testing.expect(view.layers[1].stale == null);
        try testing.expect(view.layers[0].branch_oid != null);
        const result = try cli.run(&repo, &.{"status"});
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 0), result.code);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "tip unavailable") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "refs/heads/stakrr/api") != null);
        try testing.expectError(if (symbolic) error.SymbolicRef else error.InvalidStack, stack.cut(&repo.git, "refused", null));
        try before.expectUnchanged(&repo);
    }
}

test "invalid ancestry and unexpected namespace branches remain observable without adoption" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try repo.exec(&.{ "branch", "stakrr/unexpected", "main" });
    var view = try stack.observe(&repo.git);
    defer view.deinit();
    try testing.expectEqual(@as(usize, 2), view.layers.len);
    try testing.expectEqual(stack.Issue.Kind.unexpected_layer, view.issues[0].kind);
    try testing.expectError(error.InvalidStack, stack.go(&repo.git, "unexpected"));
    try repo.exec(&.{ "branch", "-D", "stakrr/unexpected" });
    try repo.exec(&.{ "switch", "--quiet", "--orphan", "unrelated" });
    testing.allocator.free(try repo.commit("unrelated"));
    const unrelated = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(unrelated);
    try repo.exec(&.{ "update-ref", "refs/heads/work", unrelated });
    var invalid = try stack.observe(&repo.git);
    defer invalid.deinit();
    try testing.expect(invalid.unstacked_commits == null);
    try testing.expect(invalid.layers[0].commits == null);
    try testing.expectEqual(stack.Issue.Kind.invalid_ancestry, invalid.issues[0].kind);
}

test "unsupported and malformed manifests diagnose without repairing" {
    for ([_][]const u8{ "{}", "{\"version\":55}", "invalid JSON" }) |raw| {
        var repo = try Repo.init();
        defer repo.deinit();
        testing.allocator.free(try repo.initStack());
        try replaceRaw(&repo, raw);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        var view = try stack.observe(&repo.git);
        defer view.deinit();
        try testing.expect(view.state == null);
        try testing.expect(view.manifest_oid != null);
        try testing.expect(view.issues.len != 0);
        const result = try cli.run(&repo, &.{"status"});
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 0), result.code);
        try before.expectUnchanged(&repo);
    }
}

test "manifest parents deterministically retain anchor and recorded boundaries after all branches move" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try fixture.setup(&repo);
        var snapshot = try stack.inspect(&repo.git);
        defer snapshot.deinit();
        const parents = try repo.git.output(&.{ "show", "--no-patch", "--format=%P", snapshot.manifest_oid });
        defer testing.allocator.free(parents);
        const expected = try std.fmt.allocPrint(testing.allocator, "{s} {s} {s}", .{ snapshot.config.anchor_oid, snapshot.layers[0].oid, snapshot.layers[1].oid });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, parents);
        try repo.exec(&.{ "switch", "--quiet", "--orphan", "replacement" });
        const root = try repo.commit("unrelated root");
        defer testing.allocator.free(root);
        for ([_][]const u8{ "refs/heads/main", "refs/heads/work", "refs/heads/stakrr/models", "refs/heads/stakrr/api" }) |ref| try repo.exec(&.{ "update-ref", ref, root });
        try repo.exec(&.{ "reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all" });
        try repo.exec(&.{ "gc", "--prune=now" });
        try repo.exec(&.{ "cat-file", "-e", snapshot.config.anchor_oid });
        for (snapshot.layers) |layer| try repo.exec(&.{ "cat-file", "-e", layer.oid });
        try repo.exec(&.{ "fsck", "--no-reflogs", "--full" });
        // Reset archives the old manifest before removing its last direct root.
        _ = try stack.reset(&repo.git, .{ .delete_layers = true });
        try repo.expectNoRef(layout.state_ref);
        try repo.exec(&.{ "reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all" });
        try repo.exec(&.{ "gc", "--prune=now" });
        try repo.exec(&.{ "cat-file", "-e", snapshot.manifest_oid });
        for (snapshot.layers) |layer| try repo.exec(&.{ "cat-file", "-e", layer.oid });
        try repo.exec(&.{ "fsck", "--no-reflogs", "--full" });
    }
}

test "undo stub returns exit one without invoking Git even outside a repository" {
    var repo = try Repo.init();
    defer repo.deinit();
    try cli.installFaultShim(&repo);
    // If Git were called it would fail to exec, changing the diagnostic.
    try repo.env.put("STAKRR_TEST_GIT", "/does/not/exist");
    const result = try cli.run(&repo, &.{"undo"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 1), result.code);
    try testing.expectEqualStrings("error: unimplemented\n", result.stderr);
}

test "reserved namespace root collision is reported and never adopted" {
    var repo = try Repo.init();
    defer repo.deinit();
    const base = try repo.initWork();
    defer testing.allocator.free(base);
    try repo.exec(&.{ "branch", "stakrr", "main" });
    try testing.expectError(error.ExistingStackRefs, stack.initStack(&repo.git, "main"));
    try repo.exec(&.{ "branch", "-D", "stakrr" });
    try stack.initStack(&repo.git, "main");
    try repo.exec(&.{ "branch", "stakrr", "main" });
    var view = try stack.observe(&repo.git);
    defer view.deinit();
    try testing.expectEqual(@as(usize, 0), view.layers.len);
    try testing.expectEqual(stack.Issue.Kind.unexpected_layer, view.issues[0].kind);
    try testing.expectError(error.InvalidStack, stack.cut(&repo.git, "refused", null));
}

test "reset archives corrupt manifest objects before deleting their final root" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        testing.allocator.free(try repo.initStack());
        const raw = try repo.git.writeBlob("corrupt manifest bytes\x00\xff");
        defer testing.allocator.free(raw);
        try repo.exec(&.{ "update-ref", layout.state_ref, raw });
        _ = try stack.reset(&repo.git, .{});
        try repo.expectNoRef(layout.state_ref);
        try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
        try repo.exec(&.{ "gc", "--prune=now" });
        try repo.expectOutput(&.{ "cat-file", "blob", raw }, "corrupt manifest bytes\x00\xff");
        try repo.exec(&.{ "fsck", "--no-reflogs", "--full" });
    }
}

test "cut refuses a snapshot invalidated by state publication or reset before its transaction" {
    for ([_]bool{ false, true }) |reset| {
        var repo = try Repo.init();
        defer repo.deinit();
        const base = try repo.initStack();
        defer testing.allocator.free(base);
        testing.allocator.free(try repo.commit("work"));
        const old = (try repo.readRef(layout.state_ref)).?;
        defer testing.allocator.free(old);
        const tree = try repo.git.output(&.{ "rev-parse", layout.state_ref ++ "^{tree}" });
        defer testing.allocator.free(tree);
        const replacement = try repo.git.commitTree(tree, &.{ base, old }, "concurrent manifest publication");
        defer testing.allocator.free(replacement);
        var branches = try repo.git.listDirectRefs("refs/heads/");
        defer branches.deinit(testing.allocator);
        try cli.installFaultShim(&repo);
        try repo.env.put("STAKRR_TEST_RACE_LABEL", "stakrr: cut");
        try repo.env.put("STAKRR_TEST_RACE_REF", layout.state_ref);
        try repo.env.put("STAKRR_TEST_RACE_OLD", old);
        try repo.env.put("STAKRR_TEST_RACE_NEW", if (reset) "0000000000000000000000000000000000000000" else replacement);
        const result = try cli.run(&repo, &.{ "cut", "refused" });
        defer result.deinit();
        try testing.expectEqual(@as(?u8, 1), result.code);
        try repo.expectNoRef("refs/heads/stakrr/refused");
        try repo.expectNoRef(layout.transaction_ref);
        if (reset) try repo.expectNoRef(layout.state_ref) else try repo.expectRef(layout.state_ref, replacement);
        for (branches.refs) |ref| try repo.expectRef(ref.name.bytes, ref.oid.hex());
        try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    }
}

test "declared reversed or coincident boundaries are reported without sorting or mutation" {
    for ([_]bool{ false, true }) |coincident| {
        var repo = try Repo.init();
        defer repo.deinit();
        try fixture.setup(&repo);
        const loaded = try stakrr.state_store.load(&repo.git);
        defer testing.allocator.free(loaded.oid);
        var owned = loaded.state;
        defer owned.deinit();
        var layers = [_]stakrr.stack_state.Layer{ owned.value.layers[1], owned.value.layers[0] };
        if (coincident) layers[1].recorded_boundary_oid = layers[0].recorded_boundary_oid;
        var state = owned.value;
        state.layers = &layers;
        const changed = try stakrr.state_store.create(&repo.git, state);
        defer testing.allocator.free(changed);
        try repo.exec(&.{ "update-ref", layout.state_ref, changed, loaded.oid });
        const parents = try repo.git.output(&.{ "show", "--no-patch", "--format=%P", changed });
        defer testing.allocator.free(parents);
        const expected_parents = if (coincident)
            try std.fmt.allocPrint(testing.allocator, "{s} {s}", .{ state.anchor_oid.hex(), layers[0].recorded_boundary_oid.hex() })
        else
            try std.fmt.allocPrint(testing.allocator, "{s} {s} {s}", .{ state.anchor_oid.hex(), layers[0].recorded_boundary_oid.hex(), layers[1].recorded_boundary_oid.hex() });
        defer testing.allocator.free(expected_parents);
        try testing.expectEqualStrings(expected_parents, parents);
        var before = try Snapshot.capture(&repo);
        defer before.deinit();
        var view = try stack.observe(&repo.git);
        defer view.deinit();
        try testing.expectEqualStrings("refs/heads/stakrr/api", view.layers[0].branch);
        try testing.expectEqualStrings("refs/heads/stakrr/models", view.layers[1].branch);
        try testing.expect(view.layers[1].commits == null);
        try testing.expectEqual(stack.Issue.Kind.invalid_boundary, view.issues[0].kind);
        try testing.expectError(error.InvalidLayerBoundary, stack.cut(&repo.git, "refused", null));
        try before.expectUnchanged(&repo);
    }
}
