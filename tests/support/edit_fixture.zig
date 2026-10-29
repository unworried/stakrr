//! A two-layer stack with real file changes, shared by the edit tests.
const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const layout = stakrr.layout;
const Repo = @import("repo.zig").Repo;

/// main ← models ← api (deletes `obsolete`) ← one rolling commit on work
pub fn setup(repo: *const Repo) !void {
    try repo.write("shared", "base\n");
    try repo.commitAll("base");
    try repo.exec(&.{ "switch", "-q", "-c", "work" });
    try stack.initStack(&repo.git, "main");
    try repo.write("model", "original\n");
    try repo.write("obsolete", "delete me\n");
    try repo.commitAll("models");
    try stack.cut(&repo.git, "models", null);
    try repo.write("api", "api\n");
    try repo.commitAll("api");
    try repo.exec(&.{ "rm", "-q", "obsolete" });
    try repo.commitAll("delete obsolete");
    try stack.cut(&repo.git, "api", null);
    try repo.write("tail", "rolling\n");
    try repo.commitAll("rolling");
}

/// `setup` plus a top cut whose change to `shared` conflicts with a commit on
/// models. Ends on stakrr/models with that commit made; restacking conflicts.
pub fn conflictSetup(repo: *const Repo) !void {
    try setup(repo);
    try repo.write("shared", "upper\n");
    try repo.commitAll("upper shared");
    try stack.cut(&repo.git, "conflict", null);
    try on(repo, "models");
    try repo.write("shared", "edited\n");
    try repo.commitAll("edit shared");
}

/// check out a layer's branch so the next commits land on it
pub fn on(repo: *const Repo, layer: []const u8) !void {
    const branch = try std.fmt.allocPrint(testing.allocator, "stakrr/{s}", .{layer});
    defer testing.allocator.free(branch);
    try repo.exec(&.{ "switch", "-q", branch });
}

/// commit a correction to `model` on the models layer, then return to the rolling
/// branch, ready to restack
pub fn correctModels(repo: *const Repo) !void {
    try on(repo, "models");
    try repo.write("model", "corrected\n");
    try repo.commitAll("correction");
    try repo.exec(&.{ "switch", "-q", "work" });
}

/// the `setup` stack is intact and inspectable
pub fn valid(repo: *const Repo) !void {
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 2), snapshot.layers.len);
    try testing.expectEqualStrings("refs/heads/stakrr/models", snapshot.layers[0].ref_name);
    try testing.expectEqualStrings("refs/heads/stakrr/api", snapshot.layers[1].ref_name);
    try testing.expectEqual(@as(usize, 1), snapshot.unstacked_commits);
}

pub fn noSession(repo: *const Repo) !void {
    try repo.expectNoRef(layout.session_ref);
}

pub fn expectRecoverable(repo: *const Repo, oid: []const u8) !void {
    const objects = try repo.git.output(&.{ "rev-list", "--objects", "--all" });
    defer testing.allocator.free(objects);
    try testing.expect(std.mem.indexOf(u8, objects, oid) != null);
}

/// the session JSON stored in a checkpoint commit
pub fn checkpointJson(repo: *const Repo, oid: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}:session.json", .{oid});
    defer testing.allocator.free(path);
    return repo.git.outputRaw(&.{ "cat-file", "blob", path });
}

/// a linked worktree at .git/<path> on `branch`; the caller closes its cwd
pub fn linked(repo: *const Repo, path: []const u8, branch: []const u8) !stakrr.git.Git {
    const metadata_path = try std.fmt.allocPrint(testing.allocator, ".git/{s}", .{path});
    defer testing.allocator.free(metadata_path);
    try repo.exec(&.{ "worktree", "add", "-q", metadata_path, branch });
    const dir = try repo.tmp.dir.openDir(testing.io, metadata_path, .{});
    var git = repo.git;
    git.cwd = dir;
    return git;
}

/// The three-layer conflict fixture after completion or restoration.
pub fn validConflict(repo: *const Repo) !void {
    var snapshot = try stack.inspect(&repo.git);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 3), snapshot.layers.len);
    for (snapshot.layers, [_][]const u8{ "models", "api", "conflict" }) |layer, name| {
        const ref_name = try std.fmt.allocPrint(testing.allocator, layout.layer_prefix ++ "{s}", .{name});
        defer testing.allocator.free(ref_name);
        try testing.expectEqualStrings(ref_name, layer.ref_name);
        try testing.expect(!layer.stale());
    }
}

/// Borrowed fixture view of the managed workspace. Close tmp.dir, never deinit.
pub fn workspace(repo: *const Repo) !Repo {
    var status = (try stakrr.edit.readStatus(&repo.git)).?;
    defer status.deinit();
    var view = repo.*;
    view.tmp.dir = try std.Io.Dir.cwd().openDir(testing.io, status.workspace, .{});
    view.git.cwd = view.tmp.dir;
    return view;
}
pub fn boundary(repo: *const Repo, name: []const u8) ![]u8 {
    const loaded = try stakrr.state_store.load(&repo.git);
    defer testing.allocator.free(loaded.oid);
    var state = loaded.state;
    defer state.deinit();
    for (state.value.layers) |*layer| if (std.mem.eql(u8, name, layout.layerName(layer.branch.name.bytes).?)) return layer.recorded_boundary_oid.dupeHex(testing.allocator);
    return error.TestMissingLayer;
}
pub fn expectBoundary(repo: *const Repo, name: []const u8, expected: []const u8) !void {
    const oid = try boundary(repo, name);
    defer testing.allocator.free(oid);
    try testing.expectEqualStrings(expected, oid);
}
