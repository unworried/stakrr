const std = @import("std");
const Git = @import("git.zig").Git;
const stack = @import("stack.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) return error.InvalidArguments;

    const git = Git{
        .allocator = allocator,
        .io = init.io,
    };

    if (std.mem.eql(u8, args[1], "init")) {
        if (args.len != 4 or
            !std.mem.eql(u8, args[2], "--base"))
        {
            return error.InvalidArguments;
        }

        try stack.initStack(&git, allocator, args[3]);
    } else if (std.mem.eql(u8, args[1], "status")) {
        if (args.len != 2)
            return error.InvalidArguments;

        var snapshot = try stack.inspect(&git, allocator);
        defer snapshot.deinit();

        try printStatus(init.io, allocator, snapshot);
    } else if (std.mem.eql(u8, args[1], "cut")) {
        if (args.len != 3 and
            !(args.len == 5 and std.mem.eql(u8, args[3], "--at")))
        {
            return error.InvalidArguments;
        }

        const revision: ?[]const u8 =
            if (args.len == 5) args[4] else null;

        try stack.cut(&git, allocator, args[2], revision);
    } else {
        return error.UnknownCommand;
    }
}

fn shortRef(ref_name: []const u8) []const u8 {
    const prefix = "refs/heads/";

    if (std.mem.startsWith(u8, ref_name, prefix))
        return ref_name[prefix.len..];

    return ref_name;
}

fn printStatus(
    io: std.Io,
    allocator: std.mem.Allocator,
    snapshot: stack.Snapshot,
) !void {
    const stdout = std.Io.File.stdout();

    const header = try std.fmt.allocPrint(
        allocator,
        "stack: {s} → {s}\n\n",
        .{
            shortRef(snapshot.config.base_ref),
            shortRef(snapshot.config.work_ref),
        },
    );
    try stdout.writeStreamingAll(io, header);

    if (snapshot.base_moved) {
        try stdout.writeStreamingAll(
            io,
            "  warning: base moved since initialization\n\n",
        );
    }

    for (snapshot.layers) |layer| {
        const line = try std.fmt.allocPrint(
            allocator,
            "  {s}: {d} commit(s)\n",
            .{ shortRef(layer.ref_name), layer.commits },
        );

        try stdout.writeStreamingAll(io, line);
    }

    const work_line = try std.fmt.allocPrint(
        allocator,
        "  {s}: {d} unstacked commit(s)\n",
        .{
            shortRef(snapshot.config.work_ref),
            snapshot.unstacked_commits,
        },
    );
    try stdout.writeStreamingAll(io, work_line);

    const footer = try std.fmt.allocPrint(
        allocator,
        "\n  {d} layer(s)\n",
        .{snapshot.layers.len},
    );
    try stdout.writeStreamingAll(io, footer);
}
