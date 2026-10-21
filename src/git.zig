const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Domain errors raised by the Git wrapper. Allocation and process
/// spawning errors are propagated separately.
pub const Error = error{
    GitFailed,
    GitTerminated,
    InvalidRefName,
    InvalidOid,
    NotGitRepository,
    NotWorkingTree,
    DetachedHead,
    InvalidGitConfig,
    InvalidGitOutput,
    StreamTooLong,
};

/// Optional sink for the stderr of the last failed Git command.
pub const Diagnostics = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn stderr(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn record(self: *Diagnostics, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        self.len = @min(trimmed.len, self.buf.len);
        @memcpy(self.buf[0..self.len], trimmed[0..self.len]);
    }
};

/// True if `text` is a full hexadecimal SHA-1 or SHA-256 object id.
pub fn isOid(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Cheap guard for persisted branch refs before they reach argv or the
/// update-ref protocol: must be under refs/heads/ and contain no whitespace
/// or control characters. Git applies its full naming rules on use.
pub fn isSafeBranchRef(text: []const u8) bool {
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, text, prefix) or text.len == prefix.len)
        return false;
    for (text) |c| {
        if (c <= ' ' or c == 0x7f) return false;
    }
    return true;
}

pub const Git = struct {
    allocator: Allocator,
    io: Io,
    cwd: ?Io.Dir = null,
    /// replaces the child environment when set (used for hermetic tests)
    environ_map: ?*const std.process.Environ.Map = null,
    diagnostics: ?*Diagnostics = null,

    const stdout_limit = 16 * 1024 * 1024;
    const stderr_limit = 64 * 1024;

    fn childCwd(self: *const Git) std.process.Child.Cwd {
        return if (self.cwd) |dir| .{ .dir = dir } else .inherit;
    }

    /// execute git and return its raw result
    /// the caller owns stdout and stderr
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
            .cwd = self.childCwd(),
            .environ_map = self.environ_map,
            .stdout_limit = .limited(stdout_limit),
            .stderr_limit = .limited(stderr_limit),
        });
    }

    pub fn freeResult(
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

    /// record git's stderr for the caller and report the failure
    fn fail(self: *const Git, stderr: []const u8) error{GitFailed} {
        if (self.diagnostics) |diag| diag.record(stderr);
        return error.GitFailed;
    }

    /// execute a command that must succeed
    /// returns an owned, newline-trimmed copy of stdout
    pub fn output(
        self: *const Git,
        args: []const []const u8,
    ) ![]u8 {
        const bytes = try self.outputRaw(args);
        defer self.allocator.free(bytes);
        return self.allocator.dupe(u8, std.mem.trimEnd(u8, bytes, "\r\n"));
    }

    /// Successful stdout, unchanged. The caller owns the returned bytes.
    /// Use for blobs and NUL-delimited records, which are not text lines.
    pub fn outputRaw(self: *const Git, args: []const []const u8) ![]u8 {
        const result = try self.run(args);
        defer self.allocator.free(result.stderr);
        errdefer self.allocator.free(result.stdout);
        if ((try exitCode(result)) != 0) return self.fail(result.stderr);
        return result.stdout;
    }

    /// Git path output is terminated by one newline; path bytes may themselves
    /// end in newlines, unlike ordinary text output.
    pub fn path(self: *const Git, args: []const []const u8) ![]u8 {
        const result = try self.run(args);
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return self.fail(result.stderr);
        if (result.stdout.len == 0 or result.stdout[result.stdout.len - 1] != '\n')
            return error.InvalidGitOutput;
        return self.allocator.dupe(u8, result.stdout[0 .. result.stdout.len - 1]);
    }

    /// execute a Git command that must succeed without retaining stdout
    pub fn exec(self: *const Git, args: []const []const u8) !void {
        const result = try self.run(args);
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return self.fail(result.stderr);
    }

    pub fn checkRefFormat(self: *const Git, ref_name: []const u8) !void {
        const result = try self.run(&.{ "check-ref-format", ref_name });
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return error.InvalidRefName;
    }

    /// read the exact ref oid. a missing ref is distinct from a git failure
    pub fn readRef(self: *const Git, ref_name: []const u8) !?[]u8 {
        const result = try self.run(&.{
            "rev-parse",
            "--verify",
            "--quiet",
            "--end-of-options",
            ref_name,
        });
        defer self.freeResult(result);
        return switch (try exitCode(result)) {
            0 => try self.allocator.dupe(
                u8,
                std.mem.trimEnd(u8, result.stdout, "\r\n"),
            ),
            1 => null,
            else => self.fail(result.stderr),
        };
    }

    /// true if the range contains a merge commit (linear stacks only)
    pub fn hasMergeCommits(
        self: *const Git,
        older: []const u8,
        newer: []const u8,
    ) !bool {
        const range = try std.fmt.allocPrint(
            self.allocator,
            "{s}..{s}",
            .{ older, newer },
        );
        defer self.allocator.free(range);
        const merges = try self.output(&.{
            "rev-list",
            "--min-parents=2",
            "--max-count=1",
            "--end-of-options",
            range,
        });
        defer self.allocator.free(merges);
        return merges.len != 0;
    }

    /// Commits in `older..newer`, oldest first, one "<oid> <parents...>"
    /// line per commit. The caller owns the returned buffer.
    pub fn revListParents(self: *const Git, older: []const u8, newer: []const u8) ![]u8 {
        const range = try std.fmt.allocPrint(
            self.allocator,
            "{s}..{s}",
            .{ older, newer },
        );
        defer self.allocator.free(range);
        return self.output(&.{ "rev-list", "--parents", "--reverse", "--end-of-options", range });
    }

    /// require an ordinary git working tree
    pub fn ensureWorkTree(self: *const Git) !void {
        const result = try self.run(&.{
            "rev-parse",
            "--is-inside-work-tree",
        });
        defer self.freeResult(result);

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
        defer self.freeResult(result);

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
            "--end-of-options",
            a,
            b,
        });
        defer self.freeResult(result);

        return switch (try exitCode(result)) {
            0 => true,
            1 => false,
            else => self.fail(result.stderr),
        };
    }

    pub fn configGet(
        self: *const Git,
        key: []const u8,
    ) !?[]u8 {
        const result = try self.run(&.{
            "config", "--local", "--get-all", key,
        });
        defer self.freeResult(result);

        switch (try exitCode(result)) {
            1 => return null,
            0 => {},
            else => return self.fail(result.stderr),
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

    /// remove every value of a local config key; returns false if unset
    pub fn configUnset(self: *const Git, key: []const u8) !bool {
        const result = try self.run(&.{
            "config", "--local", "--unset-all", key,
        });
        defer self.freeResult(result);

        return switch (try exitCode(result)) {
            0 => true,
            5 => false,
            else => self.fail(result.stderr),
        };
    }

    pub fn listRefs(self: *const Git, prefix: []const u8) ![]u8 {
        return self.output(&.{
            "for-each-ref",
            "--format=%(refname)%09%(objectname)",
            prefix,
        });
    }

    pub fn countCommits(self: *const Git, older: []const u8, newer: []const u8) !usize {
        const range = try std.fmt.allocPrint(
            self.allocator,
            "{s}..{s}",
            .{ older, newer },
        );
        defer self.allocator.free(range);

        const text = try self.output(&.{
            "rev-list",
            "--count",
            "--end-of-options",
            range,
        });
        defer self.allocator.free(text);

        return std.fmt.parseInt(usize, text, 10) catch
            error.InvalidGitOutput;
    }

    pub const ExpectedRef = struct {
        name: []const u8,
        oid: []const u8,
    };

    /// One line of an `update-ref --stdin` transaction.
    pub const RefUpdate = union(enum) {
        verify: ExpectedRef,
        /// Idempotent recovery pin; name contains its immutable object ID.
        retain: ExpectedRef,
        create: ExpectedRef,
        /// compare-and-swap `name` from `old` to `new`
        update: struct { name: []const u8, new: []const u8, old: []const u8 },
        delete: ExpectedRef,
    };

    /// Atomically apply `updates` in one ref transaction; either every
    /// update lands or none do. Names must be Git-valid refs and every oid
    /// a full object id, since both are written into the stdin protocol.
    pub fn transact(
        self: *const Git,
        message: []const u8,
        updates: []const RefUpdate,
    ) !void {
        var transaction: Io.Writer.Allocating = .init(self.allocator);
        defer transaction.deinit();
        const w = &transaction.writer;

        try w.writeAll("start\n");
        for (updates) |update| switch (update) {
            .retain => |ref| {
                try checkUpdate(ref.name, &.{ref.oid});
                try w.print("update {s} {s}\n", .{ ref.name, ref.oid });
            },
            .verify => |ref| {
                try checkUpdate(ref.name, &.{ref.oid});
                try w.print("verify {s} {s}\n", .{ ref.name, ref.oid });
            },
            .create => |ref| {
                try checkUpdate(ref.name, &.{ref.oid});
                try w.print("create {s} {s}\n", .{ ref.name, ref.oid });
            },
            .update => |ref| {
                try checkUpdate(ref.name, &.{ ref.new, ref.old });
                try w.print("update {s} {s} {s}\n", .{ ref.name, ref.new, ref.old });
            },
            .delete => |ref| {
                try checkUpdate(ref.name, &.{ref.oid});
                try w.print("delete {s} {s}\n", .{ ref.name, ref.oid });
            },
        };
        try w.writeAll("prepare\ncommit\n");

        try self.updateRefStdin(message, transaction.written());
    }

    fn checkUpdate(name: []const u8, oids: []const []const u8) Error!void {
        if (!std.mem.startsWith(u8, name, "refs/")) return error.InvalidRefName;
        for (name) |c| {
            if (c <= ' ' or c == 0x7f) return error.InvalidRefName;
        }
        for (oids) |oid| {
            if (!isOid(oid)) return error.InvalidOid;
        }
    }

    fn updateRefStdin(
        self: *const Git,
        message: []const u8,
        transaction: []const u8,
    ) !void {
        try self.input(
            &.{ "update-ref", "--create-reflog", "-m", message, "--stdin" },
            transaction,
        );
    }

    /// Feed stdin without a shell. Stdout is ignored; blob IDs are
    /// computed locally.
    pub fn input(
        self: *const Git,
        args: []const []const u8,
        data: []const u8,
    ) !void {
        const argv = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(argv);
        argv[0] = "git";
        @memcpy(argv[1..], args);
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = self.childCwd(),
            .environ_map = self.environ_map,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .pipe,
        });

        var reaped = false;
        errdefer {
            if (!reaped) {
                if (child.stdin) |pipe| pipe.close(self.io);
                child.kill(self.io);
            }
        }

        try child.stdin.?.writeStreamingAll(self.io, data);
        child.stdin.?.close(self.io);
        child.stdin = null;

        // capture git's stderr instead of forwarding it to the terminal
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_reader = child.stderr.?.reader(
            self.io,
            &stderr_buffer,
        );

        const stderr = try stderr_reader.interface.allocRemaining(
            self.allocator,
            .limited(stderr_limit),
        );
        defer self.allocator.free(stderr);

        const term = try child.wait(self.io);
        reaped = true;

        if (!term.success()) return self.fail(stderr);
    }

    pub const ObjectFormat = enum { sha1, sha256 };

    pub fn objectFormat(self: *const Git) !ObjectFormat {
        const format = try self.output(&.{ "rev-parse", "--show-object-format" });
        defer self.allocator.free(format);
        return std.meta.stringToEnum(ObjectFormat, format) orelse
            error.InvalidGitOutput;
    }

    /// Store session metadata as a Git blob, usable in the same transaction as refs.
    pub fn writeBlob(self: *const Git, data: []const u8) ![]u8 {
        return self.writeBlobWithFormat(data, try self.objectFormat());
    }

    /// Reuse a known object format when writing a sequence of checkpoints.
    pub fn writeBlobWithFormat(
        self: *const Git,
        data: []const u8,
        format: ObjectFormat,
    ) ![]u8 {
        var header_buffer: ["blob ".len + 20 + 1]u8 = undefined;
        const header = try std.fmt.bufPrint(
            &header_buffer,
            "blob {d}\x00",
            .{data.len},
        );
        var digest: [32]u8 = undefined;
        const len: usize = if (format == .sha1) blk: {
            var hash = std.crypto.hash.Sha1.init(.{});
            hash.update(header);
            hash.update(data);
            hash.final(digest[0..20]);
            break :blk 20;
        } else blk: {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(header);
            hash.update(data);
            hash.final(&digest);
            break :blk 32;
        };
        try self.input(&.{ "hash-object", "-w", "--stdin" }, data);
        const hex = try self.allocator.alloc(u8, len * 2);
        const alphabet = "0123456789abcdef";
        for (digest[0..len], 0..) |byte, i| {
            hex[2 * i] = alphabet[byte >> 4];
            hex[2 * i + 1] = alphabet[byte & 15];
        }
        return hex;
    }

    pub fn switchBranch(self: *const Git, ref_name: []const u8) !void {
        if (!isSafeBranchRef(ref_name)) return error.InvalidRefName;

        const branch = ref_name["refs/heads/".len..];

        // Reject option-like names and Git's "-" previous-branch shorthand.
        if (branch[0] == '-') return error.InvalidRefName;

        try self.exec(&.{
            "switch", "--quiet", "--no-guess", "--no-overwrite-ignore", "--", branch,
        });
    }
};
