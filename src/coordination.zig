//! Coordination shared by every stakrr mutation, including linked worktrees.
const std = @import("std");
const Git = @import("git.zig").Git;

pub const Error = error{
    MutationInProgress,
    EditInProgress,
    BranchOccupied,
    BranchCheckedOut,
    LayerCheckedOut,
    DirtyWorkTree,
    IgnoredFilesPresent,
    GitOperationInProgress,
};

/// Keep the inode: unlinking an advisory lock would allow two owners.
/// Internal primitive; Mutation owns the lock and performs recovery.
pub fn acquireLock(git: *const Git) !std.Io.File {
    const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer git.allocator.free(common);
    const path = try std.fs.path.join(git.allocator, &.{ common, "stakrr.lock" });
    defer git.allocator.free(path);
    return std.Io.Dir.cwd().createFile(git.io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.MutationInProgress,
        else => return err,
    };
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
    return requireAvailability(git, refs, true);
}

/// Deleting a branch must also refuse its checkout in the caller's worktree.
pub fn requireDeletable(git: *const Git, refs: []const []const u8) !void {
    return requireAvailability(git, refs, false);
}

pub fn requireUnoccupied(git: *const Git, refs: []const []const u8) !void {
    return requireAvailability(git, refs, false) catch |err| switch (err) {
        error.LayerCheckedOut => error.BranchCheckedOut,
        else => err,
    };
}

fn requireAvailability(git: *const Git, refs: []const []const u8, allow_current: bool) !void {
    const result = try git.run(&.{ "rev-parse", "--show-toplevel" });
    defer git.freeResult(result);
    const here: ?[]const u8 = switch (result.term) {
        .exited => |code| switch (code) {
            0 => if (result.stdout.len != 0 and result.stdout[result.stdout.len - 1] == '\n')
                result.stdout[0 .. result.stdout.len - 1]
            else
                return error.InvalidGitOutput,
            128 => null, // bare repository, or invocation inside its Git directory
            else => return error.GitFailed,
        },
        else => return error.GitTerminated,
    };
    const worktrees = try git.outputRaw(&.{ "worktree", "list", "--porcelain", "-z" });
    defer git.allocator.free(worktrees);
    var fields = std.mem.splitScalar(u8, worktrees, 0);
    var own = false;
    var first = true;
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "worktree ")) {
            own = if (here) |root| std.mem.eql(u8, root, field[9..]) else false;
            // Git lists main first, but a separate Git directory can make its
            // displayed path differ from the actual working tree root.
            if (first and !own and here != null) {
                const private = try git.path(&.{ "rev-parse", "--absolute-git-dir" });
                defer git.allocator.free(private);
                const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
                defer git.allocator.free(common);
                own = std.mem.eql(u8, private, common);
            }
            first = false;
        } else if ((!own or !allow_current) and std.mem.startsWith(u8, field, "branch ")) {
            for (refs) |ref| {
                if (std.mem.eql(u8, ref, field[7..]))
                    return if (own) error.LayerCheckedOut else error.BranchOccupied;
            }
        }
    }
}

pub const OperationOptions = struct {
    /// the caller owns and validates a stopped cherry-pick
    allow_cherry_pick: bool = false,
};

pub fn requireNoGitOperation(git: *const Git, options: OperationOptions) !void {
    if (!options.allow_cherry_pick) {
        if (try git.cherryPickHead() != null) {
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
