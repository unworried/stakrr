//! human-readable output for the cli. renders values; never runs git
const std = @import("std");
const build_options = @import("build_options");
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const edit = stakrr.edit;
const term = @import("term.zig");
const Terminal = term.Terminal;

pub const shortRef = stakrr.layout.shortBranch;

pub fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

const help_commands = [_]struct { name: []const u8, args: []const u8, about: []const u8 }{
    .{ .name = "init", .args = "--base <branch>", .about = "adopt current branch as rolling work" },
    .{ .name = "status", .args = "", .about = "display layers and unstacked commits" },
    .{ .name = "cut", .args = "<name> [--at <rev>]", .about = "create the next layer" },
    .{
        .name = "edit",
        .args = "[<cut>|--continue|--abort|--quit]",
        .about = "edit a cut and replay descendants",
    },
    .{
        .name = "reset",
        .args = "[--delete-layers]",
        .about = "forget the stack so it can be re-initialized",
    },
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
        try w.splatByteAll(' ', @max(30, width + 2) - width);
        try term.styled(out, .dim, "{s}", .{cmd.about});
        try w.writeByte('\n');
    }
}

/// Draw the stack top-down, marking the checked-out branch with ▸.
pub fn printStatus(
    out: Terminal,
    snapshot: stack.Snapshot,
    current: ?[]const u8,
) !void {
    const w = out.writer;
    const config = snapshot.config;

    var width = columnWidth(config.base_ref, config.work_ref);
    for (snapshot.layers) |layer| width = @max(width, columnWidth(config.base_ref, layer.ref_name));

    try printStackHeader(out, config.base_ref, config.work_ref);
    try w.writeByte('\n');

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

    try printStackRow(out, config.work_ref, isCurrent(current, config.work_ref), false, width);
    try term.styled(out, .dim, "{d} unstacked", .{snapshot.unstacked_commits});
    try w.writeByte('\n');

    var i = snapshot.layers.len;
    while (i > 0) {
        i -= 1;
        const layer = snapshot.layers[i];
        try printStackRow(out, layer.ref_name, isCurrent(current, layer.ref_name), false, width);
        try term.styled(out, .dim, "{d} {s}", .{
            layer.commits,
            plural(layer.commits, "commit", "commits"),
        });
        try w.writeByte('\n');
    }

    try printFooter(out, config.base_ref, current, width, snapshot.layers.len);
}

/// The stack as an active edit session sees it, with the pending transition.
pub fn printEditStatus(out: Terminal, status: edit.Status, current: ?[]const u8) !void {
    const w = out.writer;
    try printStackHeader(out, status.base, status.branches[status.branches.len - 1]);
    try term.styled(out, .dim, "edit", .{});
    try w.writeAll("   ");
    try term.styled(out, .accent, "{s}", .{shortRef(status.branches[status.active])});
    if (status.phase != .editing)
        try w.print(" ({s}) → {s}", .{ @tagName(status.phase), shortRef(status.destination) });
    try w.writeAll("\n\n");

    var width: usize = 0;
    for (status.branches) |ref| width = @max(width, columnWidth(status.base, ref));

    var i = status.branches.len;
    while (i > 0) {
        i -= 1;
        const active = i == status.active;
        try printStackRow(out, status.branches[i], isCurrent(current, status.branches[i]), false, if (active) width else 0);
        if (active)
            try term.styled(out, if (status.phase == .conflict) .warn else .dim, "{s}", .{@tagName(status.phase)});
        try w.writeByte('\n');
    }

    try printFooter(out, status.base, current, width, status.branches.len - 1);
    if (status.phase == .conflict) {
        try w.writeAll("\n  resolve conflicts, git add, then stakrr edit --continue\n");
    } else if (status.phase != .editing) {
        try w.writeAll("\n  stakrr edit --continue\n");
    }
}

fn printStackHeader(out: Terminal, base: []const u8, work: []const u8) !void {
    try term.styled(out, .dim, "stack", .{});
    try out.writer.print("  {s} → ", .{shortRef(base)});
    try term.styled(out, .accent, "{s}", .{shortRef(work)});
    try out.writer.writeByte('\n');
}

/// Name column wide enough for the base and `ref`, plus a gutter.
fn columnWidth(base: []const u8, ref: []const u8) usize {
    return @max(shortRef(base).len, shortRef(ref).len) + 3;
}

/// Shared branch markers and column alignment for ordinary and edit status.
fn printStackRow(out: Terminal, ref: []const u8, selected: bool, base: bool, width: usize) !void {
    const name = shortRef(ref);
    try out.writer.writeAll("  ");
    try term.styled(out, if (selected) .accent else .dim, "{s}", .{
        if (selected) "▸" else if (base) "└" else "│",
    });
    try out.writer.print(" {s}", .{name});
    if (width > name.len) try out.writer.splatByteAll(' ', width - name.len);
}

/// The base row and the layer count that close every stack drawing.
fn printFooter(out: Terminal, base: []const u8, current: ?[]const u8, width: usize, layers: usize) !void {
    try printStackRow(out, base, isCurrent(current, base), true, width);
    try term.styled(out, .dim, "base", .{});
    try out.writer.print("\n\n  {d} {s}\n", .{ layers, plural(layers, "layer", "layers") });
}

fn isCurrent(current: ?[]const u8, ref_name: []const u8) bool {
    return if (current) |ref| std.mem.eql(u8, ref, ref_name) else false;
}
