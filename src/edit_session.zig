//! Private edit model and v1 checkpoint codec. All returned slices belong to
//! the caller's command arena. No Git mutation occurs while loading state.
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const stack = @import("stack.zig");
const layout = @import("layout.zig");

pub const Node = struct {
    ref_name: []const u8,
    /// Restored by abort, even after several incorporated edits.
    original_oid: []const u8,
    /// Last incorporated boundary; the active branch may have user commits.
    published_oid: []const u8,
    /// Replacement boundary produced by the current edit/replay.
    pending_oid: []const u8,
};

pub const Replay = struct {
    destination: ?usize,
    plan_oid: []const u8,
    plan_len: usize,
    next: usize = 0,
    before: []const u8,
};

pub const Phase = union(enum) {
    switching: ?usize,
    editing,
    detaching: Replay,
    replay: Replay,
    conflict: Replay,
    publishing: Replay,
    aborting: ?Replay,
    aborted,
};
pub const PhaseTag = std.meta.Tag(Phase);

pub const Session = struct {
    id: []const u8,
    owner: []const u8,
    origin: []const u8,
    config: []const u8,
    anchor: []const u8,
    nodes: []Node, // ordered cuts, then rolling work
    active: usize,
    phase: Phase,

    pub fn workNode(self: *const Session) *const Node {
        return &self.nodes[self.nodes.len - 1];
    }

    pub fn topCut(self: *const Session) *const Node {
        return &self.nodes[self.nodes.len - 2];
    }

    pub fn objectFormat(self: *const Session) Git.ObjectFormat {
        return if (self.id.len == 40) .sha1 else .sha256;
    }

    pub fn replay(self: *const Session) ?Replay {
        return switch (self.phase) {
            .detaching, .replay, .conflict, .publishing => |progress| progress,
            .aborting => |progress| progress,
            else => null,
        };
    }

    pub fn destination(self: *const Session) ?usize {
        return switch (self.phase) {
            .switching => |target| target,
            else => if (self.replay()) |progress| progress.destination else null,
        };
    }
};

pub const Loaded = struct {
    oid: []const u8,
    session: Session,
    plan: ?[]const []const u8 = null,
    // Reused only before detach; checkout hooks invalidate the observation.
    ignored_checked: bool = false,
};

// Keep the on-disk representation independent of runtime phase invariants.
const WireNode = struct {
    ref_name: []const u8,
    original: []const u8,
    oid: []const u8,
    result: []const u8,
};

const WireSession = struct {
    version: u8 = 1,
    id: []const u8,
    owner: []const u8,
    origin: []const u8,
    config: []const u8,
    anchor: []const u8,
    nodes: []WireNode,
    active: usize,
    destination: ?usize,
    phase: PhaseTag,
    queue_oid: ?[]const u8 = null,
    queue_len: usize = 0,
    next: usize = 0,
    before: []const u8,
};

pub fn encode(allocator: std.mem.Allocator, s: *const Session) ![]u8 {
    const nodes = try allocator.alloc(WireNode, s.nodes.len);
    defer allocator.free(nodes);
    for (s.nodes, nodes) |node, *wire| wire.* = .{
        .ref_name = node.ref_name,
        .original = node.original_oid,
        .oid = node.published_oid,
        .result = node.pending_oid,
    };
    const progress = s.replay();
    return std.json.Stringify.valueAlloc(allocator, WireSession{
        .id = s.id,
        .owner = s.owner,
        .origin = s.origin,
        .config = s.config,
        .anchor = s.anchor,
        .nodes = nodes,
        .active = s.active,
        .destination = if (s.phase == .editing) s.active else s.destination(),
        .phase = std.meta.activeTag(s.phase),
        .queue_oid = if (progress) |p| p.plan_oid else null,
        .queue_len = if (progress) |p| p.plan_len else 0,
        .next = if (progress) |p| p.next else 0,
        .before = if (progress) |p| p.before else s.anchor,
    }, .{});
}

pub fn load(git: *const Git) !?Loaded {
    const oid = (try git.readRef(layout.session_ref)) orelse return null;
    const raw = git.outputRaw(&.{ "cat-file", "blob", oid }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidEditSession,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(
        WireSession,
        git.allocator,
        raw,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEditSession,
    };

    const wire = parsed.value;
    if (wire.version != 1) return error.InvalidEditSession;
    if (!validOid(wire.id, oid.len) or
        !validOid(wire.anchor, oid.len) or
        !validOid(wire.before, oid.len))
        return error.InvalidEditSession;
    if (!git_mod.isSafeBranchRef(wire.origin) or wire.owner.len == 0)
        return error.InvalidEditSession;
    if (wire.nodes.len < 2 or wire.active >= wire.nodes.len - 1)
        return error.InvalidEditSession;
    if (wire.next > wire.queue_len) return error.InvalidEditSession;
    if (wire.destination) |index| {
        if (index >= wire.nodes.len - 1) return error.InvalidEditSession;
    }

    const config = stack.parseConfig(wire.config) catch return error.InvalidEditSession;
    if (!std.mem.eql(u8, config.work_ref, wire.nodes[wire.nodes.len - 1].ref_name))
        return error.InvalidEditSession;

    const nodes = try git.allocator.alloc(Node, wire.nodes.len);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(git.allocator);
    for (wire.nodes, nodes, 0..) |node, *runtime, i| {
        if (!git_mod.isSafeBranchRef(node.ref_name)) return error.InvalidEditSession;
        if (!validOid(node.original, oid.len) or
            !validOid(node.oid, oid.len) or
            !validOid(node.result, oid.len))
            return error.InvalidEditSession;
        if (i < nodes.len - 1) {
            const name = layout.layerName(node.ref_name) orelse
                return error.InvalidEditSession;
            if (name.len == 0) return error.InvalidEditSession;
        }
        if ((try names.getOrPut(git.allocator, node.ref_name)).found_existing)
            return error.InvalidEditSession;
        runtime.* = .{
            .ref_name = node.ref_name,
            .original_oid = node.original,
            .published_oid = node.oid,
            .pending_oid = node.result,
        };
    }

    var progress: ?Replay = null;
    if (wire.queue_oid) |plan| {
        if (!validOid(plan, oid.len)) return error.InvalidEditSession;
        progress = .{
            .destination = wire.destination,
            .plan_oid = plan,
            .plan_len = wire.queue_len,
            .next = wire.next,
            .before = wire.before,
        };
    } else if (wire.queue_len != 0 or wire.next != 0) return error.InvalidEditSession;

    const phase: Phase = switch (wire.phase) {
        .switching => .{ .switching = wire.destination },
        .editing => phase: {
            if (progress != null or wire.destination != wire.active)
                return error.InvalidEditSession;
            break :phase .editing;
        },
        .detaching => phase: {
            const p = progress orelse return error.InvalidEditSession;
            if (p.next != 0) return error.InvalidEditSession;
            break :phase .{ .detaching = p };
        },
        .replay => .{ .replay = progress orelse return error.InvalidEditSession },
        .conflict => phase: {
            const p = progress orelse return error.InvalidEditSession;
            if (p.next >= p.plan_len) return error.InvalidEditSession;
            break :phase .{ .conflict = p };
        },
        .publishing => phase: {
            const p = progress orelse return error.InvalidEditSession;
            if (p.next != p.plan_len) return error.InvalidEditSession;
            break :phase .{ .publishing = p };
        },
        .aborting => .{ .aborting = progress },
        .aborted => .aborted,
    };
    var s: Session = .{
        .id = wire.id,
        .owner = wire.owner,
        .origin = wire.origin,
        .config = wire.config,
        .anchor = wire.anchor,
        .nodes = nodes,
        .active = wire.active,
        .phase = phase,
    };
    // Plans are checked for every phase that can resume a replay, including
    // detaching and aborting, before any caller changes HEAD or refs.
    const plan = if (s.replay() != null) try loadReplayPlan(git, &s) else null;
    return .{ .oid = oid, .session = s, .plan = plan };
}

fn validOid(oid: []const u8, len: usize) bool {
    return oid.len == len and git_mod.isOid(oid);
}

fn loadReplayPlan(git: *const Git, s: *const Session) ![]const []const u8 {
    const progress = s.replay() orelse return error.InvalidEditSession;
    const plan = git.outputRaw(
        &.{ "cat-file", "blob", progress.plan_oid },
    ) catch |err| switch (err) {
        error.GitFailed => return error.InvalidEditSession,
        else => return err,
    };
    var queue: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(git.allocator);
    var commits = std.mem.tokenizeScalar(u8, plan, '\n');
    while (commits.next()) |commit| {
        if (!validOid(commit, s.id.len) or
            (try seen.getOrPut(git.allocator, commit)).found_existing)
            return error.InvalidEditSession;
        try queue.append(git.allocator, commit);
    }
    if (queue.items.len != progress.plan_len) return error.InvalidEditSession;

    // Boundaries alone cannot detect missing or reordered commits between cuts.
    const history = try git.revListParents(
        s.nodes[s.active].published_oid,
        s.workNode().published_oid,
    );
    defer git.allocator.free(history);
    var lines = std.mem.tokenizeScalar(u8, history, '\n');
    for (queue.items) |commit| {
        const line = lines.next() orelse return error.InvalidEditSession;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const expected = fields.next() orelse return error.InvalidEditSession;
        if (!std.mem.eql(u8, commit, expected)) return error.InvalidEditSession;
    }
    if (lines.next() != null) return error.InvalidEditSession;

    // Every descendant boundary must occur in order, including coincident
    // work/top-cut tips. This also makes replay's advancing cursor safe.
    var boundary = s.active + 1;
    const active_oid = s.nodes[s.active].published_oid;
    while (boundary < s.nodes.len) : (boundary += 1) {
        if (!std.mem.eql(u8, s.nodes[boundary].published_oid, active_oid)) break;
    }
    for (queue.items) |commit| {
        while (boundary < s.nodes.len and std.mem.eql(u8, s.nodes[boundary].published_oid, commit))
            boundary += 1;
    }
    if (boundary != s.nodes.len) return error.InvalidEditSession;
    return queue.items;
}
