//! Managed edits. A blob ref journals each step; ref publication and journal
//! advancement share a compare-and-swap transaction. Replay runs detached so
//! branch boundaries remain untouched until the complete replay is available.
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const stack = @import("stack.zig");
const state = @import("state.zig");

pub const Error = error{
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
const Phase = enum { switching, editing, detaching, replay, conflict, publishing, aborting, aborted };
const Node = struct {
    ref_name: []const u8,
    original: []const u8,
    oid: []const u8,
    result: []const u8,
};
const Session = struct {
    version: u8 = 1,
    id: []const u8,
    owner: []const u8,
    origin: []const u8,
    config: []const u8,
    anchor: []const u8,
    nodes: []Node, // ordered cuts, then rolling work
    active: usize,
    destination: ?usize,
    phase: Phase,
    // The immutable queue is stored once, rather than rewritten per commit.
    queue_oid: ?[]const u8 = null,
    queue_len: usize = 0,
    next: usize = 0,
    before: []const u8,

    fn workNode(self: *const Session) *const Node {
        return &self.nodes[self.nodes.len - 1];
    }

    fn topCut(self: *const Session) *const Node {
        return &self.nodes[self.nodes.len - 2];
    }

    fn objectFormat(self: *const Session) Git.ObjectFormat {
        return if (self.id.len == 40) .sha1 else .sha256;
    }
};
const Loaded = struct { oid: []const u8, session: Session };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// All temporary command data lives in one arena; Git's public API still uses
// the caller's allocator, including when invoked by leak-checked tests.
fn load(git: *const Git) !?Loaded {
    const oid = (try git.readRef(state.session_ref)) orelse return null;
    const raw = try git.output(&.{ "cat-file", "blob", oid });
    const parsed = std.json.parseFromSlice(Session, git.allocator, raw, .{ .allocate = .alloc_always }) catch
        return error.InvalidEditSession;
    const s = parsed.value;
    if (s.version != 1 or !git_mod.isOid(s.id) or !git_mod.isOid(s.anchor) or
        !git_mod.isOid(s.before) or !git_mod.isSafeBranchRef(s.origin) or
        s.nodes.len < 2 or s.active >= s.nodes.len - 1 or
        s.next > s.queue_len) return error.InvalidEditSession;
    if (s.destination) |index| {
        if (index >= s.nodes.len - 1) return error.InvalidEditSession;
    }
    for (s.nodes, 0..) |node, i| {
        if (!git_mod.isSafeBranchRef(node.ref_name) or
            !git_mod.isOid(node.original) or !git_mod.isOid(node.oid) or
            !git_mod.isOid(node.result)) return error.InvalidEditSession;
        if (i < s.nodes.len - 1 and !std.mem.startsWith(u8, node.ref_name, git_mod.layer_prefix))
            return error.InvalidEditSession;
        for (s.nodes[0..i]) |previous| {
            if (eql(previous.ref_name, node.ref_name)) return error.InvalidEditSession;
        }
    }
    if (s.queue_oid) |plan| {
        if (!git_mod.isOid(plan)) return error.InvalidEditSession;
    } else if (s.queue_len != 0) return error.InvalidEditSession;
    return .{ .oid = oid, .session = s };
}

fn recoveryName(git: *const Git, s: *const Session, oid: []const u8) ![]const u8 {
    return std.fmt.allocPrint(git.allocator, "refs/stakrr/recovery/{s}/{s}", .{ s.id, oid });
}

/// Retain every original boundary and every new edit/replay commit. The oid is
/// also the recovery ref's name, so repeated checkpoints are idempotent.
fn save(git: *const Git, s: *const Session, old: ?[]const u8, changes: []const Git.RefUpdate, retain: []const []const u8) ![]const u8 {
    const result = try git.allocator.alloc(u8, s.id.len);
    errdefer git.allocator.free(result);
    var scratch = std.heap.ArenaAllocator.init(git.allocator);
    defer scratch.deinit();
    var scratch_git = git.*;
    scratch_git.allocator = scratch.allocator();
    const raw = try std.json.Stringify.valueAlloc(scratch_git.allocator, s.*, .{});
    const oid = try scratch_git.writeBlobWithFormat(raw, s.objectFormat());
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    try updates.appendSlice(scratch_git.allocator, changes);
    try updates.append(scratch_git.allocator, .{ .verify = .{ .name = git_mod.anchor_ref, .oid = s.anchor } });
    try updates.append(scratch_git.allocator, if (old) |previous|
        .{ .update = .{ .name = state.session_ref, .new = oid, .old = previous } }
    else
        .{ .create = .{ .name = state.session_ref, .oid = oid } });
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
        if (eql(node.ref_name[git_mod.layer_prefix.len..], name)) return i;
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
    try state.requireAvailable(git, refs);
}

fn checkRefs(git: *const Git, s: *const Session) !void {
    const config = (try git.configGet(stack.state_key)) orelse return error.EditStateChanged;
    if (!eql(config, s.config)) return error.EditStateChanged;
    const anchor = (try git.readRef(git_mod.anchor_ref)) orelse return error.EditStateChanged;
    if (!eql(anchor, s.anchor)) return error.EditStateChanged;
    const tip = (try git.readRef(git_mod.tip_ref)) orelse return error.EditStateChanged;
    if (!eql(tip, s.topCut().oid)) return error.EditStateChanged;
    var indexes: std.StringHashMapUnmanaged(usize) = .empty;
    for (s.nodes, 0..) |node, i| try indexes.put(git.allocator, node.ref_name, i);
    const raw = try git.listStackRefs();
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidGitOutput;
        const index = indexes.get(line[0..tab]) orelse return error.EditStateChanged;
        if (index == s.nodes.len - 1) return error.InvalidEditSession;
        try checkNode(s, index, line[tab + 1 ..]);
        count += 1;
    }
    if (count != s.nodes.len - 1) return error.EditStateChanged;
    const work = (try git.readRef(s.workNode().ref_name)) orelse return error.EditStateChanged;
    try checkNode(s, s.nodes.len - 1, work);
}

fn checkNode(s: *const Session, index: usize, actual: []const u8) !void {
    if (s.phase == .editing and index == s.active) return;
    const node = s.nodes[index];
    const expected = if (index == s.active and switch (s.phase) {
        .detaching, .replay, .conflict, .publishing, .aborting => true,
        else => false,
    }) node.result else node.oid;
    if (!eql(actual, expected)) return error.EditStateChanged;
}

fn requireBranch(git: *const Git, ref: []const u8) !void {
    const current = git.currentBranch() catch |err| switch (err) {
        error.DetachedHead => return error.EditStateChanged,
        else => return err,
    };
    if (!eql(current, ref)) return error.EditStateChanged;
}

fn requireDetached(git: *const Git) !void {
    _ = git.currentBranch() catch |err| switch (err) {
        error.DetachedHead => return,
        else => return err,
    };
    return error.EditStateChanged;
}

fn detach(git: *const Git, oid: []const u8) !void {
    try git.exec(&.{ "switch", "--quiet", "--no-overwrite-ignore", "--detach", oid });
}

fn begin(git: *const Git, name: []const u8) !Loaded {
    try state.requireClean(git);
    try state.requireNoGitOperation(git);
    var snapshot = try stack.inspect(git);
    defer snapshot.deinit(git.allocator);
    const origin = try git.currentBranch();
    // Origin may be any existing branch; Git's normal occupancy rules apply.
    const nodes = try git.allocator.alloc(Node, snapshot.layers.len + 1);
    for (snapshot.layers, 0..) |layer, i| nodes[i] = .{
        .ref_name = try git.allocator.dupe(u8, layer.ref_name),
        .original = try git.allocator.dupe(u8, layer.oid),
        .oid = try git.allocator.dupe(u8, layer.oid),
        .result = try git.allocator.dupe(u8, layer.oid),
    };
    nodes[snapshot.layers.len] = .{
        .ref_name = try git.allocator.dupe(u8, snapshot.config.work_ref),
        .original = try git.allocator.dupe(u8, snapshot.work_oid),
        .oid = try git.allocator.dupe(u8, snapshot.work_oid),
        .result = try git.allocator.dupe(u8, snapshot.work_oid),
    };
    var s: Session = .{
        .id = "",
        .owner = try owner(git),
        .origin = origin,
        .config = (try git.configGet(stack.state_key)).?,
        .anchor = try git.allocator.dupe(u8, snapshot.config.anchor_oid),
        .nodes = nodes,
        .active = 0,
        .destination = null,
        .phase = .switching,
        .before = try git.allocator.dupe(u8, snapshot.work_oid),
    };
    s.active = try destination(&s, name);
    s.destination = s.active;
    try available(git, &s);
    s.id = try git.writeBlob(try std.json.Stringify.valueAlloc(git.allocator, s, .{}));
    var checks: std.ArrayList(Git.RefUpdate) = .empty;
    var retained: std.ArrayList([]const u8) = .empty;
    for (nodes) |node| {
        try checks.append(git.allocator, .{ .verify = .{ .name = node.ref_name, .oid = node.oid } });
        try retained.append(git.allocator, node.oid);
    }
    try checks.append(git.allocator, .{ .verify = .{ .name = git_mod.tip_ref, .oid = s.topCut().oid } });
    return .{ .oid = try save(git, &s, null, checks.items, retained.items), .session = s };
}

/// Entry point for both the library and CLI. Lock lifetime covers one command;
/// the persistent session excludes other mutations between commands.
pub fn run(original_git: *const Git, request: Request) !void {
    var arena = std.heap.ArenaAllocator.init(original_git.allocator);
    defer arena.deinit();
    var git = original_git.*;
    git.allocator = arena.allocator();
    try git.ensureWorkTree();
    const guard = try state.lock(&git);
    defer guard.close(git.io);
    var loaded = (try load(&git)) orelse {
        const name = switch (request) {
            .jump => |cut| cut orelse return error.NoEditSession,
            else => return error.NoEditSession,
        };
        var fresh = try begin(&git, name);
        try advance(&git, &fresh);
        return;
    };
    const s = &loaded.session;
    try checkOwner(&git, s);
    try checkRefs(&git, s);
    try available(&git, s);
    if (request == .abort) {
        try abortSession(&git, &loaded);
        return;
    }
    switch (request) {
        .jump => |name| {
            if (s.phase != .editing) return error.EditNeedsContinue;
            const target = if (name) |cut| try destination(s, cut) else null;
            try prepare(&git, &loaded, target);
        },
        .continue_edit => {
            if (s.phase == .editing) return error.NoPendingEdit;
        },
        .abort => unreachable,
    }
    try advance(&git, &loaded);
}

fn prepare(git: *const Git, loaded: *Loaded, target: ?usize) !void {
    const s = &loaded.session;
    try requireBranch(git, s.nodes[s.active].ref_name);
    try state.requireClean(git);
    try state.requireNoGitOperation(git);
    const edited = try git.resolveCommit("HEAD");
    s.destination = target;
    if (eql(edited, s.nodes[s.active].oid)) {
        s.phase = .switching;
    } else {
        const lower = if (s.active == 0) s.anchor else s.nodes[s.active - 1].oid;
        if (eql(lower, edited) or !try git.isAncestor(lower, edited)) return error.InvalidEditedHistory;
        if (try git.hasMergeCommits(lower, edited)) return error.InvalidEditedHistory;
        const history = try git.revListParents(s.nodes[s.active].oid, s.workNode().oid);
        var queue: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, history, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            try queue.append(git.allocator, fields.next().?);
        }
        const commits = try queue.toOwnedSlice(git.allocator);
        s.queue_oid = try git.writeBlobWithFormat(try std.mem.join(git.allocator, "\n", commits), s.objectFormat());
        s.queue_len = commits.len;
        s.next = 0;
        s.before = edited;
        for (s.nodes[s.active..]) |*node| {
            node.result = if (eql(node.oid, s.nodes[s.active].oid)) edited else node.oid;
        }
        s.phase = .detaching;
    }
    loaded.oid = try save(git, s, loaded.oid, &.{}, if (s.queue_oid) |plan| &.{ edited, plan } else &.{edited});
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

// The plan and its slices live in the command arena, like the loaded session.
// Validate the entire queue for both replay and abort before changing Git state.
fn loadReplayPlan(git: *const Git, s: *const Session) ![]const []const u8 {
    const oid = s.queue_oid orelse return error.InvalidEditSession;
    const plan = try git.output(&.{ "cat-file", "blob", oid });
    var queue: std.ArrayList([]const u8) = .empty;
    var commits = std.mem.tokenizeScalar(u8, plan, '\n');
    while (commits.next()) |commit| {
        if (!git_mod.isOid(commit)) return error.InvalidEditSession;
        try queue.append(git.allocator, commit);
    }
    if (queue.items.len != s.queue_len) return error.InvalidEditSession;
    return queue.items;
}

fn detachForReplay(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try state.requireClean(git);
    try state.requireNoGitOperation(git);
    if (!eql(try git.resolveCommit("HEAD"), s.before)) return error.EditStateChanged;
    try detach(git, s.before);
    s.phase = .replay;
    loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
}

// Checkpoints bracket each cherry-pick. If a process exits after Git commits
// but before the checkpoint, HEAD's single parent identifies the completed step.
fn replayDescendants(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try requireDetached(git);
    const queue = try loadReplayPlan(git, s);
    var head = try git.resolveCommit("HEAD");
    var picking = try git.readRef("CHERRY_PICK_HEAD");
    if (picking == null) {
        try state.requireClean(git);
        try state.requireNoGitOperation(git);
    }
    while (s.next < queue.len) {
        const commit = queue[s.next];
        if (picking) |oid| {
            if (!eql(oid, commit) or !eql(head, s.before)) return error.EditStateChanged;
            try requireResolution(git);
            // One commit per pick: commit clears CHERRY_PICK_HEAD and also
            // preserves a resolution that makes the patch empty.
            try git.exec(&.{ "-c", "core.editor=true", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "--allow-empty-message", "--no-edit" });
            head = try git.resolveCommit("HEAD");
            picking = null;
        } else if (eql(head, s.before)) {
            try protectIgnored(git, commit);
            git.exec(&.{ "-c", "core.hooksPath=/dev/null", "-c", "rerere.enabled=false", "cherry-pick", "--no-gpg-sign", "--allow-empty", "--allow-empty-message", "--keep-redundant-commits", commit }) catch |err| {
                if (try git.readRef("CHERRY_PICK_HEAD")) |_| {
                    s.phase = .conflict;
                    loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
                    return error.ReplayConflict;
                }
                return err;
            };
            head = try git.resolveCommit("HEAD");
        } else {
            // Only the first step after a restart may already be committed.
            const parent = try git.output(&.{ "rev-list", "--parents", "-n", "1", head });
            const expected = try std.fmt.allocPrint(git.allocator, "{s} {s}", .{ head, s.before });
            if (!eql(parent, expected)) return error.EditStateChanged;
        }
        for (s.nodes[s.active + 1 ..]) |*node| {
            if (eql(node.oid, commit)) node.result = head;
        }
        s.phase = .replay;
        s.before = head;
        s.next += 1;
        loaded.oid = try save(git, s, loaded.oid, &.{}, &.{head});
    }
    s.phase = .publishing;
    loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
}

fn publishResults(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try requireDetached(git);
    try state.requireClean(git);
    try state.requireNoGitOperation(git);
    if (!eql(try git.resolveCommit("HEAD"), s.before)) return error.EditStateChanged;
    try checkRefs(git, s);
    try available(git, s);
    var changes: std.ArrayList(Git.RefUpdate) = .empty;
    const old_tip = s.topCut().oid;
    for (s.nodes, 0..) |*node, i| {
        const old = if (i == s.active) node.result else node.oid;
        try changes.append(git.allocator, .{ .update = .{ .name = node.ref_name, .new = node.result, .old = old } });
        node.oid = node.result;
    }
    try changes.append(git.allocator, .{ .update = .{ .name = git_mod.tip_ref, .new = s.topCut().oid, .old = old_tip } });
    s.phase = .switching;
    loaded.oid = try save(git, s, loaded.oid, changes.items, &.{});
}

fn switchDestination(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    try state.requireClean(git);
    try state.requireNoGitOperation(git);
    try checkRefs(git, s);
    try available(git, s);
    const target = if (s.destination) |index| s.nodes[index].ref_name else s.origin;
    try git.switchBranch(target);
    if (s.destination) |index| {
        s.active = index;
        s.phase = .editing;
        s.queue_oid = null;
        s.queue_len = 0;
        s.next = 0;
        loaded.oid = try save(git, s, loaded.oid, &.{}, &.{});
    } else {
        try git.transact("stakrr: finish edit", &.{.{ .delete = .{ .name = state.session_ref, .oid = loaded.oid } }});
    }
}

// Unlike switch --no-overwrite-ignore, cherry-pick silently replaces ignored
// files. Check its affected paths before letting the merge touch the worktree.
fn protectIgnored(git: *const Git, commit: []const u8) !void {
    const ignored = try git.output(&.{ "ls-files", "--others", "--ignored", "--exclude-standard", "--full-name", "-z", "--", ":/" });
    defer git.allocator.free(ignored);
    if (ignored.len == 0) return;
    const changed = try git.output(&.{ "diff-tree", "--no-commit-id", "--name-only", "-r", "-z", commit });
    defer git.allocator.free(changed);
    var files = std.mem.tokenizeScalar(u8, ignored, 0);
    while (files.next()) |file| {
        var paths = std.mem.tokenizeScalar(u8, changed, 0);
        while (paths.next()) |path| {
            if (eql(file, path) or
                (std.mem.startsWith(u8, file, path) and file.len > path.len and file[path.len] == '/') or
                (std.mem.startsWith(u8, path, file) and path.len > file.len and path[file.len] == '/'))
                return error.DirtyWorkTree;
        }
    }
}

/// Only staged resolutions are accepted. Unstaged/untracked files must be
/// preserved explicitly before continuing, just as for an ordinary transition.
fn requireResolution(git: *const Git) !void {
    const unresolved = try git.output(&.{ "diff", "--name-only", "--diff-filter=U" });
    if (unresolved.len != 0) return error.ReplayConflict;
    const diff = try git.run(&.{ "diff", "--quiet" });
    if (!diff.term.success()) return error.DirtyWorkTree;
    const untracked = try git.output(&.{ "ls-files", "--others", "--exclude-standard", "--full-name", "--", ":/" });
    if (untracked.len != 0) return error.DirtyWorkTree;
}

fn abortSession(git: *const Git, loaded: *Loaded) !void {
    const s = &loaded.session;
    // Never use reset --hard: even conflict resolutions belong to the user.
    try state.requireClean(git);
    const picking = try git.readRef("CHERRY_PICK_HEAD");
    if (picking) |oid| {
        if (s.phase != .replay and s.phase != .conflict and s.phase != .aborting)
            return error.GitOperationInProgress;
        const queue = try loadReplayPlan(git, s);
        if (s.next >= queue.len) return error.InvalidEditSession;
        if (!eql(oid, queue[s.next]) or
            !eql(try git.resolveCommit("HEAD"), s.before)) return error.EditStateChanged;
        try state.requireNoOtherGitOperation(git);
    } else try state.requireNoGitOperation(git);
    if (s.phase != .aborting and s.phase != .aborted) {
        if (s.phase == .editing) {
            try requireBranch(git, s.nodes[s.active].ref_name);
            s.nodes[s.active].result = try git.resolveCommit("HEAD");
        }
        s.phase = .aborting;
        loaded.oid = try save(git, s, loaded.oid, &.{}, &.{try git.resolveCommit("HEAD")});
    }
    if (picking != null) try git.exec(&.{ "cherry-pick", "--quit" });
    if (s.phase == .aborting) {
        try checkRefs(git, s);
        try available(git, s);
        const head = try git.resolveCommit("HEAD");
        try detach(git, head);
        var changes: std.ArrayList(Git.RefUpdate) = .empty;
        const old_tip = s.topCut().oid;
        for (s.nodes, 0..) |*node, i| {
            try changes.append(git.allocator, .{ .update = .{
                .name = node.ref_name,
                .new = node.original,
                .old = if (i == s.active) node.result else node.oid,
            } });
            node.oid = node.original;
            node.result = node.original;
        }
        try changes.append(git.allocator, .{ .update = .{ .name = git_mod.tip_ref, .new = s.topCut().original, .old = old_tip } });
        s.phase = .aborted;
        loaded.oid = try save(git, s, loaded.oid, changes.items, &.{head});
    }
    try available(git, s);
    try git.switchBranch(s.origin);
    try git.transact("stakrr: abort edit", &.{.{ .delete = .{ .name = state.session_ref, .oid = loaded.oid } }});
}

/// Active sessions may intentionally have divergent cut/work refs, so status
/// uses the saved order instead of asking inspect() to validate a linear stack.
pub fn printStatus(original_git: *const Git, out: *std.Io.Writer) !bool {
    var arena = std.heap.ArenaAllocator.init(original_git.allocator);
    defer arena.deinit();
    var git = original_git.*;
    git.allocator = arena.allocator();
    try git.ensureWorkTree();
    const loaded = (try load(&git)) orelse return false;
    const s = &loaded.session;
    try out.print("edit: {s} ({s})\n", .{ s.nodes[s.active].ref_name[git_mod.layer_prefix.len..], @tagName(s.phase) });
    try out.print("origin: {s}\nworktree: {s}\n", .{ s.origin["refs/heads/".len..], s.owner });
    if (s.phase != .editing) {
        try out.print("pending: {s}\n", .{if (s.destination) |i| s.nodes[i].ref_name["refs/heads/".len..] else s.origin["refs/heads/".len..]});
        try out.writeAll("resolve conflicts, git add, then stakrr edit --continue; preserve uncommitted work before stakrr edit --abort\n");
    }
    var i = s.nodes.len;
    while (i > 0) {
        i -= 1;
        try out.print("  {s} {s}\n", .{ if (i == s.active) ">" else "|", s.nodes[i].ref_name["refs/heads/".len..] });
    }
    try out.print("recovery: refs/stakrr/recovery/{s}/\n", .{s.id});
    return true;
}
