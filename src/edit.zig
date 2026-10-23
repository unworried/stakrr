//! Managed edits. A commit ref journals each step; ref publication and journal
//! advancement share a compare-and-swap transaction. Replay runs detached so
//! branch boundaries remain untouched until the complete replay is available.
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const stack = @import("stack.zig");
const coordination = @import("coordination.zig");
const layout = @import("layout.zig");

/// Domain errors raised by edit operations, including shared Git and guards.
/// Every member has a user-facing message in main.zig.
pub const Error = stack.Error || error{
    NoEditSession,
    WrongEditWorktree,
    InvalidEditSession,
    EditStateChanged,
    ReplayConflict,
    InvalidEditedHistory,
    NothingToRestack,
    MultipleStaleLayers,
    NoUndo,
};
pub const Request = enum { restack, continue_edit, abort, quit };
const checkpoint = @import("edit_session.zig");
const Node = checkpoint.Node;
const Session = checkpoint.Session;
const Loaded = checkpoint.Loaded;

/// A command owns all temporary session data. Never expose arena-backed slices
/// through the public API; status transfers ownership of its arena explicitly.
const Context = struct {
    arena: std.heap.ArenaAllocator,
    git: Git,

    fn init(self: *Context, original: *const Git) void {
        self.arena = .init(original.allocator);
        self.git = original.withAllocator(self.arena.allocator());
    }

    fn deinit(self: *Context) void {
        self.arena.deinit();
    }
};

/// Owned read-only view. Branch names and metadata remain valid until deinit.
/// Active sessions intentionally need not form a linear published stack.
pub const Status = struct {
    active: usize,
    phase: checkpoint.PhaseTag,
    origin: []const u8,
    base: []const u8,
    owner: []const u8,
    destination: []const u8,
    branches: []const []const u8,
    session_id: []const u8,
    /// set while descendants replay, from detaching until publication
    progress: ?Progress,
    /// the commit a replay conflict stopped on
    stopped: ?Stop,
    _arena: std.heap.ArenaAllocator,

    pub const Progress = struct { done: usize, total: usize };
    pub const Stop = struct { oid: []const u8, subject: []const u8 };

    pub fn deinit(self: *Status) void {
        self._arena.deinit();
        self.* = undefined;
    }
};

/// Entry point for both the library and CLI. Lock lifetime covers one command;
/// the persistent session excludes other mutations between commands.
pub fn run(original_git: *const Git, request: Request) !void {
    var context: Context = undefined;
    context.init(original_git);
    defer context.deinit();
    const git = &context.git;
    const guard = try coordination.lock(git);
    defer guard.close(git.io);
    return runLocked(git, request);
}

fn runLocked(git: *const Git, request: Request) !void {
    if (request == .quit) return quitSession(git);
    var loaded = (try checkpoint.load(git)) orelse {
        if (request != .restack) return error.NoEditSession;
        var fresh = try begin(git);
        return advance(git, &fresh);
    };
    const s = &loaded.session;
    try checkOwner(git, s);
    try checkRefs(git, s);
    try available(git, s);
    switch (request) {
        // a pending session must be finished or abandoned first
        .restack => return error.EditInProgress,
        .abort => return abortSession(git, &loaded),
        .continue_edit => return advance(git, &loaded),
        .quit => unreachable,
    }
}

pub fn readStatus(original_git: *const Git) !?Status {
    var context: Context = undefined;
    context.init(original_git);
    errdefer context.deinit();
    const git = &context.git;
    try git.ensureWorkTree();
    const loaded = (try checkpoint.load(git)) orelse {
        context.deinit();
        return null;
    };
    const s = &loaded.session;
    const branches = try git.allocator.alloc([]const u8, s.nodes.len);
    for (s.nodes, branches) |node, *ref| ref.* = node.ref_name;
    const progress: ?Status.Progress = switch (s.phase) {
        .detaching, .replay, .conflict, .publishing => |p| .{ .done = p.next, .total = p.plan_len },
        else => null,
    };
    var stopped: ?Status.Stop = null;
    if (s.phase == .conflict) {
        const oid = loaded.plan.?[s.phase.conflict.next];
        stopped = .{ .oid = oid, .subject = try git.output(&.{ "log", "--no-walk", "--format=%s", oid }) };
    }
    return .{
        .active = s.active,
        .phase = std.meta.activeTag(s.phase),
        .origin = s.origin,
        .base = s.branches.base_ref,
        .owner = s.owner,
        .destination = s.origin,
        .branches = branches,
        .session_id = s.id,
        .progress = progress,
        .stopped = stopped,
        ._arena = context.arena,
    };
}

pub const Log = struct {
    steps: []const Step,
    _arena: std.heap.ArenaAllocator,

    pub const Move = struct { name: []const u8, before: []const u8, after: []const u8 };
    pub const Step = struct { oid: []const u8, time: []const u8, label: []const u8, moves: []const Move, rescue: []const u8 };

    pub fn deinit(self: *Log) void {
        self._arena.deinit();
        self.* = undefined;
    }
};

/// Log reads never resume a session, so the replay plan is not validated.
fn decodeCheckpoint(git: *const Git, oid: []const u8) !?Loaded {
    return checkpoint.loadMetadata(git, oid) catch |err| switch (err) {
        error.InvalidEditSession => null,
        else => return err,
    };
}

/// Newest first, including an in-progress session and previous operations.
pub fn readLog(original_git: *const Git) !Log {
    var context: Context = undefined;
    context.init(original_git);
    errdefer context.deinit();
    const git = &context.git;
    try git.ensureWorkTree();
    var cursor: ?[]const u8 = (try git.readRef(layout.session_ref)) orelse try git.readRef(layout.oplog_ref);
    var steps: std.ArrayList(Log.Step) = .empty;
    var carried: ??Loaded = null;
    while (cursor) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (!eql(kind, "commit")) break; // not a checkpoint
        const rescue_path = try std.fmt.allocPrint(git.allocator, "{s}:rescue", .{oid});
        const rescue = git.output(&.{ "show", rescue_path }) catch |err| switch (err) {
            error.GitFailed => break, // not a journal commit
            else => return err,
        };
        const metadata = try git.output(&.{ "show", "--no-patch", "--format=%cI%x09%s", oid });
        const separator = std.mem.indexOfScalar(u8, metadata, '\t') orelse return error.InvalidEditSession;
        const previous = try checkpoint.previous(git, oid);
        // The parent decoded for one step is the next step's checkpoint.
        const current = carried orelse try decodeCheckpoint(git, oid);
        const before = if (previous) |parent| try decodeCheckpoint(git, parent) else null;
        carried = if (previous != null) @as(??Loaded, before) else null;
        var moves: std.ArrayList(Log.Move) = .empty;
        if (current) |after| {
            for (after.session.nodes, 0..) |node, i| {
                // A new operation starts from its saved original refs. Only
                // checkpoints within that operation describe its earlier steps.
                var from = node.original_oid;
                if (before) |prior| {
                    if (eql(prior.session.id, after.session.id)) {
                        for (prior.session.nodes, 0..) |old, j| {
                            if (!eql(node.ref_name, old.ref_name)) continue;
                            from = prior.session.expectedOid(j);
                            break;
                        }
                    }
                }
                const to = after.session.expectedOid(i);
                if (!eql(from, to)) try moves.append(git.allocator, .{ .name = node.ref_name, .before = from, .after = to });
            }
        }
        try steps.append(git.allocator, .{
            .oid = oid,
            .time = metadata[0..separator],
            .label = metadata[separator + 1 ..],
            .moves = moves.items,
            .rescue = rescue,
        });
        cursor = previous;
    }
    return .{ .steps = steps.items, ._arena = context.arena };
}

/// Owned description of the first ref, config value or HEAD that differs from
/// the journal. `expected` is null for a ref the session does not know; `actual`
/// is null for a missing ref. HEAD values are a branch ref or a detached oid.
pub const Drift = struct {
    name: []const u8,
    expected: ?[]const u8,
    actual: ?[]const u8,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Drift) void {
        self._arena.deinit();
        self.* = undefined;
    }
};

/// Explain an `EditStateChanged` failure. Read-only and unlocked, like status;
/// null when no session exists or nothing differs any more.
pub fn findDrift(original_git: *const Git) !?Drift {
    var context: Context = undefined;
    context.init(original_git);
    errdefer context.deinit();
    const git = &context.git;
    const found = drift(git) catch |err| switch (err) {
        error.InvalidEditSession => null,
        else => return err,
    };
    const m = found orelse {
        context.deinit();
        return null;
    };
    return .{ .name = m.name, .expected = m.expected, .actual = m.actual, ._arena = context.arena };
}

fn drift(git: *const Git) !?Mismatch {
    const loaded = (try checkpoint.load(git)) orelse return null;
    return (try refDrift(git, &loaded.session)) orelse try headDrift(git, &loaded.session);
}

/// Start a restack: the one layer whose branch moved past its recorded boundary
/// becomes the new boundary, and everything above it is queued for replay.
fn begin(git: *const Git) !Loaded {
    try coordination.requireQuiescent(git);
    var snapshot = try stack.inspect(git);
    defer snapshot.deinit();
    var stale: ?usize = null;
    for (snapshot.layers, 0..) |layer, i| {
        if (!layer.stale()) continue;
        if (stale != null) return error.MultipleStaleLayers;
        stale = i;
    }
    const active = stale orelse return error.NothingToRestack;
    const origin = try git.currentBranch();
    const nodes = try git.allocator.alloc(Node, snapshot.layers.len + 1);
    for (snapshot.layers, 0..) |layer, i|
        nodes[i] = try Node.init(git.allocator, layer.ref_name, layer.oid);
    nodes[snapshot.layers.len] =
        try Node.init(git.allocator, snapshot.config.work_ref, snapshot.work_oid);
    const config = (try git.configGet(layout.state_key)) orelse
        return error.EditStateChanged;
    var s: Session = .{
        .oplog_parent = try git.readRef(layout.oplog_ref),
        .id = "",
        .owner = try owner(git),
        .origin = origin,
        .config = config,
        .branches = try stack.parseConfig(config),
        .anchor = try git.allocator.dupe(u8, snapshot.config.anchor_oid),
        .nodes = nodes,
        .active = active,
        .phase = .switching,
    };
    s.id = try git.writeBlob(try checkpoint.encode(git.allocator, &s));
    try available(git, &s);

    const edited = snapshot.layers[active].branch_oid;
    const lower = if (active == 0) s.anchor else nodes[active - 1].published_oid;
    if (eql(lower, edited) or !try git.isAncestor(lower, edited))
        return error.InvalidEditedHistory;
    if (!(try git.history(lower, edited)).linear)
        return error.InvalidEditedHistory;

    const commits = (try git.history(
        nodes[active].published_oid,
        s.workNode().published_oid,
    )).commits;
    if (commits.len != 0) try requireNoIgnored(git);
    const plan = try git.writeBlobWithFormat(
        try std.mem.join(git.allocator, "\n", commits),
        s.objectFormat(),
    );
    for (nodes[active..]) |*node| {
        node.pending_oid = if (eql(node.published_oid, nodes[active].published_oid))
            edited
        else
            node.published_oid;
    }
    s.phase = .{ .detaching = .{
        .plan_oid = plan,
        .plan_len = commits.len,
        .before = edited,
    } };

    var checks: std.ArrayList(Git.RefUpdate) = .empty;
    try checks.append(git.allocator, .{ .verify = .{ .name = layout.tip_ref, .oid = s.topCut().published_oid } });
    for (nodes, 0..) |node, i| {
        try checks.append(git.allocator, .{ .verify = .{ .name = node.ref_name, .oid = s.expectedOid(i) } });
        if (i == nodes.len - 1) break;
        try checks.append(git.allocator, .{ .verify = .{
            .name = try layout.recordRef(git.allocator, node.ref_name),
            .oid = node.published_oid,
        } });
    }
    return .{
        .oid = try save(git, &s, null, checks.items, &.{ edited, plan }),
        .session = s,
        .plan = commits,
        .ignored_checked = true,
    };
}

// Each handler advances and checkpoints one phase. Keep the fallthrough order
// explicit: one command can replay, publish, then switch to its destination.
fn advance(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    if (s.phase == .aborting or s.phase == .aborted) return abortSession(git, loaded);
    if (s.phase == .detaching) try detachForReplay(git, loaded);
    if (s.phase == .replay or s.phase == .conflict) try replayDescendants(git, loaded);
    if (s.phase == .publishing) try publishResults(git, loaded);
    if (s.phase == .switching) try switchDestination(git, loaded);
}

fn detachForReplay(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    const progress = s.phase.detaching;
    const queue = loaded.plan orelse return error.InvalidEditSession;
    try coordination.requireQuiescent(git);
    if (queue.len != 0 and !loaded.ignored_checked) {
        try requireNoIgnored(git);
        loaded.ignored_checked = true;
    }
    try detach(git, progress.before);
    // Checkout hooks can create ignored files. Recheck before the first pick.
    loaded.ignored_checked = false;
    s.phase = .{ .replay = progress };
    loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
}

// Checkpoints bracket each cherry-pick. If a process exits after Git commits
// but before the checkpoint, HEAD's single parent identifies the completed step.
fn replayDescendants(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try requireDetached(git);
    var progress = s.replay().?;
    const queue = loaded.plan orelse return error.InvalidEditSession;
    var head = try git.resolveCommit("HEAD");
    var picking = try git.readRef(coordination.cherry_pick_head);
    if (picking == null) {
        try coordination.requireQuiescent(git);
    }
    // Skip boundaries incorporated before this command was interrupted.
    var boundary = s.boundaryAfter(queue[0..progress.next]);
    while (progress.next < queue.len) {
        const commit = queue[progress.next];
        if (picking) |oid| {
            if (!eql(oid, commit) or !eql(head, progress.before)) return error.EditStateChanged;
            try requireResolution(git);
            // One commit per pick: commit clears CHERRY_PICK_HEAD and also
            // preserves a resolution that makes the patch empty.
            try git.exec(&.{
                "-c",
                "core.editor=true",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--allow-empty",
                "--allow-empty-message",
                "--no-edit",
            });
            head = try git.resolveCommit("HEAD");
            picking = null;
        } else if (eql(head, progress.before)) {
            if (!loaded.ignored_checked) try requireNoIgnored(git);
            loaded.ignored_checked = false;
            git.exec(&.{
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "rerere.enabled=false",
                "cherry-pick",
                "--no-gpg-sign",
                "--allow-empty",
                "--allow-empty-message",
                "--keep-redundant-commits",
                commit,
            }) catch |err| {
                if (try git.readRef(coordination.cherry_pick_head)) |_| {
                    s.phase = .{ .conflict = progress };
                    loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
                    return error.ReplayConflict;
                }
                return err;
            };
            head = try git.resolveCommit("HEAD");
        } else {
            // Only the first step after a restart may already be committed.
            const parent = try git.output(&.{ "rev-list", "--parents", "-n", "1", head });
            const expected = try std.fmt.allocPrint(
                git.allocator,
                "{s} {s}",
                .{ head, progress.before },
            );
            if (!eql(parent, expected)) return error.EditStateChanged;
        }
        while (boundary < s.nodes.len and eql(s.nodes[boundary].published_oid, commit)) : (boundary += 1) {
            s.nodes[boundary].pending_oid = head;
        }
        progress.before = head;
        progress.next += 1;
        s.phase = .{ .replay = progress };
        loaded.oid = try save(git, s, loaded.oid, &.{}, &.{head});
    }
    s.phase = .{ .publishing = progress };
    loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
}

fn publishResults(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try requireDetached(git);
    try coordination.requireQuiescent(git);
    if (!eql(try git.resolveCommit("HEAD"), s.phase.publishing.before)) return error.EditStateChanged;
    try checkRefs(git, s);
    try available(git, s);
    const changes = try moveBoundaries(git, s, .pending);
    s.phase = .switching;
    loaded.oid = try save(git, s, loaded.oid, changes, &.{});
}

/// Compare-and-swap every boundary and the tip guard to the replay result
/// or back to the original stack, recording the target as published.
fn moveBoundaries(
    git: *const Git,
    s: *Session,
    comptime target: enum { pending, original },
) ![]const Git.RefUpdate {
    const layers = s.nodes.len - 1;
    const changes = try git.allocator.alloc(Git.RefUpdate, s.nodes.len + 1 + layers);
    // the tip guard tracks the published top cut, never a pending edit
    const old_tip = s.topCut().published_oid;
    for (s.nodes, 0..) |*node, i| {
        const new = switch (target) {
            .pending => node.pending_oid,
            .original => if (s.rollback) |rollback| rollback.target[i] else node.original_oid,
        };
        changes[i] = .{ .update = .{ .name = node.ref_name, .new = new, .old = s.expectedOid(i) } };
        // each layer's recorded boundary moves with its branch
        if (i < layers) changes[s.nodes.len + 1 + i] = .{ .update = .{
            .name = try layout.recordRef(git.allocator, node.ref_name),
            .new = new,
            .old = node.published_oid,
        } };
        node.published_oid = new;
        node.pending_oid = new;
    }
    changes[s.nodes.len] = .{ .update = .{
        .name = layout.tip_ref,
        .new = s.topCut().published_oid,
        .old = old_tip,
    } };
    return changes;
}

/// Archive the terminal checkpoint and remove the active session atomically.
fn finish(git: *const Git, loaded: *Loaded, comptime message: []const u8) !void {
    const s = &loaded.session;
    s.outcome = if (s.operation == .undo) .undone else if (s.phase == .aborted) .aborted else .finished;
    const label = if (s.operation == .undo) "stakrr: undo edit" else message;
    const oid = try checkpoint.create(git, s, loaded.oid, &.{}, label);
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(git.allocator, &.{
        .{ .delete = .{ .name = layout.session_ref, .oid = loaded.oid } },
        oplogUpdate(s.oplog_parent, oid),
        .{ .verify = .{ .name = layout.anchor_ref, .oid = s.anchor } },
        .{ .verify = .{ .name = layout.tip_ref, .oid = s.topCut().published_oid } },
    });
    for (s.nodes, 0..) |node, i| try updates.append(git.allocator, .{ .verify = .{ .name = node.ref_name, .oid = s.expectedOid(i) } });
    for (s.nodes[0 .. s.nodes.len - 1]) |node| try updates.append(git.allocator, .{ .verify = .{
        .name = try layout.recordRef(git.allocator, node.ref_name),
        .oid = node.published_oid,
    } });
    try git.transact(label, updates.items);
}

fn oplogUpdate(old: ?[]const u8, oid: []const u8) Git.RefUpdate {
    return if (old) |previous|
        .{ .update = .{ .name = layout.oplog_ref, .new = oid, .old = previous } }
    else
        .{ .create = .{ .name = layout.oplog_ref, .oid = oid } };
}

fn switchDestination(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try coordination.requireQuiescent(git);
    try checkRefs(git, s);
    try available(git, s);
    try git.switchBranch(s.origin);
    try finish(git, loaded, "stakrr: restack");
}

fn abortSession(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    // Never use reset --hard: even conflict resolutions belong to the user.
    try coordination.requireClean(git);
    const picking = try validatePick(git, loaded);
    if (s.phase != .aborting and s.phase != .aborted) {
        const target = try git.allocator.alloc([]const u8, s.nodes.len);
        for (s.nodes, target) |node, *oid| oid.* = node.original_oid;
        try startRestore(git, loaded, target, loaded.oid);
    }
    if (picking != null) try git.exec(&.{ "cherry-pick", "--quit" });
    if (s.phase == .aborting) {
        try checkRefs(git, s);
        try available(git, s);
        const head = try git.resolveCommit("HEAD");
        try detach(git, head);
        const changes = try moveBoundaries(git, s, .original);
        s.phase = .aborted;
        loaded.oid = try save(git, s, loaded.oid, changes, &.{head});
    }
    try available(git, s);
    try git.switchBranch(s.origin);
    try finish(git, loaded, "stakrr: abort restack");
}

fn validatePick(git: *const Git, loaded: *const Loaded) !?[]const u8 {
    const s = &loaded.session;
    const picking = try git.readRef(coordination.cherry_pick_head);
    if (picking) |oid| {
        if (s.phase != .replay and s.phase != .conflict and s.phase != .aborting)
            return error.GitOperationInProgress;
        const progress = s.replay() orelse return error.InvalidEditSession;
        const queue = loaded.plan orelse return error.InvalidEditSession;
        if (progress.next >= queue.len) return error.InvalidEditSession;
        if (!eql(oid, queue[progress.next]) or
            !eql(try git.resolveCommit("HEAD"), progress.before))
            return error.EditStateChanged;
    }
    try coordination.requireNoGitOperation(git, .{ .allow_cherry_pick = picking != null });
    return picking;
}

/// Checkpoint before moving any branch; a restart resumes the same restoration.
fn startRestore(git: *const Git, loaded: *Loaded, target: []const []const u8, old: ?[]const u8) !void {
    const s = &loaded.session;
    const expected = try git.allocator.alloc([]const u8, s.nodes.len);
    var checks: std.ArrayList(Git.RefUpdate) = .empty;
    for (s.nodes, expected, 0..) |node, *oid, i| {
        oid.* = s.expectedOid(i);
        try checks.append(git.allocator, .{ .verify = .{ .name = node.ref_name, .oid = oid.* } });
        if (i == s.nodes.len - 1) break;
        try checks.append(git.allocator, .{ .verify = .{
            .name = try layout.recordRef(git.allocator, node.ref_name),
            .oid = node.published_oid,
        } });
    }
    try checks.append(git.allocator, .{ .verify = .{ .name = layout.tip_ref, .oid = s.topCut().published_oid } });
    const progress = s.replay();
    s.rollback = .{ .expected = expected, .target = target };
    s.phase = .{ .aborting = progress };
    loaded.oid = try save(git, s, old, checks.items, &.{try git.resolveCommit("HEAD")});
}

/// Reverse the last completed edit, checking every published boundary first.
/// An undo is itself a completed operation with reversed before/after positions.
pub fn undo(original_git: *const Git) !void {
    var context: Context = undefined;
    context.init(original_git);
    defer context.deinit();
    const git = &context.git;
    const guard = try coordination.lockStack(git);
    defer guard.close(git.io);
    try coordination.requireQuiescent(git);
    const oplog = (try git.readRef(layout.oplog_ref)) orelse return error.NoUndo;
    var cursor: ?[]const u8 = oplog;
    while (cursor) |oid| {
        var loaded = checkpoint.loadAt(git, oid) catch |err| switch (err) {
            error.InvalidEditSession => {
                cursor = try checkpoint.previous(git, oid);
                continue;
            },
            else => return err,
        };
        const s = &loaded.session;
        if (s.outcome != .finished and s.outcome != .undone) {
            cursor = try checkpoint.previous(git, oid);
            continue;
        }
        // Global undo is allowed from another worktree once no session owns it.
        s.owner = try owner(git);
        s.origin = try git.currentBranch();
        s.phase = .aborted; // require every branch to match, including the active cut
        try checkRefs(git, s);
        try available(git, s);
        const target = try git.allocator.alloc([]const u8, s.nodes.len);
        for (s.nodes, target) |*node, *to| {
            to.* = node.original_oid;
            node.original_oid = node.published_oid;
            node.pending_oid = node.published_oid;
        }
        s.rollback = null;
        s.oplog_parent = oplog;
        s.outcome = .active;
        s.operation = .undo;
        s.id = try git.writeBlob(try checkpoint.encode(git.allocator, s));
        try startRestore(git, &loaded, target, null);
        try abortSession(git, &loaded);
        return;
    }
    return error.NoUndo;
}

/// Drop the journal like `git rebase --quit`: HEAD, the index, files and every
/// branch stay exactly as they are. Skips ref and plan validation so drifted or
/// corrupt sessions can always be left; HEAD and the checkpoint stay retained.
fn quitSession(git: *const Git) !void {
    const oid = (try git.readRef(layout.session_ref)) orelse return error.NoEditSession;
    const loaded = checkpoint.load(git) catch |err| switch (err) {
        error.InvalidEditSession => null,
        else => return err,
    };
    try coordination.requireNoGitOperation(git, .{});
    const head = try git.resolveCommit("HEAD");
    const oplog = try git.readRef(layout.oplog_ref);
    const archived = if (loaded) |l| valid: {
        try checkOwner(git, &l.session);
        var session = l.session;
        session.outcome = .quit;
        break :valid try checkpoint.create(git, &session, oid, &.{head}, "stakrr: quit edit");
    } else corrupt: {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        var entries: std.ArrayList(Git.TreeEntry) = .empty;
        var parents: std.ArrayList([]const u8) = .empty;
        if (oplog) |previous| try parents.append(git.allocator, previous);
        if (eql(kind, "commit")) {
            try parents.append(git.allocator, oid);
        } else {
            try entries.append(git.allocator, .{ .name = "checkpoint", .oid = oid, .tree = eql(kind, "tree") });
        }
        try parents.append(git.allocator, head);
        try entries.append(git.allocator, .{ .name = "rescue", .oid = try git.writeBlob(head) });
        try entries.append(git.allocator, .{ .name = "previous", .oid = try git.writeBlob(oplog orelse "") });
        break :corrupt try git.commitTree(try git.writeTree(entries.items), parents.items, "stakrr: quit corrupt edit");
    };
    try git.transact("stakrr: quit edit", &.{
        oplogUpdate(oplog, archived),
        .{ .delete = .{ .name = layout.session_ref, .oid = oid } },
    });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn checkpointLabel(git: *const Git, s: *const Session) ![]const u8 {
    return switch (s.phase) {
        .switching => try std.fmt.allocPrint(git.allocator, "move to {s}", .{layout.shortBranch(s.origin)}),
        .detaching, .replay, .conflict, .publishing => |p| try std.fmt.allocPrint(git.allocator, "{s} {d}/{d}", .{ @tagName(s.phase), p.next, p.plan_len }),
        .aborting => if (s.operation == .undo) "undo completed edit" else "abort edit",
        .aborted => if (s.operation == .undo) "completed edit undone" else "stack restored",
    };
}

/// Journal and branch publication share one compare-and-swap transaction.
fn save(
    git: *const Git,
    s: *const Session,
    old: ?[]const u8,
    changes: []const Git.RefUpdate,
    retain: []const []const u8,
) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(git.allocator);
    defer scratch.deinit();
    const scratch_git = git.withAllocator(scratch.allocator());
    const oid = try checkpoint.create(&scratch_git, s, old, retain, try checkpointLabel(&scratch_git, s));
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(scratch_git.allocator, changes);
    try updates.append(scratch_git.allocator, .{ .verify = .{ .name = layout.anchor_ref, .oid = s.anchor } });
    try updates.append(scratch_git.allocator, if (old) |previous|
        .{ .update = .{ .name = layout.session_ref, .new = oid, .old = previous } }
    else
        .{ .create = .{ .name = layout.session_ref, .oid = oid } });
    try scratch_git.transact("stakrr: edit checkpoint", updates.items);
    return git.allocator.dupe(u8, oid);
}

fn owner(git: *const Git) ![]const u8 {
    return git.path(&.{ "rev-parse", "--absolute-git-dir" });
}

fn checkOwner(git: *const Git, s: *const Session) !void {
    if (!eql(try owner(git), s.owner)) return error.WrongEditWorktree;
}

fn available(git: *const Git, s: *const Session) !void {
    const refs = try git.allocator.alloc([]const u8, s.nodes.len + 1);
    for (s.nodes, 0..) |node, i| refs[i] = node.ref_name;
    refs[s.nodes.len] = s.origin;
    try coordination.requireAvailable(git, refs);
}

fn checkRefs(git: *const Git, s: *const Session) !void {
    if (try refDrift(git, s) != null) return error.EditStateChanged;
}

const Mismatch = struct {
    name: []const u8,
    expected: ?[]const u8,
    actual: ?[]const u8,

    fn of(name: []const u8, expected: ?[]const u8, actual: ?[]const u8) ?Mismatch {
        if (expected != null and actual != null and eql(expected.?, actual.?)) return null;
        return .{ .name = name, .expected = expected, .actual = actual };
    }
};

/// First persisted value that no longer matches the journal.
fn refDrift(git: *const Git, s: *const Session) !?Mismatch {
    const config = try git.configGet(layout.state_key);
    if (Mismatch.of(layout.state_key, s.config, config)) |m| return m;
    if (Mismatch.of(layout.anchor_ref, s.anchor, try git.readRef(layout.anchor_ref))) |m| return m;
    const tip = try git.readRef(layout.tip_ref);
    if (Mismatch.of(layout.tip_ref, s.topCut().published_oid, tip)) |m| return m;

    for (s.nodes[0 .. s.nodes.len - 1]) |node| {
        const record = try layout.recordRef(git.allocator, node.ref_name);
        if (Mismatch.of(record, node.published_oid, try git.readRef(record))) |m| return m;
    }

    var indexes: std.StringHashMapUnmanaged(usize) = .empty;
    for (s.nodes, 0..) |node, i| try indexes.put(git.allocator, node.ref_name, i);
    const seen = try git.allocator.alloc(bool, s.nodes.len);
    @memset(seen, false);
    const layers = (try git.listRefs(layout.layer_prefix)).refs;
    for (layers) |ref| {
        const index = indexes.get(ref.name) orelse
            return .{ .name = ref.name, .expected = null, .actual = ref.oid };
        if (index == s.nodes.len - 1) return error.InvalidEditSession;
        seen[index] = true;
        if (nodeDrift(s, index, ref.oid)) |m| return m;
    }
    for (s.nodes[0 .. s.nodes.len - 1], seen[0 .. s.nodes.len - 1], 0..) |node, found, i| {
        if (!found) return .{ .name = node.ref_name, .expected = s.expectedOid(i), .actual = null };
    }

    const work = (try git.readRef(s.workNode().ref_name)) orelse
        return .{ .name = s.workNode().ref_name, .expected = s.workNode().published_oid, .actual = null };
    return nodeDrift(s, s.nodes.len - 1, work);
}

fn nodeDrift(s: *const Session, index: usize, actual: []const u8) ?Mismatch {
    return Mismatch.of(s.nodes[index].ref_name, s.expectedOid(index), actual);
}

/// Where each phase leaves HEAD, mirroring the checks its handler makes.
fn headDrift(git: *const Git, s: *const Session) !?Mismatch {
    const current = try git.head();
    const head = try git.resolveCommit("HEAD");
    const actual = current orelse head;
    switch (s.phase) {
        .replay, .conflict, .publishing => |progress| {
            if (current == null and s.phase == .replay and !eql(head, progress.before)) {
                // a pick committed before its checkpoint is still in sequence
                const parent = try git.output(&.{ "rev-list", "--parents", "-n", "1", head });
                const expected = try std.fmt.allocPrint(git.allocator, "{s} {s}", .{ head, progress.before });
                if (eql(parent, expected)) return null;
            }
            if (current != null) return .{ .name = "HEAD", .expected = progress.before, .actual = actual };
            return Mismatch.of("HEAD", progress.before, head);
        },
        // HEAD only reaches the first replay commit once it detaches
        .detaching, .switching, .aborting, .aborted => return null,
    }
}

fn requireDetached(git: *const Git) !void {
    if (try git.head() != null) return error.EditStateChanged;
}

fn detach(git: *const Git, oid: []const u8) !void {
    try git.exec(&.{ "switch", "--quiet", "--no-overwrite-ignore", "--detach", oid });
}

// Merge rename handling can write paths absent from the incoming commit's
// diff. Refuse all ignored files rather than predict those destinations.
fn requireNoIgnored(git: *const Git) !void {
    const ignored = try git.outputRaw(
        &.{
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "--full-name",
            "-z",
            "--",
            ":/",
        },
    );
    defer git.allocator.free(ignored);
    if (ignored.len != 0) return error.IgnoredFilesPresent;
}

/// Only staged resolutions are accepted. Unstaged/untracked files must be
/// preserved explicitly before continuing, just as for an ordinary transition.
fn requireResolution(git: *const Git) !void {
    const unresolved = try git.output(&.{ "diff", "--name-only", "--diff-filter=U" });
    if (unresolved.len != 0) return error.ReplayConflict;
    if (!try git.check(&.{ "diff", "--quiet" }, 1)) return error.DirtyWorkTree;
    const untracked = try git.output(
        &.{ "ls-files", "--others", "--exclude-standard", "--full-name", "--", ":/" },
    );
    if (untracked.len != 0) return error.DirtyWorkTree;
}
