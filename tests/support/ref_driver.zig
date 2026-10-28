//! Run ref APIs in a child that inherits the fault shim's PATH. Executable
//! lookup in an existing Zig process does not use Git.environ_map's PATH.
const std = @import("std");
const stakrr = @import("stakrr");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const git: stakrr.git.Git = .{ .allocator = init.arena.allocator(), .io = init.io };
    run(&git, args[1..]) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err));
        std.process.exit(1);
    };
}

fn run(git: *const stakrr.git.Git, args: []const []const u8) !void {
    if (std.mem.eql(u8, args[0], "recover") or std.mem.eql(u8, args[0], "retain")) {
        // Journal APIs require the common mutation lock, including in a child.
        const common = try git.path(&.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
        const path = try std.fs.path.join(git.allocator, &.{ common, "stakrr.lock" });
        const guard = try std.Io.Dir.cwd().createFile(git.io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        defer guard.close(git.io);
        if (std.mem.eql(u8, args[0], "recover")) {
            if (!try git.recoverTransaction()) return error.ExpectedPendingTransaction;
        } else {
            try git.transact("test retained objects", &.{
                .{ .update = .{ .name = "refs/stakrr/commit", .old = args[1], .new = args[2] } },
                .{ .create = .{ .name = "refs/stakrr/blob", .oid = args[3] } },
                .{ .create = .{ .name = "refs/stakrr/tree", .oid = args[4] } },
                .{ .create = .{ .name = "refs/tags/retained", .oid = args[5] } },
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "reset")) {
        _ = try stakrr.stack.reset(git, .{ .delete_layers = true });
        return;
    }
    if (std.mem.eql(u8, args[0], "fix")) {
        var result = try stakrr.fix.fix(git, .{ .layer = "models", .how = .{ .message = "fix" } });
        defer result.deinit(git.allocator);
        return;
    }
    const name = "refs/stakrr/publication-test";
    const old = args[1];
    const new = args[2];
    const update: stakrr.git.Git.RefUpdate = if (std.mem.eql(u8, args[0], "verify") or std.mem.eql(u8, args[0], "verify_absent"))
        .{ .verify = .{ .name = name, .oid = old } }
    else if (std.mem.eql(u8, args[0], "create"))
        .{ .create = .{ .name = name, .oid = new } }
    else if (std.mem.eql(u8, args[0], "update"))
        .{ .update = .{ .name = name, .old = old, .new = new } }
    else if (std.mem.eql(u8, args[0], "delete"))
        .{ .delete = .{ .name = name, .oid = old } }
    else
        return error.InvalidTestOperation;
    try git.transactRaw("test symbolic publication", &.{
        update,
        .{ .create = .{ .name = "refs/stakrr/unrelated", .oid = new } },
    });
}
