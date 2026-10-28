//! Write-ahead intent for ref transactions that Git may only partly publish.
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const types = @import("git_types.zig");
const Oid = types.Oid;
const RefUpdate = types.RefUpdate;
const mutation_mod = @import("mutation.zig");
const Mutation = mutation_mod.Mutation;
const backend = @import("ref_backend.zig");
const layout = @import("layout.zig");
const coordination = @import("coordination.zig");
const intent_name = types.RefName.init(layout.transaction_ref) catch unreachable;

// Wire fields stay hexadecimal strings; live publication uses validated values.
const Change = struct { name: []const u8, old: ?[]const u8, new: ?[]const u8 };
const Tag = struct { oid: []const u8, blob: []const u8 };
const Intent = struct {
    version: u8 = layout.transaction_version,
    label: []const u8,
    changes: []const Change,
    tags: []const Tag = &.{},
    current_branch: ?[]const u8 = null,
    owner: ?[]const u8 = null,
};
const Loaded = struct { oid: Oid, intent: Intent, updates: []const RefUpdate };

pub fn transact(mutation: *const Mutation, options: types.PublishOptions) !void {
    var arena = std.heap.ArenaAllocator.init(mutation.repo().allocator);
    defer arena.deinit();
    const scoped = mutation.repo().withAllocator(arena.allocator());
    const git = &scoped;
    // Recovery belongs to acquisition, before the workflow observes its state.
    if (try readExpectedRef(git, intent_name) != null) return error.RefTransactionPending;
    try mutation_mod.validatePublication(git, options.updates, options.current_branch);
    try validateNames(git, options.updates);
    const changes = try git.allocator.alloc(Change, options.updates.len);
    var writes: usize = 0;
    for (options.updates, changes) |update, *change| {
        change.* = .{
            .name = update.name().bytes,
            .old = if (update.oldOid()) |oid| try oid.dupeHex(git.allocator) else null,
            .new = if (update.newOid()) |oid| try oid.dupeHex(git.allocator) else null,
        };
        if (update.writes()) writes += 1;
    }
    // A single ref write already has Git's per-ref atomicity.
    if (writes <= 1) return backend.publish(git, options.message, options.updates);

    const saved = try git.parseOid(try save(git, options.message, changes, options.current_branch));
    var checks = try expected(git, options.updates, .old);
    try checks.append(git.allocator, .{ .create = .{ .name = intent_name, .new = saved } });
    try backend.publish(git, "stakrr: prepare transaction", checks.items);
    var refused = false;
    publishUpdates(git, options, &refused) catch |err| {
        // A confirmed refusal cannot have published any refs. Otherwise cancel
        // only when every old value still matches, preserving partial writes.
        var cancel = if (refused) std.ArrayList(RefUpdate).empty else try expected(git, options.updates, .old);
        try cancel.append(git.allocator, .{ .delete = .{ .name = intent_name, .old = saved } });
        backend.publish(git, "stakrr: cancel transaction", cancel.items) catch {};
        return err;
    };
    try finish(git, saved, options.updates);
}

fn publishUpdates(git: *const Git, options: types.PublishOptions, refused: *bool) !void {
    refused.* = true; // a failed preflight has not sent a commit
    try mutation_mod.validatePublication(git, options.updates, options.current_branch);
    try backend.publishWithRefusal(git, options.message, options.updates, refused);
}

/// Only acquisition calls recovery, while already holding the common lock.
pub fn recover(mutation: *const Mutation) !bool {
    var arena = std.heap.ArenaAllocator.init(mutation.repo().allocator);
    defer arena.deinit();
    const scoped = mutation.repo().withAllocator(arena.allocator());
    const git = &scoped;
    const loaded = (try load(git)) orelse return false;
    var remaining: std.ArrayList(RefUpdate) = .empty;
    var moves_branch = false;
    for (loaded.updates) |update| {
        const actual = try readExpectedRef(git, update.name());
        if (types.equalOids(actual, update.newOid())) {
            try remaining.append(git.allocator, .{ .verify = .{ .name = update.name(), .expected = update.newOid() } });
        } else if (types.equalOids(actual, update.oldOid())) {
            try remaining.append(git.allocator, update);
            if (std.mem.startsWith(u8, update.name().bytes, layout.branch_prefix)) moves_branch = true;
        } else return error.RefTransactionChanged;
    }
    if (moves_branch) try coordination.requireNoGitOperation(git, .{});
    const policy = try recoveryPolicy(git, loaded.intent);
    try mutation_mod.validatePublication(git, remaining.items, policy);
    // Tags are archived as blobs, with their targets retained separately.
    // Recreate their exact bytes if pruning ran during the interruption.
    for (loaded.intent.tags) |tag| {
        const tag_oid = Oid.init(loaded.oid.format, tag.oid) catch return error.InvalidRefTransaction;
        const blob_oid = Oid.init(loaded.oid.format, tag.blob) catch return error.InvalidRefTransaction;
        const tag_path = try std.fmt.allocPrint(git.allocator, "{s}:{s}", .{ loaded.oid.hex(), tag_oid.hex() });
        const data = git.outputRaw(&.{ "cat-file", "blob", tag_path }) catch |err| switch (err) {
            error.GitFailed => return error.InvalidRefTransaction,
            else => return err,
        };
        if (!std.mem.eql(u8, try git.writeBlob(data), blob_oid.hex())) return error.InvalidRefTransaction;
        const oid = try git.inputOutput(&.{ "hash-object", "-w", "-t", "tag", "--stdin" }, data);
        if (!std.mem.eql(u8, oid, tag_oid.hex())) return error.InvalidRefTransaction;
    }
    try remaining.append(git.allocator, .{ .verify = .{ .name = intent_name, .expected = loaded.oid } });
    try backend.publish(git, loaded.intent.label, remaining.items);
    try finish(git, loaded.oid, loaded.updates);
    return true;
}

fn recoveryPolicy(git: *const Git, intent: Intent) !types.CurrentBranchPolicy {
    const branch = intent.current_branch orelse return .forbid;
    const owner = try git.path(&.{ "rev-parse", "--absolute-git-dir" });
    if (!std.mem.eql(u8, owner, intent.owner.?)) return .forbid;
    return .{ .allow = try types.BranchRef.init(branch) };
}

/// Read-only callers may observe a completed publication awaiting intent cleanup.
pub fn requirePublished(original: *const Git) !void {
    var arena = std.heap.ArenaAllocator.init(original.allocator);
    defer arena.deinit();
    var scoped = original.withAllocator(arena.allocator());
    scoped.object_format = try original.objectFormat();
    const git = &scoped;
    const loaded = (try load(git)) orelse return;
    for (loaded.updates) |update| {
        if (!types.equalOids(try readExpectedRef(git, update.name()), update.newOid()))
            return error.RefTransactionPending;
    }
}

/// Returned names and metadata belong to the caller's command arena.
fn load(git: *const Git) !?Loaded {
    const saved = (try readExpectedRef(git, intent_name)) orelse return null;
    const path = try std.fmt.allocPrint(git.allocator, "{s}:transaction.json", .{saved.hex()});
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidRefTransaction,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Intent, git.allocator, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRefTransaction,
    };
    const intent = parsed.value;
    if (intent.version != layout.transaction_version or intent.changes.len == 0)
        return error.InvalidRefTransaction;
    if (intent.current_branch) |branch| {
        _ = types.BranchRef.init(branch) catch return error.InvalidRefTransaction;
        if (intent.owner == null or intent.owner.?.len == 0)
            return error.InvalidRefTransaction;
    } else if (intent.owner != null) return error.InvalidRefTransaction;
    const updates = try git.allocator.alloc(RefUpdate, intent.changes.len);
    for (intent.changes, updates) |change, *update| {
        const name = types.RefName.init(change.name) catch return error.InvalidRefTransaction;
        const old = try decodeOid(saved.format, change.old);
        const new = try decodeOid(saved.format, change.new);
        update.* = if (types.equalOids(old, new))
            .{ .verify = .{ .name = name, .expected = old } }
        else if (new) |oid|
            if (old) |previous|
                .{ .update = .{ .name = name, .old = previous, .new = oid } }
            else
                .{ .create = .{ .name = name, .new = oid } }
        else
            .{ .delete = .{ .name = name, .old = old.? } };
    }
    validateNames(git, updates) catch |err| switch (err) {
        error.InvalidRefName => return error.InvalidRefTransaction,
        else => return err,
    };
    // Validate every tag before recovery creates even an unreachable object.
    for (intent.tags) |tag| {
        _ = Oid.init(saved.format, tag.oid) catch return error.InvalidRefTransaction;
        _ = Oid.init(saved.format, tag.blob) catch return error.InvalidRefTransaction;
    }
    return .{ .oid = saved, .intent = intent, .updates = updates };
}

fn decodeOid(format: types.ObjectFormat, value: ?[]const u8) !?Oid {
    const hex = value orelse return null;
    return Oid.init(format, hex) catch return error.InvalidRefTransaction;
}

fn readExpectedRef(git: *const Git, name: types.RefName) !?Oid {
    return git.readDirectRef(name) catch |err| switch (err) {
        error.SymbolicRef => error.RefTransactionChanged,
        else => return err,
    };
}

fn validateNames(git: *const Git, updates: []const RefUpdate) !void {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(git.allocator);
    for (updates) |update| {
        const name = update.name().bytes;
        _ = try types.RefName.init(name);
        if (std.mem.eql(u8, name, layout.transaction_ref) or
            std.mem.startsWith(u8, name, layout.transaction_ref ++ "/") or
            (try names.getOrPut(git.allocator, name)).found_existing)
            return error.InvalidRefName;
    }
}

fn expected(git: *const Git, changes: []const RefUpdate, comptime side: enum { old, new }) !std.ArrayList(RefUpdate) {
    var updates: std.ArrayList(RefUpdate) = .empty;
    for (changes) |change| try updates.append(git.allocator, .{ .verify = .{
        .name = change.name(),
        .expected = if (side == .old) change.oldOid() else change.newOid(),
    } });
    return updates;
}

fn finish(git: *const Git, saved: Oid, changes: []const RefUpdate) !void {
    var updates = try expected(git, changes, .new);
    try updates.append(git.allocator, .{ .delete = .{ .name = intent_name, .old = saved } });
    try backend.publish(git, "stakrr: finish transaction", updates.items);
}

fn save(git: *const Git, label: []const u8, changes: []const Change, policy: types.CurrentBranchPolicy) ![]const u8 {
    var objects: std.ArrayList([]const u8) = .empty;
    for (changes) |change| {
        if (change.old) |oid| try objects.append(git.allocator, oid);
        if (change.new) |oid| try objects.append(git.allocator, oid);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var parents: std.ArrayList([]const u8) = .empty;
    var entries: std.ArrayList(Git.TreeEntry) = .empty;
    var tags: std.ArrayList(Tag) = .empty;
    var i: usize = 0;
    while (i < objects.items.len) : (i += 1) {
        const oid = objects.items[i];
        if ((try seen.getOrPut(git.allocator, oid)).found_existing) continue;
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (std.mem.eql(u8, kind, "commit")) {
            try parents.append(git.allocator, oid);
        } else if (std.mem.eql(u8, kind, "tag")) {
            const raw = try git.outputRaw(&.{ "cat-file", "tag", oid });
            const end = std.mem.indexOfScalar(u8, raw, '\n') orelse return error.InvalidGitOutput;
            if (!std.mem.startsWith(u8, raw, "object ")) return error.InvalidGitOutput;
            _ = Oid.init(try git.objectFormat(), raw[7..end]) catch return error.InvalidGitOutput;
            const blob = try git.writeBlob(raw);
            try entries.append(git.allocator, .{ .name = oid, .oid = blob });
            try tags.append(git.allocator, .{ .oid = oid, .blob = blob });
            try objects.append(git.allocator, raw[7..end]);
        } else if (std.mem.eql(u8, kind, "tree") or std.mem.eql(u8, kind, "blob")) {
            try entries.append(git.allocator, .{ .name = oid, .oid = oid, .tree = std.mem.eql(u8, kind, "tree") });
        } else return error.InvalidGitOutput;
    }
    const allowed: ?types.BranchRef = switch (policy) {
        .forbid => null,
        .allow => |branch| branch,
    };
    const intent: Intent = .{
        .label = label,
        .changes = changes,
        .tags = tags.items,
        .current_branch = if (allowed) |branch| branch.name.bytes else null,
        .owner = if (allowed != null) try git.path(&.{ "rev-parse", "--absolute-git-dir" }) else null,
    };
    const metadata = try git.writeBlob(try std.json.Stringify.valueAlloc(git.allocator, intent, .{}));
    try entries.append(git.allocator, .{ .name = "transaction.json", .oid = metadata });
    // Ref bookkeeping must also work before the user configures an identity.
    return git.commitTreeWithOptions(try git.writeTree(entries.items), parents.items, "stakrr: pending ref transaction", .{
        .identity = .{ .name = "stakrr", .email = "stakrr@localhost" },
    });
}
