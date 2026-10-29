//! Internal update-ref protocol. Callers use Mutation.publish instead.
const std = @import("std");
const Io = std.Io;
const Git = @import("git.zig").Git;
const RefUpdate = @import("git_types.zig").RefUpdate;
const stdout_limit = 16 * 1024 * 1024;
const stderr_limit = 64 * 1024;

/// One Git transaction. Only individual ref writes are crash-atomic.
/// The journal uses this primitive to avoid recursively journaling itself.
pub fn publish(
    self: *const Git,
    message: []const u8,
    updates: []const RefUpdate,
) !void {
    var refused = false;
    return publishWithRefusal(self, message, updates, &refused);
}

/// A normal failure before preparation or a type-check abort confirms no
/// requested refs changed. Interrupted commits and I/O errors are uncertain.
pub fn publishWithRefusal(
    self: *const Git,
    message: []const u8,
    updates: []const RefUpdate,
    refused: *bool,
) !void {
    refused.* = false;
    var transaction: Io.Writer.Allocating = .init(self.allocator);
    defer transaction.deinit();
    const w = &transaction.writer;

    const format = try self.objectFormat();
    const zeros: [64]u8 = @splat('0');
    const absent = zeros[0..format.hexLength()];
    try w.writeAll("start\n");
    for (updates) |update| switch (update) {
        .verify => |ref| {
            try w.print("verify {s} {s}\n", .{ ref.name.bytes, if (ref.expected) |*oid| oid.hex() else absent });
        },
        .create => |ref| {
            try w.print("create {s} {s}\n", .{ ref.name.bytes, ref.new.hex() });
        },
        .update => |ref| {
            try w.print("update {s} {s} {s}\n", .{ ref.name.bytes, ref.new.hex(), ref.old.hex() });
        },
        .delete => |ref| {
            try w.print("delete {s} {s}\n", .{ ref.name.bytes, ref.old.hex() });
        },
    };
    try w.writeAll("prepare\n");

    const publication = try inputRefTransaction(self, message, transaction.written(), updates);
    const result = publication.result;
    defer self.freeResult(result);
    if (publication.rejected or !result.term.success()) {
        // Git acknowledges prepare before it processes commit. An ordinary
        // fatal exit with only the start acknowledgement is a refusal,
        // rather than an interrupted commit that may have written refs.
        refused.* = publication.rejected or (result.term == .exited and result.term.exited == 128 and
            std.mem.eql(u8, result.stdout, "start: ok\n"));
        return self.recordFailure(result.stderr);
    }
}

const Publication = struct { result: std.process.RunResult, rejected: bool };

/// --no-deref locks the requested names, including symbolic and absent
/// refs. Check their types only after prepare acknowledges those locks,
/// and keep stdin open so Git cannot publish before we choose commit.
fn inputRefTransaction(self: *const Git, message: []const u8, data: []const u8, updates: []const RefUpdate) !Publication {
    const argv = &.{ "git", "update-ref", "--no-deref", "--create-reflog", "-m", message, "--stdin" };
    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .cwd = if (self.cwd) |dir| .{ .dir = dir } else .inherit,
        .environ_map = self.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(self.io);

    var input_task = try self.io.concurrent(writePreparedInput, .{ self.io, child.stdin.?, data });
    defer input_task.cancel(self.io) catch {};
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(self.allocator, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    var decided = false;
    var rejection: ?[]u8 = null;
    defer if (rejection) |reason| self.allocator.free(reason);
    var validation_error: ?anyerror = null;
    while (reader.fill(64, .none)) |_| {
        try reader.checkAnyError();
        const stdout = reader.reader(0).buffered();
        if (stdout.len > stdout_limit or reader.reader(1).buffered().len > stderr_limit)
            return error.StreamTooLong;
        if (!decided and std.mem.endsWith(u8, stdout, "prepare: ok\n")) {
            try input_task.await(self.io);
            for (updates) |update| {
                const name = switch (update) {
                    inline else => |ref| ref.name,
                };
                self.requireDirectRef(name) catch |err| {
                    if (err == error.SymbolicRef) {
                        rejection = try std.fmt.allocPrint(self.allocator, "cannot publish symbolic ref {s}; managed refs must be direct", .{name.bytes});
                    } else validation_error = err;
                    break;
                };
            }
            const command = if (rejection != null or validation_error != null) "abort\n" else "commit\n";
            try child.stdin.?.writeStreamingAll(self.io, command);
            child.stdin.?.close(self.io);
            child.stdin = null;
            decided = true;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(self.io);
    if (term.success()) {
        try input_task.await(self.io);
        if (!decided) return error.InvalidGitOutput;
        if (validation_error) |err| return err;
    }
    const stdout = try reader.toOwnedSlice(0);
    errdefer self.allocator.free(stdout);
    const stderr = if (rejection) |reason| try self.allocator.dupe(u8, reason) else try reader.toOwnedSlice(1);
    return .{ .result = .{ .term = term, .stdout = stdout, .stderr = stderr }, .rejected = rejection != null };
}

fn writePreparedInput(io: Io, pipe: Io.File, data: []const u8) !void {
    try pipe.writeStreamingAll(io, data);
}
