const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const layout = @import("layout.zig");
const types = @import("git_types.zig");
pub const RefName = types.RefName;
pub const BranchRef = types.BranchRef;
pub const Oid = types.Oid;
pub const RefUpdate = types.RefUpdate;
pub const CurrentBranchPolicy = types.CurrentBranchPolicy;
pub const PublishOptions = types.PublishOptions;
pub const Mutation = @import("mutation.zig").Mutation;

/// Domain errors raised by the Git wrapper. Allocation and process
/// spawning errors are propagated separately.
pub const Error = error{
    GitFailed,
    GitTerminated,
    InvalidRefName,
    SymbolicRef,
    InvalidOid,
    NotGitRepository,
    NotWorkingTree,
    DetachedHead,
    InvalidGitConfig,
    InvalidGitOutput,
    StreamTooLong,
    UnsupportedGitVersion,
    UnsupportedRefStorage,
    InvalidRefTransaction,
    RefTransactionChanged,
    RefTransactionPending,
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

/// Full naming and namespace validation for persisted local branch refs.
pub fn isSafeBranchRef(text: []const u8) bool {
    _ = BranchRef.init(text) catch return false;
    return true;
}

pub const Git = struct {
    allocator: Allocator,
    io: Io,
    cwd: ?Io.Dir = null,
    /// replaces the child environment when set (used for hermetic tests)
    environ_map: ?*const std.process.Environ.Map = null,
    diagnostics: ?*Diagnostics = null,
    object_format: ?types.ObjectFormat = null,

    const stdout_limit = 16 * 1024 * 1024;
    const stderr_limit = 64 * 1024;

    fn childCwd(self: *const Git) std.process.Child.Cwd {
        return if (self.cwd) |dir| .{ .dir = dir } else .inherit;
    }

    /// `git` followed by `args`; the caller frees the slice, not its items
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
    pub fn recordFailure(self: *const Git, stderr: []const u8) error{GitFailed} {
        if (self.diagnostics) |diag| diag.record(stderr);
        return error.GitFailed;
    }

    /// execute a command that must succeed
    /// returns owned, newline-trimmed stdout
    pub fn output(
        self: *const Git,
        args: []const []const u8,
    ) ![]u8 {
        const bytes = try self.outputRaw(args);
        errdefer self.allocator.free(bytes);
        return self.allocator.realloc(bytes, std.mem.trimEnd(u8, bytes, "\r\n").len);
    }

    /// Successful stdout, unchanged. The caller owns the returned bytes.
    /// Use for blobs and NUL-delimited records, which are not text lines.
    pub fn outputRaw(self: *const Git, args: []const []const u8) ![]u8 {
        const result = try self.run(args);
        defer self.allocator.free(result.stderr);
        errdefer self.allocator.free(result.stdout);
        if ((try exitCode(result)) != 0) return self.recordFailure(result.stderr);
        return result.stdout;
    }

    /// Git path output is terminated by one newline; path bytes may themselves
    /// end in newlines, unlike ordinary text output.
    pub fn path(self: *const Git, args: []const []const u8) ![]u8 {
        const result = try self.run(args);
        defer self.allocator.free(result.stderr);
        errdefer self.allocator.free(result.stdout);
        if ((try exitCode(result)) != 0) return self.recordFailure(result.stderr);
        if (result.stdout.len == 0 or result.stdout[result.stdout.len - 1] != '\n')
            return error.InvalidGitOutput;
        return self.allocator.realloc(result.stdout, result.stdout.len - 1);
    }

    /// execute a Git command that must succeed without retaining stdout
    pub fn exec(self: *const Git, args: []const []const u8) !void {
        const result = try self.run(args);
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return self.recordFailure(result.stderr);
    }

    /// For commands where exit status `absent` is an expected answer rather
    /// than a failure. Returns owned, newline-trimmed stdout on success and
    /// null on `absent`; any other status fails with diagnostics.
    pub fn query(self: *const Git, args: []const []const u8, absent: u8) !?[]u8 {
        const result = try self.run(args);
        defer self.allocator.free(result.stderr);
        errdefer self.allocator.free(result.stdout);
        const code = try exitCode(result);
        if (code == absent) {
            self.allocator.free(result.stdout);
            return null;
        }
        if (code != 0) return self.recordFailure(result.stderr);
        return try self.allocator.realloc(result.stdout, std.mem.trimEnd(u8, result.stdout, "\r\n").len);
    }

    /// True on success, false on exit status `no`; any other status fails.
    pub fn check(self: *const Git, args: []const []const u8, no: u8) !bool {
        const result = try self.run(args);
        defer self.freeResult(result);
        const code = try exitCode(result);
        if (code == no) return false;
        if (code != 0) return self.recordFailure(result.stderr);
        return true;
    }

    /// A copy that allocates from `allocator`, e.g. a command arena.
    pub fn withAllocator(self: *const Git, allocator: Allocator) Git {
        var copy = self.*;
        copy.allocator = allocator;
        return copy;
    }

    pub fn checkRefFormat(self: *const Git, ref_name: []const u8) !void {
        const result = try self.run(&.{ "check-ref-format", ref_name });
        defer self.freeResult(result);
        if ((try exitCode(result)) != 0) return error.InvalidRefName;
    }

    /// Managed refs are direct. HEAD and Git's operation pseudorefs retain
    /// their ordinary semantics; symbolic HEAD is used throughout the app.
    pub fn requireDirectRef(self: *const Git, ref_name: RefName) !void {
        const target = (try self.query(&.{ "symbolic-ref", "--quiet", "--no-recurse", ref_name.bytes }, 1)) orelse return;
        defer self.allocator.free(target);
        if (self.diagnostics) |diag| {
            var buf: [1024]u8 = undefined;
            diag.record(std.fmt.bufPrint(&buf, "symbolic ref {s} points to {s}; restore a direct ref before retrying", .{ ref_name.bytes, target }) catch "managed refs must be direct, not symbolic");
        }
        return error.SymbolicRef;
    }

    /// Read a direct ref OID, distinguishing absence from a Git failure.
    pub fn readDirectRef(self: *const Git, ref_name: RefName) !?Oid {
        // symbolic-ref also distinguishes malformed loose refs from absence.
        try self.requireDirectRef(ref_name);
        const raw = (try self.query(&.{
            "rev-parse",
            "--verify",
            "--quiet",
            "--end-of-options",
            ref_name.bytes,
        }, 1)) orelse {
            // Recheck a disappearance or corruption between the two reads.
            try self.requireDirectRef(ref_name);
            return null;
        };
        defer self.allocator.free(raw);
        return self.parseOid(raw) catch |err| switch (err) {
            error.InvalidOid => error.InvalidGitOutput,
            else => err,
        };
    }

    /// Owned hexadecimal bytes for the persisted snapshot/checkpoint codecs.
    pub fn readDirectRefAlloc(self: *const Git, ref_name: RefName) !?[]u8 {
        const value = (try self.readDirectRef(ref_name)) orelse return null;
        return try value.dupeHex(self.allocator);
    }

    /// Git operation pseudorefs are distinct from names in the refs/ namespace.
    pub fn cherryPickHead(self: *const Git) !?Oid {
        const raw = (try self.query(&.{ "rev-parse", "--verify", "--quiet", "CHERRY_PICK_HEAD" }, 1)) orelse return null;
        defer self.allocator.free(raw);
        return try self.parseOid(raw);
    }

    pub fn cherryPickHeadAlloc(self: *const Git) !?[]u8 {
        const value = (try self.cherryPickHead()) orelse return null;
        return try value.dupeHex(self.allocator);
    }

    /// Commits in `older..newer`, oldest first. Oids borrow from `raw`.
    pub const History = struct {
        raw: []u8,
        commits: []const []const u8,
        /// every commit has exactly one parent (no merges or roots)
        linear: bool,

        pub fn deinit(self: *History, allocator: Allocator) void {
            allocator.free(self.commits);
            allocator.free(self.raw);
            self.* = undefined;
        }
    };

    pub fn history(self: *const Git, older: []const u8, newer: []const u8) !History {
        const range = try std.fmt.allocPrint(self.allocator, "{s}..{s}", .{ older, newer });
        defer self.allocator.free(range);
        const raw = try self.output(&.{ "rev-list", "--parents", "--reverse", "--end-of-options", range });
        errdefer self.allocator.free(raw);

        var commits: std.ArrayList([]const u8) = .empty;
        errdefer commits.deinit(self.allocator);
        var linear = true;
        var lines = std.mem.tokenizeScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const oid = fields.next() orelse return error.InvalidGitOutput;
            var parents: usize = 0;
            while (fields.next()) |_| parents += 1;
            if (parents != 1) linear = false;
            try commits.append(self.allocator, oid);
        }
        return .{
            .raw = raw,
            .commits = try commits.toOwnedSlice(self.allocator),
            .linear = linear,
        };
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

    /// HEAD's immediate symbolic target, without following branch aliases;
    /// null when HEAD is detached.
    pub fn head(self: *const Git) !?[]u8 {
        return self.query(&.{ "symbolic-ref", "--quiet", "--no-recurse", "HEAD" }, 1);
    }

    /// The name borrows raw; release the owned buffer with deinit.
    pub const OwnedBranchRef = struct {
        value: BranchRef,
        raw: []u8,

        pub fn deinit(self: *OwnedBranchRef, allocator: Allocator) void {
            allocator.free(self.raw);
            self.* = undefined;
        }
    };

    /// Require attached HEAD targeting a direct local branch, possibly unborn.
    pub fn currentBranch(self: *const Git) !OwnedBranchRef {
        const name = (try self.head()) orelse return error.DetachedHead;
        errdefer self.allocator.free(name);
        const branch = try BranchRef.init(name);
        try self.requireDirectRef(branch.name);
        return .{ .value = branch, .raw = name };
    }

    pub fn currentBranchAlloc(self: *const Git) ![]u8 {
        return (try self.currentBranch()).raw;
    }

    /// resolve a revision to an actual commit oid
    pub fn resolveCommit(self: *const Git, revision: []const u8) !Oid {
        const peeled = try std.fmt.allocPrint(
            self.allocator,
            "{s}^{{commit}}",
            .{revision},
        );
        defer self.allocator.free(peeled);

        const raw = try self.output(&.{
            "rev-parse",
            "--verify",
            "--end-of-options",
            peeled,
        });
        defer self.allocator.free(raw);
        return self.parseOid(raw);
    }

    pub fn resolveCommitAlloc(self: *const Git, revision: []const u8) ![]u8 {
        const value = try self.resolveCommit(revision);
        return try value.dupeHex(self.allocator);
    }

    /// Resolve the observed direct branch tip, without interpreting its name as a revision.
    pub fn branchCommit(self: *const Git, branch: BranchRef) !Oid {
        const value = (try self.readDirectRef(branch.name)) orelse
            return self.recordFailure("branch does not exist");
        return self.resolveCommit(value.hex());
    }

    pub fn branchCommitAlloc(self: *const Git, branch: BranchRef) ![]u8 {
        const value = try self.branchCommit(branch);
        return try value.dupeHex(self.allocator);
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
        const value = (try self.query(&.{ "config", "--null", "--local", "--get-all", key }, 1)) orelse
            return null;
        errdefer self.allocator.free(value);

        // Preserve value boundaries: trimming newlines could hide a trailing
        // empty value or a newline embedded in the persisted state.
        if (value.len <= 1 or value[value.len - 1] != 0 or
            std.mem.indexOfAny(u8, value[0 .. value.len - 1], "\x00\r\n") != null)
            return error.InvalidGitConfig;

        return try self.allocator.realloc(value, value.len - 1);
    }

    /// remove every value of a local config key; returns false if unset
    pub fn configUnset(self: *const Git, key: []const u8) !bool {
        return self.check(&.{ "config", "--local", "--unset-all", key }, 5);
    }

    /// Refs under a prefix, in refname order. Names borrow raw; OIDs are values.
    pub const RefList = struct {
        raw: []u8,
        refs: []ExpectedRef,

        pub fn deinit(self: *RefList, allocator: Allocator) void {
            allocator.free(self.refs);
            allocator.free(self.raw);
            self.* = undefined;
        }
    };

    pub fn listDirectRefs(self: *const Git, prefix: []const u8) !RefList {
        if (!std.mem.startsWith(u8, prefix, "refs/")) return error.InvalidRefName;
        const storage = try self.configGet("extensions.refStorage");
        defer if (storage) |name| self.allocator.free(name);
        if (storage) |name| {
            if (!std.mem.eql(u8, name, "files")) return error.UnsupportedRefStorage;
        }
        // Git omits dangling symbolic refs from for-each-ref. Inspect loose
        // names as well, letting Git interpret symbolic-ref candidates.
        const format = try self.objectFormat();
        try self.requireDirectLooseRefs(prefix, format);
        const raw = try self.output(&.{
            "for-each-ref",
            "--format=%(refname)%09%(objectname)%09%(symref)",
            prefix,
        });
        errdefer self.allocator.free(raw);

        var refs: std.ArrayList(ExpectedRef) = .empty;
        errdefer refs.deinit(self.allocator);
        var lines = std.mem.tokenizeScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse
                return error.InvalidGitOutput;
            const last_tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse return error.InvalidGitOutput;
            if (last_tab == tab) return error.InvalidGitOutput;
            if (last_tab + 1 != line.len) return error.SymbolicRef;
            const oid = line[tab + 1 .. last_tab];
            try refs.append(self.allocator, .{ .name = try RefName.init(line[0..tab]), .oid = Oid.init(format, oid) catch return error.InvalidGitOutput });
        }
        return .{ .raw = raw, .refs = try refs.toOwnedSlice(self.allocator) };
    }

    fn requireDirectLooseRefs(self: *const Git, prefix: []const u8, format: ObjectFormat) !void {
        // Walk only the requested subtree (or its parent for a partial prefix).
        const base = if (std.mem.endsWith(u8, prefix, "/"))
            std.mem.trimEnd(u8, prefix, "/")
        else
            std.fs.path.dirname(prefix) orelse return error.InvalidRefName;
        if (!std.mem.eql(u8, base, "refs")) _ = try RefName.init(base);
        const root = try self.path(&.{ "rev-parse", "--git-path", base });
        defer self.allocator.free(root);
        const cwd = self.cwd orelse Io.Dir.cwd();
        var dir = cwd.openDir(self.io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind == .directory) continue;
            const bytes = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, entry.path });
            defer self.allocator.free(bytes);
            if (!std.mem.startsWith(u8, bytes, prefix) or std.mem.endsWith(u8, bytes, ".lock")) continue;
            const name = try RefName.init(bytes);
            if (entry.kind == .sym_link) try self.requireDirectRef(name);
            const file = entry.dir.openFile(self.io, entry.basename, .{}) catch |err| switch (err) {
                error.FileNotFound => continue, // a concurrent pack/prune removed the loose copy
                else => return err,
            };
            defer file.close(self.io);
            var contents: [128]u8 = undefined;
            const len = try file.readPositionalAll(self.io, &contents, 0);
            if (std.mem.startsWith(u8, contents[0..len], "ref:")) {
                try self.requireDirectRef(name);
                continue;
            }
            if (len == contents.len) return error.InvalidGitOutput;
            _ = Oid.init(format, std.mem.trim(u8, contents[0..len], " \t\r\n")) catch
                return error.InvalidGitOutput;
        }
    }

    pub const ExpectedRef = types.ExpectedRef;
    pub const RefUpdate = types.RefUpdate;

    pub fn beginStackMutation(self: *const Git) !@import("mutation.zig").Mutation {
        return @import("mutation.zig").begin(self, .stack);
    }

    pub fn beginEditMutation(self: *const Git) !@import("mutation.zig").Mutation {
        return @import("mutation.zig").begin(self, .edit);
    }

    /// Object/ref plumbing also supports bare repositories.
    pub fn beginRefMutation(self: *const Git) !@import("mutation.zig").Mutation {
        return @import("mutation.zig").begin(self, .refs);
    }

    pub fn requireNoPendingTransaction(self: *const Git) !void {
        return @import("ref_transaction.zig").requirePublished(self);
    }

    pub fn parseOid(self: *const Git, hex: []const u8) !Oid {
        return Oid.init(try self.objectFormat(), hex);
    }

    /// Constructors for byte-oriented checkpoint and snapshot data.
    pub fn expectedRef(self: *const Git, name: []const u8, hex: []const u8) !types.ExpectedRef {
        return .{ .name = try RefName.init(name), .oid = try self.parseOid(hex) };
    }

    pub fn verifyRef(self: *const Git, name: []const u8, expected: ?[]const u8) !types.RefUpdate {
        return .{ .verify = .{ .name = try RefName.init(name), .expected = if (expected) |hex| try self.parseOid(hex) else null } };
    }

    pub fn createRef(self: *const Git, name: []const u8, new: []const u8) !types.RefUpdate {
        return .{ .create = .{ .name = try RefName.init(name), .new = try self.parseOid(new) } };
    }

    pub fn updateRef(self: *const Git, name: []const u8, old: []const u8, new: []const u8) !types.RefUpdate {
        return .{ .update = .{ .name = try RefName.init(name), .old = try self.parseOid(old), .new = try self.parseOid(new) } };
    }

    pub fn deleteRef(self: *const Git, name: []const u8, old: []const u8) !types.RefUpdate {
        return .{ .delete = .{ .name = try RefName.init(name), .old = try self.parseOid(old) } };
    }

    /// Feed stdin while draining both output pipes. Git supplies object IDs.
    pub fn inputOutput(self: *const Git, args: []const []const u8, data: []const u8) ![]u8 {
        const result = try self.inputResult(args, data);
        defer self.allocator.free(result.stderr);
        errdefer self.allocator.free(result.stdout);
        if ((try exitCode(result)) != 0) return self.recordFailure(result.stderr);
        return self.allocator.realloc(result.stdout, std.mem.trimEnd(u8, result.stdout, "\r\n").len);
    }

    fn inputResult(self: *const Git, args: []const []const u8, data: []const u8) !std.process.RunResult {
        const argv = try self.argvFor(args);
        defer self.allocator.free(argv);
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = self.childCwd(),
            .environ_map = self.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(self.io);

        var input_task = try self.io.concurrent(writeInput, .{ self.io, child.stdin.?, data });
        child.stdin = null; // the task owns and closes this pipe
        defer input_task.cancel(self.io) catch {};

        var buffer: Io.File.MultiReader.Buffer(2) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(self.allocator, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(64, .none)) |_| {
            if (reader.reader(0).buffered().len > stdout_limit or
                reader.reader(1).buffered().len > stderr_limit)
                return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try reader.checkAnyError();
        const term = try child.wait(self.io);
        // Prefer Git's refusal diagnostics over a writer's broken pipe.
        if (term.success()) try input_task.await(self.io);
        const stdout = try reader.toOwnedSlice(0);
        errdefer self.allocator.free(stdout);
        return .{ .term = term, .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
    }

    fn writeInput(io: Io, pipe: Io.File, data: []const u8) !void {
        defer pipe.close(io);
        try pipe.writeStreamingAll(io, data);
    }

    pub fn input(self: *const Git, args: []const []const u8, data: []const u8) !void {
        const stdout = try self.inputOutput(args, data);
        self.allocator.free(stdout);
    }

    pub const ObjectFormat = types.ObjectFormat;

    pub fn objectFormat(self: *const Git) !ObjectFormat {
        if (self.object_format) |format| return format;
        const format = try self.output(&.{ "rev-parse", "--show-object-format" });
        defer self.allocator.free(format);
        return std.meta.stringToEnum(ObjectFormat, format) orelse
            error.InvalidGitOutput;
    }

    /// Store bytes unchanged and use Git's authoritative object ID.
    pub fn writeBlob(self: *const Git, data: []const u8) ![]u8 {
        return self.writeObject("blob", data);
    }

    fn writeObject(self: *const Git, kind: []const u8, data: []const u8) ![]u8 {
        const format = try self.objectFormat();
        return self.validateOidOutput(format, try self.inputOutput(&.{ "hash-object", "-w", "-t", kind, "--stdin" }, data));
    }

    /// Takes ownership of Git's output and returns it only when it is a full OID.
    fn validateOidOutput(self: *const Git, format: ObjectFormat, raw: []u8) ![]u8 {
        errdefer self.allocator.free(raw);
        _ = Oid.init(format, raw) catch return error.InvalidGitOutput;
        return raw;
    }

    pub const TreeEntry = struct { name: []const u8, oid: []const u8, tree: bool = false };

    /// Write a tree of blobs/subtrees without touching the worktree's index.
    pub fn writeTree(self: *const Git, entries: []const TreeEntry) ![]u8 {
        var data: Io.Writer.Allocating = .init(self.allocator);
        defer data.deinit();
        const format = try self.objectFormat();
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.allocator);
        for (entries) |entry| {
            if (entry.name.len == 0 or std.mem.indexOfAny(u8, entry.name, "/\x00\n") != null)
                return error.InvalidRefName;
            if ((try names.getOrPut(self.allocator, entry.name)).found_existing) return error.InvalidRefName;
            _ = try Oid.init(format, entry.oid);
            try data.writer.print("{s} {s} {s}\t{s}\x00", .{
                if (entry.tree) "040000" else "100644",
                if (entry.tree) "tree" else "blob",
                entry.oid,
                entry.name,
            });
        }
        return self.validateOidOutput(format, try self.inputOutput(&.{ "mktree", "-z" }, data.written()));
    }

    pub const CommitTreeOptions = struct {
        identity: ?struct { name: []const u8, email: []const u8 } = null,
    };

    /// Create a checkpoint commit, preserving parent order and bypassing hooks/signing.
    pub fn commitTree(self: *const Git, tree: []const u8, parents: []const []const u8, label: []const u8) ![]u8 {
        return self.commitTreeWithOptions(tree, parents, label, .{});
    }

    /// Internal journals may supply an identity without changing repository config.
    pub fn commitTreeWithOptions(self: *const Git, tree: []const u8, parents: []const []const u8, label: []const u8, options: CommitTreeOptions) ![]u8 {
        const format = try self.objectFormat();
        _ = try Oid.init(format, tree);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        const name = if (options.identity) |identity| try std.fmt.allocPrint(self.allocator, "user.name={s}", .{identity.name}) else null;
        defer if (name) |value| self.allocator.free(value);
        const email = if (options.identity) |identity| try std.fmt.allocPrint(self.allocator, "user.email={s}", .{identity.email}) else null;
        defer if (email) |value| self.allocator.free(value);
        if (name) |value| try args.appendSlice(self.allocator, &.{ "-c", value, "-c", email.? });
        try args.appendSlice(self.allocator, &.{ "-c", "commit.gpgsign=false", "commit-tree", tree, "-m", label });
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);
        for (parents) |parent| {
            _ = try Oid.init(format, parent);
            if ((try seen.getOrPut(self.allocator, parent)).found_existing) continue;
            try args.appendSlice(self.allocator, &.{ "-p", parent });
        }
        return self.validateOidOutput(format, try self.output(args.items));
    }

    /// Three-way merge of two commits in memory; neither the index nor the
    /// worktree is touched. Returns the merged tree, or null when the merge
    /// conflicts. Needs Git 2.40 or newer for the explicit merge base.
    pub fn mergeTree(self: *const Git, base: []const u8, ours: []const u8, theirs: []const u8) !?[]u8 {
        const format = try self.objectFormat();
        for ([_][]const u8{ base, ours, theirs }) |oid| _ = try Oid.init(format, oid);
        const merge_base = try std.fmt.allocPrint(self.allocator, "--merge-base={s}", .{base});
        defer self.allocator.free(merge_base);
        const result = try self.run(&.{ "merge-tree", "--write-tree", "--no-messages", merge_base, ours, theirs });
        defer self.allocator.free(result.stderr);
        var owns_stdout = true;
        defer if (owns_stdout) self.allocator.free(result.stdout);
        switch (try exitCode(result)) {
            0 => {
                const raw = try self.allocator.realloc(result.stdout, std.mem.trimEnd(u8, result.stdout, "\r\n").len);
                owns_stdout = false;
                return try self.validateOidOutput(format, raw);
            },
            1 => return null,
            129 => return error.UnsupportedGitVersion,
            else => return self.recordFailure(result.stderr),
        }
    }

    /// A copy of `source` with another tree and a single parent. Author,
    /// committer and message are kept; signatures are dropped because they
    /// would no longer verify.
    pub fn rewriteCommit(self: *const Git, source: []const u8, tree: []const u8, parent: []const u8) ![]u8 {
        const format = try self.objectFormat();
        for ([_][]const u8{ source, tree, parent }) |oid| _ = try Oid.init(format, oid);
        const raw = try self.outputRaw(&.{ "cat-file", "commit", source });
        defer self.allocator.free(raw);
        const split = std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidGitOutput;

        var data: Io.Writer.Allocating = .init(self.allocator);
        defer data.deinit();
        try data.writer.print("tree {s}\nparent {s}\n", .{ tree, parent });

        var skipping = false;
        var lines = std.mem.splitScalar(u8, raw[0..split], '\n');
        while (lines.next()) |line| {
            // a header continues on lines that start with a space
            if (line.len == 0 or line[0] != ' ') {
                skipping = for ([_][]const u8{ "tree ", "parent ", "gpgsig", "mergetag" }) |name| {
                    if (std.mem.startsWith(u8, line, name)) break true;
                } else false;
            }
            if (skipping) continue;
            try data.writer.writeAll(line);
            try data.writer.writeByte('\n');
        }
        try data.writer.writeAll(raw[split + 1 ..]);
        return self.writeObject("commit", data.written());
    }
};

const testing = std.testing;

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
