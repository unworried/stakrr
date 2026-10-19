//! terminal styling for cli output. colour is only emitted when the stream
//! is a terminal, NO_COLOR disables it and CLICOLOR_FORCE forces it on
const std = @import("std");
const Io = std.Io;
pub const Terminal = Io.Terminal;

/// the palette, kept to the 16 ANSI colours so it follows the user's theme
pub const Style = enum {
    accent,
    warn,
    err,
    dim,
    bold,

    fn colors(style: Style) []const Terminal.Color {
        return switch (style) {
            .accent => &.{.cyan},
            .warn => &.{.magenta},
            .err => &.{ .bold, .red },
            .dim => &.{.dim},
            .bold => &.{.bold},
        };
    }
};

pub fn detect(io: Io, file: Io.File, env: *const std.process.Environ.Map) Io.Cancelable!Terminal.Mode {
    return Terminal.Mode.detect(io, file, isSet(env, "NO_COLOR"), isSet(env, "CLICOLOR_FORCE"));
}

/// set and non-empty, matching the NO_COLOR and CLICOLOR_FORCE conventions
fn isSet(env: *const std.process.Environ.Map, key: []const u8) bool {
    const val = env.get(key) orelse return false;
    return val.len != 0;
}

/// print `fmt` in `style`, resetting afterwards
pub fn styled(
    t: Terminal,
    style: Style,
    comptime fmt: []const u8,
    args: anytype,
) Terminal.SetColorError!void {
    for (style.colors()) |c| try t.setColor(c);
    try t.writer.print(fmt, args);
    try t.setColor(.reset);
}

const testing = std.testing;

test "styled wraps text in escape codes" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const t: Terminal = .{ .writer = &w, .mode = .escape_codes };

    try styled(t, .err, "{s}", .{"error:"});
    try testing.expectEqualStrings("\x1b[1m\x1b[31merror:\x1b[0m", w.buffered());
}

test "styled writes plain text without colour" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const t: Terminal = .{ .writer = &w, .mode = .no_color };

    try styled(t, .accent, "{d} layers", .{2});
    try testing.expectEqualStrings("2 layers", w.buffered());
}

test "empty env values do not count as set" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("NO_COLOR", "");
    try env.put("CLICOLOR_FORCE", "1");

    try testing.expect(!isSet(&env, "NO_COLOR"));
    try testing.expect(isSet(&env, "CLICOLOR_FORCE"));
    try testing.expect(!isSet(&env, "TERM_UNSET_FOR_TEST"));
}
