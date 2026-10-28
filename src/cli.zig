//! command-line parsing. pure: no git, no output
const std = @import("std");
const stakrr = @import("stakrr");
const stack = stakrr.stack;
const edit = stakrr.edit;

pub const Command = union(enum) {
    help,
    version,
    init: struct { base: []const u8 },
    status,
    log,
    undo,
    cut: struct { name: []const u8, at: ?[]const u8 = null },
    reset: stack.ResetOptions,
    navigate: stack.Direction,
    go: []const u8,
    edit: edit.Request,
};

pub const ParseError = error{ InvalidArguments, UnknownCommand };

pub fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return .help;

    const command = args[1];
    const rest = args[2..];

    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h"))
        return .help;

    if (eql(command, "version") or eql(command, "--version")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .version;
    }

    if (eql(command, "init")) {
        if (rest.len == 2 and eql(rest[0], "--base"))
            return .{ .init = .{ .base = try value(rest[1]) } };
        if (rest.len == 1 and std.mem.startsWith(u8, rest[0], "--base="))
            return .{ .init = .{ .base = try value(rest[0]["--base=".len..]) } };
        return error.InvalidArguments;
    }

    if (eql(command, "undo")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .undo;
    }

    if (eql(command, "log")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .log;
    }

    if (eql(command, "status")) {
        if (rest.len != 0) return error.InvalidArguments;
        return .status;
    }

    if (eql(command, "cut")) {
        var name: ?[]const u8 = null;
        var at: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const arg = rest[i];
            if (eql(arg, "--at")) {
                i += 1;
                if (at != null or i == rest.len) return error.InvalidArguments;
                at = try value(rest[i]);
            } else if (std.mem.startsWith(u8, arg, "--at=")) {
                if (at != null) return error.InvalidArguments;
                at = try value(arg["--at=".len..]);
            } else if (name == null) {
                name = try value(arg);
            } else {
                return error.InvalidArguments;
            }
        }
        return .{ .cut = .{
            .name = name orelse return error.InvalidArguments,
            .at = at,
        } };
    }

    if (eql(command, "go")) {
        if (rest.len != 1) return error.InvalidArguments;
        return .{ .go = try value(rest[0]) };
    }

    inline for (.{
        .{ "restack", edit.Request.restack },
        .{ "continue", edit.Request.continue_edit },
        .{ "abort", edit.Request.abort },
        .{ "quit", edit.Request.quit },
    }) |entry| {
        if (eql(command, entry[0])) {
            if (rest.len != 0) return error.InvalidArguments;
            return .{ .edit = entry[1] };
        }
    }

    if (eql(command, "reset")) {
        if (rest.len == 0) return .{ .reset = .{} };
        if (rest.len == 1 and eql(rest[0], "--delete-layers"))
            return .{ .reset = .{ .delete_layers = true } };
        return error.InvalidArguments;
    }

    if (std.meta.stringToEnum(stack.Direction, command)) |direction| {
        if (rest.len != 0) return error.InvalidArguments;
        return .{ .navigate = direction };
    }

    return error.UnknownCommand;
}

/// option values and positionals must be non-empty and not look like flags
fn value(arg: []const u8) ParseError![]const u8 {
    if (arg.len == 0 or arg[0] == '-') return error.InvalidArguments;
    return arg;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

test "parseArgs: help and version" {
    try testing.expectEqual(Command.help, try parseArgs(&.{"stakrr"}));
    try testing.expectEqual(Command.help, try parseArgs(&.{ "stakrr", "--help" }));
    try testing.expectEqual(Command.version, try parseArgs(&.{ "stakrr", "--version" }));
    try testing.expectError(error.UnknownCommand, parseArgs(&.{ "stakrr", "nope" }));
}

test "parseArgs: init" {
    const a = try parseArgs(&.{ "stakrr", "init", "--base", "main" });
    try testing.expectEqualStrings("main", a.init.base);

    const b = try parseArgs(&.{ "stakrr", "init", "--base=main" });
    try testing.expectEqualStrings("main", b.init.base);

    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "init" }));
    try testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "stakrr", "init", "--base", "--x" }),
    );
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "init", "--base=" }));
}

test "parseArgs: cut accepts --at in any position" {
    const a = try parseArgs(&.{ "stakrr", "cut", "p1" });
    try testing.expectEqualStrings("p1", a.cut.name);
    try testing.expect(a.cut.at == null);

    const b = try parseArgs(&.{ "stakrr", "cut", "--at", "HEAD~1", "p1" });
    try testing.expectEqualStrings("p1", b.cut.name);
    try testing.expectEqualStrings("HEAD~1", b.cut.at.?);

    const c = try parseArgs(&.{ "stakrr", "cut", "p1", "--at=HEAD~2" });
    try testing.expectEqualStrings("HEAD~2", c.cut.at.?);

    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut", "p1", "p2" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut", "p1", "--at" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "cut", "--bad" }));
}

test "parseArgs: status and reset" {
    try testing.expectEqual(Command.status, try parseArgs(&.{ "stakrr", "status" }));
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "status", "x" }));

    try testing.expect(!(try parseArgs(&.{ "stakrr", "reset" })).reset.delete_layers);
    try testing.expect(
        (try parseArgs(&.{ "stakrr", "reset", "--delete-layers" })).reset.delete_layers,
    );
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "reset", "--force" }));
}

test "parseArgs: up and down" {
    try testing.expectEqual(stack.Direction.up, (try parseArgs(&.{ "stakrr", "up" })).navigate);
    try testing.expectEqual(stack.Direction.down, (try parseArgs(&.{ "stakrr", "down" })).navigate);
    try testing.expectError(error.InvalidArguments, parseArgs(&.{ "stakrr", "up", "2" }));
}

test "parseArgs: go and session verbs" {
    try testing.expectEqual(edit.Request.restack, (try parseArgs(&.{ "stakrr", "restack" })).edit);
    try testing.expectEqualStrings("models", (try parseArgs(&.{ "stakrr", "go", "models" })).go);
    try testing.expectEqual(
        edit.Request.continue_edit,
        (try parseArgs(&.{ "stakrr", "continue" })).edit,
    );
    try testing.expectEqual(edit.Request.abort, (try parseArgs(&.{ "stakrr", "abort" })).edit);
    try testing.expectEqual(edit.Request.quit, (try parseArgs(&.{ "stakrr", "quit" })).edit);
    for ([_][]const []const u8{
        &.{ "stakrr", "go" },
        &.{ "stakrr", "go", "models", "api" },
        &.{ "stakrr", "go", "--abort" },
        &.{ "stakrr", "abort", "now" },
        &.{ "stakrr", "restack", "models" },
    }) |args| try testing.expectError(error.InvalidArguments, parseArgs(args));
}

test "parseArgs: the old edit command is gone" {
    try testing.expectError(error.UnknownCommand, parseArgs(&.{ "stakrr", "edit" }));
    try testing.expectError(error.UnknownCommand, parseArgs(&.{ "stakrr", "edit", "--abort" }));
}

test "parseArgs: log and undo reject extra arguments" {
    try testing.expectEqual(Command.log, try parseArgs(&.{ "stakrr", "log" }));
    try testing.expectEqual(Command.undo, try parseArgs(&.{ "stakrr", "undo" }));
    for ([_][]const []const u8{
        &.{ "stakrr", "log", "extra" },
        &.{ "stakrr", "undo", "extra" },
    }) |args| try testing.expectError(error.InvalidArguments, parseArgs(args));
}
