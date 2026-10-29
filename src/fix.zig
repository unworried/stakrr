//! One-shot fix: fold the staged changes into a lower layer and replay everything
//! above it. The whole rewrite happens in object storage via in-memory merges, so
//! the index, the worktree and unstaged edits are never touched. Nothing is
//! published unless every step merges cleanly; a refused fix changes nothing.
const Mutation = @import("mutation.zig").Mutation;
const RefName = @import("git.zig").RefName;
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const stack = @import("stack.zig");
const coordination = @import("coordination.zig");
const layout = @import("layout.zig");
const replay = @import("replay.zig");
const operations = @import("operation.zig");

pub const Error = stack.Error || error{
    NoLayers,
    NothingStaged,
    FixConflict,
    FixDiverged,
};

/// Add the staged changes as a new commit on the layer, or amend its last commit.
pub const How = union(enum) { message: []const u8, amend };

pub const Options = struct {
    /// short layer name; the highest layer when null
    layer: ?[]const u8 = null,
    how: How,
};

pub const Result = struct {
    /// short name of the fixed layer, owned by the caller's allocator
    layer: []const u8,
    /// commits above the fixed layer that were rewritten
    replayed: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.layer);
        self.* = undefined;
    }
};

pub fn fix(original_git: *const Git, options: Options) !Result {
    var arena: std.heap.ArenaAllocator = .init(original_git.allocator);
    defer arena.deinit();
    const scoped = original_git.withAllocator(arena.allocator());
    var mutation = try @import("mutation.zig").begin(&scoped, .stack);
    defer mutation.deinit();
    const git = mutation.repo();
    const allocator = git.allocator;

    var snapshot = try stack.inspect(git);
    defer snapshot.deinit();
    const layers = snapshot.layers;

    var current = try git.currentBranch();
    defer current.deinit(allocator);
    if (!std.mem.eql(u8, current.value.name.bytes, snapshot.config.work_ref.name.bytes)) return error.NotOnWorkBranch;
    try coordination.requireNoGitOperation(git, .{});
    if (layers.len == 0) return error.NoLayers;
    // commits made on a layer must be restacked before anything else moves it
    for (layers) |layer| if (layer.stale()) return error.StaleLayers;
    const index = try findLayer(layers, options.layer);

    if (try git.check(&.{ "diff", "--no-relative", "--cached", "--quiet" }, 1)) return error.NothingStaged;
    const work_old = snapshot.work_oid;
    const staged_tree = try git.output(&.{"write-tree"});
    const staged = try git.commitTree(staged_tree, &.{work_old}, "stakrr: staged changes");

    // the layer with the staged change applied
    const layer_old = layers[index].oid;
    const folded = (try git.mergeTree(work_old, layer_old, staged)) orelse return error.FixConflict;
    const layer_new = switch (options.how) {
        .message => |text| try git.commitTree(folded, &.{layer_old}, text),
        .amend => try git.rewriteCommit(
            layer_old,
            folded,
            try git.output(&.{ "rev-parse", try std.fmt.allocPrint(allocator, "{s}^", .{layer_old}) }),
        ),
    };

    const plan = try replay.plan(git, snapshot.state, work_old, index);
    const moved = try allocator.dupe([]const u8, plan.boundaries);
    moved[index] = layer_new;
    plan.map(moved, layer_old, layer_new);
    var cursor = layer_new;
    var parent_old = layer_old;
    for (plan.commits) |commit| {
        const tree = (try git.mergeTree(parent_old, cursor, commit)) orelse return error.FixConflict;
        cursor = try git.rewriteCommit(commit, tree, cursor);
        parent_old = commit;
        plan.map(moved, commit, cursor);
    }
    const work_new = cursor;
    moved[moved.len - 1] = work_new;

    // the index must still describe the new tip, or the staged state would be lost
    const tip_tree = try git.output(&.{ "rev-parse", try std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{work_new}) });
    if (!eql(tip_tree, staged_tree)) return error.FixDiverged;

    try publish(&mutation, snapshot, moved);

    return .{
        .layer = try original_git.allocator.dupe(u8, layout.layerName(layers[index].ref_name).?),
        .replayed = plan.commits.len,
    };
}

/// Fix writes a completed operation directly, without resumable progress.
fn publish(mutation: *const Mutation, snapshot: stack.Snapshot, moved: []const []const u8) !void {
    const git = mutation.repo();
    const a = git.allocator;
    const expected = try a.alloc([]const u8, snapshot.layers.len + 1);
    for (snapshot.layers, expected[0..snapshot.layers.len]) |layer, *oid| oid.* = layer.branch_oid;
    expected[expected.len - 1] = snapshot.work_oid;
    const publication = try replay.publication(git, snapshot.state, snapshot.manifest_oid, expected, moved);
    const old = try git.readDirectRefAlloc(try RefName.init(layout.oplog_ref));
    var moves: std.ArrayList(operations.Move) = .empty;
    for (expected, moved, 0..) |from, to, i| {
        if (eql(from, to)) continue;
        const name = if (i < snapshot.layers.len) snapshot.layers[i].ref_name else snapshot.config.work_ref.name.bytes;
        try moves.append(a, .{ .name = name, .before = from, .after = to });
    }
    const record = try operations.create(git, .{ .kind = .fix, .before_manifest = snapshot.manifest_oid, .after_manifest = publication.manifest, .moves = moves.items, .rescue = &.{snapshot.work_oid}, .previous = old }, null);
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(a, publication.updates);
    try updates.append(a, try operations.update(git, old, record));
    try mutation.publish(.{ .message = "stakrr: fix", .updates = updates.items, .current_branch = .{ .allow = snapshot.config.work_ref } });
}

fn findLayer(layers: []const stack.Layer, name: ?[]const u8) !usize {
    const wanted = name orelse return layers.len - 1;
    for (layers, 0..) |layer, i| {
        const short = layout.layerName(layer.ref_name) orelse continue;
        if (eql(short, wanted)) return i;
    }
    return error.UnknownCut;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
