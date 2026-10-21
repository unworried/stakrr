const std = @import("std");
const layout = @import("stakrr").layout;
const testing = std.testing;

const stakrr_git = @import("stakrr").git;
const Git = stakrr_git.Git;

const support = @import("support/repo.zig");
const Repo = support.Repo;

test "blob storage computes Git object IDs for both formats and arbitrary bytes" {
    inline for (.{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();

        for ([_][]const u8{ "", "metadata\x00with binary bytes\xff\n\n" }) |data| {
            const oid = try repo.git.writeBlob(data);
            defer testing.allocator.free(oid);
            try testing.expectEqual(@as(usize, if (std.mem.eql(u8, format, "sha1")) 40 else 64), oid.len);
            const bytes = try repo.git.outputRaw(&.{ "cat-file", "blob", oid });
            defer testing.allocator.free(bytes);
            try testing.expectEqualStrings(data, bytes);
        }
    }
}

test "Git paths preserve trailing newline bytes" {
    var repo = try Repo.init();
    defer repo.deinit();
    const path = try repo.git.path(&.{ "rev-parse", "--git-path", "trailing\n\n" });
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(".git/trailing\n\n", path);
}

test "ensureWorkTree accepts a normal repository" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.git.ensureWorkTree();
}

test "ensureWorkTree rejects a bare repository" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try support.hermeticEnv();
    defer support.destroyEnv(env);

    const git = Git{
        .allocator = testing.allocator,
        .io = testing.io,
        .cwd = tmp.dir,
        .environ_map = env,
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

    // prevent git from discovering an enclosing repository
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git",
        .data = "gitdir: does-not-exist\n",
    });

    const env = try support.hermeticEnv();
    defer support.destroyEnv(env);

    const git = Git{
        .allocator = testing.allocator,
        .io = testing.io,
        .cwd = tmp.dir,
        .environ_map = env,
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
    defer repo.git.freeResult(result);

    try testing.expect(!result.term.success());
    try testing.expect(result.stderr.len > 0);
}

test "failed commands record git's stderr in diagnostics" {
    var repo = try Repo.init();
    defer repo.deinit();

    var diagnostics: stakrr_git.Diagnostics = .{};
    repo.git.diagnostics = &diagnostics;

    try testing.expectError(
        error.GitFailed,
        repo.git.resolveCommit("missing-revision"),
    );
    try testing.expect(diagnostics.stderr().len > 0);
}

test "transact rejects malformed oids before writing to git" {
    var repo = try Repo.init();
    defer repo.deinit();

    try testing.expectError(
        error.InvalidOid,
        repo.git.transact("test", &.{.{ .create = .{
            .name = layout.tip_ref,
            .oid = "HEAD",
        } }}),
    );
    try testing.expectError(
        error.InvalidRefName,
        repo.git.transact("test", &.{.{ .create = .{
            .name = "refs/heads/x\ndelete refs/heads/main",
            .oid = &@as([40]u8, @splat('a')),
        } }}),
    );
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

test "listRefs returns empty when the prefix has no refs" {
    var repo = try Repo.init();
    defer repo.deinit();

    var refs = try repo.git.listRefs("refs/heads/stakrr/");
    defer refs.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), refs.refs.len);
}

test "listRefs finds only branches under the requested prefix" {
    var repo = try Repo.init();
    defer repo.deinit();

    const oid = try repo.commit("base");
    defer testing.allocator.free(oid);

    try repo.exec(&.{ "branch", "stakrr/first" });
    try repo.exec(&.{ "branch", "stakrr/second" });
    try repo.exec(&.{ "branch", "stakrr-other" });

    var refs = try repo.git.listRefs("refs/heads/stakrr/");
    defer refs.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), refs.refs.len);
    try testing.expectEqualStrings("refs/heads/stakrr/first", refs.refs[0].name);
    try testing.expectEqualStrings(oid, refs.refs[0].oid);
    try testing.expectEqualStrings("refs/heads/stakrr/second", refs.refs[1].name);
    try testing.expectEqualStrings(oid, refs.refs[1].oid);
}

test "history lists a range oldest first" {
    var repo = try Repo.init();
    defer repo.deinit();

    const a = try repo.commit("A");
    defer testing.allocator.free(a);

    const b = try repo.commit("B");
    defer testing.allocator.free(b);

    const c = try repo.commit("C");
    defer testing.allocator.free(c);

    var empty = try repo.git.history(a, a);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.commits.len);

    var range = try repo.git.history(a, c);
    defer range.deinit(testing.allocator);
    try testing.expect(range.linear);
    try testing.expectEqual(@as(usize, 2), range.commits.len);
    try testing.expectEqualStrings(b, range.commits[0]);
    try testing.expectEqualStrings(c, range.commits[1]);

    var backwards = try repo.git.history(c, a);
    defer backwards.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), backwards.commits.len);
}

test "history reports merges as non-linear" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);
    try repo.exec(&.{ "switch", "-q", "-c", "side" });
    const side = try repo.commit("side");
    defer testing.allocator.free(side);
    try repo.exec(&.{ "switch", "-q", "main" });
    const main = try repo.commit("main");
    defer testing.allocator.free(main);
    try repo.exec(&.{ "merge", "-q", "--no-edit", "side" });
    const merge = try repo.git.resolveCommit("HEAD");
    defer testing.allocator.free(merge);

    var linear = try repo.git.history(base, main);
    defer linear.deinit(testing.allocator);
    try testing.expect(linear.linear);

    var merged = try repo.git.history(base, merge);
    defer merged.deinit(testing.allocator);
    try testing.expect(!merged.linear);
}
