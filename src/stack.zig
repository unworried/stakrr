const BranchRef = @import("git.zig").BranchRef;
const RefName = @import("git.zig").RefName;
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const coordination = @import("coordination.zig");
const layout = @import("layout.zig");

/// Domain errors raised by stack operations. Every member needs a
/// user-facing message in main.zig; a test there enforces it.
pub const Error = git_mod.Error || coordination.Error || error{
    AlreadyInitialized,
    NotInitialized,
    ExistingStackRefs,
    ReservedBranchNamespace,
    BaseEqualsWork,
    BaseNotFound,
    BaseNotAncestor,
    MergeCommitsUnsupported,
    InvalidManifest,
    UnsupportedManifestVersion,
    InvalidStack,
    InvalidLayerBoundary,
    NotOnWorkBranch,
    InvalidLayerName,
    LayerExists,
    LayerCheckedOut,
    EmptyCut,
    InvalidCutBoundary,
    CutOutsideWork,
    NotOnStackBranch,
    UnknownCut,
    StaleLayers,
};

const model = @import("stack_state.zig");
const store = @import("state_store.zig");
const operations = @import("operation.zig");
pub const StackState = model.StackState;
pub const Config = struct { base_ref: BranchRef, work_ref: BranchRef, anchor_oid: []const u8 };
pub const Layer = struct {
    ref_name: []const u8,
    oid: []const u8,
    branch_oid: []const u8,
    commits: usize,
    pub fn stale(self: Layer) bool {
        return !std.mem.eql(u8, self.oid, self.branch_oid);
    }
};
/// Strict mutation view. Values belong to this arena until deinit.
pub const Snapshot = struct {
    state: StackState,
    manifest_oid: []const u8,
    config: Config,
    layers: []const Layer,
    work_oid: []const u8,
    unstacked_commits: usize,
    base_moved: bool,
    _arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Snapshot) void {
        self._arena.deinit();
        self.* = undefined;
    }
};

pub const Issue = struct {
    kind: Kind,
    ref_name: []const u8,
    pub const Kind = enum {
        missing_branch,
        symbolic_ref,
        invalid_ancestry,
        merge_history,
        invalid_boundary,
        unexpected_layer,
        pending_publication,
        invalid_manifest,
        unsupported_manifest,
    };
};
/// Read-only evidence. Null means unavailable, never an inferred zero/false.
pub const StackObservation = struct {
    manifest_oid: ?[]const u8 = null,
    state: ?StackState = null,
    base_oid: ?[]const u8 = null,
    work_oid: ?[]const u8 = null,
    base_moved: ?bool = null,
    unstacked_commits: ?usize = null,
    layers: []const ObservedLayer = &.{},
    worktrees: ?[]const u8 = null,
    issues: []const Issue = &.{},
    _arena: std.heap.ArenaAllocator,
    pub const ObservedLayer = struct {
        branch: []const u8,
        recorded_boundary_oid: []const u8,
        branch_oid: ?[]const u8 = null,
        commits: ?usize = null,
        stale: ?bool = null,
    };
    pub fn deinit(self: *StackObservation) void {
        self._arena.deinit();
        self.* = undefined;
    }
};

pub fn observe(parent: *const Git) !StackObservation {
    try parent.ensureWorkTree();
    var arena: std.heap.ArenaAllocator = .init(parent.allocator);
    errdefer arena.deinit();
    const git = parent.withAllocator(arena.allocator());
    const a = git.allocator;
    var result: StackObservation = .{ ._arena = undefined };
    var issues: std.ArrayList(Issue) = .empty;
    git.requireNoPendingTransaction() catch |err| switch (err) {
        error.RefTransactionPending => try issues.append(a, .{ .kind = .pending_publication, .ref_name = layout.transaction_ref }),
        else => return err,
    };
    const loaded = loadObserved(&git, &result) catch |err| switch (err) {
        error.NotInitialized => {
            if (issues.items.len == 0) return err;
            result.issues = issues.items;
            result._arena = arena;
            return result;
        },
        error.InvalidManifest, error.UnsupportedManifestVersion, error.SymbolicRef => {
            try issues.append(a, .{ .kind = switch (err) {
                error.UnsupportedManifestVersion => .unsupported_manifest,
                error.SymbolicRef => .symbolic_ref,
                else => .invalid_manifest,
            }, .ref_name = layout.state_ref });
            result.issues = issues.items;
            result._arena = arena;
            return result;
        },
        else => return err,
    };
    // Transfer decoded state into the observation arena.
    const state = loaded.state.value;
    // Nested arena allocations are owned by the outer arena as well.
    result.state = state;
    result.manifest_oid = loaded.oid;
    result.base_oid = try observedBranch(&git, state.base_branch.name.bytes, &issues);
    result.work_oid = try observedBranch(&git, state.work_branch.name.bytes, &issues);
    if (result.base_oid) |oid| result.base_moved = !std.mem.eql(u8, oid, state.anchor_oid.hex());
    const layers = try a.alloc(StackObservation.ObservedLayer, state.layers.len);
    for (state.layers, layers) |*layer, *out| {
        out.* = .{ .branch = layer.branch.name.bytes, .recorded_boundary_oid = layer.recorded_boundary_oid.hex() };
        out.branch_oid = try observedBranch(&git, out.branch, &issues);
        if (out.branch_oid) |oid| out.stale = !std.mem.eql(u8, oid, out.recorded_boundary_oid);
    }
    result.layers = layers;
    const namespace_root = "refs/heads/stakrr";
    const root = git.readDirectRefAlloc(try RefName.init(namespace_root)) catch |err| switch (err) {
        error.SymbolicRef => blk: {
            try issues.append(a, .{ .kind = .symbolic_ref, .ref_name = namespace_root });
            break :blk null;
        },
        else => return err,
    };
    if (root != null) try issues.append(a, .{ .kind = .unexpected_layer, .ref_name = namespace_root });
    const listed = git.listDirectRefs(layout.layer_prefix) catch |err| switch (err) {
        error.SymbolicRef => blk: {
            try issues.append(a, .{ .kind = .symbolic_ref, .ref_name = layout.layer_prefix });
            break :blk null;
        },
        else => return err,
    };
    if (listed) |refs| for (refs.refs) |ref| {
        var declared = false;
        for (layers) |layer| if (std.mem.eql(u8, layer.branch, ref.name.bytes)) {
            declared = true;
            break;
        };
        if (!declared) try issues.append(a, .{ .kind = .unexpected_layer, .ref_name = ref.name.bytes });
    };
    if (result.work_oid) |work| {
        const ancestor = git.isAncestor(state.anchor_oid.hex(), work) catch |err| switch (err) {
            error.GitFailed => false,
            else => return err,
        };
        if (!ancestor) {
            try issues.append(a, .{ .kind = .invalid_ancestry, .ref_name = state.work_branch.name.bytes });
        } else {
            const history = try git.history(state.anchor_oid.hex(), work);
            if (!history.linear) {
                try issues.append(a, .{ .kind = .merge_history, .ref_name = state.work_branch.name.bytes });
            } else {
                var depths: std.StringHashMapUnmanaged(usize) = .empty;
                for (history.commits, 1..) |oid, depth| try depths.put(a, oid, depth);
                var previous: usize = 0;
                var valid = true;
                for (layers) |*layer| {
                    const depth = depths.get(layer.recorded_boundary_oid);
                    if (depth == null or depth.? <= previous) {
                        try issues.append(a, .{ .kind = .invalid_boundary, .ref_name = layer.branch });
                        valid = false;
                    } else {
                        if (valid) layer.commits = depth.? - previous;
                        previous = depth.?;
                    }
                }
                if (valid) result.unstacked_commits = history.commits.len - previous;
            }
        }
    }
    result.worktrees = try git.outputRaw(&.{ "worktree", "list", "--porcelain", "-z" });
    result.issues = issues.items;
    result._arena = arena;
    return result;
}
fn loadObserved(git: *const Git, result: *StackObservation) !store.Loaded {
    const oid = try store.identity(git);
    result.manifest_oid = oid;
    return .{ .oid = oid, .state = try store.loadAt(git, oid) };
}
fn observedBranch(git: *const Git, name: []const u8, issues: *std.ArrayList(Issue)) !?[]const u8 {
    const oid = git.branchCommitAlloc(try BranchRef.init(name)) catch |err| switch (err) {
        error.SymbolicRef => {
            try issues.append(git.allocator, .{ .kind = .symbolic_ref, .ref_name = name });
            return null;
        },
        error.GitFailed => {
            try issues.append(git.allocator, .{ .kind = .missing_branch, .ref_name = name });
            return null;
        },
        else => return err,
    };
    return oid;
}
pub fn inspect(parent: *const Git) !Snapshot {
    var view = try observe(parent);
    errdefer view.deinit();
    for (view.issues) |issue| switch (issue.kind) {
        .pending_publication => return error.RefTransactionPending,
        .invalid_manifest => return error.InvalidManifest,
        .unsupported_manifest => return error.UnsupportedManifestVersion,
        .symbolic_ref => return error.SymbolicRef,
        .merge_history => return error.MergeCommitsUnsupported,
        .invalid_boundary => return error.InvalidLayerBoundary,
        else => return error.InvalidStack,
    };
    const a = view._arena.allocator();
    const state = view.state.?;
    const layers = try a.alloc(Layer, view.layers.len);
    for (view.layers, layers) |layer, *out| out.* = .{ .ref_name = layer.branch, .oid = layer.recorded_boundary_oid, .branch_oid = layer.branch_oid.?, .commits = layer.commits.? };
    return .{ .state = state, .manifest_oid = view.manifest_oid.?, .config = .{ .base_ref = state.base_branch, .work_ref = state.work_branch, .anchor_oid = try a.dupe(u8, state.anchor_oid.hex()) }, .layers = layers, .work_oid = view.work_oid.?, .unstacked_commits = view.unstacked_commits.?, .base_moved = view.base_moved.?, ._arena = view._arena };
}

pub fn initStack(original: *const Git, base_name: []const u8) !void {
    var mutation = try @import("mutation.zig").begin(original, .stack);
    defer mutation.deinit();
    const git = mutation.repo();
    const a = git.allocator;
    const existing = try git.readDirectRefAlloc(try RefName.init(layout.state_ref));
    defer if (existing) |oid| a.free(oid);
    if (existing != null) return error.AlreadyInitialized;
    const root = try git.readDirectRefAlloc(try RefName.init("refs/heads/stakrr"));
    defer if (root) |oid| a.free(oid);
    if (root != null) return error.ExistingStackRefs;
    var listed = try git.listDirectRefs(layout.layer_prefix);
    defer listed.deinit(a);
    if (listed.refs.len != 0) return error.ExistingStackRefs;
    const work = try git.currentBranchAlloc();
    defer a.free(work);
    const base = if (std.mem.startsWith(u8, base_name, layout.branch_prefix)) try a.dupe(u8, base_name) else try std.fmt.allocPrint(a, layout.branch_prefix ++ "{s}", .{base_name});
    defer a.free(base);
    if (std.mem.eql(u8, base, work)) return error.BaseEqualsWork;
    if (model.conflict(base, "refs/heads/stakrr") or model.conflict(work, "refs/heads/stakrr")) return error.ReservedBranchNamespace;
    const base_ref = try BranchRef.init(base);
    const work_ref = try BranchRef.init(work);
    const base_oid = (try git.readDirectRefAlloc(base_ref.name)) orelse return error.BaseNotFound;
    defer a.free(base_oid);
    const work_oid = try git.branchCommitAlloc(work_ref);
    defer a.free(work_oid);
    if (!try git.isAncestor(base_oid, work_oid)) return error.BaseNotAncestor;
    var history = try git.history(base_oid, work_oid);
    defer history.deinit(a);
    if (!history.linear) return error.MergeCommitsUnsupported;
    const oid = try store.create(git, .{ .base_branch = base_ref, .work_branch = work_ref, .anchor_oid = try git.parseOid(base_oid), .layers = &.{} });
    defer a.free(oid);
    try mutation.publish(.{ .message = "stakrr: init", .updates = &.{ try git.verifyRef(base, base_oid), try git.verifyRef(work, work_oid), try git.createRef(layout.state_ref, oid) } });
}

/// carve the next stack layer out of the linear rolling branch
/// head, index, working tree and existing branch refs remain untouched
pub fn cut(
    original_git: *const Git,
    name: []const u8,
    revision: ?[]const u8,
) !void {
    var mutation = try @import("mutation.zig").begin(original_git, .stack);
    defer mutation.deinit();
    const git = mutation.repo();
    const allocator = git.allocator;

    // validate the name before inspecting the stack
    if (name.len == 0 or name[0] == '-')
        return error.InvalidLayerName;

    const new_ref = try std.fmt.allocPrint(
        allocator,
        layout.layer_prefix ++ "{s}",
        .{name},
    );
    defer allocator.free(new_ref);

    git.checkRefFormat(new_ref) catch |err| switch (err) {
        error.InvalidRefName => return error.InvalidLayerName,
        else => return err,
    };

    var snapshot = try inspect(git);
    defer snapshot.deinit();

    var current_branch = try git.currentBranch();
    defer current_branch.deinit(allocator);
    const current_ref = current_branch.value.name.bytes;

    if (!std.mem.eql(u8, current_ref, snapshot.config.work_ref.name.bytes))
        return error.NotOnWorkBranch;

    for (snapshot.layers) |layer| {
        if (layer.stale()) return error.StaleLayers;
        if (model.conflict(layer.ref_name, new_ref))
            return error.LayerExists;
    }

    const target = if (revision) |rev|
        try git.resolveCommitAlloc(rev)
    else
        try allocator.dupe(u8, snapshot.work_oid);
    defer allocator.free(target);

    const last_layer: ?Layer = if (snapshot.layers.len != 0)
        snapshot.layers[snapshot.layers.len - 1]
    else
        null;

    const lower = if (last_layer) |layer|
        layer.oid
    else
        snapshot.config.anchor_oid;

    if (std.mem.eql(u8, lower, target))
        return error.EmptyCut;

    if (!try git.isAncestor(lower, target))
        return error.InvalidCutBoundary;

    if (!try git.isAncestor(target, snapshot.work_oid))
        return error.CutOutsideWork;

    const appended = try allocator.alloc(model.Layer, snapshot.state.layers.len + 1);
    defer allocator.free(appended);
    @memcpy(appended[0..snapshot.state.layers.len], snapshot.state.layers);
    appended[appended.len - 1] = .{ .branch = try BranchRef.init(new_ref), .recorded_boundary_oid = try git.parseOid(target) };
    var next_state = snapshot.state;
    next_state.layers = appended;
    const oid = try store.create(git, next_state);
    defer allocator.free(oid);
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    defer updates.deinit(allocator);
    try updates.appendSlice(allocator, &.{ try git.updateRef(layout.state_ref, snapshot.manifest_oid, oid), try git.verifyRef(snapshot.config.work_ref.name.bytes, snapshot.work_oid), try git.createRef(new_ref, target) });
    for (snapshot.layers) |layer| try updates.append(allocator, try git.verifyRef(layer.ref_name, layer.branch_oid));
    try mutation.publish(.{ .message = "stakrr: cut", .updates = updates.items });
}

pub const ResetResult = struct { deleted_layers: usize, kept_layers: usize };
pub const ResetOptions = struct { delete_layers: bool = false };
/// Archive all roots before deleting state.
pub fn reset(original: *const Git, options: ResetOptions) !ResetResult {
    var arena: std.heap.ArenaAllocator = .init(original.allocator);
    defer arena.deinit();
    const scoped = original.withAllocator(arena.allocator());
    var mutation = try @import("mutation.zig").begin(&scoped, .stack);
    defer mutation.deinit();
    const git = mutation.repo();
    const state = try git.readDirectRefAlloc(try RefName.init(layout.state_ref));
    const layers = try git.listDirectRefs(layout.layer_prefix);
    if (state == null and layers.refs.len == 0) {
        if (mutation.recovered) return .{ .deleted_layers = 0, .kept_layers = 0 };
        return error.NotInitialized;
    }
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    var rescue: std.ArrayList([]const u8) = .empty;
    var moves: std.ArrayList(operations.Move) = .empty;
    if (state) |oid| {
        try updates.append(git.allocator, try git.deleteRef(layout.state_ref, oid));
        try rescue.append(git.allocator, oid);
    }
    for (layers.refs) |ref| {
        try rescue.append(git.allocator, try ref.oid.dupeHex(git.allocator));
        if (options.delete_layers) {
            try updates.append(git.allocator, ref.delete());
            try moves.append(git.allocator, .{ .name = ref.name.bytes, .before = try ref.oid.dupeHex(git.allocator), .after = null });
        }
    }
    const old = try git.readDirectRefAlloc(try RefName.init(layout.oplog_ref));
    const archive = try operations.create(git, .{ .kind = .reset, .before_manifest = state, .after_manifest = null, .moves = moves.items, .rescue = rescue.items, .previous = old }, null);
    try updates.append(git.allocator, try operations.update(git, old, archive));
    try mutation.publish(.{ .message = "stakrr: reset", .updates = updates.items });
    return .{ .deleted_layers = if (options.delete_layers) layers.refs.len else 0, .kept_layers = if (options.delete_layers) 0 else layers.refs.len };
}

pub const Direction = enum { up, down };

/// Navigation positions: base, ordered layers, rolling work.
fn navigationRef(snapshot: *const Snapshot, index: usize) []const u8 {
    if (index == 0) return snapshot.config.base_ref.name.bytes;
    if (index == snapshot.layers.len + 1)
        return snapshot.config.work_ref.name.bytes;
    return snapshot.layers[index - 1].ref_name;
}

/// Returns false when already at the requested end of the stack.
pub fn navigate(original_git: *const Git, direction: Direction) !bool {
    var mutation = try @import("mutation.zig").begin(original_git, .stack);
    defer mutation.deinit();
    const git = mutation.repo();
    var snapshot = try inspect(git);
    defer snapshot.deinit();

    var current_branch = try git.currentBranch();
    defer current_branch.deinit(git.allocator);
    const current = current_branch.value.name.bytes;

    const top = snapshot.layers.len + 1;
    const index = for (0..(top + 1)) |i| {
        if (std.mem.eql(u8, current, navigationRef(&snapshot, i)))
            break i;
    } else return error.NotOnStackBranch;

    const target_index = switch (direction) {
        .up => if (index == top) return false else index + 1,
        .down => if (index == 0) return false else index - 1,
    };

    try mutation.switchBranch(try BranchRef.init(navigationRef(&snapshot, target_index)));
    return true;
}

/// Switch to a layer's branch by its short name. Commits made there are picked
/// up by the next restack.
pub fn go(original_git: *const Git, name: []const u8) !void {
    var mutation = try @import("mutation.zig").begin(original_git, .stack);
    defer mutation.deinit();
    const git = mutation.repo();
    var snapshot = try inspect(git);
    defer snapshot.deinit();
    for (snapshot.layers) |layer| {
        const short = layout.layerName(layer.ref_name) orelse continue;
        if (!std.mem.eql(u8, short, name)) continue;
        return mutation.switchBranch(try BranchRef.init(layer.ref_name));
    }
    return error.UnknownCut;
}
