const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;

/// Domain errors raised by stack operations. Every member needs a
/// user-facing message in main.zig; a test there enforces it.
pub const Error = git_mod.Error || error{
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
};

/// git config key holding "<version> <base_ref> <work_ref>"
pub const state_key = "stakrr.state";
pub const state_version = "v1";

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

    // commits between anchor and this layer
    depth: usize,

    // commits since the previous layer boundary
    commits: usize = 0,
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
    const allocator = git.allocator;
    // 1. require standard working tree
    try git.ensureWorkTree();

    // 2. refuse existing initialisation
    if (try git.configGet(state_key)) |existing| {
        allocator.free(existing);
        return error.AlreadyInitialized;
    }

    // reserve stakrr's branch namespace and internal refs for managed layers
    const existing_layers = try git.listStackRefs();
    defer allocator.free(existing_layers);
    if (existing_layers.len != 0) return error.ExistingStackRefs;
    for ([_][]const u8{ git_mod.tip_ref, git_mod.anchor_ref }) |ref_name| {
        const existing = try git.readRef(ref_name);
        defer if (existing) |oid| allocator.free(oid);
        if (existing != null) return error.ExistingStackRefs;
    }

    // 3. identify rolling branch and base
    const work_ref = try git.currentBranch();
    defer allocator.free(work_ref);

    // accept either a branch name or its full refs/heads/ ref
    const base_ref = if (std.mem.startsWith(u8, base_name, "refs/heads/"))
        try allocator.dupe(u8, base_name)
    else
        try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{base_name});
    defer allocator.free(base_ref);

    // layer names live exclusively under refs/heads/stakrr/
    if (std.mem.startsWith(u8, work_ref, git_mod.layer_prefix) or
        std.mem.startsWith(u8, base_ref, git_mod.layer_prefix))
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
    // FIXME: m1
    if (try git.hasMergeCommits(base_oid, work_oid))
        return error.MergeCommitsUnsupported;

    // 7. claim the anchor; `create` fails if a concurrent init won the race
    const anchor: Git.ExpectedRef = .{ .name = git_mod.anchor_ref, .oid = base_oid };
    try git.transact("stakrr: init", &.{.{ .create = anchor }});
    errdefer git.transact("stakrr: init rollback", &.{.{ .delete = anchor }}) catch {};

    // 8. persist the branch pair
    const state = try std.fmt.allocPrint(
        allocator,
        state_version ++ " {s} {s}",
        .{ base_ref, work_ref },
    );
    defer allocator.free(state);

    try git.exec(&.{ "config", "--local", state_key, state });
}

pub fn loadConfig(git: *const Git) !Config {
    const allocator = git.allocator;
    const raw = (try git.configGet(state_key)) orelse
        return error.NotInitialized;
    errdefer allocator.free(raw);

    var tokens = std.mem.tokenizeScalar(u8, raw, ' ');

    const version = tokens.next() orelse
        return error.InvalidConfig;

    if (!std.mem.eql(u8, version, state_version))
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

    const anchor = (try git.readRef(git_mod.anchor_ref)) orelse
        return error.InvalidStack;
    errdefer allocator.free(anchor);

    if (!git_mod.isOid(anchor))
        return error.InvalidGitOutput;

    return .{
        .base_ref = base,
        .work_ref = work,
        .anchor_oid = anchor,
        ._storage = raw,
    };
}

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
    const history = try git.revListParents(config.anchor_oid, work_oid);
    defer allocator.free(history);

    var depths: std.StringHashMapUnmanaged(usize) = .empty;
    defer depths.deinit(allocator);

    var chain_len: usize = 0;
    var commits = std.mem.splitScalar(u8, history, '\n');
    while (commits.next()) |line| {
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const oid = fields.next() orelse return error.InvalidGitOutput;

        var parents: usize = 0;
        while (fields.next()) |_| parents += 1;

        // only supports linear history
        // FIXME: m2
        if (parents > 1) return error.MergeCommitsUnsupported;
        if (parents == 0) return error.InvalidStack;

        chain_len += 1;
        try depths.put(allocator, oid, chain_len);
    }

    // discover branches owned by stakrr
    const raw_refs = try git.listStackRefs();
    errdefer allocator.free(raw_refs);

    var layers: std.ArrayList(Layer) = .empty;
    errdefer layers.deinit(allocator);
    var lines = std.mem.splitScalar(u8, raw_refs, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const separator = std.mem.indexOfScalar(
            u8,
            line,
            '\t',
        ) orelse return error.InvalidGitOutput;

        const ref_name = line[0..separator];
        const oid = line[separator + 1 ..];

        if (oid.len == 0)
            return error.InvalidGitOutput;

        // every layer must sit on the chain between the anchor and work
        const depth = depths.get(oid) orelse
            return error.InvalidStack;

        try layers.append(allocator, .{
            .ref_name = ref_name,
            .oid = oid,
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
    const tip = try git.readRef(git_mod.tip_ref);
    defer if (tip) |oid| allocator.free(oid);
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
        ._refs_storage = raw_refs,
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
    const allocator = git.allocator;

    // validate the name before inspecting the stack
    if (name.len == 0 or name[0] == '-')
        return error.InvalidLayerName;

    const new_ref = try std.fmt.allocPrint(
        allocator,
        git_mod.layer_prefix ++ "{s}",
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
    try git.createLayerRef(
        new_ref,
        target,
        .{
            .name = git_mod.anchor_ref,
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
