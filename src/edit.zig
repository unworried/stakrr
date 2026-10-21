//! Managed edits. A blob ref journals each step; ref publication and journal
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
    UnknownCut,
    WrongEditWorktree,
    InvalidEditSession,
    EditStateChanged,
    ReplayConflict,
    EditNeedsContinue,
    NoPendingEdit,
    InvalidEditedHistory,
};
pub const Request = union(enum) { jump: ?[]const u8, continue_edit, abort };
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
    _arena: std.heap.ArenaAllocator,

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
    var loaded = (try checkpoint.load(git)) orelse {
        const name = switch (request) {
            .jump => |cut| cut orelse return error.NoEditSession,
            else => return error.NoEditSession,
        };
        var fresh = try begin(git, name);
        try advance(git, &fresh);
        return;
    };
    const s = &loaded.session;
    try checkOwner(git, s);
    try checkRefs(git, s);
    try available(git, s);
    if (request == .abort) {
        try abortSession(git, &loaded);
        return;
    }
    switch (request) {
        .jump => |name| {
            if (s.phase != .editing) return error.EditNeedsContinue;
            const target = if (name) |cut| try destination(s, cut) else null;
            try prepare(git, &loaded, target);
        },
        .continue_edit => {
            if (s.phase == .editing) return error.NoPendingEdit;
        },
        .abort => unreachable,
    }
    try advance(git, &loaded);
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
    return .{
        .active = s.active,
        .phase = std.meta.activeTag(s.phase),
        .origin = s.origin,
        .base = (try stack.parseConfig(s.config)).base_ref,
        .owner = s.owner,
        .destination = if (s.destination()) |i| s.nodes[i].ref_name else s.origin,
        .branches = branches,
        .session_id = s.id,
        ._arena = context.arena,
    };
}

fn begin(git: *const Git, name: []const u8) !Loaded {
    try coordination.requireClean(git);
    try coordination.requireNoGitOperation(git);
    var snapshot = try stack.inspect(git);
    defer snapshot.deinit(git.allocator);
    const origin = try git.currentBranch();
    // Origin may be any existing branch; Git's normal occupancy rules apply.
    const nodes = try git.allocator.alloc(Node, snapshot.layers.len + 1);
    for (snapshot.layers, 0..) |layer, i| nodes[i] = .{
        .ref_name = try git.allocator.dupe(u8, layer.ref_name),
        .original_oid = try git.allocator.dupe(u8, layer.oid),
        .published_oid = try git.allocator.dupe(u8, layer.oid),
        .pending_oid = try git.allocator.dupe(u8, layer.oid),
    };
    nodes[snapshot.layers.len] = .{
        .ref_name = try git.allocator.dupe(u8, snapshot.config.work_ref),
        .original_oid = try git.allocator.dupe(u8, snapshot.work_oid),
        .published_oid = try git.allocator.dupe(u8, snapshot.work_oid),
        .pending_oid = try git.allocator.dupe(u8, snapshot.work_oid),
    };
    var s: Session = .{
        .id = "",
        .owner = try owner(git),
        .origin = origin,
        .config = (try git.configGet(layout.state_key)).?,
        .anchor = try git.allocator.dupe(u8, snapshot.config.anchor_oid),
        .nodes = nodes,
        .active = 0,
        .phase = .{ .switching = null },
    };
    s.active = try destination(&s, name);
    s.phase = .{ .switching = s.active };
    try available(git, &s);
    s.id = try git.writeBlob(try checkpoint.encode(git.allocator, &s));
    var checks: std.ArrayList(Git.RefUpdate) = .empty;
    var retained: std.ArrayList([]const u8) = .empty;
    for (nodes) |node| {
        try checks.append(git.allocator, .{
            .verify = .{
                .name = node.ref_name,
                .oid = node.published_oid,
            },
        });
        try retained.append(git.allocator, node.published_oid);
    }
    try checks.append(git.allocator, .{
        .verify = .{
            .name = layout.tip_ref,
            .oid = s.topCut().published_oid,
        },
    });
    return .{
        .oid = try save(git, &s, null, checks.items, retained.items),
        .session = s,
    };
}

fn prepare(git: *const Git, loaded: *Loaded, target: ?usize) !void {
    const s = &loaded.session;
    try requireBranch(git, s.nodes[s.active].ref_name);
    try coordination.requireClean(git);
    try coordination.requireNoGitOperation(git);
    const edited = try git.resolveCommit("HEAD");
    var retained: []const []const u8 = &.{edited};
    if (eql(edited, s.nodes[s.active].published_oid)) {
        s.phase = .{ .switching = target };
    } else {
        const lower = if (s.active == 0)
            s.anchor
        else
            s.nodes[s.active - 1].published_oid;

        if (eql(lower, edited) or !try git.isAncestor(lower, edited))
            return error.InvalidEditedHistory;

        if (try git.hasMergeCommits(lower, edited))
            return error.InvalidEditedHistory;

        const history = try git.revListParents(
            s.nodes[s.active].published_oid,
            s.workNode().published_oid,
        );

        var queue: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, history, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            try queue.append(git.allocator, fields.next().?);
        }

        const commits = try queue.toOwnedSlice(git.allocator);
        if (commits.len != 0) try requireNoIgnored(git);

        const plan = try git.writeBlobWithFormat(
            try std.mem.join(git.allocator, "\n", commits),
            s.objectFormat(),
        );
        for (s.nodes[s.active..]) |*node| {
            node.pending_oid = if (eql(node.published_oid, s.nodes[s.active].published_oid))
                edited
            else
                node.published_oid;
        }

        s.phase = .{ .detaching = .{
            .destination = target,
            .plan_oid = plan,
            .plan_len = commits.len,
            .before = edited,
        } };

        loaded.plan = commits;
        loaded.ignored_checked = true;
        retained = &.{ edited, plan };
    }
    loaded.oid = try save(git, s, loaded.oid, &.{}, retained);
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
    try coordination.requireClean(git);
    try coordination.requireNoGitOperation(git);
    if (queue.len != 0 and !loaded.ignored_checked) {
        try requireNoIgnored(git);
        loaded.ignored_checked = true;
    }
    if (!eql(try git.resolveCommit("HEAD"), progress.before)) return error.EditStateChanged;
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
    var picking = try git.readRef("CHERRY_PICK_HEAD");
    if (picking == null) {
        try coordination.requireClean(git);
        try coordination.requireNoGitOperation(git);
    }
    // Skip boundaries incorporated before this command was interrupted.
    var boundary = s.active + 1;
    const active_oid = s.nodes[s.active].published_oid;
    while (boundary < s.nodes.len) : (boundary += 1) {
        if (!eql(s.nodes[boundary].published_oid, active_oid)) break;
    }
    for (queue[0..progress.next]) |commit| {
        while (boundary < s.nodes.len and eql(s.nodes[boundary].published_oid, commit))
            boundary += 1;
    }
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
                if (try git.readRef("CHERRY_PICK_HEAD")) |_| {
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
    const target = s.phase.publishing.destination;
    try requireDetached(git);
    try coordination.requireClean(git);
    try coordination.requireNoGitOperation(git);
    if (!eql(try git.resolveCommit("HEAD"), s.phase.publishing.before)) return error.EditStateChanged;
    try checkRefs(git, s);
    try available(git, s);
    var changes: std.ArrayList(Git.RefUpdate) = .empty;
    const old_tip = s.topCut().published_oid;
    for (s.nodes, 0..) |*node, i| {
        const old = if (i == s.active) node.pending_oid else node.published_oid;
        try changes.append(
            git.allocator,
            .{ .update = .{
                .name = node.ref_name,
                .new = node.pending_oid,
                .old = old,
            } },
        );
        node.published_oid = node.pending_oid;
    }
    try changes.append(
        git.allocator,
        .{ .update = .{
            .name = layout.tip_ref,
            .new = s.topCut().published_oid,
            .old = old_tip,
        } },
    );
    s.phase = .{ .switching = target };
    loaded.oid = try save(git, s, loaded.oid, changes.items, &.{});
}

fn switchDestination(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try coordination.requireClean(git);
    try coordination.requireNoGitOperation(git);
    try checkRefs(git, s);
    try available(git, s);
    const target = if (s.phase.switching) |index| s.nodes[index].ref_name else s.origin;
    try git.switchBranch(target);
    if (s.phase.switching) |index| {
        s.active = index;
        s.phase = .editing;
        loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
    } else {
        try git.transact(
            "stakrr: finish edit",
            &.{
                .{ .delete = .{
                    .name = layout.session_ref,
                    .oid = loaded.oid,
                } },
            },
        );
    }
}

fn abortSession(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    // Never use reset --hard: even conflict resolutions belong to the user.
    try coordination.requireClean(git);
    const picking = try git.readRef("CHERRY_PICK_HEAD");
    if (picking) |oid| {
        if (s.phase != .replay and s.phase != .conflict and s.phase != .aborting)
            return error.GitOperationInProgress;
        const progress = s.replay() orelse return error.InvalidEditSession;
        const queue = loaded.plan orelse return error.InvalidEditSession;
        if (progress.next >= queue.len) return error.InvalidEditSession;
        if (!eql(oid, queue[progress.next]) or
            !eql(try git.resolveCommit("HEAD"), progress.before))
            return error.EditStateChanged;
        try coordination.requireNoOtherGitOperation(git);
    } else try coordination.requireNoGitOperation(git);
    if (s.phase != .aborting and s.phase != .aborted) {
        if (s.phase == .editing) {
            try requireBranch(git, s.nodes[s.active].ref_name);
            s.nodes[s.active].pending_oid = try git.resolveCommit("HEAD");
        }
        const progress = s.replay();
        s.phase = .{ .aborting = progress };
        loaded.oid = try save(git, s, loaded.oid, &.{}, &.{try git.resolveCommit("HEAD")});
    }
    if (picking != null) try git.exec(&.{ "cherry-pick", "--quit" });
    if (s.phase == .aborting) {
        try checkRefs(git, s);
        try available(git, s);
        const head = try git.resolveCommit("HEAD");
        try detach(git, head);
        var changes: std.ArrayList(Git.RefUpdate) = .empty;
        const old_tip = s.topCut().published_oid;
        for (s.nodes, 0..) |*node, i| {
            try changes.append(git.allocator, .{ .update = .{
                .name = node.ref_name,
                .new = node.original_oid,
                .old = if (i == s.active) node.pending_oid else node.published_oid,
            } });
            node.published_oid = node.original_oid;
            node.pending_oid = node.original_oid;
        }
        try changes.append(
            git.allocator,
            .{ .update = .{
                .name = layout.tip_ref,
                .new = s.topCut().original_oid,
                .old = old_tip,
            } },
        );
        s.phase = .aborted;
        loaded.oid = try save(git, s, loaded.oid, changes.items, &.{head});
    }
    try available(git, s);
    try git.switchBranch(s.origin);
    try git.transact(
        "stakrr: abort edit",
        &.{
            .{ .delete = .{
                .name = layout.session_ref,
                .oid = loaded.oid,
            } },
        },
    );
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn recoveryName(git: *const Git, s: *const Session, oid: []const u8) ![]const u8 {
    return std.fmt.allocPrint(git.allocator, layout.recovery_prefix ++ "{s}/{s}", .{ s.id, oid });
}

/// Retain every original boundary and every new edit/replay commit. The oid is
/// also the recovery ref's name, so repeated checkpoints are idempotent.
fn save(
    git: *const Git,
    s: *const Session,
    old: ?[]const u8,
    changes: []const Git.RefUpdate,
    retain: []const []const u8,
) ![]const u8 {
    const result = try git.allocator.alloc(u8, s.id.len);
    errdefer git.allocator.free(result);
    var scratch = std.heap.ArenaAllocator.init(git.allocator);
    defer scratch.deinit();
    const scratch_git = git.withAllocator(scratch.allocator());
    const raw = try checkpoint.encode(scratch_git.allocator, s);
    const oid = try scratch_git.writeBlobWithFormat(raw, s.objectFormat());
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(scratch_git.allocator, changes);
    try updates.append(
        scratch_git.allocator,
        .{
            .verify = .{
                .name = layout.anchor_ref,
                .oid = s.anchor,
            },
        },
    );
    try updates.append(scratch_git.allocator, if (old) |previous|
        .{ .update = .{ .name = layout.session_ref, .new = oid, .old = previous } }
    else
        .{ .create = .{ .name = layout.session_ref, .oid = oid } });
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (retain) |commit| {
        const entry = try seen.getOrPut(scratch_git.allocator, commit);
        if (entry.found_existing) continue;
        try updates.append(scratch_git.allocator, .{ .retain = .{
            .name = try recoveryName(&scratch_git, s, commit),
            .oid = commit,
        } });
    }
    try scratch_git.transact("stakrr: edit checkpoint", updates.items);
    @memcpy(result, oid);
    return result;
}

fn destination(s: *const Session, name: []const u8) !usize {
    for (s.nodes[0 .. s.nodes.len - 1], 0..) |node, i| {
        const short = layout.layerName(node.ref_name) orelse continue;
        if (eql(short, name)) return i;
    }
    return error.UnknownCut;
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
    const config = (try git.configGet(layout.state_key)) orelse
        return error.EditStateChanged;
    if (!eql(config, s.config)) return error.EditStateChanged;

    const anchor = (try git.readRef(layout.anchor_ref)) orelse
        return error.EditStateChanged;
    if (!eql(anchor, s.anchor)) return error.EditStateChanged;

    const tip = (try git.readRef(layout.tip_ref)) orelse
        return error.EditStateChanged;
    if (!eql(tip, s.topCut().published_oid)) return error.EditStateChanged;

    var indexes: std.StringHashMapUnmanaged(usize) = .empty;
    for (s.nodes, 0..) |node, i| try indexes.put(git.allocator, node.ref_name, i);
    const layers = (try git.listRefs(layout.layer_prefix)).refs;
    for (layers) |ref| {
        const index = indexes.get(ref.name) orelse
            return error.EditStateChanged;
        if (index == s.nodes.len - 1) return error.InvalidEditSession;
        try checkNode(s, index, ref.oid);
    }
    if (layers.len != s.nodes.len - 1) return error.EditStateChanged;

    const work = (try git.readRef(s.workNode().ref_name)) orelse
        return error.EditStateChanged;
    try checkNode(s, s.nodes.len - 1, work);
}

fn checkNode(s: *const Session, index: usize, actual: []const u8) !void {
    if (s.phase == .editing and index == s.active) return;
    const node = s.nodes[index];
    const expected = if (index == s.active and switch (s.phase) {
        .detaching, .replay, .conflict, .publishing, .aborting => true,
        else => false,
    }) node.pending_oid else node.published_oid;
    if (!eql(actual, expected)) return error.EditStateChanged;
}

fn requireBranch(git: *const Git, ref: []const u8) !void {
    const current = (try git.head()) orelse return error.EditStateChanged;
    if (!eql(current, ref)) return error.EditStateChanged;
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
