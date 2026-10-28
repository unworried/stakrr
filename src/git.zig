const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const layout = @import("layout.zig");

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
    const prefix = layout.branch_prefix;
    return std.mem.startsWith(u8, text, prefix) and
        text.len != prefix.len and
        isProtocolSafe(text);
}

/// No whitespace or control bytes, which would split argv words or
/// update-ref stdin lines.
fn isProtocolSafe(text: []const u8) bool {
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

    /// `git` followed by `args`; the caller frees the slice, not its items.
    fn argvFor(self: *const Git, args: []const []const u8) ![]const []const u8 {
        const argv = try self.allocator.alloc([]const u8, args.len + 1);
        argv[0] = "git";
        @memcpy(argv[1..], args);
        return argv;
    }

    /// execute git and return its raw result
    /// the caller owns stdout and stderr
    pub fn run(
        self: *const Git,
        args: []const []const u8,
    ) !std.process.RunResult {
        const argv = try self.argvFor(args);
        defer self.allocator.free(argv);

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
        const result = try self.run(args);
        defer self.freeResult(result);

        if ((try exitCode(result)) != 0)
            return self.fail(result.stderr);

        const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
        return self.allocator.dupe(u8, trimmed);
    }

    /// execute a Git command that must succeed without retaining stdout
    pub fn exec(self: *const Git, args: []const []const u8) !void {
        const result = try self.run(args);
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return self.fail(result.stderr);
    }

    /// Return owned, newline-trimmed stdout on success and null on `absent`;
    /// any other exit status fails with diagnostics.
    pub fn query(self: *const Git, args: []const []const u8, absent: u8) !?[]u8 {
        const result = try self.run(args);
        defer self.freeResult(result);
        const code = try exitCode(result);
        if (code == absent) return null;
        if (code != 0) return self.fail(result.stderr);
        return try self.allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\r\n"));
    }

    /// True on success, false on exit status `no`; any other status fails.
    pub fn check(self: *const Git, args: []const []const u8, no: u8) !bool {
        const result = try self.run(args);
        defer self.freeResult(result);
        const code = try exitCode(result);
        if (code == no) return false;
        if (code != 0) return self.fail(result.stderr);
        return true;
    }

    pub fn checkRefFormat(self: *const Git, ref_name: []const u8) !void {
        const result = try self.run(&.{ "check-ref-format", ref_name });
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return error.InvalidRefName;
    }

    /// read the exact ref oid. a missing ref is distinct from a git failure
    pub fn readRef(self: *const Git, ref_name: []const u8) !?[]u8 {
        return self.query(&.{
            "rev-parse",
            "--verify",
            "--quiet",
            "--end-of-options",
            ref_name,
        }, 1);
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
        const range = try std.fmt.allocPrint(self.allocator, "{s}..{s}", .{ older, newer });
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

    /// The full current branch ref, or null when HEAD is detached.
    pub fn head(self: *const Git) !?[]u8 {
        return self.query(&.{ "symbolic-ref", "--quiet", "HEAD" }, 1);
    }

    /// Like `head`, but a detached HEAD is an error.
    pub fn currentBranch(self: *const Git) ![]u8 {
        return (try self.head()) orelse error.DetachedHead;
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
        return self.check(&.{ "merge-base", "--is-ancestor", "--end-of-options", a, b }, 1);
    }

    pub fn configGet(
        self: *const Git,
        key: []const u8,
    ) !?[]u8 {
        const value = (try self.query(&.{ "config", "--local", "--get-all", key }, 1)) orelse
            return null;
        errdefer self.allocator.free(value);

        // stakrr expects exactly one config value
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, '\n') != null)
            return error.InvalidGitConfig;

        return value;
    }

    /// remove every value of a local config key; returns false if unset
    pub fn configUnset(self: *const Git, key: []const u8) !bool {
        return self.check(&.{ "config", "--local", "--unset-all", key }, 5);
    }

    pub fn listStackRefs(self: *const Git) ![]u8 {
        return self.output(&.{
            "for-each-ref",
            "--format=%(refname)%09%(objectname)",
            layout.layer_prefix,
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
        create: ExpectedRef,
        /// compare-and-swap `name` from `old` to `new`
        update: struct { name: []const u8, new: []const u8, old: []const u8 },
        delete: ExpectedRef,
    };

    /// Atomically apply `updates` in one ref transaction; either every
    /// update lands or none do. Names must be Git-valid refs and every oid
    /// a full object id, since both are written into the stdin protocol.
    /// Updates affect the named refs themselves, never symbolic-ref targets.
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
        if (!std.mem.startsWith(u8, name, "refs/") or !isProtocolSafe(name))
            return error.InvalidRefName;
        for (oids) |oid| {
            if (!isOid(oid)) return error.InvalidOid;
        }
    }

    fn updateRefStdin(self: *const Git, message: []const u8, transaction: []const u8) !void {
        const argv = try self.argvFor(&.{
            "update-ref", "--no-deref", "--create-reflog", "-m", message, "--stdin",
        });
        defer self.allocator.free(argv);
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

        try child.stdin.?.writeStreamingAll(self.io, transaction);
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

    /// atomically create a layer and advance the internal tip guard
    /// verifies all observed refs and fails if the stack changed meanwhile
    pub fn createLayerRef(
        self: *const Git,
        name: []const u8,
        oid: []const u8,
        anchor: ExpectedRef,
        work: ExpectedRef,
        previous: ?ExpectedRef,
    ) !void {
        var updates: [5]RefUpdate = undefined;
        var count: usize = 0;

        updates[count] = .{ .verify = anchor };
        count += 1;
        updates[count] = .{ .verify = work };
        count += 1;

        if (previous) |ref| {
            updates[count] = .{ .verify = ref };
            count += 1;
        }

        updates[count] = .{ .create = .{ .name = name, .oid = oid } };
        count += 1;

        updates[count] = if (previous) |ref|
            .{ .update = .{ .name = layout.tip_ref, .new = oid, .old = ref.oid } }
        else
            .{ .create = .{ .name = layout.tip_ref, .oid = oid } };
        count += 1;

        try self.transact("stakrr: cut", updates[0..count]);
    }

    pub fn switchBranch(self: *const Git, ref_name: []const u8) !void {
        if (!isSafeBranchRef(ref_name)) return error.InvalidRefName;

        const branch = ref_name[layout.branch_prefix.len..];

        // Reject option-like names and Git's "-" previous-branch shorthand.
        if (branch[0] == '-') return error.InvalidRefName;

        try self.exec(&.{
            "switch", "--quiet", "--no-guess", "--", branch,
        });
    }
};

/// internal guard pointing at the highest layer
pub const tip_ref = layout.tip_ref;

/// the stack's starting commit; also keeps it reachable for gc
pub const anchor_ref = layout.anchor_ref;

/// namespace for stakrr-managed layer branches
pub const layer_prefix = layout.layer_prefix;

const testing = std.testing;

test "isOid accepts only full lowercase sha1/sha256 ids" {
    const sha1: [40]u8 = @splat('a');
    const sha256: [64]u8 = @splat('f');
    const upper: [40]u8 = @splat('A');
    const option: [40]u8 = ("--output=x" ++ @as([30]u8, @splat('a'))).*;

    try testing.expect(isOid(&sha1));
    try testing.expect(isOid(&sha256));
    try testing.expect(!isOid("abc"));
    try testing.expect(!isOid(&upper));
    try testing.expect(!isOid(&option));
}

test "isSafeBranchRef rejects options and protocol injection" {
    try testing.expect(isSafeBranchRef("refs/heads/main"));
    try testing.expect(isSafeBranchRef("refs/heads/stakrr/p1"));
    try testing.expect(!isSafeBranchRef("refs/heads/"));
    try testing.expect(!isSafeBranchRef("refs/tags/v1"));
    try testing.expect(!isSafeBranchRef("--output=x"));
    try testing.expect(!isSafeBranchRef("refs/heads/a\nverify x"));
    try testing.expect(!isSafeBranchRef("refs/heads/a b"));
    try testing.expect(!isSafeBranchRef("refs/heads/a\tb"));
    try testing.expect(!isSafeBranchRef("refs/heads/a\x00b"));
    try testing.expect(!isSafeBranchRef("refs/heads/a\x7fb"));
}

test "checkUpdate guards every name and oid written to update-ref" {
    const oid: [40]u8 = @splat('a');
    try Git.checkUpdate("refs/stakrr/tip", &.{&oid});
    try Git.checkUpdate("refs/heads/main", &.{ &oid, &oid });
    for ([_][]const u8{
        "heads/main",
        "-refs/heads/main",
        "refs/heads/a b",
        "refs/heads/a\nverify x",
        "refs/heads/a\x00",
        "refs/heads/a\x7f",
    }) |name| {
        try testing.expectError(error.InvalidRefName, Git.checkUpdate(name, &.{&oid}));
    }
    try testing.expectError(error.InvalidOid, Git.checkUpdate("refs/x", &.{ &oid, "HEAD" }));
}
