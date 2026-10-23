//! A two-layer stack with real file changes, shared by the edit tests.
const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const edit = stakrr.edit;
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

/// `setup` plus a top cut whose change to `shared` conflicts with an
/// in-progress edit of models
pub fn conflictSetup(repo: *const Repo) !void {
    try setup(repo);
    try repo.write("shared", "upper\n");
    try repo.commitAll("upper shared");
    try stack.cut(&repo.git, "conflict", null);
    try edit.run(&repo.git, .{ .jump = "models" });
    try repo.write("shared", "edited\n");
    try repo.commitAll("edit shared");
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

/// Both v1 blobs and v2 commits can be used to test the checkpoint codec.
pub fn checkpointJson(repo: *const Repo, oid: []const u8) ![]u8 {
    const kind = try repo.git.output(&.{ "cat-file", "-t", oid });
    defer testing.allocator.free(kind);
    const path = if (std.mem.eql(u8, kind, "commit"))
        try std.fmt.allocPrint(testing.allocator, "{s}:session.json", .{oid})
    else
        try testing.allocator.dupe(u8, oid);
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
