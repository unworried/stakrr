//! Shared immutable replay boundaries and guarded publication construction.
const std = @import("std");
const Git = @import("git.zig").Git;
const model = @import("stack_state.zig");
const store = @import("state_store.zig");
const layout = @import("layout.zig");
pub const Plan = struct {
    /// Layer boundaries followed by the work tip, in declared order.
    boundaries: []const []const u8,
    active: usize,
    commits: []const []const u8,
    pub fn boundaryAfter(self: Plan, picked: []const []const u8) usize {
        var next = self.active + 1;
        while (next < self.boundaries.len and eql(self.boundaries[next], self.boundaries[self.active])) next += 1;
        for (picked) |oid| while (next < self.boundaries.len and eql(self.boundaries[next], oid)) {
            next += 1;
        };
        return next;
    }
    pub fn map(self: Plan, rewritten: [][]const u8, old: []const u8, new: []const u8) void {
        for (self.boundaries[self.active + 1 ..], rewritten[self.active + 1 ..]) |boundary, *target| if (eql(boundary, old)) {
            target.* = new;
        };
    }
};
pub fn plan(git: *const Git, state: model.StackState, work: []const u8, active: usize) !Plan {
    if (active >= state.layers.len) return error.InvalidStack;
    const bounds = try git.allocator.alloc([]const u8, state.layers.len + 1);
    for (state.layers, bounds[0..state.layers.len]) |*layer, *oid| oid.* = try layer.recorded_boundary_oid.dupeHex(git.allocator);
    bounds[state.layers.len] = work;
    const history = try git.history(bounds[active], work);
    if (!history.linear) return error.MergeCommitsUnsupported;
    const result: Plan = .{ .boundaries = bounds, .active = active, .commits = history.commits };
    if (result.boundaryAfter(history.commits) != bounds.len) return error.InvalidStack;
    return result;
}
pub const Publication = struct { manifest: []const u8, updates: []const Git.RefUpdate };
pub fn publication(git: *const Git, state: model.StackState, old_manifest: []const u8, expected: []const []const u8, rewritten: []const []const u8) !Publication {
    if (expected.len != state.layers.len + 1 or rewritten.len != expected.len) return error.InvalidStack;
    const a = git.allocator;
    var next = state;
    const layers = try a.alloc(model.Layer, state.layers.len);
    for (state.layers, layers, rewritten[0..state.layers.len]) |layer, *out, oid| out.* = .{ .branch = layer.branch, .recorded_boundary_oid = try git.parseOid(oid) };
    next.layers = layers;
    // Re-establish strict increasing boundaries on a single chain before publishing.
    const work = rewritten[rewritten.len - 1];
    if (!try git.isAncestor(next.anchor_oid.hex(), work)) return error.InvalidStack;
    const history = try git.history(next.anchor_oid.hex(), work);
    if (!history.linear) return error.MergeCommitsUnsupported;
    var index: usize = 0;
    for (rewritten[0 .. rewritten.len - 1]) |boundary| {
        while (index < history.commits.len and !eql(boundary, history.commits[index])) index += 1;
        if (index == history.commits.len) return error.InvalidLayerBoundary;
        index += 1;
    }
    const oid = try store.create(git, next);
    const updates = try a.alloc(Git.RefUpdate, expected.len + 1);
    for (expected, rewritten, updates[0..expected.len], 0..) |from, to, *update, i| {
        const name = if (i < layers.len) layers[i].branch.name.bytes else state.work_branch.name.bytes;
        update.* = if (eql(from, to)) try git.verifyRef(name, from) else try git.updateRef(name, from, to);
    }
    updates[expected.len] = try git.updateRef(layout.state_ref, old_manifest, oid);
    return .{ .manifest = oid, .updates = updates };
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
