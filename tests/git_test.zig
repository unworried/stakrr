const std = @import("std");
const Git = @import("git").Git;
const Repo = @import("support/repo.zig").Repo;

const testing = std.testing;

test "ensureWorkTree accepts a normal repository" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.git.ensureWorkTree();
}

test "ensureWorkTree rejects a bare repository" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const git = Git{
        .allocator = testing.allocator,
        .io = testing.io,
        .cwd = tmp.dir,
    };

    const output = try git.output(&.{ "init", "--bare", "-q" });
    defer testing.allocator.free(output);

    try testing.expectError(
        error.NotWorkingTree,
        git.ensureWorkTree(),
    );
}

test "ensureWorkTree rejects an invalid repository" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Prevent Git from discovering an enclosing repository.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git",
        .data = "gitdir: does-not-exist\n",
    });

    const git = Git{
        .allocator = testing.allocator,
        .io = testing.io,
        .cwd = tmp.dir,
    };

    try testing.expectError(
        error.NotGitRepository,
        git.ensureWorkTree(),
    );
}

test "currentBranch returns a full branch ref" {
    var repo = try Repo.init();
    defer repo.deinit();

    // works even before the first commit
    const branch = try repo.git.currentBranch();
    defer testing.allocator.free(branch);

    try testing.expectEqualStrings(
        "refs/heads/main",
        branch,
    );
}

test "currentBranch rejects detached HEAD" {
    var repo = try Repo.init();
    defer repo.deinit();

    const oid = try repo.commit("base");
    defer testing.allocator.free(oid);

    try repo.exec(&.{
        "switch", "--detach", "-q", "HEAD",
    });

    try testing.expectError(
        error.DetachedHead,
        repo.git.currentBranch(),
    );
}

test "resolveCommit resolves a branch to its commit" {
    var repo = try Repo.init();
    defer repo.deinit();

    const expected = try repo.commit("base");
    defer testing.allocator.free(expected);

    const actual = try repo.git.resolveCommit("main");
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

test "resolveCommit rejects missing revisions" {
    var repo = try Repo.init();
    defer repo.deinit();

    try testing.expectError(
        error.GitFailed,
        repo.git.resolveCommit("missing-revision"),
    );
}

test "isAncestor distinguishes commit ancestry" {
    var repo = try Repo.init();
    defer repo.deinit();

    // main: A
    const a = try repo.commit("A");
    defer testing.allocator.free(a);

    // feature: A -> B
    try repo.exec(&.{ "switch", "-q", "-c", "feature" });

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    try testing.expect(try repo.git.isAncestor(a, b));
    try testing.expect(!try repo.git.isAncestor(b, a));
    try testing.expect(try repo.git.isAncestor(a, a));
}

test "isAncestor reports invalid revisions as errors" {
    var repo = try Repo.init();
    defer repo.deinit();

    const oid = try repo.commit("base");
    defer testing.allocator.free(oid);

    try testing.expectError(
        error.GitFailed,
        repo.git.isAncestor("missing-revision", oid),
    );
}

test "output trims Git's trailing newline" {
    var repo = try Repo.init();
    defer repo.deinit();

    const output = try repo.git.output(&.{
        "rev-parse", "--is-inside-work-tree",
    });
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("true", output);
}

test "run preserves Git's nonzero exit status" {
    var repo = try Repo.init();
    defer repo.deinit();

    const result = try repo.git.run(&.{
        "rev-parse", "--verify", "refs/heads/missing",
    });
    defer repo.git.free(result);

    try testing.expect(!result.term.success());
    try testing.expect(result.stderr.len > 0);
}

test "configGet returns null when key is missing" {
    var repo = try Repo.init();
    defer repo.deinit();

    const value = try repo.git.configGet("stakrr.state");
    try testing.expect(value == null);
}

test "configGet returns a single config value" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.exec(&.{
        "config",       "--local", "--add",
        "stakrr.state", "v1 test",
    });

    const value = (try repo.git.configGet("stakrr.state")).?;
    defer testing.allocator.free(value);

    try testing.expectEqualStrings("v1 test", value);
}

test "configGet rejects duplicate values" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.exec(&.{
        "config",       "--local", "--add",
        "stakrr.state", "first",
    });

    try repo.exec(&.{
        "config",       "--local", "--add",
        "stakrr.state", "second",
    });

    try testing.expectError(
        error.InvalidGitConfig,
        repo.git.configGet("stakrr.state"),
    );
}

test "configGet rejects empty values" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.exec(&.{
        "config",       "--local", "--add",
        "stakrr.state", "",
    });

    try testing.expectError(
        error.InvalidGitConfig,
        repo.git.configGet("stakrr.state"),
    );
}

test "listStackRefs returns empty when no layers exist" {
    var repo = try Repo.init();
    defer repo.deinit();

    const refs = try repo.git.listStackRefs();
    defer testing.allocator.free(refs);

    try testing.expectEqualStrings("", refs);
}

test "listStackRefs finds only owned stack branches" {
    var repo = try Repo.init();
    defer repo.deinit();

    const oid = try repo.commit("base");
    defer testing.allocator.free(oid);

    try repo.exec(&.{ "branch", "stakrr/first" });
    try repo.exec(&.{ "branch", "stakrr/second" });
    try repo.exec(&.{ "branch", "stakrr-other" });

    const refs = try repo.git.listStackRefs();
    defer testing.allocator.free(refs);

    const first = try std.fmt.allocPrint(
        testing.allocator,
        "refs/heads/stakrr/first\t{s}",
        .{oid},
    );
    defer testing.allocator.free(first);

    try testing.expect(std.mem.indexOf(u8, refs, first) != null);

    try testing.expect(
        std.mem.indexOf(u8, refs, "refs/heads/stakrr/second\t") != null,
    );

    try testing.expect(
        std.mem.indexOf(u8, refs, "stakrr-other") == null,
    );
}

test "countCommits counts a linear range" {
    var repo = try Repo.init();
    defer repo.deinit();

    const a = try repo.commit("A");
    defer testing.allocator.free(a);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    try testing.expectEqual(
        @as(usize, 0),
        try repo.git.countCommits(a, a),
    );

    try testing.expectEqual(
        @as(usize, 1),
        try repo.git.countCommits(a, b),
    );

    try testing.expectEqual(
        @as(usize, 2),
        try repo.git.countCommits(a, c),
    );

    try testing.expectEqual(
        @as(usize, 0),
        try repo.git.countCommits(c, a),
    );
}
