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
        var mutation = try @import("stakrr").mutation.begin(git, .refs);
        defer mutation.deinit();
        if (std.mem.eql(u8, args[0], "recover")) {
            if (!mutation.recovered) return error.ExpectedPendingTransaction;
        } else {
            try mutation.publish(.{ .message = "test retained objects", .updates = &.{
                try git.updateRef("refs/stakrr/commit", args[1], args[2]),
                try git.createRef("refs/stakrr/blob", args[3]),
                try git.createRef("refs/stakrr/tree", args[4]),
                try git.createRef("refs/tags/retained", args[5]),
            } });
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
    var mutation = try @import("stakrr").mutation.begin(git, .refs);
    defer mutation.deinit();
    const name = "refs/stakrr/publication-test";
    const old = args[1];
    const new = args[2];
    const update = if (std.mem.eql(u8, args[0], "verify"))
        try git.verifyRef(name, old)
    else if (std.mem.eql(u8, args[0], "verify_absent"))
        try git.verifyRef(name, null)
    else if (std.mem.eql(u8, args[0], "create"))
        try git.createRef(name, new)
    else if (std.mem.eql(u8, args[0], "update"))
        try git.updateRef(name, old, new)
    else if (std.mem.eql(u8, args[0], "delete"))
        try git.deleteRef(name, old)
    else
        return error.InvalidTestOperation;
    try mutation.publish(.{ .message = "test symbolic publication", .updates = &.{
        update,
        try git.createRef("refs/stakrr/unrelated", new),
    } });
}
