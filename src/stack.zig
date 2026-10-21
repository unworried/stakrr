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
    InvalidConfig,
    UnsupportedConfigVersion,
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
};

pub const Config = struct {
    base_ref: []const u8,
    work_ref: []const u8,
    anchor_oid: []const u8,

    // base_ref and work_ref borrow from this buffer
    _storage: []u8,

    pub fn deinit(
        self: *Config,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self._storage);
        allocator.free(self.anchor_oid);
        self.* = undefined;
    }
};

pub const Layer = struct {
    ref_name: []const u8,
    oid: []const u8,

    // commits since the previous layer boundary
    commits: usize,
};

pub const Snapshot = struct {
    config: Config,
    layers: []Layer,

    work_oid: []const u8,
    unstacked_commits: usize,
    base_moved: bool,

    // layer ref_name and oid slices borrow from this buffer
    _refs_storage: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.layers);
        allocator.free(self._refs_storage);
        allocator.free(self.work_oid);
        self.config.deinit(allocator);
        self.* = undefined;
    }
};

pub fn initStack(
    git: *const Git,
    base_name: []const u8,
) !void {
    const guard = try coordination.lockStack(git);
    defer guard.close(git.io);
    const allocator = git.allocator;
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

/// Validated config refs borrowing from the supplied persisted value.
/// Shared by stack loading and edit checkpoint validation.
pub const ConfigRefs = struct {
    base_ref: []const u8,
    work_ref: []const u8,
};

pub fn parseConfig(raw: []const u8) Error!ConfigRefs {
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

    if (std.mem.eql(u8, base, work) or
        std.mem.startsWith(u8, base, layout.layer_prefix) or
        std.mem.startsWith(u8, work, layout.layer_prefix))
        return error.InvalidConfig;

    return .{ .base_ref = base, .work_ref = work };
}

pub fn loadConfig(git: *const Git) !Config {
    const allocator = git.allocator;
    const raw = (try git.configGet(layout.state_key)) orelse
        return error.NotInitialized;
    errdefer allocator.free(raw);

    const refs = try parseConfig(raw);

    const anchor = (try git.readRef(layout.anchor_ref)) orelse
        return error.InvalidStack;
    errdefer allocator.free(anchor);

    if (!git_mod.isOid(anchor))
        return error.InvalidGitOutput;

    return .{
        .base_ref = refs.base_ref,
        .work_ref = refs.work_ref,
        .anchor_oid = anchor,
        ._storage = raw,
    };
}

// Inspection alone needs cumulative depths to sort boundaries by ancestry.
const Boundary = struct { ref_name: []const u8, oid: []const u8, depth: usize };

pub fn inspect(git: *const Git) !Snapshot {
    const allocator = git.allocator;
    try git.ensureWorkTree();

    var config = try loadConfig(git);
    errdefer config.deinit(allocator);

    const base_oid = try git.resolveCommit(config.base_ref);
    defer allocator.free(base_oid);

    const work_oid = try git.resolveCommit(config.work_ref);
    errdefer allocator.free(work_oid);

    // anchor must be reachable from the rolling branch
    if (!try git.isAncestor(config.anchor_oid, work_oid))
        return error.InvalidStack;

    // With no merges, anchor..work is a single chain. Index it once so
    // every layer resolves to a depth without spawning more git processes.
    var history = try git.history(config.anchor_oid, work_oid);
    defer history.deinit(allocator);

    // only supports linear history
    // FIXME: m2
    if (!history.linear) return error.MergeCommitsUnsupported;

    var depths: std.StringHashMapUnmanaged(usize) = .empty;
    defer depths.deinit(allocator);
    for (history.commits, 1..) |oid, depth| try depths.put(allocator, oid, depth);
    const chain_len = history.commits.len;

    // discover branches owned by stakrr
    const listed = try git.listRefs(layout.layer_prefix);
    defer allocator.free(listed.refs);
    errdefer allocator.free(listed.raw);

    var layers: std.ArrayList(Boundary) = .empty;
    defer layers.deinit(allocator);

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
    std.mem.sort(Boundary, layers.items, {}, struct {
        fn lessThan(_: void, a: Boundary, b: Boundary) bool {
            return a.depth < b.depth;
        }
    }.lessThan);

    // on a single chain, depth order is ancestry order
    var previous_oid = config.anchor_oid;
    var previous_depth: usize = 0;

    const result = try allocator.alloc(Layer, layers.items.len);
    errdefer allocator.free(result);
    for (layers.items, result) |layer, *out| {
        // each layer must introduce at least one commit
        if (layer.depth <= previous_depth)
            return error.InvalidLayerBoundary;

        out.* = .{
            .ref_name = layer.ref_name,
            .oid = layer.oid,
            .commits = layer.depth - previous_depth,
        };

        previous_oid = layer.oid;
        previous_depth = layer.depth;
    }

    // the private tip guard must match the highest committed layer
    const tip = try git.readRef(layout.tip_ref);
    defer if (tip) |oid| allocator.free(oid);
    if (layers.items.len == 0) {
        if (tip != null) return error.InvalidStack;
    } else {
        const tip_oid = tip orelse return error.InvalidStack;
        if (!std.mem.eql(u8, tip_oid, previous_oid)) return error.InvalidStack;
    }

    return .{
        .config = config,
        .layers = result,
        .work_oid = work_oid,
        .unstacked_commits = chain_len - previous_depth,
        .base_moved = !std.mem.eql(
            u8,
            base_oid,
            config.anchor_oid,
        ),
        ._refs_storage = listed.raw,
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
    const guard = try coordination.lockStack(git);
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
    defer snapshot.deinit(allocator);

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
    try createLayerRef(git, .{
        .layer = .{ .name = new_ref, .oid = target },
        .anchor = .{ .name = layout.anchor_ref, .oid = snapshot.config.anchor_oid },
        .work = .{ .name = snapshot.config.work_ref, .oid = snapshot.work_oid },
        .previous = if (last_layer) |layer|
            .{ .name = layer.ref_name, .oid = layer.oid }
        else
            null,
    });
}

pub const LayerCreation = struct {
    layer: Git.ExpectedRef,
    anchor: Git.ExpectedRef,
    work: Git.ExpectedRef,
    previous: ?Git.ExpectedRef = null,
};

/// Create a boundary and advance the stack guard in one compare-and-swap.
pub fn createLayerRef(git: *const Git, expected: LayerCreation) !void {
    var updates: [5]Git.RefUpdate = undefined;
    updates[0] = .{ .verify = expected.anchor };
    updates[1] = .{ .verify = expected.work };
    var count: usize = 2;
    if (expected.previous) |previous| {
        updates[count] = .{ .verify = previous };
        count += 1;
    }
    updates[count] = .{ .create = expected.layer };
    count += 1;
    updates[count] = if (expected.previous) |previous|
        .{ .update = .{
            .name = layout.tip_ref,
            .new = expected.layer.oid,
            .old = previous.oid,
        } }
    else
        .{ .create = .{ .name = layout.tip_ref, .oid = expected.layer.oid } };
    count += 1;
    try git.transact("stakrr: cut", updates[0..count]);
}

pub const ResetResult = struct {
    deleted_layers: usize,
    kept_layers: usize,
};

pub const ResetOptions = struct { delete_layers: bool = false };

/// Remove stakrr's state and internal refs so the stack can be
/// re-initialised. Layer branches are kept unless `delete_layers` is set.
/// Works on corrupt or outdated state, so it never parses the config.
pub fn reset(git: *const Git, options: ResetOptions) !ResetResult {
    const delete_layers = options.delete_layers;
    const guard = try coordination.lockStack(git);
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

    // deleting a checked-out branch would leave HEAD pointing nowhere
    if (delete_layers and layer_count != 0) {
        const names = try allocator.alloc([]const u8, layer_count);
        defer allocator.free(names);
        for (layers.refs, names) |ref, *name| name.* = ref.name;
        try coordination.requireAvailable(git, names);
        const head = try git.head();
        defer if (head) |ref_name| allocator.free(ref_name);
        if (head) |ref_name| {
            if (std.mem.startsWith(u8, ref_name, layout.layer_prefix))
                return error.LayerCheckedOut;
        }
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
    const guard = try coordination.lockStack(git);
    defer guard.close(git.io);
    var snapshot = try inspect(git);
    defer snapshot.deinit(git.allocator);

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
