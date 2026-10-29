//! drive the built stakrr binary inside a test repository
const std = @import("std");
const testing = std.testing;
const exe_path = @import("cli_options").exe_path;
const Repo = @import("repo.zig").Repo;

pub const Run = struct {
    /// null when the process did not exit normally (e.g. a fault kill)
    code: ?u8,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    /// A command refusal or panic must not masquerade as an injected crash.
    pub fn expectKilled(self: Run) !void {
        if (self.term != .signal or self.term.signal != .KILL)
            std.debug.print("expected injected SIGKILL, got {f}: {s}\n", .{ self.term, self.stderr });
        try testing.expectEqualDeep(std.process.Child.Term{ .signal = .KILL }, self.term);
    }

    pub fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// run the built stakrr binary inside the test repository
pub fn run(repo: *const Repo, args: []const []const u8) !Run {
    return runAt(repo, args, repo.tmp.dir);
}

pub fn runAt(repo: *const Repo, args: []const []const u8, cwd: std.Io.Dir) !Run {
    return runExecutable(repo, exe_path, args, cwd);
}

pub fn runRefDriver(repo: *const Repo, args: []const []const u8) !Run {
    return runExecutable(repo, @import("cli_options").ref_driver_path, args, repo.git.cwd orelse repo.tmp.dir);
}

fn runExecutable(repo: *const Repo, path: []const u8, args: []const []const u8, cwd: std.Io.Dir) !Run {
    // the build passes a path relative to the build root; the child runs
    // inside the temp repository, so resolve it first
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, path, testing.allocator);
    defer testing.allocator.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, exe);
    try argv.appendSlice(testing.allocator, args);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .environ_map = repo.env,
    });

    return .{
        .code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
        .term = result.term,
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

/// Put support/git_fault.sh first on PATH as `git` for publication faults.
pub fn installFaultShim(repo: *const Repo) !void {
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "command -v git" },
        .environ_map = repo.env,
    });
    defer repo.git.freeResult(result);
    try testing.expect(result.term.success());
    try repo.env.put("STAKRR_TEST_GIT", std.mem.trimEnd(u8, result.stdout, "\r\n"));
    const common = try repo.git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer testing.allocator.free(common);
    const bin = try std.fs.path.join(testing.allocator, &.{ common, "test-bin" });
    defer testing.allocator.free(bin);
    try repo.tmp.dir.createDir(testing.io, bin, .default_dir);
    const shim = try std.fs.path.join(testing.allocator, &.{ bin, "git" });
    defer testing.allocator.free(shim);
    try repo.tmp.dir.writeFile(testing.io, .{
        .sub_path = shim,
        .data = @embedFile("git_fault.sh"),
        .flags = .{ .permissions = .executable_file },
    });
    const path = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ bin, repo.env.get("PATH").? });
    defer testing.allocator.free(path);
    try repo.env.put("PATH", path);
    const counter = try std.fs.path.join(testing.allocator, &.{ common, "test-fault-count" });
    defer testing.allocator.free(counter);
    try repo.env.put("STAKRR_TEST_COUNTER", counter);
}
