//! Private edit model and v1/v2 checkpoint codec. All returned slices belong to
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

    /// A boundary not yet edited, copied into `allocator`.
    pub fn init(allocator: std.mem.Allocator, ref_name: []const u8, oid: []const u8) !Node {
        const copy = try allocator.dupe(u8, oid);
        return .{
            .ref_name = try allocator.dupe(u8, ref_name),
            .original_oid = copy,
            .published_oid = copy,
            .pending_oid = copy,
        };
    }
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

pub const Rollback = struct {
    expected: []const []const u8,
    target: []const []const u8,
    active: usize,
    return_ref: []const u8,
    end: bool,
};

pub const Outcome = enum { active, finished, aborted, quit, undone };
pub const Operation = enum { edit, undo };

pub const Session = struct {
    oplog_parent: ?[]const u8 = null,
    outcome: Outcome = .active,
    operation: Operation = .edit,
    rollback: ?Rollback = null,
    undo_cursor: ?[]const u8 = null,
    id: []const u8,
    owner: []const u8,
    origin: []const u8,
    /// raw persisted state, compared byte-for-byte before each transition
    config: []const u8,
    /// parsed from `config`
    branches: stack.Branches,
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

    /// Once an edit is incorporated, the active cut's ref holds its pending
    /// replacement until the replay is published or rolled back.
    pub fn expectedOid(self: *const Session, index: usize) []const u8 {
        const node = self.nodes[index];
        if (self.phase == .aborting) {
            if (self.rollback) |rollback| return rollback.expected[index];
        }
        const pending = index == self.active and switch (self.phase) {
            .detaching, .replay, .conflict, .publishing, .aborting => true,
            else => false,
        };
        return if (pending) node.pending_oid else node.published_oid;
    }

    /// Index of the first descendant boundary not yet reached once `picked`,
    /// a prefix of the replay plan, is applied. Boundaries coinciding with
    /// the active cut are reached before the first pick.
    pub fn boundaryAfter(self: *const Session, picked: []const []const u8) usize {
        var boundary = self.active + 1;
        const active_oid = self.nodes[self.active].published_oid;
        while (boundary < self.nodes.len and
            std.mem.eql(u8, self.nodes[boundary].published_oid, active_oid))
            boundary += 1;
        for (picked) |commit| {
            while (boundary < self.nodes.len and
                std.mem.eql(u8, self.nodes[boundary].published_oid, commit))
                boundary += 1;
        }
        return boundary;
    }

    pub fn destination(self: *const Session) ?usize {
        if (self.rollback) |rollback| return if (rollback.end) null else rollback.active;
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

// Flatten the phase union so the on-disk representation is independent of
// runtime phase invariants; `load` re-establishes them.
const WireSession = struct {
    version: u8 = 2,
    oplog_parent: ?[]const u8 = null,
    outcome: Outcome = .active,
    operation: Operation = .edit,
    rollback: ?Rollback = null,
    undo_cursor: ?[]const u8 = null,
    id: []const u8,
    owner: []const u8,
    origin: []const u8,
    config: []const u8,
    anchor: []const u8,
    nodes: []Node,
    active: usize,
    destination: ?usize,
    phase: PhaseTag,
    plan_oid: ?[]const u8 = null,
    plan_len: usize = 0,
    next: usize = 0,
    before: []const u8,
};

pub fn encode(allocator: std.mem.Allocator, s: *const Session) ![]u8 {
    const progress = s.replay();
    return std.json.Stringify.valueAlloc(allocator, WireSession{
        .oplog_parent = s.oplog_parent,
        .outcome = s.outcome,
        .operation = s.operation,
        .rollback = s.rollback,
        .undo_cursor = s.undo_cursor,
        .id = s.id,
        .owner = s.owner,
        .origin = s.origin,
        .config = s.config,
        .anchor = s.anchor,
        .nodes = s.nodes,
        .active = s.active,
        .destination = if (s.phase == .editing) s.active else s.destination(),
        .phase = std.meta.activeTag(s.phase),
        .plan_oid = if (progress) |p| p.plan_oid else null,
        .plan_len = if (progress) |p| p.plan_len else 0,
        .next = if (progress) |p| p.next else 0,
        .before = if (progress) |p| p.before else s.anchor,
    }, .{});
}

pub fn load(git: *const Git) !?Loaded {
    const oid = (try git.readRef(layout.session_ref)) orelse return null;
    return try loadAt(git, oid);
}

pub fn loadAt(git: *const Git, oid: []const u8) !Loaded {
    const kind = try git.output(&.{ "cat-file", "-t", oid });
    const is_commit = std.mem.eql(u8, kind, "commit");
    if (!is_commit and !std.mem.eql(u8, kind, "blob")) return error.InvalidEditSession;
    const path = if (is_commit) try std.fmt.allocPrint(git.allocator, "{s}:session.json", .{oid}) else oid;
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
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
    if (wire.version != (if (is_commit) @as(u8, 2) else 1)) return error.InvalidEditSession;
    if (wire.oplog_parent) |parent| if (!validOid(parent, oid.len)) return error.InvalidEditSession;
    if (is_commit and wire.plan_oid != null) {
        const plan_path = try std.fmt.allocPrint(git.allocator, "{s}:plan", .{oid});
        const actual = git.output(&.{ "rev-parse", "--verify", plan_path }) catch return error.InvalidEditSession;
        if (!std.mem.eql(u8, actual, wire.plan_oid.?)) return error.InvalidEditSession;
    }
    if (!validOid(wire.id, oid.len) or
        !validOid(wire.anchor, oid.len) or
        !validOid(wire.before, oid.len))
        return error.InvalidEditSession;
    if (!git_mod.isSafeBranchRef(wire.origin) or wire.owner.len == 0)
        return error.InvalidEditSession;
    if (wire.nodes.len < 2 or wire.active >= wire.nodes.len - 1)
        return error.InvalidEditSession;
    if (wire.next > wire.plan_len) return error.InvalidEditSession;
    if (wire.destination) |index| {
        if (index >= wire.nodes.len - 1) return error.InvalidEditSession;
    }

    if (wire.undo_cursor) |cursor| if (!validOid(cursor, oid.len)) return error.InvalidEditSession;
    if (wire.rollback) |rollback| {
        if (wire.phase != .aborting and wire.phase != .aborted) return error.InvalidEditSession;
        if (rollback.expected.len != wire.nodes.len or rollback.target.len != wire.nodes.len or
            rollback.active >= wire.nodes.len - 1 or !git_mod.isSafeBranchRef(rollback.return_ref))
            return error.InvalidEditSession;
        for (rollback.expected, rollback.target) |from, to|
            if (!validOid(from, oid.len) or !validOid(to, oid.len)) return error.InvalidEditSession;
    }

    const branches = stack.parseConfig(wire.config) catch return error.InvalidEditSession;
    if (!std.mem.eql(u8, branches.work_ref, wire.nodes[wire.nodes.len - 1].ref_name))
        return error.InvalidEditSession;

    const nodes = wire.nodes;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(git.allocator);
    for (nodes, 0..) |node, i| {
        if (!git_mod.isSafeBranchRef(node.ref_name)) return error.InvalidEditSession;
        if (!validOid(node.original_oid, oid.len) or
            !validOid(node.published_oid, oid.len) or
            !validOid(node.pending_oid, oid.len))
            return error.InvalidEditSession;
        if (i < nodes.len - 1) {
            const name = layout.layerName(node.ref_name) orelse
                return error.InvalidEditSession;
            if (name.len == 0) return error.InvalidEditSession;
        }
        if ((try names.getOrPut(git.allocator, node.ref_name)).found_existing)
            return error.InvalidEditSession;
    }

    var progress: ?Replay = null;
    if (wire.plan_oid) |plan| {
        if (!validOid(plan, oid.len)) return error.InvalidEditSession;
        progress = .{
            .destination = wire.destination,
            .plan_oid = plan,
            .plan_len = wire.plan_len,
            .next = wire.next,
            .before = wire.before,
        };
    } else if (wire.plan_len != 0 or wire.next != 0) return error.InvalidEditSession;

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
        .oplog_parent = if (wire.version == 1) try git.readRef(layout.oplog_ref) else wire.oplog_parent,
        .outcome = wire.outcome,
        .operation = wire.operation,
        .rollback = wire.rollback,
        .undo_cursor = wire.undo_cursor,
        .id = wire.id,
        .owner = wire.owner,
        .origin = wire.origin,
        .config = wire.config,
        .branches = branches,
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

/// Previous journal checkpoint, kept as the first parent when it is a commit.
/// The explicit link also ends traversal before the retained user commits.
pub fn previous(git: *const Git, oid: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(git.allocator, "{s}:previous", .{oid});
    const value = git.output(&.{ "show", path }) catch |err| switch (err) {
        error.GitFailed => return null,
        else => return err,
    };
    if (value.len == 0) return null;
    if (!git_mod.isOid(value)) return error.InvalidEditSession;
    return value;
}

/// Write a v2 journal commit. Blobs live in its tree; commits to retain are
/// parents, so ordinary Git reachability protects everything from pruning.
pub fn create(git: *const Git, s: *const Session, old: ?[]const u8, retain: []const []const u8, label: []const u8) ![]u8 {
    var entries: std.ArrayList(Git.TreeEntry) = .empty;
    var parents: std.ArrayList([]const u8) = .empty;
    var predecessor = old orelse s.oplog_parent;
    if (predecessor) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (std.mem.eql(u8, kind, "commit")) {
            try parents.append(git.allocator, oid);
        } else if (std.mem.eql(u8, kind, "blob")) {
            // Migrating an in-flight v1 session also retains its raw journal.
            try entries.append(git.allocator, .{ .name = "legacy", .oid = oid });
            predecessor = s.oplog_parent;
            if (s.oplog_parent) |oplog| try parents.append(git.allocator, oplog);
        } else return error.InvalidEditSession;
    }
    const rescue = if (retain.len != 0) retain[0] else if (s.replay()) |p| p.before else s.workNode().published_oid;
    try parents.append(git.allocator, rescue);
    for (retain) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (std.mem.eql(u8, kind, "commit")) try parents.append(git.allocator, oid);
    }
    // A newly migrated v1 session may have no retained commit parents yet.
    for (s.nodes) |node| {
        try parents.appendSlice(git.allocator, &.{ node.original_oid, node.published_oid, node.pending_oid });
    }
    try entries.append(git.allocator, .{ .name = "session.json", .oid = try git.writeBlobWithFormat(try encode(git.allocator, s), s.objectFormat()) });
    try entries.append(git.allocator, .{ .name = "rescue", .oid = try git.writeBlobWithFormat(rescue, s.objectFormat()) });
    try entries.append(git.allocator, .{ .name = "previous", .oid = try git.writeBlobWithFormat(predecessor orelse "", s.objectFormat()) });
    if (s.replay()) |p| try entries.append(git.allocator, .{ .name = "plan", .oid = p.plan_oid });
    return git.commitTree(try git.writeTree(entries.items), parents.items, label);
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
    var history = try git.history(
        s.nodes[s.active].published_oid,
        s.workNode().published_oid,
    );
    defer history.deinit(git.allocator);
    if (history.commits.len != queue.items.len) return error.InvalidEditSession;
    for (queue.items, history.commits) |commit, expected| {
        if (!std.mem.eql(u8, commit, expected)) return error.InvalidEditSession;
    }

    // Every descendant boundary must occur in order, including coincident
    // work/top-cut tips. This also makes replay's advancing cursor safe.
    if (s.boundaryAfter(queue.items) != s.nodes.len) return error.InvalidEditSession;
    return queue.items;
}
