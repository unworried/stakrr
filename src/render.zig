//! human-readable output for the cli. renders values; never runs git
const std = @import("std");
const build_options = @import("build_options");
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const term = @import("term.zig");
const Terminal = term.Terminal;

const help_commands = [_]struct { name: []const u8, args: []const u8, about: []const u8 }{
    .{ .name = "init", .args = "--base <branch>", .about = "adopt current branch as rolling work" },
    .{ .name = "status", .args = "", .about = "display layers and unstacked commits" },
    .{ .name = "cut", .args = "<name> [--at <rev>]", .about = "create the next layer" },
    .{ .name = "reset", .args = "[--delete-layers]", .about = "forget the stack so it can be re-initialized" },
    .{ .name = "up", .args = "", .about = "switch toward rolling work" },
    .{ .name = "down", .args = "", .about = "switch toward the base" },
    .{ .name = "version", .args = "", .about = "print the stakrr version" },
    .{ .name = "help", .args = "", .about = "show this message" },
};

pub fn printHelp(out: Terminal) !void {
    const w = out.writer;
    try term.styled(out, .bold, "stakrr", .{});
    try term.styled(out, .dim, " {s} // ", .{build_options.version});
    try w.writeAll("downstack from a rolling branch\n\n");

    try term.styled(out, .dim, "usage:", .{});
    try w.writeAll(" stakrr <command> [options]\n\n");

    for (help_commands) |cmd| {
        const width = cmd.name.len + @as(usize, if (cmd.args.len != 0) 1 else 0) + cmd.args.len;
        try w.writeAll("  ");
        try term.styled(out, .accent, "{s}", .{cmd.name});
        if (cmd.args.len != 0) try w.print(" {s}", .{cmd.args});
        try w.splatByteAll(' ', 30 - width);
        try term.styled(out, .dim, "{s}", .{cmd.about});
        try w.writeByte('\n');
    }
}

pub const shortRef = stakrr.layout.shortBranch;

pub fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// Draw the stack top-down, marking the checked-out branch with ▸.
pub fn printStatus(
    out: Terminal,
    snapshot: stack.Snapshot,
    current: ?[]const u8,
) !void {
    const w = out.writer;
    const base = shortRef(snapshot.config.base_ref);
    const work = shortRef(snapshot.config.work_ref);

    var width = @max(base.len, work.len);
    for (snapshot.layers) |layer|
        width = @max(width, shortRef(layer.ref_name).len);
    width += 3;

    try term.styled(out, .dim, "stack", .{});
    try w.print("  {s} → ", .{base});
    try term.styled(out, .accent, "{s}", .{work});
    try w.writeAll("\n\n");

    if (snapshot.base_moved) {
        try w.writeAll("  ");
        try term.styled(
            out,
            .warn,
            "warning: base moved since initialization; layers stay cut from the original base",
            .{},
        );
        try w.writeAll("\n\n");
    }

    try w.writeAll("  ");
    try term.styled(out, .accent, "{s} {s}", .{
        if (isCurrent(current, snapshot.config.work_ref)) "▸" else "│",
        work,
    });
    try w.splatByteAll(' ', width - work.len);
    try term.styled(out, .dim, "{d} unstacked", .{snapshot.unstacked_commits});
    try w.writeByte('\n');

    var i = snapshot.layers.len;
    while (i > 0) {
        i -= 1;
        const layer = snapshot.layers[i];
        const name = shortRef(layer.ref_name);
        const selected = isCurrent(current, layer.ref_name);

        try w.writeAll("  ");
        try term.styled(out, if (selected) .accent else .dim, "{s}", .{
            if (selected) "▸" else "│",
        });
        try w.print(" {s}", .{name});
        try w.splatByteAll(' ', width - name.len);
        try term.styled(out, .dim, "{d} {s}", .{
            layer.commits,
            plural(layer.commits, "commit", "commits"),
        });
        try w.writeByte('\n');
    }

    const base_selected = isCurrent(current, snapshot.config.base_ref);

    try w.writeAll("  ");
    try term.styled(out, if (base_selected) .accent else .dim, "{s}", .{
        if (base_selected) "▸" else "└",
    });
    try w.print(" {s}", .{base});
    try w.splatByteAll(' ', width - base.len);
    try term.styled(out, .dim, "base", .{});
    try w.writeByte('\n');

    try w.print("\n  {d} {s}\n", .{
        snapshot.layers.len,
        plural(snapshot.layers.len, "layer", "layers"),
    });
}

fn isCurrent(current: ?[]const u8, ref_name: []const u8) bool {
    return if (current) |ref| std.mem.eql(u8, ref, ref_name) else false;
}
