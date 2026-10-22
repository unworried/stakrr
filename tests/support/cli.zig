//! drive the built stakrr binary inside a test repository
const std = @import("std");
const testing = std.testing;
const exe_path = @import("cli_options").exe_path;
const Repo = @import("repo.zig").Repo;

pub const Run = struct {
    /// null when the process did not exit normally (e.g. a fault kill)
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

pub fn run(repo: *const Repo, args: []const []const u8) !Run {
    // the build passes a path relative to the build root; the child runs
    // inside the temp repository, so resolve it first
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, exe_path, testing.allocator);
    defer testing.allocator.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, exe);
    try argv.appendSlice(testing.allocator, args);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = repo.tmp.dir },
        .environ_map = repo.env,
    });

    return .{
        .code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// run and require exit 0, printing stderr on failure
pub fn expectSuccess(repo: *const Repo, args: []const []const u8) !void {
    const result = try run(repo, args);
    defer result.deinit();
    if (result.code != 0) std.debug.print("stakrr stderr: {s}\n", .{result.stderr});
    try testing.expectEqual(@as(?u8, 0), result.code);
}

/// Put support/git_fault.sh first on PATH as `git`. Setting
/// STAKRR_TEST_FAULT in `repo.env` then kills stakrr around a checkpoint.
pub fn installFaultShim(repo: *const Repo) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "command -v git" },
        .environ_map = repo.env,
    });
    defer repo.git.freeResult(result);
    try testing.expect(result.term.success());
    try repo.env.put("STAKRR_TEST_GIT", std.mem.trimEnd(u8, result.stdout, "\r\n"));
    try repo.tmp.dir.createDir(testing.io, ".git/test-bin", .default_dir);
    try repo.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git/test-bin/git",
        .data = @embedFile("git_fault.sh"),
        .flags = .{ .permissions = .executable_file },
    });
    const dir = try repo.tmp.dir.realPathFileAlloc(testing.io, ".git/test-bin", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ dir, repo.env.get("PATH").? });
    defer testing.allocator.free(path);
    try repo.env.put("PATH", path);
    try repo.env.put("STAKRR_TEST_COUNTER", ".git/test-fault-count");
}
