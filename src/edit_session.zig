//! Active execution progress only. Completed operations use operation.zig.
const std = @import("std");
const Git = @import("git.zig").Git;
const types = @import("git_types.zig");
const layout = @import("layout.zig");
const store = @import("state_store.zig");
const replay_mod = @import("replay.zig");
const model = @import("stack_state.zig");
pub const Node = struct {
    ref_name: []const u8,
    original_oid: []const u8,
    published_oid: []const u8,
    pending_oid: []const u8,
};
pub const Replay = struct { plan_oid: []const u8, plan_len: usize, next: usize = 0, before: []const u8 };
pub const Phase = union(enum) { detaching: Replay, replay: Replay, conflict: Replay, publishing: Replay, switching, aborting: ?Replay, aborted };
pub const PhaseTag = std.meta.Tag(Phase);
pub const Session = struct {
    id: []const u8,
    oplog_parent: ?[]const u8,
    owner: []const u8,
    origin_path: []const u8,
    origin: []const u8,
    origin_oid: []const u8,
    workspace: []const u8,
    workspace_owner: ?[]const u8 = null,
    before_manifest: []const u8,
    manifest: []const u8,
    edited_oid: []const u8,
    nodes: []Node,
    active: usize,
    phase: Phase,
    /// Durable intent to detach the invocation checkout for publication/restoration.
    final_detach: bool = false,
    detached_oid: ?[]const u8 = null,
    cleanup_intent: bool = false,
    abort_expected: ?[]const []const u8 = null,
    // Derived only, never separately persisted.
    state: model.StackState,
    pub fn workNode(self: *const Session) *const Node {
        return &self.nodes[self.nodes.len - 1];
    }
    pub fn replay(self: *const Session) ?Replay {
        return switch (self.phase) {
            .detaching, .replay, .conflict, .publishing => |p| p,
            .aborting => |p| p,
            else => null,
        };
    }
    pub fn expectedOid(self: *const Session, i: usize) []const u8 {
        if (self.phase == .aborting) if (self.abort_expected) |expected| return expected[i];
        if (i == self.active and switch (self.phase) {
            .detaching, .replay, .conflict, .publishing => true,
            else => false,
        }) return self.edited_oid;
        return self.nodes[i].published_oid;
    }
    pub fn plan(self: *const Session, commits: []const []const u8, a: std.mem.Allocator) !replay_mod.Plan {
        const bounds = try a.alloc([]const u8, self.nodes.len);
        for (self.nodes, bounds) |node, *oid| oid.* = node.original_oid;
        return .{ .boundaries = bounds, .active = self.active, .commits = commits };
    }
};
pub const Loaded = struct { oid: []const u8, session: Session, plan: ?[]const []const u8 = null };
const Wire = struct {
    version: u8,
    id: []const u8,
    oplog_parent: ?[]const u8,
    owner: []const u8,
    origin_path: []const u8,
    origin: []const u8,
    origin_oid: []const u8,
    workspace: []const u8,
    workspace_owner: ?[]const u8,
    before_manifest: []const u8,
    manifest: []const u8,
    edited_oid: []const u8,
    nodes: []Node,
    active: usize,
    phase: PhaseTag,
    final_detach: bool,
    detached_oid: ?[]const u8,
    cleanup_intent: bool,
    abort_expected: ?[]const []const u8,
    progress: ?Replay,
};
pub fn encode(a: std.mem.Allocator, s: *const Session) ![]u8 {
    return std.json.Stringify.valueAlloc(a, Wire{
        .version = layout.checkpoint_version,
        .id = s.id,
        .oplog_parent = s.oplog_parent,
        .owner = s.owner,
        .origin_path = s.origin_path,
        .origin = s.origin,
        .origin_oid = s.origin_oid,
        .workspace = s.workspace,
        .workspace_owner = s.workspace_owner,
        .before_manifest = s.before_manifest,
        .manifest = s.manifest,
        .edited_oid = s.edited_oid,
        .nodes = s.nodes,
        .active = s.active,
        .phase = std.meta.activeTag(s.phase),
        .final_detach = s.final_detach,
        .detached_oid = s.detached_oid,
        .cleanup_intent = s.cleanup_intent,
        .abort_expected = s.abort_expected,
        .progress = s.replay(),
    }, .{});
}
pub fn load(git: *const Git) !?Loaded {
    const oid = (try git.readDirectRefAlloc(try types.RefName.init(layout.session_ref))) orelse return null;
    return try loadAt(git, oid);
}
pub fn loadAt(git: *const Git, oid: []const u8) !Loaded {
    var loaded = try loadMetadata(git, oid);
    const s = &loaded.session;
    if (s.replay()) |p| {
        const raw = git.outputRaw(&.{ "cat-file", "blob", p.plan_oid }) catch return error.InvalidEditSession;
        const history = git.history(s.nodes[s.active].original_oid, s.workNode().original_oid) catch return error.InvalidEditSession;
        if (!history.linear or history.commits.len != p.plan_len) return error.InvalidEditSession;
        var lines = std.mem.tokenizeScalar(u8, raw, '\n');
        for (history.commits) |expected| if (!std.mem.eql(u8, expected, lines.next() orelse return error.InvalidEditSession)) return error.InvalidEditSession;
        if (lines.next() != null) return error.InvalidEditSession;
        const plan = try s.plan(history.commits, git.allocator);
        if (plan.boundaryAfter(history.commits) != s.nodes.len) return error.InvalidEditSession;
        loaded.plan = history.commits;
    }
    return loaded;
}
pub fn loadMetadata(git: *const Git, oid: []const u8) !Loaded {
    const a = git.allocator;
    const path = try std.fmt.allocPrint(a, "{s}:session.json", .{oid});
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidEditSession,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Wire, a, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEditSession,
    };
    const w = parsed.value;
    if (w.version != layout.checkpoint_version) return error.InvalidEditSession;
    for ([_][]const u8{ w.id, w.origin_oid, w.before_manifest, w.manifest, w.edited_oid }) |value| _ = git.parseOid(value) catch return error.InvalidEditSession;
    if (w.oplog_parent) |value| _ = git.parseOid(value) catch return error.InvalidEditSession;
    _ = types.BranchRef.init(w.origin) catch return error.InvalidEditSession;
    for ([_][]const u8{ w.owner, w.origin_path, w.workspace }) |value| if (!std.fs.path.isAbsolute(value)) return error.InvalidEditSession;
    if (w.workspace_owner) |value| if (!std.fs.path.isAbsolute(value)) return error.InvalidEditSession;
    const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    const expected_path = try std.fs.path.join(a, &.{ common, "stakrr-workspaces", w.id });
    if (!std.mem.eql(u8, expected_path, w.workspace)) return error.InvalidEditSession;
    if (w.detached_oid) |value| _ = git.parseOid(value) catch return error.InvalidEditSession;
    if (w.final_detach != (w.detached_oid != null)) return error.InvalidEditSession;
    if (w.cleanup_intent and w.phase != .switching and w.phase != .aborted and w.phase != .aborting) return error.InvalidEditSession;
    const before = store.loadAt(git, w.before_manifest) catch return error.InvalidEditSession;
    const state = before.value;
    if (w.nodes.len != state.layers.len + 1 or state.layers.len == 0 or w.active >= state.layers.len) return error.InvalidEditSession;
    for (w.nodes, 0..) |node, i| {
        for ([_][]const u8{ node.original_oid, node.published_oid, node.pending_oid }) |value| _ = git.parseOid(value) catch return error.InvalidEditSession;
        const expected = if (i < state.layers.len) state.layers[i].branch.name.bytes else state.work_branch.name.bytes;
        if (!std.mem.eql(u8, expected, node.ref_name)) return error.InvalidEditSession;
        if (i < state.layers.len and !std.mem.eql(u8, state.layers[i].recorded_boundary_oid.hex(), node.original_oid)) return error.InvalidEditSession;
    }
    const current = store.loadAt(git, w.manifest) catch return error.InvalidEditSession;
    if (!std.mem.eql(u8, current.value.base_branch.name.bytes, state.base_branch.name.bytes) or
        !std.mem.eql(u8, current.value.work_branch.name.bytes, state.work_branch.name.bytes) or
        !current.value.anchor_oid.eql(state.anchor_oid) or current.value.layers.len != state.layers.len) return error.InvalidEditSession;
    for (current.value.layers, w.nodes[0..state.layers.len]) |*layer, node| {
        if (!std.mem.eql(u8, layer.branch.name.bytes, node.ref_name) or
            !std.mem.eql(u8, layer.recorded_boundary_oid.hex(), node.published_oid)) return error.InvalidEditSession;
    }
    if (w.abort_expected) |expected| {
        if (w.phase != .aborting and w.phase != .aborted or expected.len != w.nodes.len) return error.InvalidEditSession;
        for (expected) |value| _ = git.parseOid(value) catch return error.InvalidEditSession;
    }
    const phase: Phase = switch (w.phase) {
        .detaching, .replay, .conflict, .publishing => blk: {
            const p = w.progress orelse return error.InvalidEditSession;
            if (p.next > p.plan_len) return error.InvalidEditSession;
            if (w.phase == .detaching and p.next != 0 or w.phase == .conflict and p.next == p.plan_len or w.phase == .publishing and p.next != p.plan_len) return error.InvalidEditSession;
            break :blk switch (w.phase) {
                .detaching => .{ .detaching = p },
                .replay => .{ .replay = p },
                .conflict => .{ .conflict = p },
                .publishing => .{ .publishing = p },
                else => unreachable,
            };
        },
        .aborting => .{ .aborting = w.progress },
        .aborted => .aborted,
        .switching => .switching,
    };
    if (w.progress) |p| {
        _ = git.parseOid(p.plan_oid) catch return error.InvalidEditSession;
        _ = git.parseOid(p.before) catch return error.InvalidEditSession;
        const actual = git.output(&.{ "rev-parse", try std.fmt.allocPrint(a, "{s}:plan", .{oid}) }) catch return error.InvalidEditSession;
        if (!std.mem.eql(u8, actual, p.plan_oid)) return error.InvalidEditSession;
    }
    return .{ .oid = oid, .session = .{
        .id = w.id,
        .oplog_parent = w.oplog_parent,
        .owner = w.owner,
        .origin_path = w.origin_path,
        .origin = w.origin,
        .origin_oid = w.origin_oid,
        .workspace = w.workspace,
        .workspace_owner = w.workspace_owner,
        .before_manifest = w.before_manifest,
        .manifest = w.manifest,
        .edited_oid = w.edited_oid,
        .nodes = w.nodes,
        .active = w.active,
        .phase = phase,
        .final_detach = w.final_detach,
        .detached_oid = w.detached_oid,
        .cleanup_intent = w.cleanup_intent,
        .abort_expected = w.abort_expected,
        .state = state,
    } };
}
pub fn previous(git: *const Git, oid: []const u8) !?[]const u8 {
    const value = git.output(&.{ "show", try std.fmt.allocPrint(git.allocator, "{s}:previous", .{oid}) }) catch |err| switch (err) {
        error.GitFailed => return null,
        else => return err,
    };
    if (value.len == 0) return null;
    _ = git.parseOid(value) catch return error.InvalidEditSession;
    return value;
}
pub fn create(git: *const Git, s: *const Session, old: ?[]const u8, retain: []const []const u8, label: []const u8) ![]u8 {
    const a = git.allocator;
    var parents: std.ArrayList([]const u8) = .empty;
    const predecessor = old orelse s.oplog_parent;
    if (predecessor) |value| try parents.append(a, value);
    try parents.appendSlice(a, &.{ s.before_manifest, s.manifest, s.edited_oid, s.origin_oid });
    for (s.nodes) |node| try parents.appendSlice(a, &.{ node.original_oid, node.published_oid, node.pending_oid });
    for (retain) |oid| try parents.append(a, oid);
    const rescue = if (s.replay()) |p| p.before else s.workNode().published_oid;
    try parents.append(a, rescue);
    var entries: std.ArrayList(Git.TreeEntry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .name = "session.json", .oid = try git.writeBlob(try encode(a, s)) },
        .{ .name = "previous", .oid = try git.writeBlob(predecessor orelse "") },
        .{ .name = "rescue", .oid = try git.writeBlob(rescue) },
    });
    if (s.replay()) |p| try entries.append(a, .{ .name = "plan", .oid = p.plan_oid });
    return git.commitTreeWithOptions(try git.writeTree(entries.items), parents.items, label, .{ .identity = .{ .name = "stakrr", .email = "stakrr@localhost" } });
}
