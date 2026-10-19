const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Git = struct {
    allocator: Allocator,
    io: Io,
    cwd: ?Io.Dir = null,

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
            .cwd = if (self.cwd) |dir| .{ .dir = dir } else .inherit,
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

    /// execute a command that must succeed
    /// returns an owned, newline-trimmed copy of stdout
    pub fn output(
        self: *const Git,
        args: []const []const u8,
    ) ![]u8 {
        const result = try self.run(args);
        defer self.free(result);

        if ((try exitCode(result)) != 0)
            return error.GitFailed;

        const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
        return self.allocator.dupe(u8, trimmed);
    }

    /// require an ordinary git working tree
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

    /// returns the full current branch ref
    /// example: refs/heads/work
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

    /// resolve a revision to an actual commit oid
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

    /// check whether a is an ancestor of b
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

    pub fn configGet(
        self: *const Git,
        key: []const u8,
    ) !?[]u8 {
        const result = try self.run(&.{
            "config", "--local", "--get-all", key,
        });
        defer self.free(result);

        const code = switch (result.term) {
            .exited => |status| status,
            else => return error.GitTerminated,
        };

        switch (code) {
            1 => return null,
            0 => {},
            else => return error.GitFailed,
        }

        const value = std.mem.trimEnd(
            u8,
            result.stdout,
            "\r\n",
        );

        // stakrr expects exactly one config value
        if (value.len == 0 or
            std.mem.indexOfScalar(u8, value, '\n') != null)
        {
            return error.InvalidGitConfig;
        }

        return try self.allocator.dupe(u8, value);
    }

    pub fn listStackRefs(self: *const Git) ![]u8 {
        return self.output(&.{
            "for-each-ref",
            "--format=%(refname)%09%(objectname)",
            "refs/heads/stakrr/",
        });
    }

    pub fn countCommits(
        self: *const Git,
        older: []const u8,
        newer: []const u8,
    ) !usize {
        const range = try std.fmt.allocPrint(
            self.allocator,
            "{s}..{s}",
            .{ older, newer },
        );
        defer self.allocator.free(range);

        const text = try self.output(&.{
            "rev-list",
            "--count",
            range,
        });
        defer self.allocator.free(text);

        return std.fmt.parseInt(usize, text, 10);
    }
};
