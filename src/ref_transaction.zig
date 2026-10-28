//! Write-ahead intent for ref transactions that Git may only partly publish.
const std = @import("std");
const git_mod = @import("git.zig");
const Git = git_mod.Git;
const layout = @import("layout.zig");
const coordination = @import("coordination.zig");

const Change = struct { name: []const u8, old: ?[]const u8, new: ?[]const u8 };
const Tag = struct { oid: []const u8, blob: []const u8 };
const Intent = struct {
    version: u8 = 1,
    label: []const u8,
    changes: []const Change,
    tags: []const Tag = &.{},
};
const Loaded = struct { oid: []const u8, intent: Intent };

pub fn transact(original: *const Git, label: []const u8, updates: []const Git.RefUpdate) !void {
    var arena = std.heap.ArenaAllocator.init(original.allocator);
    defer arena.deinit();
    const scoped = original.withAllocator(arena.allocator());
    const git = &scoped;
    _ = try recover(git);
    const changes = try git.allocator.alloc(Change, updates.len);
    var writes: usize = 0;
    for (updates, changes) |update, *change| {
        change.* = switch (update) {
            .verify => |ref| .{ .name = ref.name, .old = ref.oid, .new = ref.oid },
            .create => |ref| .{ .name = ref.name, .old = null, .new = ref.oid },
            .update => |ref| .{ .name = ref.name, .old = ref.old, .new = ref.new },
            .delete => |ref| .{ .name = ref.name, .old = ref.oid, .new = null },
        };
        if (!equal(change.old, change.new)) writes += 1;
    }
    try validate(git, changes, null);
    // A single ref write already has Git's per-ref atomicity.
    if (writes <= 1) return git.transactRaw(label, updates);

    const saved = try save(git, label, changes);
    const zero = try git.allocator.alloc(u8, saved.len);
    @memset(zero, '0');
    var checks = try expected(git, changes, zero, .old);
    try checks.append(git.allocator, .{ .create = .{ .name = layout.transaction_ref, .oid = saved } });
    try git.transactRaw("stakrr: prepare transaction", checks.items);
    var refused = false;
    git.transactRawWithRefusal(label, updates, &refused) catch |err| {
        // A confirmed prepare refusal cannot have published any refs, even
        // when a competing writer changed an expected value. Otherwise only
        // cancel if every old value still matches; keep partial publication.
        var cancel = if (refused) std.ArrayList(Git.RefUpdate).empty else try expected(git, changes, zero, .old);
        try cancel.append(git.allocator, .{ .delete = .{ .name = layout.transaction_ref, .oid = saved } });
        git.transactRaw("stakrr: cancel transaction", cancel.items) catch {};
        return err;
    };
    try finish(git, saved, changes, zero);
}

/// Call under the common mutation lock, before reading stack/session state.
pub fn recover(original: *const Git) !bool {
    var arena = std.heap.ArenaAllocator.init(original.allocator);
    defer arena.deinit();
    const scoped = original.withAllocator(arena.allocator());
    const git = &scoped;
    const loaded = (try load(git)) orelse return false;
    const saved = loaded.oid;
    const intent = loaded.intent;
    const zero = try git.allocator.alloc(u8, saved.len);
    @memset(zero, '0');
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    var moving: std.ArrayList([]const u8) = .empty;
    var deleting: std.ArrayList([]const u8) = .empty;
    for (intent.changes) |change| {
        const actual = try readExpectedRef(git, change.name);
        if (equal(actual, change.new)) {
            try updates.append(git.allocator, .{ .verify = .{ .name = change.name, .oid = change.new orelse zero } });
        } else if (equal(actual, change.old)) {
            try updates.append(git.allocator, if (change.new) |new|
                if (change.old) |old|
                    .{ .update = .{ .name = change.name, .new = new, .old = old } }
                else
                    .{ .create = .{ .name = change.name, .oid = new } }
            else
                .{ .delete = .{ .name = change.name, .oid = change.old.? } });
            if (std.mem.startsWith(u8, change.name, layout.branch_prefix)) {
                try moving.append(git.allocator, change.name);
                if (equal(change.new, null)) try deleting.append(git.allocator, change.name);
            }
        } else return error.RefTransactionChanged;
    }
    if (moving.items.len != 0) {
        try coordination.requireNoGitOperation(git, .{});
        try coordination.requireAvailable(git, moving.items);
        if (deleting.items.len != 0) try coordination.requireDeletable(git, deleting.items);
    }
    // Tags are archived as blobs, with their targets retained separately.
    // Recreate their exact bytes if pruning ran during the interruption.
    for (intent.tags) |tag| {
        if (!git_mod.isOid(tag.oid) or tag.oid.len != saved.len or
            !git_mod.isOid(tag.blob) or tag.blob.len != saved.len)
            return error.InvalidRefTransaction;
        const tag_path = try std.fmt.allocPrint(git.allocator, "{s}:{s}", .{ saved, tag.oid });
        const data = git.outputRaw(&.{ "cat-file", "blob", tag_path }) catch return error.InvalidRefTransaction;
        if (!std.mem.eql(u8, try git.writeBlob(data), tag.blob)) return error.InvalidRefTransaction;
        const oid = try git.inputOutput(&.{ "hash-object", "-w", "-t", "tag", "--stdin" }, data);
        if (!std.mem.eql(u8, oid, tag.oid)) return error.InvalidRefTransaction;
    }
    try updates.append(git.allocator, .{ .verify = .{ .name = layout.transaction_ref, .oid = saved } });
    try git.transactRaw(intent.label, updates.items);
    try finish(git, saved, intent.changes, zero);
    return true;
}

/// Read-only callers may observe a completed publication awaiting intent cleanup.
pub fn requirePublished(original: *const Git) !void {
    var arena = std.heap.ArenaAllocator.init(original.allocator);
    defer arena.deinit();
    const scoped = original.withAllocator(arena.allocator());
    const git = &scoped;
    const loaded = (try load(git)) orelse return;
    for (loaded.intent.changes) |change| {
        if (!equal(try readExpectedRef(git, change.name), change.new)) return error.RefTransactionPending;
    }
}

/// Returned storage belongs to the caller's command arena.
fn load(git: *const Git) !?Loaded {
    const saved = (try readExpectedRef(git, layout.transaction_ref)) orelse return null;
    const path = try std.fmt.allocPrint(git.allocator, "{s}:transaction.json", .{saved});
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidRefTransaction,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Intent, git.allocator, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRefTransaction,
    };
    const intent = parsed.value;
    if (intent.version != 1 or intent.changes.len == 0) return error.InvalidRefTransaction;
    validate(git, intent.changes, saved.len) catch |err| switch (err) {
        error.InvalidRefName, error.InvalidOid => return error.InvalidRefTransaction,
        else => return err,
    };
    return .{ .oid = saved, .intent = intent };
}

fn readExpectedRef(git: *const Git, name: []const u8) !?[]u8 {
    return git.readRef(name) catch |err| switch (err) {
        error.SymbolicRef => error.RefTransactionChanged,
        else => return err,
    };
}

fn validate(git: *const Git, changes: []const Change, oid_len: ?usize) !void {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (changes) |change| {
        try Git.checkUpdate(change.name, &.{});
        if (std.mem.eql(u8, change.name, layout.transaction_ref) or
            std.mem.startsWith(u8, change.name, layout.transaction_ref ++ "/") or
            (try names.getOrPut(git.allocator, change.name)).found_existing)
            return error.InvalidRefName;
        for ([_]?[]const u8{ change.old, change.new }) |value| {
            if (value) |oid| {
                if (!git_mod.isOid(oid) or (oid_len != null and oid.len != oid_len.?)) return error.InvalidOid;
            }
        }
    }
}

fn expected(git: *const Git, changes: []const Change, zero: []const u8, comptime side: enum { old, new }) !std.ArrayList(Git.RefUpdate) {
    var updates: std.ArrayList(Git.RefUpdate) = .empty;
    for (changes) |change| try updates.append(git.allocator, .{ .verify = .{
        .name = change.name,
        .oid = @field(change, @tagName(side)) orelse zero,
    } });
    return updates;
}

fn finish(git: *const Git, saved: []const u8, changes: []const Change, zero: []const u8) !void {
    var updates = try expected(git, changes, zero, .new);
    try updates.append(git.allocator, .{ .delete = .{ .name = layout.transaction_ref, .oid = saved } });
    try git.transactRaw("stakrr: finish transaction", updates.items);
}

fn save(git: *const Git, label: []const u8, changes: []const Change) ![]const u8 {
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
        if (std.mem.allEqual(u8, oid, '0')) continue; // Git's absent-ref sentinel
        if ((try seen.getOrPut(git.allocator, oid)).found_existing) continue;
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (std.mem.eql(u8, kind, "commit")) {
            try parents.append(git.allocator, oid);
        } else if (std.mem.eql(u8, kind, "tag")) {
            const raw = try git.outputRaw(&.{ "cat-file", "tag", oid });
            const end = std.mem.indexOfScalar(u8, raw, '\n') orelse return error.InvalidGitOutput;
            if (!std.mem.startsWith(u8, raw, "object ") or !git_mod.isOid(raw[7..end])) return error.InvalidGitOutput;
            const blob = try git.writeBlob(raw);
            try entries.append(git.allocator, .{ .name = oid, .oid = blob });
            try tags.append(git.allocator, .{ .oid = oid, .blob = blob });
            try objects.append(git.allocator, raw[7..end]);
        } else if (std.mem.eql(u8, kind, "tree") or std.mem.eql(u8, kind, "blob")) {
            try entries.append(git.allocator, .{ .name = oid, .oid = oid, .tree = std.mem.eql(u8, kind, "tree") });
        } else return error.InvalidGitOutput;
    }
    const intent: Intent = .{ .label = label, .changes = changes, .tags = tags.items };
    const metadata = try git.writeBlob(try std.json.Stringify.valueAlloc(git.allocator, intent, .{}));
    try entries.append(git.allocator, .{ .name = "transaction.json", .oid = metadata });
    // Ref bookkeeping must also work before the user configures an identity.
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.allocator, &.{
        "-c", "user.name=stakrr",                "-c",          "user.email=stakrr@localhost",
        "-c", "commit.gpgsign=false",            "commit-tree", try git.writeTree(entries.items),
        "-m", "stakrr: pending ref transaction",
    });
    for (parents.items) |parent| try args.appendSlice(git.allocator, &.{ "-p", parent });
    return git.output(args.items);
}

fn equal(a: ?[]const u8, b: ?[]const u8) bool {
    const left: ?[]const u8 = if (a) |oid| if (std.mem.allEqual(u8, oid, '0')) null else oid else null;
    const right: ?[]const u8 = if (b) |oid| if (std.mem.allEqual(u8, oid, '0')) null else oid else null;
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}
