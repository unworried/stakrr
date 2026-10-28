const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const layout = @import("layout.zig");
const coordination = @import("coordination.zig");

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
    InvalidConfig,
    UnsupportedConfigVersion,
    InvalidStack,
    InvalidLayerBoundary,
    NotOnWorkBranch,
    InvalidLayerName,
    LayerExists,
    EmptyCut,
    InvalidCutBoundary,
    CutOutsideWork,
    NotOnStackBranch,
};

/// git config key holding "<version> <base_ref> <work_ref>"
pub const state_key = layout.state_key;
pub const state_version = layout.state_version;

/// Stack configuration borrowing storage from its owning snapshot.
pub const Config = struct {
    base_ref: []const u8,
    work_ref: []const u8,
    anchor_oid: []const u8,
};

pub const Layer = struct {
    ref_name: []const u8,
    oid: []const u8,

    // commits between anchor and this layer
    depth: usize,

    // commits since the previous layer boundary
    commits: usize = 0,
};

/// Owned view of the stack. Every slice stays valid until deinit.
pub const Snapshot = struct {
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

pub fn initStack(
    git: *const Git,
    base_name: []const u8,
) !void {
    const allocator = git.allocator;
    const guard = try coordination.lock(git);
    defer guard.close(git.io);
    // lock() also validates the working tree.

    // 2. refuse existing initialisation
    if (try git.configGet(layout.state_key)) |existing| {
        allocator.free(existing);
        return error.AlreadyInitialized;
    }

    // reserve stakrr's branch namespace and internal refs for managed layers
    var existing_layers = try git.listRefs(layout.layer_prefix);
    defer existing_layers.deinit(allocator);
    if (existing_layers.refs.len != 0) return error.ExistingStackRefs;
    for ([_][]const u8{ layout.tip_ref, layout.anchor_ref }) |ref_name| {
        const existing = try git.readRef(ref_name);
        defer if (existing) |oid| allocator.free(oid);
        if (existing != null) return error.ExistingStackRefs;
    }

    // 3. identify rolling branch and base
    const work_ref = try git.currentBranch();
    defer allocator.free(work_ref);

    // accept either a branch name or its full refs/heads/ ref
    const base_ref = if (std.mem.startsWith(u8, base_name, layout.branch_prefix))
        try allocator.dupe(u8, base_name)
    else
        try std.fmt.allocPrint(allocator, layout.branch_prefix ++ "{s}", .{base_name});
    defer allocator.free(base_ref);

    // layer names live exclusively under refs/heads/stakrr/
    if (std.mem.startsWith(u8, work_ref, layout.layer_prefix) or
        std.mem.startsWith(u8, base_ref, layout.layer_prefix))
        return error.ReservedBranchNamespace;

    try git.checkRefFormat(base_ref);

    if (std.mem.eql(u8, work_ref, base_ref))
        return error.BaseEqualsWork;

    // 4. resolve both branch tips
    const base_oid = (try git.readRef(base_ref)) orelse
        return error.BaseNotFound;
    defer allocator.free(base_oid);
    const work_oid = try git.resolveCommit(work_ref);
    defer allocator.free(work_oid);

    // 5. check ancestry
    if (!try git.isAncestor(base_oid, work_oid))
        return error.BaseNotAncestor;

    // 6. reject merge commits
    // FIXME: m2
    var history = try git.history(base_oid, work_oid);
    defer history.deinit(allocator);
    if (!history.linear) return error.MergeCommitsUnsupported;

    // 7. claim the anchor; `create` fails if a concurrent init won the race
    const anchor: Git.ExpectedRef = .{ .name = layout.anchor_ref, .oid = base_oid };
    try git.transact("stakrr: init", &.{.{ .create = anchor }});
    errdefer git.transact("stakrr: init rollback", &.{.{ .delete = anchor }}) catch {};

    // 8. persist the branch pair
    const state = try std.fmt.allocPrint(
        allocator,
        layout.state_version ++ " {s} {s}",
        .{ base_ref, work_ref },
    );
    defer allocator.free(state);

    try git.exec(&.{ "config", "--local", layout.state_key, state });
}

/// Slices are allocated from `git.allocator` and never freed individually;
/// callers pass an arena-backed Git.
fn loadConfig(git: *const Git) !Config {
    const raw = (try git.configGet(layout.state_key)) orelse
        return error.NotInitialized;

    var tokens = std.mem.tokenizeScalar(u8, raw, ' ');

    const version = tokens.next() orelse
        return error.InvalidConfig;

    if (!std.mem.eql(u8, version, layout.state_version))
        return error.UnsupportedConfigVersion;

    const base = tokens.next() orelse
        return error.InvalidConfig;

    const work = tokens.next() orelse
        return error.InvalidConfig;

    if (tokens.next() != null)
        return error.InvalidConfig;

    // config is user-editable: validate before refs reach argv or update-ref
    if (!git_mod.isSafeBranchRef(base) or !git_mod.isSafeBranchRef(work))
        return error.InvalidConfig;

    if (std.mem.eql(u8, base, work))
        return error.InvalidConfig;

    const anchor = (try git.readRef(layout.anchor_ref)) orelse
        return error.InvalidStack;

    if (!git_mod.isOid(anchor))
        return error.InvalidGitOutput;

    return .{
        .base_ref = base,
        .work_ref = work,
        .anchor_oid = anchor,
    };
}

pub fn inspect(parent_git: *const Git) !Snapshot {
    try parent_git.ensureWorkTree();

    // The snapshot owns everything inspection allocates.
    var arena: std.heap.ArenaAllocator = .init(parent_git.allocator);
    errdefer arena.deinit();
    const scoped = parent_git.withAllocator(arena.allocator());
    const git = &scoped;
    const allocator = git.allocator;

    const config = try loadConfig(git);
    const base_oid = try git.resolveCommit(config.base_ref);
    const work_oid = try git.resolveCommit(config.work_ref);

    // anchor must be reachable from the rolling branch
    if (!try git.isAncestor(config.anchor_oid, work_oid))
        return error.InvalidStack;

    // With no merges, anchor..work is a single chain. Index it once so
    // every layer resolves to a depth without spawning more git processes.
    const history = try git.history(config.anchor_oid, work_oid);
    if (!history.linear) return error.MergeCommitsUnsupported;

    var depths: std.StringHashMapUnmanaged(usize) = .empty;
    for (history.commits, 1..) |oid, depth| try depths.put(allocator, oid, depth);
    const chain_len = history.commits.len;

    // discover branches owned by stakrr
    const listed = try git.listRefs(layout.layer_prefix);

    var layers: std.ArrayList(Layer) = .empty;

    for (listed.refs) |ref| {
        // every layer must sit on the chain between the anchor and work
        const depth = depths.get(ref.oid) orelse
            return error.InvalidStack;

        try layers.append(allocator, .{
            .ref_name = ref.name,
            .oid = ref.oid,
            .depth = depth,
        });
    }

    // order by distance from anchor, not branch name
    std.mem.sort(Layer, layers.items, {}, struct {
        fn lessThan(
            _: void,
            a: Layer,
            b: Layer,
        ) bool {
            return a.depth < b.depth;
        }
    }.lessThan);

    // on a single chain, depth order is ancestry order
    var previous_oid = config.anchor_oid;
    var previous_depth: usize = 0;

    for (layers.items) |*layer| {
        // each layer must introduce at least one commit
        if (layer.depth <= previous_depth)
            return error.InvalidLayerBoundary;

        layer.commits = layer.depth - previous_depth;

        previous_oid = layer.oid;
        previous_depth = layer.depth;
    }

    // the private tip guard must match the highest committed layer
    const tip = try git.readRef(layout.tip_ref);
    if (layers.items.len == 0) {
        if (tip != null) return error.InvalidStack;
    } else {
        const tip_oid = tip orelse return error.InvalidStack;
        if (!std.mem.eql(u8, tip_oid, previous_oid)) return error.InvalidStack;
    }

    return .{
        .config = config,
        .layers = try layers.toOwnedSlice(allocator),
        .work_oid = work_oid,
        .unstacked_commits = chain_len - previous_depth,
        .base_moved = !std.mem.eql(
            u8,
            base_oid,
            config.anchor_oid,
        ),
        ._arena = arena,
    };
}

/// True if two refs are equal or one is a directory of the other
/// (e.g. stakrr/p1 and stakrr/p1/x), which Git cannot store together.
fn refsConflict(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or isPathPrefix(a, b) or isPathPrefix(b, a);
}

fn isPathPrefix(prefix: []const u8, full: []const u8) bool {
    return full.len > prefix.len and
        std.mem.startsWith(u8, full, prefix) and
        full[prefix.len] == '/';
}

/// carve the next stack layer out of the linear rolling branch
/// head, index, working tree and existing branch refs remain untouched
pub fn cut(
    git: *const Git,
    name: []const u8,
    revision: ?[]const u8,
) !void {
    const guard = try coordination.lock(git);
    defer guard.close(git.io);
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

    const current_ref = try git.currentBranch();
    defer allocator.free(current_ref);

    if (!std.mem.eql(u8, current_ref, snapshot.config.work_ref))
        return error.NotOnWorkBranch;

    for (snapshot.layers) |layer| {
        if (refsConflict(layer.ref_name, new_ref))
            return error.LayerExists;
    }

    const target = if (revision) |rev|
        try git.resolveCommit(rev)
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

    // The base may have moved since init; layers are carved relative to
    // the anchor, which the transaction pins instead of the base branch.
    try git.createLayerRef(
        new_ref,
        target,
        .{
            .name = layout.anchor_ref,
            .oid = snapshot.config.anchor_oid,
        },
        .{
            .name = snapshot.config.work_ref,
            .oid = snapshot.work_oid,
        },
        if (last_layer) |layer|
            .{
                .name = layer.ref_name,
                .oid = layer.oid,
            }
        else
            null,
    );
}

pub const ResetResult = struct {
    deleted_layers: usize,
    kept_layers: usize,
};

/// Remove stakrr's state and internal refs so the stack can be
/// re-initialised. Layer branches are kept unless `delete_layers` is set.
/// Works on corrupt or outdated state, so it never parses the config.
pub fn reset(git: *const Git, delete_layers: bool) !ResetResult {
    const guard = try coordination.lock(git);
    defer guard.close(git.io);
    const allocator = git.allocator;

    var layers = try git.listRefs(layout.layer_prefix);
    defer layers.deinit(allocator);

    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    defer updates.deinit(allocator);

    const internal = [_][]const u8{ layout.tip_ref, layout.anchor_ref };
    var internal_oids: [internal.len]?[]u8 = @splat(null);
    defer for (internal_oids) |maybe| if (maybe) |oid| allocator.free(oid);

    for (internal, &internal_oids) |ref_name, *slot| {
        slot.* = try git.readRef(ref_name);
        if (slot.*) |oid|
            try updates.append(
                allocator,
                .{ .delete = .{ .name = ref_name, .oid = oid } },
            );
    }

    const layer_count = layers.refs.len;
    if (delete_layers) for (layers.refs) |ref| {
        try updates.append(allocator, .{ .delete = ref });
    };

    // Deleting a checked-out branch would leave HEAD pointing nowhere.
    if (delete_layers and layer_count != 0) {
        const names = try allocator.alloc([]const u8, layer_count);
        defer allocator.free(names);
        for (layers.refs, names) |ref, *name| name.* = ref.name;
        try coordination.requireDeletable(git, names);
    }

    // refs first: if unsetting config fails, reset can simply be re-run
    if (updates.items.len != 0)
        try git.transact("stakrr: reset", updates.items);

    const had_state = try git.configUnset(layout.state_key);

    if (!had_state and updates.items.len == 0 and layer_count == 0)
        return error.NotInitialized;

    return .{
        .deleted_layers = if (delete_layers) layer_count else 0,
        .kept_layers = if (delete_layers) 0 else layer_count,
    };
}

pub const Direction = enum { up, down };

/// Navigation positions: base, ordered layers, rolling work.
fn navigationRef(snapshot: *const Snapshot, index: usize) []const u8 {
    if (index == 0) return snapshot.config.base_ref;
    if (index == snapshot.layers.len + 1)
        return snapshot.config.work_ref;
    return snapshot.layers[index - 1].ref_name;
}

/// Returns false when already at the requested end of the stack.
pub fn navigate(git: *const Git, direction: Direction) !bool {
    const guard = try coordination.lock(git);
    defer guard.close(git.io);
    var snapshot = try inspect(git);
    defer snapshot.deinit();

    const current = try git.currentBranch();
    defer git.allocator.free(current);

    const top = snapshot.layers.len + 1;
    const index = for (0..(top + 1)) |i| {
        if (std.mem.eql(u8, current, navigationRef(&snapshot, i)))
            break i;
    } else return error.NotOnStackBranch;

    const target_index = switch (direction) {
        .up => if (index == top) return false else index + 1,
        .down => if (index == 0) return false else index - 1,
    };

    try git.switchBranch(navigationRef(&snapshot, target_index));
    return true;
}
