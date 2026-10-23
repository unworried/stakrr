//! Private edit model and checkpoint codec. All returned slices belong to
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
    plan_oid: []const u8,
    plan_len: usize,
    next: usize = 0,
    before: []const u8,
};

pub const Phase = union(enum) {
    /// published; only the return to the original branch remains
    switching,
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
};

pub const Outcome = enum { active, finished, aborted, quit, undone };
pub const Operation = enum { edit, undo };

pub const Session = struct {
    oplog_parent: ?[]const u8 = null,
    outcome: Outcome = .active,
    operation: Operation = .edit,
    rollback: ?Rollback = null,
    id: []const u8,
    owner: []const u8,
    /// the branch checked out when the session began; restored at the end
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
    id: []const u8,
    owner: []const u8,
    origin: []const u8,
    config: []const u8,
    anchor: []const u8,
    nodes: []Node,
    active: usize,
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
        .id = s.id,
        .owner = s.owner,
        .origin = s.origin,
        .config = s.config,
        .anchor = s.anchor,
        .nodes = s.nodes,
        .active = s.active,
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

/// Load a checkpoint and, for replay phases, validate its plan before any
/// caller changes HEAD or refs.
pub fn loadAt(git: *const Git, oid: []const u8) !Loaded {
    var loaded = try loadMetadata(git, oid);
    // Plans are checked for every phase that can resume a replay, including
    // detaching and aborting.
    if (loaded.session.replay() != null) loaded.plan = try loadReplayPlan(git, &loaded.session);
    return loaded;
}

/// Decode and validate a checkpoint without reading its replay plan. For
/// read-only callers; anything that resumes a session must use `loadAt`.
pub fn loadMetadata(git: *const Git, oid: []const u8) !Loaded {
    const kind = try git.output(&.{ "cat-file", "-t", oid });
    if (!std.mem.eql(u8, kind, "commit")) return error.InvalidEditSession;
    const path = try std.fmt.allocPrint(git.allocator, "{s}:session.json", .{oid});
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidEditSession,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(
        WireSession,
        git.allocator,
        raw,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEditSession,
    };

    const wire = parsed.value;
    if (wire.version != 2) return error.InvalidEditSession;
    if (wire.oplog_parent) |parent| if (!validOid(parent, oid.len)) return error.InvalidEditSession;
    if (wire.plan_oid != null) {
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

    if (wire.rollback) |rollback| {
        if (wire.phase != .aborting and wire.phase != .aborted) return error.InvalidEditSession;
        if (rollback.expected.len != wire.nodes.len or rollback.target.len != wire.nodes.len)
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
            .plan_oid = plan,
            .plan_len = wire.plan_len,
            .next = wire.next,
            .before = wire.before,
        };
    } else if (wire.plan_len != 0 or wire.next != 0) return error.InvalidEditSession;

    const phase: Phase = switch (wire.phase) {
        .switching => .switching,
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
    const s: Session = .{
        .oplog_parent = wire.oplog_parent,
        .outcome = wire.outcome,
        .operation = wire.operation,
        .rollback = wire.rollback,
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
    return .{ .oid = oid, .session = s, .plan = null };
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
    const predecessor = old orelse s.oplog_parent;
    if (predecessor) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (!std.mem.eql(u8, kind, "commit")) return error.InvalidEditSession;
        try parents.append(git.allocator, oid);
    }
    const rescue = if (retain.len != 0) retain[0] else if (s.replay()) |p| p.before else s.workNode().published_oid;
    try parents.append(git.allocator, rescue);
    for (retain) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (std.mem.eql(u8, kind, "commit")) try parents.append(git.allocator, oid);
    }
    // every boundary the checkpoint refers to stays reachable
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
    defer git.allocator.free(plan);

    // Exact history comparison also rejects malformed and duplicate IDs;
    // boundaries alone cannot detect missing or reordered commits between cuts.
    var history = try git.history(
        s.nodes[s.active].published_oid,
        s.workNode().published_oid,
    );
    errdefer history.deinit(git.allocator);
    if (!history.linear or history.commits.len != progress.plan_len) return error.InvalidEditSession;
    var commits = std.mem.tokenizeScalar(u8, plan, '\n');
    for (history.commits) |expected| {
        const commit = commits.next() orelse return error.InvalidEditSession;
        if (!std.mem.eql(u8, commit, expected)) return error.InvalidEditSession;
    }
    if (commits.next() != null) return error.InvalidEditSession;

    // Every descendant boundary must occur in order, including coincident
    // work/top-cut tips. This also makes replay's advancing cursor safe.
    if (s.boundaryAfter(history.commits) != s.nodes.len) return error.InvalidEditSession;
    return history.commits;
}
