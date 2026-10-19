const std = @import("std");
const Git = @import("git.zig").Git;

pub const Config = struct {
    base_ref: []const u8,
    work_ref: []const u8,
    anchor_oid: []const u8,

    _storage: []u8,

    pub fn deinit(
        self: *Config,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self._storage);
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

    _allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        self._allocator.free(self.layers);
        self._allocator.free(self._refs_storage);
        self._allocator.free(self.work_oid);
        self.config.deinit(self._allocator);
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
    const existing = try git.run(&.{
        "config", "--local", "--get", "stakrr.state",
    });
    defer git.free(existing);

    switch (existing.term) {
        .exited => |code| switch (code) {
            0 => return error.AlreadyInitialised,
            1 => {},
            else => return error.GitFailed,
        },
        else => return error.GitTerminated,
    }

    // reserve stakrr's branch namespace and internal tip for managed layers
    const existing_layers = try git.listStackRefs();
    defer allocator.free(existing_layers);
    if (existing_layers.len != 0) return error.ExistingStackRefs;
    const existing_tip = try git.readRef("refs/stakrr/tip");
    defer if (existing_tip) |oid| allocator.free(oid);
    if (existing_tip != null) return error.ExistingStackRefs;

    // 3. identify rolling branch and base
    const work_ref = try git.currentBranch();
    defer git.allocator.free(work_ref);

    const base_ref = try std.fmt.allocPrint(
        allocator,
        "refs/heads/{s}",
        .{base_name},
    );
    defer allocator.free(base_ref);

    // layer names live exclusively under refs/heads/stakrr/
    if (std.mem.startsWith(u8, work_ref, "refs/heads/stakrr/") or
        std.mem.startsWith(u8, base_ref, "refs/heads/stakrr/"))
        return error.ReservedBranchNamespace;

    try git.checkRefFormat(base_ref);

    if (std.mem.eql(u8, work_ref, base_ref))
        return error.BaseEqualsWork;

    // 4. resolve both branch tips
    const base_oid = try git.resolveCommit(base_ref);
    defer git.allocator.free(base_oid);
    const work_oid = try git.resolveCommit(work_ref);
    defer git.allocator.free(work_oid);

    // 5. check ancestry
    if (!try git.isAncestor(base_oid, work_oid))
        return error.BaseNotAncestor;

    // 6. reject merge commits
    // FIXME: m1
    if (try git.hasMergeCommits(base_oid, work_oid))
        return error.MergeCommitsUnsupported;

    // 7. persist the initialisation metadata
    const state = try std.fmt.allocPrint(
        allocator,
        "v1 {s} {s} {s}",
        .{ base_ref, work_ref, base_oid },
    );
    defer allocator.free(state);

    try git.exec(&.{
        "config",
        "--local",
        "--add",
        "stakrr.state",
        state,
    });

    std.log.info("initialised: {s} -> {s}", .{
        base_ref,
        work_ref,
    });
}

pub fn loadConfig(git: *const Git) !Config {
    const raw = (try git.configGet("stakrr.state")) orelse
        return error.NotInitialized;
    errdefer git.allocator.free(raw);

    var tokens = std.mem.tokenizeScalar(u8, raw, ' ');

    const version = tokens.next() orelse
        return error.InvalidConfig;

    const base = tokens.next() orelse
        return error.InvalidConfig;

    const work = tokens.next() orelse
        return error.InvalidConfig;

    const anchor = tokens.next() orelse
        return error.InvalidConfig;

    if (tokens.next() != null)
        return error.InvalidConfig;

    if (!std.mem.eql(u8, version, "v1"))
        return error.UnsupportedConfigVersion;

    if (!std.mem.startsWith(u8, base, "refs/heads/") or
        !std.mem.startsWith(u8, work, "refs/heads/"))
    {
        return error.InvalidConfig;
    }

    if (std.mem.eql(u8, base, work))
        return error.InvalidConfig;

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
    errdefer config.deinit(git.allocator);

    const base_oid = try git.resolveCommit(config.base_ref);
    defer git.allocator.free(base_oid);

    const work_oid = try git.resolveCommit(config.work_ref);
    errdefer git.allocator.free(work_oid);

    // anchor must be reachable from the rolling branch
    if (!try git.isAncestor(config.anchor_oid, work_oid))
        return error.InvalidStack;

    // only supports linear history
    // FIXME: m1
    if (try git.hasMergeCommits(config.anchor_oid, work_oid))
        return error.MergeCommitsUnsupported;

    // discover branches owned by stakrr
    const raw_refs = try git.listStackRefs();
    errdefer git.allocator.free(raw_refs);

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

        // every layer must be between the anchor and work
        if (!try git.isAncestor(config.anchor_oid, oid))
            return error.InvalidStack;

        if (!try git.isAncestor(oid, work_oid))
            return error.InvalidStack;

        const depth = try git.countCommits(
            config.anchor_oid,
            oid,
        );

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

    // validate each successive boundary
    var previous_oid = config.anchor_oid;
    var previous_depth: usize = 0;

    for (layers.items) |*layer| {
        // each layer must introduce at least one commit
        if (layer.depth <= previous_depth)
            return error.InvalidLayerBoundary;

        if (!try git.isAncestor(previous_oid, layer.oid))
            return error.InvalidStack;

        layer.commits = try git.countCommits(
            previous_oid,
            layer.oid,
        );

        previous_oid = layer.oid;
        previous_depth = layer.depth;
    }

    // the private tip guard must match the highest committed layer
    const tip = try git.readRef("refs/stakrr/tip");
    defer if (tip) |oid| allocator.free(oid);
    if (layers.items.len == 0) {
        if (tip != null) return error.InvalidStack;
    } else {
        const tip_oid = tip orelse return error.InvalidStack;
        if (!std.mem.eql(u8, tip_oid, previous_oid)) return error.InvalidStack;
    }

    const unstacked = try git.countCommits(
        previous_oid,
        work_oid,
    );

    return .{
        .config = config,
        .layers = try layers.toOwnedSlice(allocator),
        .work_oid = work_oid,
        .unstacked_commits = unstacked,
        .base_moved = !std.mem.eql(
            u8,
            base_oid,
            config.anchor_oid,
        ),
        ._refs_storage = raw_refs,
        ._allocator = allocator,
    };
}

/// carve the next stack layer out of the linear rolling branch
/// head, index, working tree and existing branch refs remain untouched
pub fn cut(
    git: *const Git,
    name: []const u8,
    revision: ?[]const u8,
) !void {
    const allocator = git.allocator;
    var snapshot = try inspect(git);
    defer snapshot.deinit();

    const current_ref = try git.currentBranch();
    defer git.allocator.free(current_ref);

    if (!std.mem.eql(u8, current_ref, snapshot.config.work_ref))
        return error.NotOnWorkBranch;

    if (snapshot.base_moved)
        return error.BaseMoved;

    if (name.len == 0)
        return error.InvalidLayerName;

    const new_ref = try std.fmt.allocPrint(
        allocator,
        "refs/heads/stakrr/{s}",
        .{name},
    );
    defer allocator.free(new_ref);

    git.checkRefFormat(new_ref) catch |err| switch (err) {
        error.InvalidRefName => return error.InvalidLayerName,
        else => return err,
    };

    const target = if (revision) |rev|
        try git.resolveCommit(rev)
    else
        try git.allocator.dupe(u8, snapshot.work_oid);
    defer git.allocator.free(target);

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

    try git.createLayerRef(
        new_ref,
        target,
        .{
            .name = snapshot.config.base_ref,
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
