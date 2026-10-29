//! Completed operations are history, never resumable execution state.
const std = @import("std");
const Git = @import("git.zig").Git;
const layout = @import("layout.zig");
pub const Move = struct { name: []const u8, before: []const u8, after: ?[]const u8 };
pub const Record = struct {
    version: u8 = 1,
    kind: enum { fix, restack, abort, quit, reset },
    before_manifest: ?[]const u8,
    after_manifest: ?[]const u8,
    moves: []const Move,
    rescue: []const []const u8,
    previous: ?[]const u8,
};
pub fn label(record: Record) []const u8 {
    return switch (record.kind) {
        .fix => "stakrr: fix",
        .restack => "stakrr: restack",
        .abort => "stakrr: abort restack",
        .quit => "stakrr: quit edit",
        .reset => "stakrr: reset",
    };
}
pub fn create(git: *const Git, record: Record, checkpoint: ?[]const u8) ![]u8 {
    const a = git.allocator;
    var parents: std.ArrayList([]const u8) = .empty;
    var entries: std.ArrayList(Git.TreeEntry) = .empty;
    if (record.previous) |oid| try parents.append(a, oid);
    if (checkpoint) |oid| {
        const kind = try git.output(&.{ "cat-file", "-t", oid });
        if (std.mem.eql(u8, kind, "commit")) try parents.append(a, oid) else try entries.append(a, .{ .name = "checkpoint", .oid = oid, .tree = std.mem.eql(u8, kind, "tree") });
    }
    if (record.before_manifest) |oid| try parents.append(a, oid);
    if (record.after_manifest) |oid| try parents.append(a, oid);
    for (record.moves) |move| {
        try parents.append(a, move.before);
        if (move.after) |value| try parents.append(a, value);
    }
    try parents.appendSlice(a, record.rescue);
    // Corrupt state can point to a blob or tree. Archive those as tree entries,
    // retaining commit objects as parents, without ever interpreting their schema.
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.appendSlice(a, parents.items);
    parents.clearRetainingCapacity();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (roots.items) |value| {
        if ((try seen.getOrPut(a, value)).found_existing) continue;
        const kind = try git.output(&.{ "cat-file", "-t", value });
        if (std.mem.eql(u8, kind, "commit")) try parents.append(a, value) else if (std.mem.eql(u8, kind, "blob") or std.mem.eql(u8, kind, "tree")) {
            try entries.append(a, .{ .name = value, .oid = value, .tree = std.mem.eql(u8, kind, "tree") });
        } else return error.InvalidManifest;
    }
    try entries.appendSlice(a, &.{
        .{ .name = "operation.json", .oid = try git.writeBlob(try std.json.Stringify.valueAlloc(a, record, .{})) },
        .{ .name = "previous", .oid = try git.writeBlob(record.previous orelse "") },
        .{ .name = "rescue", .oid = try git.writeBlob(if (record.rescue.len != 0) record.rescue[0] else record.before_manifest orelse "") },
    });
    return git.commitTreeWithOptions(try git.writeTree(entries.items), parents.items, label(record), .{ .identity = .{ .name = "stakrr", .email = "stakrr@localhost" } });
}
pub fn update(git: *const Git, old: ?[]const u8, new: []const u8) !Git.RefUpdate {
    return if (old) |oid| git.updateRef(layout.oplog_ref, oid, new) else git.createRef(layout.oplog_ref, new);
}
pub fn read(git: *const Git, oid: []const u8) !?Record {
    const path = try std.fmt.allocPrint(git.allocator, "{s}:operation.json", .{oid});
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
        error.GitFailed => return null,
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Record, git.allocator, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const r = parsed.value;
    if (r.version != 1) return null;
    for ([_]?[]const u8{ r.before_manifest, r.after_manifest, r.previous }) |maybe| if (maybe) |value| {
        _ = git.parseOid(value) catch return null;
    };
    for (r.moves) |move| {
        _ = @import("git_types.zig").BranchRef.init(move.name) catch return null;
        _ = git.parseOid(move.before) catch return null;
        if (move.after) |value| _ = git.parseOid(value) catch return null;
    }
    for (r.rescue) |value| {
        _ = git.parseOid(value) catch return null;
    }
    return r;
}
