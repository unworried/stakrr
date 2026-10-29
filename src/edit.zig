//! Managed edits. A commit ref journals each step; ref publication and journal
//! advancement share a compare-and-swap transaction. Replay runs detached so
//! branch boundaries remain untouched until the complete replay is available.
const Mutation = @import("mutation.zig").Mutation;
const BranchRef = @import("git.zig").BranchRef;
const RefName = @import("git.zig").RefName;
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
    WorkspaceChanged,
    WorkspaceCleanupPending,
};
pub const Request = enum { restack, continue_edit, abort, quit };
const checkpoint = @import("edit_session.zig");
const Node = checkpoint.Node;
const Session = checkpoint.Session;
const Loaded = checkpoint.Loaded;
const replay_mod = @import("replay.zig");
const operations = @import("operation.zig");
const store = @import("state_store.zig");

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
    workspace: []const u8,
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
    _ = try runWithRecovery(original_git, request);
}

/// True when recovery already completed the requested pending operation.
pub fn runWithRecovery(original_git: *const Git, request: Request) !bool {
    var context: Context = undefined;
    context.init(original_git);
    defer context.deinit();
    var mutation = try @import("mutation.zig").begin(&context.git, .edit);
    defer mutation.deinit();
    const git = mutation.repo();
    if (mutation.recovered and request != .restack and
        try git.readDirectRefAlloc(try RefName.init(layout.session_ref)) == null) return true;
    try runLocked(&mutation, request);
    return false;
}

fn runLocked(mutation: *Mutation, request: Request) !void {
    const git = mutation.repo();
    if (request == .quit) return quitSession(mutation);
    var loaded = (try checkpoint.load(git)) orelse {
        if (request != .restack) return error.NoEditSession;
        var fresh = try begin(mutation);
        return advance(mutation, &fresh);
    };
    const s = &loaded.session;
    try checkOwner(git, s);
    var origin_repo = try openOrigin(git, s);
    defer origin_repo.close();
    mutation.git = origin_repo.git;
    try checkRefs(mutation.repo(), s);
    switch (request) {
        // a pending session must be finished or abandoned first
        .restack => return error.EditInProgress,
        .abort => return abortSession(mutation, &loaded),
        .continue_edit => return advance(mutation, &loaded),
        .quit => unreachable,
    }
}

pub fn readStatus(original_git: *const Git) !?Status {
    var context: Context = undefined;
    context.init(original_git);
    errdefer context.deinit();
    const git = &context.git;
    try git.ensureWorkTree();
    context.git.object_format = try git.objectFormat();
    try git.requireNoPendingTransaction();
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
        .base = s.state.base_branch.name.bytes,
        .owner = s.owner,
        .workspace = s.workspace,
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

    pub const Move = operations.Move;
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
    context.git.object_format = try git.objectFormat();
    try git.requireNoPendingTransaction();
    var cursor: ?[]const u8 = (try git.readDirectRefAlloc(try RefName.init(layout.session_ref))) orelse try git.readDirectRefAlloc(try RefName.init(layout.oplog_ref));
    var steps: std.ArrayList(Log.Step) = .empty;
    var carried: ??Loaded = null;
    while (cursor) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (!eql(kind, "commit")) break; // not a checkpoint
        if (try operations.read(git, oid)) |record| {
            const metadata = try git.output(&.{ "show", "--no-patch", "--format=%cI%x09%s", oid });
            const separator = std.mem.indexOfScalar(u8, metadata, '\t') orelse return error.InvalidEditSession;
            try steps.append(git.allocator, .{ .oid = oid, .time = metadata[0..separator], .label = metadata[separator + 1 ..], .moves = record.moves, .rescue = if (record.rescue.len != 0) record.rescue[0] else record.before_manifest orelse "" });
            // Checkpoints remain inspectable through the completed record's explicit link.
            cursor = try checkpoint.previous(git, oid);
            carried = null;
            continue;
        }
        if (try decodeCheckpoint(git, oid) == null) break;
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
    context.git.object_format = try git.objectFormat();
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

/// Persist workspace intent and immutable observations before creating anything.
fn begin(mutation: *const Mutation) !Loaded {
    const git = mutation.repo();
    const a = git.allocator;
    try coordination.requireQuiescent(git);
    var snapshot = try stack.inspect(git);
    defer snapshot.deinit();
    var stale: ?usize = null;
    for (snapshot.layers, 0..) |layer, i| if (layer.stale()) {
        if (stale != null) return error.MultipleStaleLayers;
        stale = i;
    };
    const active = stale orelse return error.NothingToRestack;
    const origin = try git.currentBranchAlloc();
    const origin_oid = try git.resolveCommitAlloc("HEAD");
    const state = (try store.loadAt(git, snapshot.manifest_oid)).value;
    const plan = try replay_mod.plan(git, state, try a.dupe(u8, snapshot.work_oid), active);
    const edited = try a.dupe(u8, snapshot.layers[active].branch_oid);
    const lower = if (active == 0) state.anchor_oid.hex() else plan.boundaries[active - 1];
    if (eql(lower, edited) or !try git.isAncestor(lower, edited) or !(try git.history(lower, edited)).linear) return error.InvalidEditedHistory;
    const nodes = try a.alloc(Node, plan.boundaries.len);
    for (nodes, plan.boundaries, 0..) |*node, oid, i| node.* = .{
        .ref_name = if (i < state.layers.len) state.layers[i].branch.name.bytes else state.work_branch.name.bytes,
        .original_oid = oid,
        .published_oid = oid,
        .pending_oid = oid,
    };
    nodes[active].pending_oid = edited;
    const moved = try a.dupe([]const u8, plan.boundaries);
    moved[active] = edited;
    plan.map(moved, plan.boundaries[active], edited);
    for (nodes, moved) |*node, oid| node.pending_oid = oid;
    const old = try git.readDirectRefAlloc(try RefName.init(layout.oplog_ref));
    const id = try git.writeBlob(try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}", .{ snapshot.manifest_oid, edited, origin_oid, old orelse "" }));
    const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    var s: Session = .{
        .id = id,
        .oplog_parent = old,
        .owner = try owner(git),
        .origin = origin,
        .origin_oid = origin_oid,
        .origin_path = try git.path(&.{ "rev-parse", "--show-toplevel" }),
        .workspace = try std.fs.path.join(a, &.{ common, "stakrr-workspaces", id }),
        .before_manifest = try a.dupe(u8, snapshot.manifest_oid),
        .manifest = try a.dupe(u8, snapshot.manifest_oid),
        .edited_oid = edited,
        .state = state,
        .nodes = nodes,
        .active = active,
        .phase = .{ .detaching = .{ .plan_oid = try git.writeBlob(try std.mem.join(a, "\n", plan.commits)), .plan_len = plan.commits.len, .before = edited } },
    };
    try available(git, &s);
    const checks = try expectedChecks(git, &s);
    return .{ .oid = try save(mutation, &s, null, checks, &.{}), .session = s, .plan = plan.commits };
}
fn advance(mutation: *const Mutation, loaded: *Loaded) !void {
    const s = &loaded.session;
    if (s.phase == .aborting or s.phase == .aborted) return abortSession(mutation, loaded);
    if (s.phase == .detaching) try createWorkspace(mutation, loaded);
    if (s.phase == .replay or s.phase == .conflict) try replayDescendants(mutation, loaded);
    if (s.phase == .publishing) try publishResults(mutation, loaded);
    if (s.phase == .switching) try switchDestination(mutation, loaded);
}

const OpenRepo = struct {
    git: Git,
    fn open(git: *const Git, path: []const u8) !OpenRepo {
        var copy = git.*;
        copy.cwd = try std.Io.Dir.cwd().openDir(git.io, path, .{});
        return .{ .git = copy };
    }
    fn close(self: *OpenRepo) void {
        self.git.cwd.?.close(self.git.io);
    }
};
fn workspaceReason(git: *const Git, s: *const Session) ![]const u8 {
    return std.fmt.allocPrint(git.allocator, "stakrr {s}", .{s.id});
}
/// Verify both private Git directory and the unique lock marker before touching files.
fn openWorkspace(git: *const Git, s: *const Session) !OpenRepo {
    var repo = OpenRepo.open(git, s.workspace) catch return error.WorkspaceChanged;
    errdefer repo.close();
    repo.git.isolated_workspace = true;
    const w = &repo.git;
    const private = try owner(w);
    if (s.workspace_owner) |expected| if (!eql(expected, private)) return error.WorkspaceChanged;
    const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    const actual_common = try w.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    const expected_parent = try std.fs.path.join(git.allocator, &.{ common, "worktrees" });
    if (!eql(common, actual_common) or !eql(std.fs.path.dirname(private) orelse "", expected_parent) or !eql(try w.path(&.{ "rev-parse", "--show-toplevel" }), s.workspace)) return error.WorkspaceChanged;
    const locked_path = try std.fs.path.join(git.allocator, &.{ private, "locked" });
    const marker = std.Io.Dir.cwd().readFileAlloc(git.io, locked_path, git.allocator, .limited(1024)) catch |err| blk: {
        if (err != error.FileNotFound or !s.cleanup_intent or s.workspace_owner == null) return error.WorkspaceChanged;
        try git.exec(&.{ "worktree", "lock", "--reason", try workspaceReason(git, s), s.workspace });
        break :blk try git.allocator.dupe(u8, try workspaceReason(git, s));
    };
    if (!eql(std.mem.trimEnd(u8, marker, "\r\n"), try workspaceReason(git, s))) return error.WorkspaceChanged;
    if (try w.head() != null) return error.WorkspaceChanged;
    return repo;
}
fn openOrigin(git: *const Git, s: *const Session) !OpenRepo {
    var repo = OpenRepo.open(git, s.origin_path) catch return error.WrongEditWorktree;
    errdefer repo.close();
    if (!eql(try owner(&repo.git), s.owner)) return error.WrongEditWorktree;
    const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    const origin_common = try repo.git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    if (!eql(common, origin_common) or !eql(try repo.git.path(&.{ "rev-parse", "--show-toplevel" }), s.origin_path)) return error.WrongEditWorktree;
    return repo;
}
fn createWorkspace(mutation: *const Mutation, loaded: *Loaded) !void {
    const git = mutation.repo();
    const s = &loaded.session;
    const exists = blk: {
        std.Io.Dir.cwd().access(git.io, s.workspace, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (!exists) {
        try git.exec(&.{ "-c", "core.hooksPath=/dev/null", "-c", "core.sparseCheckout=false", "-c", "core.sparseCheckoutCone=false", "-c", "submodule.recurse=false", "worktree", "add", "--quiet", "--detach", "--lock", "--reason", try workspaceReason(git, s), s.workspace, s.edited_oid });
    }
    var workspace = try openWorkspace(git, s);
    defer workspace.close();
    try coordination.requireQuiescent(&workspace.git);
    try requireNoIgnored(&workspace.git);
    if (!eql(try workspace.git.resolveCommitAlloc("HEAD"), s.edited_oid)) return error.WorkspaceChanged;
    s.workspace_owner = try owner(&workspace.git);
    const progress = s.phase.detaching;
    s.phase = .{ .replay = progress };
    loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{});
}
fn replayDescendants(mutation: *const Mutation, loaded: *Loaded) !void {
    const s = &loaded.session;
    var workspace = try openWorkspace(mutation.repo(), s);
    defer workspace.close();
    const git = &workspace.git;
    var workspace_mutation = mutation.*;
    workspace_mutation.git = git.*;
    var progress = s.replay().?;
    const queue = loaded.plan orelse return error.InvalidEditSession;
    const plan = try s.plan(queue, git.allocator);
    const moved = try git.allocator.alloc([]const u8, s.nodes.len);
    for (s.nodes, moved) |node, *oid| oid.* = node.pending_oid;
    var head = try git.resolveCommitAlloc("HEAD");
    var picking = try git.cherryPickHeadAlloc();
    try coordination.requireNoGitOperation(git, .{ .allow_cherry_pick = picking != null });
    if (picking == null) try coordination.requireQuiescent(git);
    while (progress.next < queue.len) {
        const commit = queue[progress.next];
        if (picking) |oid| {
            if (!eql(oid, commit) or !eql(head, progress.before)) return error.EditStateChanged;
            try requireResolution(git);
            try workspace_mutation.commitResolution();
            head = try git.resolveCommitAlloc("HEAD");
            picking = null;
        } else if (eql(head, progress.before)) {
            try requireNoIgnored(git);
            workspace_mutation.cherryPick(try git.parseOid(commit)) catch |err| {
                if (try git.cherryPickHeadAlloc() != null) {
                    s.phase = .{ .conflict = progress };
                    loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{});
                    return error.ReplayConflict;
                }
                return err;
            };
            head = try git.resolveCommitAlloc("HEAD");
        } else {
            const parent = try git.output(&.{ "rev-list", "--parents", "-n", "1", head });
            if (!eql(parent, try std.fmt.allocPrint(git.allocator, "{s} {s}", .{ head, progress.before }))) return error.EditStateChanged;
        }
        plan.map(moved, commit, head);
        for (s.nodes, moved) |*node, oid| node.pending_oid = oid;
        progress.before = head;
        progress.next += 1;
        s.phase = .{ .replay = progress };
        loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{head});
    }
    s.phase = .{ .publishing = progress };
    loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{});
}
/// Validate the original checkout, checkpoint detach intent, then detach briefly.
fn prepareCheckout(mutation: *const Mutation, loaded: *Loaded) !void {
    const s = &loaded.session;
    var origin = try openOrigin(mutation.repo(), s);
    defer origin.close();
    const git = &origin.git;
    try coordination.requireQuiescent(git);
    const branch = try git.head();
    const head = try git.resolveCommitAlloc("HEAD");
    const expected = try destinationOid(git, s);
    if (branch) |ref| {
        if (!eql(ref, s.origin) or !eql(head, expected)) return error.EditStateChanged;
    } else if (!s.final_detach or !eql(head, s.detached_oid orelse return error.InvalidEditSession)) return error.EditStateChanged;
    try available(mutation.repo(), s);
    if (!s.final_detach or (branch != null and !eql(s.detached_oid.?, head))) {
        s.final_detach = true;
        s.detached_oid = head;
        loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{});
    }
    if (branch != null) {
        try git.exec(&.{ "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "switch", "--quiet", "--no-overwrite-ignore", "--detach", head });
    }
}
fn destinationOid(git: *const Git, s: *const Session) ![]const u8 {
    for (s.nodes, 0..) |node, i| if (eql(node.ref_name, s.origin)) return s.expectedOid(i);
    // Destinations outside the rewritten stack must remain exactly where observed.
    _ = git;
    return s.origin_oid;
}
fn publishResults(mutation: *const Mutation, loaded: *Loaded) !void {
    const git = mutation.repo();
    const s = &loaded.session;
    var workspace = try openWorkspace(git, s);
    defer workspace.close();
    try coordination.requireQuiescent(&workspace.git);
    if (!eql(try workspace.git.resolveCommitAlloc("HEAD"), s.phase.publishing.before)) return error.EditStateChanged;
    try checkRefs(git, s);
    try prepareCheckout(mutation, loaded);
    const expected = try git.allocator.alloc([]const u8, s.nodes.len);
    const moved = try git.allocator.alloc([]const u8, s.nodes.len);
    for (s.nodes, expected, moved, 0..) |node, *from, *to, i| {
        from.* = s.expectedOid(i);
        to.* = node.pending_oid;
    }
    const publication = try replay_mod.publication(git, s.state, s.manifest, expected, moved);
    s.manifest = publication.manifest;
    for (s.nodes) |*node| node.published_oid = node.pending_oid;
    s.phase = .switching;
    loaded.oid = try save(mutation, s, loaded.oid, publication.updates, &.{});
}
fn switchDestination(mutation: *const Mutation, loaded: *Loaded) !void {
    const git = mutation.repo();
    const s = &loaded.session;
    var origin = try openOrigin(git, s);
    defer origin.close();
    try coordination.requireQuiescent(&origin.git);
    try checkRefs(git, s);
    try available(git, s);
    const branch = try origin.git.head();
    if (branch) |ref| {
        if (!eql(ref, s.origin) or !eql(try origin.git.resolveCommitAlloc("HEAD"), try destinationOid(git, s))) return error.EditStateChanged;
    } else {
        // After publication detached HEAD must still be the pre-publication destination.
        if (!eql(try origin.git.resolveCommitAlloc("HEAD"), s.detached_oid orelse return error.InvalidEditSession)) return error.EditStateChanged;
        try origin.git.exec(&.{ "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "switch", "--quiet", "--no-guess", "--no-overwrite-ignore", "--", (try BranchRef.init(s.origin)).short() });
    }
    if (!s.cleanup_intent) {
        s.cleanup_intent = true;
        loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{});
    }
    try cleanupWorkspace(git, s);
    try finish(mutation, loaded, if (s.phase == .aborted) .abort else .restack);
}
/// Remove only an owned, clean workspace, with no ignored files or Git operation.
fn cleanupWorkspace(git: *const Git, s: *const Session) !void {
    if (try workspaceRemoved(git, s)) return;
    var workspace = try openWorkspace(git, s);
    defer workspace.close();
    coordination.requireQuiescent(&workspace.git) catch return error.WorkspaceCleanupPending;
    requireNoIgnored(&workspace.git) catch return error.WorkspaceCleanupPending;
    try git.exec(&.{ "worktree", "unlock", s.workspace });
    git.exec(&.{ "-c", "core.hooksPath=/dev/null", "worktree", "remove", s.workspace }) catch {
        git.exec(&.{ "worktree", "lock", "--reason", try workspaceReason(git, s), s.workspace }) catch {};
        return error.WorkspaceCleanupPending;
    };
}
/// Missing workspace and private registration together prove a journaled removal.
fn workspaceRemoved(git: *const Git, s: *const Session) !bool {
    std.Io.Dir.cwd().access(git.io, s.workspace, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (!s.cleanup_intent) return error.WorkspaceChanged;
            const path = s.workspace_owner orelse return error.WorkspaceChanged;
            std.Io.Dir.cwd().access(git.io, path, .{}) catch |missing| switch (missing) {
                error.FileNotFound => return true,
                else => return missing,
            };
            return error.WorkspaceChanged;
        },
        else => return err,
    };
    return false;
}
fn abortSession(mutation: *const Mutation, loaded: *Loaded) !void {
    const git = mutation.repo();
    const s = &loaded.session;
    if (s.phase == .aborted) return switchDestination(mutation, loaded);
    if (s.phase == .detaching) try createWorkspace(mutation, loaded);
    var workspace: ?OpenRepo = if (try workspaceRemoved(git, s)) null else try openWorkspace(git, s);
    defer if (workspace) |*repo| repo.close();
    var picking: ?[]const u8 = null;
    const rescue = if (workspace) |*repo| try repo.git.resolveCommitAlloc("HEAD") else s.workNode().pending_oid;
    if (workspace) |*repo| {
        const w = &repo.git;
        // Resolutions and unexpected files belong to the user; commit them first.
        try coordination.requireClean(w);
        picking = try w.cherryPickHeadAlloc();
        if (picking) |oid| {
            const p = s.replay() orelse return error.GitOperationInProgress;
            const queue = loaded.plan orelse return error.InvalidEditSession;
            if (p.next >= queue.len or !eql(oid, queue[p.next]) or !eql(rescue, p.before)) return error.EditStateChanged;
        }
        try coordination.requireNoGitOperation(w, .{ .allow_cherry_pick = picking != null });
    }
    if (s.phase != .aborting) {
        const expected = try git.allocator.alloc([]const u8, s.nodes.len);
        for (expected, 0..) |*oid, i| oid.* = s.expectedOid(i);
        const progress = s.replay();
        s.abort_expected = expected;
        s.phase = .{ .aborting = progress };
        loaded.oid = try save(mutation, s, loaded.oid, &.{}, &.{rescue});
    }
    if (picking != null) try workspace.?.git.exec(&.{ "cherry-pick", "--quit" });
    try checkRefs(git, s);
    try prepareCheckout(mutation, loaded);
    const original = try git.allocator.alloc([]const u8, s.nodes.len);
    for (s.nodes, original) |node, *oid| oid.* = node.original_oid;
    const publication = try replay_mod.publication(git, s.state, s.manifest, s.abort_expected.?, original);
    s.manifest = publication.manifest;
    for (s.nodes) |*node| {
        node.published_oid = node.original_oid;
        node.pending_oid = node.original_oid;
    }
    s.phase = .aborted;
    loaded.oid = try save(mutation, s, loaded.oid, publication.updates, &.{rescue});
    try switchDestination(mutation, loaded);
}
fn finish(mutation: *const Mutation, loaded: *Loaded, kind: @FieldType(operations.Record, "kind")) !void {
    const git = mutation.repo();
    const a = git.allocator;
    const s = &loaded.session;
    var moves: std.ArrayList(operations.Move) = .empty;
    for (s.nodes, 0..) |node, i| {
        const from = if (i == s.active) s.edited_oid else node.original_oid;
        if (!eql(from, node.published_oid)) try moves.append(a, .{ .name = node.ref_name, .before = from, .after = node.published_oid });
    }
    const record = try operations.create(git, .{ .kind = kind, .before_manifest = s.before_manifest, .after_manifest = s.manifest, .moves = moves.items, .rescue = &.{ s.edited_oid, s.workNode().original_oid }, .previous = loaded.oid }, loaded.oid);
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(a, try expectedChecks(git, s));
    try updates.appendSlice(a, &.{ try git.deleteRef(layout.session_ref, loaded.oid), try operations.update(git, s.oplog_parent, record) });
    try mutation.publish(.{ .message = operations.label(.{ .kind = kind, .before_manifest = null, .after_manifest = null, .moves = &.{}, .rescue = &.{}, .previous = null }), .updates = updates.items });
}
fn quitSession(mutation: *const Mutation) !void {
    const git = mutation.repo();
    const a = git.allocator;
    const oid = (try git.readDirectRefAlloc(try RefName.init(layout.session_ref))) orelse return error.NoEditSession;
    const loaded = checkpoint.loadMetadata(git, oid) catch |err| switch (err) {
        error.InvalidEditSession => null,
        else => return err,
    };
    try coordination.requireNoGitOperation(git, .{});
    var rescue: std.ArrayList([]const u8) = .empty;
    try rescue.append(a, try git.resolveCommitAlloc("HEAD"));
    var before: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    if (loaded) |l| {
        const s = &l.session;
        try checkOwner(git, s);
        before = s.before_manifest;
        after = s.manifest;
        const exists = blk: {
            std.Io.Dir.cwd().access(git.io, s.workspace, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        if (exists) {
            var workspace = try openWorkspace(git, s);
            defer workspace.close();
            try coordination.requireNoGitOperation(&workspace.git, .{});
            try rescue.append(a, try workspace.git.resolveCommitAlloc("HEAD"));
        }
    }
    const old = try git.readDirectRefAlloc(try RefName.init(layout.oplog_ref));
    const record = try operations.create(git, .{ .kind = .quit, .before_manifest = before, .after_manifest = after, .moves = &.{}, .rescue = rescue.items, .previous = if (loaded != null) oid else old }, oid);
    try mutation.publish(.{ .message = "stakrr: quit edit", .updates = &.{ try operations.update(git, old, record), try git.deleteRef(layout.session_ref, oid) } });
}
fn save(mutation: *const Mutation, s: *const Session, old: ?[]const u8, changes: []const Git.RefUpdate, retain: []const []const u8) ![]const u8 {
    const git = mutation.repo();
    const a = git.allocator;
    const label = try std.fmt.allocPrint(a, "stakrr: checkpoint {s}", .{@tagName(s.phase)});
    const oid = try checkpoint.create(git, s, old, retain, label);
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(a, changes);
    var has_origin = false;
    for (s.nodes) |node| if (eql(node.ref_name, s.origin)) {
        has_origin = true;
    };
    if (!has_origin) try updates.append(a, try git.verifyRef(s.origin, s.origin_oid));
    var has_state = false;
    for (changes) |change| if (eql(change.name().bytes, layout.state_ref)) {
        has_state = true;
    };
    if (!has_state) try updates.append(a, try git.verifyRef(layout.state_ref, s.manifest));
    try updates.append(a, if (old) |previous| try git.updateRef(layout.session_ref, previous, oid) else try git.createRef(layout.session_ref, oid));
    try mutation.publish(.{ .message = label, .updates = updates.items });
    return oid;
}
fn owner(git: *const Git) ![]const u8 {
    return git.path(&.{ "rev-parse", "--absolute-git-dir" });
}
fn checkOwner(git: *const Git, s: *const Session) !void {
    const actual = try owner(git);
    if (eql(actual, s.owner)) return;
    if (s.workspace_owner) |expected| if (eql(actual, expected)) {
        var workspace = try openWorkspace(git, s);
        workspace.close();
        return;
    };
    return error.WrongEditWorktree;
}
fn available(git: *const Git, s: *const Session) !void {
    var origin = try openOrigin(git, s);
    defer origin.close();
    const refs = try git.allocator.alloc([]const u8, s.nodes.len + 1);
    for (s.nodes, refs[0..s.nodes.len]) |node, *ref| ref.* = node.ref_name;
    refs[s.nodes.len] = s.origin;
    try coordination.requireAvailable(&origin.git, refs);
}
fn expectedChecks(git: *const Git, s: *const Session) ![]const Git.RefUpdate {
    const checks = try git.allocator.alloc(Git.RefUpdate, s.nodes.len + 1);
    for (s.nodes, checks[0..s.nodes.len], 0..) |node, *check, i| check.* = try git.verifyRef(node.ref_name, s.expectedOid(i));
    checks[s.nodes.len] = try git.verifyRef(layout.state_ref, s.manifest);
    return checks;
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
fn refDrift(git: *const Git, s: *const Session) !?Mismatch {
    if (Mismatch.of(layout.state_ref, s.manifest, try git.readDirectRefAlloc(try RefName.init(layout.state_ref)))) |m| return m;
    var known_origin = false;
    for (s.nodes) |node| if (eql(node.ref_name, s.origin)) {
        known_origin = true;
    };
    if (!known_origin) if (Mismatch.of(s.origin, s.origin_oid, try git.readDirectRefAlloc(try RefName.init(s.origin)))) |m| return m;
    for (s.nodes, 0..) |node, i| if (Mismatch.of(node.ref_name, s.expectedOid(i), try git.readDirectRefAlloc(try RefName.init(node.ref_name)))) |m| return m;
    const listed = try git.listDirectRefs(layout.layer_prefix);
    for (listed.refs) |ref| {
        var known = false;
        for (s.nodes) |node| if (eql(node.ref_name, ref.name.bytes)) {
            known = true;
            break;
        };
        if (!known) return .{ .name = ref.name.bytes, .expected = null, .actual = try ref.oid.dupeHex(git.allocator) };
    }
    return null;
}
fn headDrift(git: *const Git, s: *const Session) !?Mismatch {
    var origin = try openOrigin(git, s);
    defer origin.close();
    const branch = try origin.git.head();
    if (branch) |ref| return Mismatch.of("HEAD", s.origin, ref);
    if (s.final_detach) return null;
    return .{ .name = "HEAD", .expected = s.origin, .actual = try origin.git.resolveCommitAlloc("HEAD") };
}
fn requireNoIgnored(git: *const Git) !void {
    const ignored = try git.outputRaw(&.{ "ls-files", "--others", "--ignored", "--exclude-standard", "--full-name", "-z", "--", ":/" });
    if (ignored.len != 0) return error.IgnoredFilesPresent;
}
fn requireResolution(git: *const Git) !void {
    const unresolved = try git.output(&.{ "diff", "--no-relative", "--name-only", "--diff-filter=U" });
    if (unresolved.len != 0) return error.ReplayConflict;
    if (!try git.check(&.{ "diff", "--no-relative", "--quiet" }, 1)) return error.DirtyWorkTree;
    const untracked = try git.output(&.{ "ls-files", "--others", "--exclude-standard", "--full-name", "--", ":/" });
    if (untracked.len != 0) return error.DirtyWorkTree;
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
