//! A repository mutation owns the common lock from recovery through publication.
const std = @import("std");
const Git = @import("git.zig").Git;
const types = @import("git_types.zig");
const coordination = @import("coordination.zig");
const journal = @import("ref_transaction.zig");
const layout = @import("layout.zig");

pub const Kind = enum { stack, edit, refs };

pub const Mutation = struct {
    git: Git,
    lock: std.Io.File,
    recovered: bool,

    pub fn repo(self: *const Mutation) *const Git {
        return &self.git;
    }

    pub fn deinit(self: *Mutation) void {
        self.lock.close(self.git.io);
        self.* = undefined;
    }

    /// Publication never recovers implicitly after a caller has read its snapshot.
    pub fn publish(self: *const Mutation, options: types.PublishOptions) !void {
        try journal.transact(self, options);
    }

    pub fn switchBranch(self: *const Mutation, branch: types.BranchRef) !void {
        _ = try types.BranchRef.init(branch.name.bytes);
        try self.git.requireDirectRef(branch.name);
        try self.git.exec(&.{
            "switch", "--quiet", "--no-guess", "--no-overwrite-ignore", "--", branch.short(),
        });
    }

    /// Replay one commit. The workflow validates HEAD, ignored files and pick state.
    pub fn cherryPick(self: *const Mutation, commit: types.Oid) !void {
        _ = try self.git.parseOid(commit.hex());
        try self.git.exec(&.{
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "rerere.enabled=false",
            "cherry-pick",
            "--no-gpg-sign",
            "--allow-empty",
            "--allow-empty-message",
            "--keep-redundant-commits",
            commit.hex(),
        });
    }

    /// Commit a stopped pick after its index and resolution have been validated.
    pub fn commitResolution(self: *const Mutation) !void {
        try self.git.exec(&.{
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
    }
};

pub fn begin(original: *const Git, kind: Kind) !Mutation {
    if (kind != .refs) try original.ensureWorkTree();
    var git = original.*;
    git.object_format = try original.objectFormat();
    const lock = try coordination.acquireLock(&git);
    errdefer lock.close(git.io);
    var mutation: Mutation = .{ .git = git, .lock = lock, .recovered = false };
    mutation.recovered = try journal.recover(&mutation);
    if (kind == .stack and try git.readDirectRef(try types.RefName.init(layout.session_ref)) != null)
        return error.EditInProgress;
    return mutation;
}

/// Shared by initial publication and recovery. Workflows never supply a second
/// list of affected branches; only writes in the actual update set count.
pub fn validatePublication(git: *const Git, updates: []const types.RefUpdate, policy: types.CurrentBranchPolicy) !void {
    const format = try git.objectFormat();
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(git.allocator);
    var exclusive: std.ArrayList([]const u8) = .empty;
    defer exclusive.deinit(git.allocator);
    var allow_current: std.ArrayList([]const u8) = .empty;
    defer allow_current.deinit(git.allocator);
    var deleting: std.ArrayList([]const u8) = .empty;
    defer deleting.deinit(git.allocator);
    const allowed: ?types.BranchRef = switch (policy) {
        .forbid => null,
        .allow => |branch| try types.BranchRef.init(branch.name.bytes),
    };
    for (updates) |update| {
        const name = update.name();
        _ = try types.RefName.init(name.bytes);
        if ((try names.getOrPut(git.allocator, name.bytes)).found_existing)
            return error.InvalidRefName;
        for ([_]?types.Oid{ update.oldOid(), update.newOid() }) |value| {
            if (value) |oid| _ = try types.Oid.init(format, oid.hex());
        }
        if (!update.writes() or !std.mem.startsWith(u8, name.bytes, layout.branch_prefix)) continue;
        const branch = try types.BranchRef.init(name.bytes);
        // Deletions never receive an exception for the caller's checkout.
        if (update == .delete) {
            try deleting.append(git.allocator, name.bytes);
        } else if (allowed != null and std.mem.eql(u8, branch.name.bytes, allowed.?.name.bytes)) {
            try allow_current.append(git.allocator, name.bytes);
        } else {
            try exclusive.append(git.allocator, name.bytes);
        }
    }
    if (deleting.items.len != 0) try coordination.requireDeletable(git, deleting.items);
    if (exclusive.items.len != 0) try coordination.requireUnoccupied(git, exclusive.items);
    if (allow_current.items.len != 0) try coordination.requireAvailable(git, allow_current.items);
}
