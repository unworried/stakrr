//! Capture observable repository state for refusal and read-only checks.
const std = @import("std");
const testing = std.testing;
const Repo = @import("repo.zig").Repo;

// Include ref types, config, HEAD, the index and working files when checking
// refusal. Resolved OIDs alone would hide a symbolic substitution.
pub const Snapshot = struct {
    const commands = [_][]const []const u8{
        &.{ "for-each-ref", "--format=%(refname)%09%(objectname)%09%(symref)" },
        &.{ "config", "--local", "--null", "--list" },
        &.{ "symbolic-ref", "--no-recurse", "HEAD" },
        &.{ "rev-parse", "--verify", "HEAD" },
        &.{ "ls-files", "--stage", "-z" },
        &.{ "diff", "--no-relative", "--no-ext-diff", "--binary", "HEAD" },
        &.{ "status", "--porcelain=v1", "-z" },
    };
    values: [commands.len][]u8,

    pub fn capture(repo: *const Repo) !Snapshot {
        var result: Snapshot = undefined;
        var initialized: usize = 0;
        errdefer for (result.values[0..initialized]) |value| testing.allocator.free(value);
        for (commands, &result.values) |command, *value| {
            value.* = try repo.git.outputRaw(command);
            initialized += 1;
        }
        return result;
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.values) |value| testing.allocator.free(value);
    }

    pub fn expectUnchanged(self: *const Snapshot, repo: *const Repo) !void {
        for (commands, self.values) |command, expected| {
            const actual = try repo.git.outputRaw(command);
            defer testing.allocator.free(actual);
            if (!std.mem.eql(u8, expected, actual))
                std.debug.print("repository changed for git {s}\n", .{command[0]});
            try testing.expectEqualStrings(expected, actual);
        }
    }
};
