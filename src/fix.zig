//! One-shot fix: fold the staged changes into a lower layer and replay everything
//! above it. The whole rewrite happens in object storage via in-memory merges, so
//! the index, the worktree and unstaged edits are never touched. Nothing is
//! published unless every step merges cleanly; a refused fix changes nothing.
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const stack = @import("stack.zig");
const coordination = @import("coordination.zig");
const layout = @import("layout.zig");
const checkpoint = @import("edit_session.zig");

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
    const git = &scoped;
    const allocator = git.allocator;

    // an active edit session excludes this, like every stack mutation
    const guard = try coordination.lockStack(git);
    defer guard.close(git.io);

    var snapshot = try stack.inspect(git);
    defer snapshot.deinit();
    const layers = snapshot.layers;

    const current = try git.currentBranch();
    if (!std.mem.eql(u8, current, snapshot.config.work_ref)) return error.NotOnWorkBranch;
    try coordination.requireNoGitOperation(git, .{});
    if (layers.len == 0) return error.NoLayers;
    // commits made on a layer must be restacked before anything else moves it
    for (layers) |layer| if (layer.stale()) return error.StaleLayers;
    const index = try findLayer(layers, options.layer);

    // rewritten branches must not be checked out in another worktree
    const touched = try allocator.alloc([]const u8, layers.len - index);
    for (layers[index..], touched) |layer, *ref| ref.* = layer.ref_name;
    try coordination.requireAvailable(git, touched);

    if (try git.check(&.{ "diff", "--cached", "--quiet" }, 1)) return error.NothingStaged;
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

    // replay every commit above it, mapping each layer boundary it crosses
    const moved = try allocator.alloc([]const u8, layers.len - index);
    moved[0] = layer_new;
    const above = (try git.history(layer_old, work_old)).commits;
    var cursor = layer_new;
    var parent_old = layer_old;
    var next = index + 1;
    for (above) |commit| {
        const tree = (try git.mergeTree(parent_old, cursor, commit)) orelse return error.FixConflict;
        cursor = try git.rewriteCommit(commit, tree, cursor);
        parent_old = commit;
        while (next < layers.len and eql(layers[next].oid, commit)) : (next += 1) moved[next - index] = cursor;
    }
    if (next != layers.len) return error.InvalidStack;
    const work_new = cursor;

    // the index must still describe the new tip, or the staged state would be lost
    const tip_tree = try git.output(&.{ "rev-parse", try std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{work_new}) });
    if (!eql(tip_tree, staged_tree)) return error.FixDiverged;

    try publish(git, snapshot, index, moved, work_new);

    return .{
        .layer = try original_git.allocator.dupe(u8, layout.layerName(layers[index].ref_name).?),
        .replayed = above.len,
    };
}

/// Every moved ref, the tip guard and the operation log land in one transaction,
/// so `stakrr undo` can reverse the fix like any finished edit.
fn publish(
    git: *const Git,
    snapshot: stack.Snapshot,
    index: usize,
    moved: []const []const u8,
    work_new: []const u8,
) !void {
    const allocator = git.allocator;
    const layers = snapshot.layers;

    const nodes = try allocator.alloc(checkpoint.Node, layers.len + 1);
    for (layers, nodes[0..layers.len]) |layer, *node| node.* = try checkpoint.Node.init(allocator, layer.ref_name, layer.oid);
    nodes[layers.len] = try checkpoint.Node.init(allocator, snapshot.config.work_ref, snapshot.work_oid);
    for (nodes[index..layers.len], moved) |*node, oid| {
        node.published_oid = oid;
        node.pending_oid = oid;
    }
    nodes[layers.len].published_oid = work_new;
    nodes[layers.len].pending_oid = work_new;

    const config = (try git.configGet(layout.state_key)) orelse return error.InvalidConfig;
    const oplog = try git.readRef(layout.oplog_ref);
    var s: checkpoint.Session = .{
        .oplog_parent = oplog,
        .outcome = .finished,
        .id = "",
        .owner = try git.path(&.{ "rev-parse", "--absolute-git-dir" }),
        .origin = snapshot.config.work_ref,
        .config = config,
        .branches = try stack.parseConfig(config),
        .anchor = snapshot.config.anchor_oid,
        .nodes = nodes,
        .active = index,
        .phase = .switching,
    };
    s.id = try git.writeBlob(try checkpoint.encode(allocator, &s));

    const label = try std.fmt.allocPrint(allocator, "stakrr: fix {s}", .{layout.layerName(layers[index].ref_name).?});
    // the first retained commit is the rescue point: the work tip from before the fix
    const saved = try checkpoint.create(git, &s, null, &.{snapshot.work_oid}, label);

    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    for (layers[index..], moved) |layer, oid| {
        try updates.append(allocator, .{ .update = .{ .name = layer.ref_name, .new = oid, .old = layer.oid } });
        try updates.append(allocator, .{ .update = .{
            .name = try layout.recordRef(allocator, layer.ref_name),
            .new = oid,
            .old = layer.oid,
        } });
    }
    try updates.append(allocator, .{ .update = .{
        .name = snapshot.config.work_ref,
        .new = work_new,
        .old = snapshot.work_oid,
    } });
    try updates.append(allocator, .{ .update = .{
        .name = layout.tip_ref,
        .new = moved[moved.len - 1],
        .old = layers[layers.len - 1].oid,
    } });
    try updates.append(allocator, if (oplog) |previous|
        .{ .update = .{ .name = layout.oplog_ref, .new = saved, .old = previous } }
    else
        .{ .create = .{ .name = layout.oplog_ref, .oid = saved } });
    try updates.append(allocator, .{ .verify = .{ .name = layout.anchor_ref, .oid = snapshot.config.anchor_oid } });
    try git.transact(label, updates.items);
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
