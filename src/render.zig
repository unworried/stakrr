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
    try w.writeByte('\n');
    if (status.progress) |progress| {
        try term.styled(out, .dim, "replay", .{});
        if (status.stopped) |stop| {
            try w.print(" {d}/{d} stopped at ", .{ progress.done + 1, progress.total });
            try term.styled(out, .warn, "{s}", .{stop.oid[0..7]});
            try w.print(" {s}\n", .{stop.subject});
        } else try w.print(" {d}/{d} done\n", .{ progress.done, progress.total });
    }
    try w.writeByte('\n');

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
    // every command that can move this phase forward, back, or out
    switch (status.phase) {
        .editing => try w.writeAll("\n  commit fixes, then stakrr edit <cut> to move or stakrr edit to finish\n" ++
            "  stakrr edit --abort restores the pre-edit stack\n"),
        .conflict => try w.writeAll("\n  resolve conflicts, git add, then stakrr edit --continue\n" ++
            "  to give up, commit the resolution, then stakrr edit --abort\n"),
        else => try w.writeAll("\n  stakrr edit --continue\n" ++
            "  stakrr edit --abort restores the pre-edit stack\n" ++
            "  stakrr edit --quit leaves HEAD and branches as they are\n"),
    }
}

/// Git-style hints naming what changed under an edit and how to put it back.
pub fn printDriftHints(out: Terminal, drift: edit.Drift) !void {
    const name = drift.name;
    if (std.mem.eql(u8, name, "HEAD")) {
        const expected = drift.expected.?;
        try hint(out, "HEAD is at {s}, expected {s}", .{ drift.actual.?, shortRef(expected) });
        if (std.mem.startsWith(u8, expected, stakrr.layout.branch_prefix)) {
            try hint(out, "restore it: git switch {s}", .{shortRef(expected)});
        } else try hint(out, "restore it: git switch --detach {s}", .{expected});
    } else if (std.mem.eql(u8, name, stakrr.layout.state_key)) {
        try hint(out, "{s} is '{s}', expected '{s}'", .{ name, drift.actual orelse "", drift.expected.? });
        try hint(out, "restore it: git config {s} '{s}'", .{ name, drift.expected.? });
    } else if (drift.expected) |expected| {
        if (drift.actual) |actual| {
            try hint(out, "{s} is at {s}, expected {s}", .{ name, actual, expected });
            try keepHint(out, name, actual);
            try hint(out, "restore it: git update-ref {s} {s} {s}", .{ name, expected, actual });
        } else {
            try hint(out, "{s} is missing, expected {s}", .{ name, expected });
            try hint(out, "restore it: git update-ref {s} {s}", .{ name, expected });
        }
    } else {
        const actual = drift.actual.?;
        try hint(out, "{s} at {s} is not part of the edit session", .{ name, actual });
        try keepHint(out, name, actual);
        try hint(out, "remove it: git update-ref -d {s} {s}", .{ name, actual });
    }
    try hint(out, "then rerun the stakrr edit command, or keep it and leave: stakrr edit --quit", .{});
}

fn keepHint(out: Terminal, name: []const u8, actual: []const u8) !void {
    if (!std.mem.startsWith(u8, name, stakrr.layout.branch_prefix)) return;
    try hint(out, "keep it:    git branch rescue/{s} {s}", .{ shortRef(name), actual });
}

fn hint(out: Terminal, comptime fmt: []const u8, args: anytype) !void {
    try term.styled(out, .dim, "hint:", .{});
    try out.writer.print(" " ++ fmt ++ "\n", args);
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
