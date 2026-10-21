const std = @import("std");
const testing = std.testing;
const exe_path = @import("cli_options").exe_path;
const Repo = @import("support/repo.zig").Repo;

const Run = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// run the built stakrr binary inside the test repository
fn stakrr(repo: *const Repo, args: []const []const u8) !Run {
    // the build passes a path relative to the build root; the child runs
    // inside the temp repository, so resolve it first
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, exe_path, testing.allocator);
    defer testing.allocator.free(exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, exe);
    try argv.appendSlice(testing.allocator, args);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = repo.tmp.dir },
        .environ_map = repo.env,
    });

    return .{
        .code = switch (result.term) {
            .exited => |code| code,
            else => return error.Terminated,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn setup(repo: *const Repo) !void {
    const base = try repo.commit("base");
    testing.allocator.free(base);
    try repo.exec(&.{ "switch", "-q", "-c", "work" });
}

test "cli: full init, cut, status, reset flow" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(u8, 0), init.code);
    try testing.expectEqualStrings("", init.stderr);

    const b = try repo.commit("B");
    testing.allocator.free(b);

    const cut = try stakrr(&repo, &.{ "cut", "p1" });
    defer cut.deinit();
    try testing.expectEqual(@as(u8, 0), cut.code);
    try testing.expectEqualStrings("created layer: stakrr/p1\n", cut.stdout);

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(u8, 0), status.code);
    try testing.expectEqualStrings(
        \\stack  main → work
        \\
        \\  ▸ work        0 unstacked
        \\  │ stakrr/p1   1 commit
        \\  └ main        base
        \\
        \\  1 layer
        \\
    , status.stdout);

    const reset = try stakrr(&repo, &.{ "reset", "--delete-layers" });
    defer reset.deinit();
    try testing.expectEqual(@as(u8, 0), reset.code);
    try testing.expectEqualStrings("stack reset\ndeleted 1 layer branch\n", reset.stdout);

    const again = try stakrr(&repo, &.{ "init", "--base=main" });
    defer again.deinit();
    try testing.expectEqual(@as(u8, 0), again.code);
}

test "cli: failures print one clean message and exit non-zero" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(u8, 1), status.code);
    try testing.expectEqualStrings(
        "error: stack not initialized (run 'stakrr init --base <branch>')\n",
        status.stderr,
    );

    const usage = try stakrr(&repo, &.{ "cut", "a", "b" });
    defer usage.deinit();
    try testing.expectEqual(@as(u8, 2), usage.code);
    try testing.expect(std.mem.startsWith(u8, usage.stderr, "error: invalid arguments"));
}

test "cli: git failures include git's stderr" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();

    const b = try repo.commit("B");
    testing.allocator.free(b);

    const cut = try stakrr(&repo, &.{ "cut", "p1", "--at", "does-not-exist" });
    defer cut.deinit();
    try testing.expectEqual(@as(u8, 1), cut.code);
    try testing.expect(std.mem.startsWith(u8, cut.stderr, "error: git command failed\ngit: "));
}

test "cli: CLICOLOR_FORCE colours output unless NO_COLOR is set" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);

    try repo.env.put("CLICOLOR_FORCE", "1");
    const forced = try stakrr(&repo, &.{"status"});
    defer forced.deinit();
    try testing.expect(std.mem.startsWith(u8, forced.stderr, "\x1b[1m\x1b[31merror:\x1b[0m "));

    try repo.env.put("NO_COLOR", "1");
    const plain = try stakrr(&repo, &.{"status"});
    defer plain.deinit();
    try testing.expect(std.mem.startsWith(u8, plain.stderr, "error: "));
}

test "cli: help aligns the command list" {
    var repo = try Repo.init();
    defer repo.deinit();

    const help = try stakrr(&repo, &.{"help"});
    defer help.deinit();
    try testing.expectEqual(@as(u8, 0), help.code);
    try testing.expect(std.mem.startsWith(u8, help.stdout, "stakrr "));
    try testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "\n  cut <name> [--at <rev>]       create the next layer\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        help.stdout,
        "\n  status                        display layers and unstacked commits\n",
    ) != null);
}

test "cli: version" {
    var repo = try Repo.init();
    defer repo.deinit();

    const version = try stakrr(&repo, &.{"--version"});
    defer version.deinit();
    try testing.expectEqual(@as(u8, 0), version.code);
    try testing.expect(std.mem.startsWith(u8, version.stdout, "stakrr "));
}

test "cli: navigation and status follow the checked-out branch" {
    var repo = try Repo.init();
    defer repo.deinit();
    try setup(&repo);
    const init = try stakrr(&repo, &.{ "init", "--base", "main" });
    defer init.deinit();
    try testing.expectEqual(@as(u8, 0), init.code);

    const down = try stakrr(&repo, &.{"down"});
    defer down.deinit();
    try testing.expectEqual(@as(u8, 0), down.code);
    const status = try stakrr(&repo, &.{"status"});
    defer status.deinit();
    try testing.expectEqual(@as(u8, 0), status.code);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "▸ main") != null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "▸ work") == null);

    const base = try stakrr(&repo, &.{"down"});
    defer base.deinit();
    try testing.expectEqualStrings("already at base\n", base.stdout);
    const up = try stakrr(&repo, &.{"up"});
    defer up.deinit();
    try testing.expectEqual(@as(u8, 0), up.code);
    const top = try stakrr(&repo, &.{"up"});
    defer top.deinit();
    try testing.expectEqualStrings("already at top\n", top.stdout);

    try repo.exec(&.{ "switch", "-q", "--detach" });
    const detached = try stakrr(&repo, &.{"status"});
    defer detached.deinit();
    try testing.expectEqual(@as(u8, 0), detached.code);
    try testing.expect(std.mem.indexOf(u8, detached.stdout, "▸") == null);
}
