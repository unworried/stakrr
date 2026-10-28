//! Coordination shared by every stakrr mutation, including linked worktrees.
const std = @import("std");
const Git = @import("git.zig").Git;

pub const Error = error{MutationInProgress};

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
