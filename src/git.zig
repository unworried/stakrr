const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Git = struct {
    allocator: Allocator,
    io: Io,

    /// execute git and return its raw result.
    /// the caller owns stdout and stderr.
    pub fn run(
        self: *const Git,
        args: []const []const u8,
    ) !std.process.RunResult {
        const argv = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(argv);

        argv[0] = "git";
        @memcpy(argv[1..], args);

        return std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
    }

    pub fn free(
        self: *const Git,
        result: std.process.RunResult,
    ) void {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    fn exitCode(result: std.process.RunResult) !u8 {
        return switch (result.term) {
            .exited => |status| status,
            else => error.GitTerminated,
        };
    }

    /// Execute a command that must succeed.
    /// Returns an owned, newline-trimmed copy of stdout.
    pub fn output(
        self: *const Git,
        args: []const []const u8,
    ) ![]u8 {
        const result = try self.run(args);
        defer self.free(result);

        if ((try exitCode(result)) != 0) {
            std.log.err("git {s}: {s}", .{ args[0], result.stderr });
            return error.GitFailed;
        }

        const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
        return self.allocator.dupe(u8, trimmed);
    }

    /// Require an ordinary Git working tree.
    pub fn ensureWorkTree(self: *const Git) !void {
        const result = try self.run(&.{
            "rev-parse",
            "--is-inside-work-tree",
        });
        defer self.free(result);

        if ((try exitCode(result)) != 0)
            return error.NotGitRepository;

        const value = std.mem.trim(u8, result.stdout, "\r\n");

        if (!std.mem.eql(u8, value, "true"))
            return error.NotWorkingTree;
    }

    /// Returns the full current branch ref.
    /// Example: refs/heads/work
    pub fn currentBranch(self: *const Git) ![]u8 {
        const result = try self.run(&.{
            "symbolic-ref",
            "--quiet",
            "HEAD",
        });
        defer self.free(result);

        if ((try exitCode(result)) != 0)
            return error.DetachedHead;

        return self.allocator.dupe(u8, std.mem.trimEnd(
            u8,
            result.stdout,
            "\r\n",
        ));
    }

    /// Resolve a revision to an actual commit OID.
    pub fn resolveCommit(self: *const Git, revision: []const u8) ![]u8 {
        const peeled = try std.fmt.allocPrint(
            self.allocator,
            "{s}^{{commit}}",
            .{revision},
        );
        defer self.allocator.free(peeled);

        return self.output(&.{
            "rev-parse",
            "--verify",
            "--end-of-options",
            peeled,
        });
    }

    /// Check whether a is an ancestor of b.
    pub fn isAncestor(
        self: *const Git,
        a: []const u8,
        b: []const u8,
    ) !bool {
        const result = try self.run(&.{
            "merge-base",
            "--is-ancestor",
            a,
            b,
        });
        defer self.free(result);

        return switch (try exitCode(result)) {
            0 => true,
            1 => false,
            else => error.GitFailed,
        };
    }
};
