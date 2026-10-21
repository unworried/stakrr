//! Coordination shared by every stakrr mutation, including linked worktrees.
const std = @import("std");
const Git = @import("git.zig").Git;
const layout = @import("layout.zig");

pub const Error = error{
    MutationInProgress,
    EditInProgress,
    BranchOccupied,
    DirtyWorkTree,
    IgnoredFilesPresent,
    GitOperationInProgress,
};

/// Keep the inode: unlinking an advisory lock would allow two owners.
pub fn lock(git: *const Git) !std.Io.File {
    try git.ensureWorkTree();
    const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer git.allocator.free(common);
    const path = try std.fs.path.join(git.allocator, &.{ common, "stakrr.lock" });
    defer git.allocator.free(path);
    return std.Io.Dir.cwd().createFile(git.io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => error.MutationInProgress,
        else => return err,
    };
}

/// Lock for a stack mutation, which an active edit session excludes.
pub fn lockStack(git: *const Git) !std.Io.File {
    const guard = try lock(git);
    errdefer guard.close(git.io);
    if (try git.readRef(layout.session_ref)) |oid| {
        git.allocator.free(oid);
        return error.EditInProgress;
    }
    return guard;
}

/// A clean working tree with no Git operation in progress.
pub fn requireQuiescent(git: *const Git) !void {
    try requireClean(git);
    try requireNoGitOperation(git, .{});
}

pub fn requireClean(git: *const Git) !void {
    const status = try git.outputRaw(&.{ "status", "--porcelain=v1", "-z", "--untracked-files=all" });
    defer git.allocator.free(status);
    if (status.len != 0) return error.DirtyWorkTree;
}

/// Worktree porcelain -z keeps paths containing spaces/newlines unambiguous.
/// Only the caller's actual worktree is exempt; even forced duplicate checkouts
/// in another worktree are rejected.
pub fn requireAvailable(git: *const Git, refs: []const []const u8) !void {
    const here = try git.path(&.{ "rev-parse", "--show-toplevel" });
    defer git.allocator.free(here);
    const worktrees = try git.outputRaw(&.{ "worktree", "list", "--porcelain", "-z" });
    defer git.allocator.free(worktrees);
    var fields = std.mem.splitScalar(u8, worktrees, 0);
    var own = false;
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "worktree ")) {
            own = std.mem.eql(u8, here, field[9..]);
        } else if (!own and std.mem.startsWith(u8, field, "branch ")) {
            for (refs) |ref| {
                if (std.mem.eql(u8, ref, field[7..])) return error.BranchOccupied;
            }
        }
    }
}

pub const cherry_pick_head = "CHERRY_PICK_HEAD";

pub const OperationOptions = struct {
    /// the caller owns and validates a stopped cherry-pick
    allow_cherry_pick: bool = false,
};

pub fn requireNoGitOperation(git: *const Git, options: OperationOptions) !void {
    if (!options.allow_cherry_pick) {
        if (try git.readRef(cherry_pick_head)) |oid| {
            git.allocator.free(oid);
            return error.GitOperationInProgress;
        }
    }
    for ([_][]const u8{ "MERGE_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer" }) |name| {
        const path = try git.path(&.{ "rev-parse", "--git-path", name });
        defer git.allocator.free(path);
        const dir = git.cwd orelse std.Io.Dir.cwd();
        dir.access(git.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return error.GitOperationInProgress;
    }
}
