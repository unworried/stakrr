//! Coordination shared by every stakrr mutation, including linked worktrees.
const std = @import("std");
const Git = @import("git.zig").Git;

pub const session_ref = "refs/stakrr/edit";
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

pub fn requireNoSession(git: *const Git) !void {
    if (try git.readRef(session_ref)) |oid| {
        git.allocator.free(oid);
        return error.EditInProgress;
    }
}

pub fn requireClean(git: *const Git) !void {
    const result = try git.run(&.{ "status", "--porcelain=v1", "-z", "--untracked-files=all" });
    defer git.freeResult(result);
    if (!result.term.success()) return error.GitFailed;
    if (result.stdout.len != 0) return error.DirtyWorkTree;
}

/// Worktree porcelain -z keeps paths containing spaces/newlines unambiguous.
/// Only the caller's actual worktree is exempt; even forced duplicate checkouts
/// in another worktree are rejected.
pub fn requireAvailable(git: *const Git, refs: []const []const u8) !void {
    const here = try git.path(&.{ "rev-parse", "--show-toplevel" });
    defer git.allocator.free(here);
    const result = try git.run(&.{ "worktree", "list", "--porcelain", "-z" });
    defer git.freeResult(result);
    if (!result.term.success()) return error.GitFailed;
    var fields = std.mem.splitScalar(u8, result.stdout, 0);
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

pub fn requireNoGitOperation(git: *const Git) !void {
    if (try git.readRef("CHERRY_PICK_HEAD")) |oid| {
        git.allocator.free(oid);
        return error.GitOperationInProgress;
    }
    try requireNoOtherGitOperation(git);
}

pub fn requireNoOtherGitOperation(git: *const Git) !void {
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
