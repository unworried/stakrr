const std = @import("std");
const layout = @import("stakrr").layout;
const testing = std.testing;

const stakrr_git = @import("stakrr").git;
const Git = stakrr_git.Git;

const support = @import("support/repo.zig");
const Repo = support.Repo;

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

test "invalid repositories are failures rather than detached HEAD" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // prevent git from discovering an enclosing repository
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git",
        .data = "gitdir: does-not-exist\n",
    });

    const env = try support.hermeticEnv();
    defer support.destroyEnv(env);

    var diagnostics: stakrr_git.Diagnostics = .{};
    const git = Git{
        .allocator = testing.allocator,
        .io = testing.io,
        .cwd = tmp.dir,
        .environ_map = env,
        .diagnostics = &diagnostics,
    };

    try testing.expectError(
        error.NotGitRepository,
        git.ensureWorkTree(),
    );
    try testing.expectError(error.GitFailed, git.head());
    try testing.expectError(error.GitFailed, git.currentBranchAlloc());
    try testing.expect(diagnostics.stderr().len > 0);
}

test "currentBranch returns a full branch ref" {
    var repo = try Repo.init();
    defer repo.deinit();

    // works even before the first commit
    const branch = try repo.git.currentBranchAlloc();
    defer testing.allocator.free(branch);

    try testing.expectEqualStrings(
        "refs/heads/main",
        branch,
    );
    const head = (try repo.git.head()).?;
    defer testing.allocator.free(head);
    try testing.expectEqualStrings(branch, head);
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
        repo.git.currentBranchAlloc(),
    );
    try testing.expect((try repo.git.head()) == null);
}

test "query distinguishes missing values from fatal Git errors" {
    var repo = try Repo.init();
    defer repo.deinit();

    var diagnostics: stakrr_git.Diagnostics = .{};
    repo.git.diagnostics = &diagnostics;

    const output = (try repo.git.query(&.{ "rev-parse", "--is-inside-work-tree" }, 1)).?;
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("true", output);
    try testing.expect((try repo.git.query(&.{ "config", "--local", "--get-all", "stakrr.missing" }, 1)) == null);
    try testing.expectEqual(@as(usize, 0), diagnostics.stderr().len);

    try testing.expectError(error.GitFailed, repo.git.query(&.{ "rev-parse", "--verify", "refs/heads/missing" }, 1));
    try testing.expect(diagnostics.stderr().len > 0);
}

test "check distinguishes negative answers from fatal Git errors" {
    var repo = try Repo.init();
    defer repo.deinit();

    var diagnostics: stakrr_git.Diagnostics = .{};
    repo.git.diagnostics = &diagnostics;

    try testing.expect(try repo.git.check(&.{ "diff", "--cached", "--quiet" }, 1));
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "staged.txt", .data = "staged\n" });
    try repo.exec(&.{ "add", "staged.txt" });
    try testing.expect(!try repo.git.check(&.{ "diff", "--cached", "--quiet" }, 1));
    try testing.expectEqual(@as(usize, 0), diagnostics.stderr().len);

    try testing.expectError(error.GitFailed, repo.git.check(&.{ "rev-parse", "--verify", "refs/heads/missing" }, 1));
    try testing.expect(diagnostics.stderr().len > 0);
}

test "resolveCommit resolves a branch to its commit" {
    var repo = try Repo.init();
    defer repo.deinit();

    const expected = try repo.commit("base");
    defer testing.allocator.free(expected);

    const actual = try repo.git.resolveCommitAlloc("main");
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

test "resolveCommit rejects missing revisions" {
    var repo = try Repo.init();
    defer repo.deinit();

    try testing.expectError(
        error.GitFailed,
        repo.git.resolveCommitAlloc("missing-revision"),
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
        repo.git.resolveCommitAlloc("missing-revision"),
    );
    try testing.expect(diagnostics.stderr().len > 0);
}

test "ref constructors reject malformed names and OIDs without creating refs" {
    var repo = try Repo.init();
    defer repo.deinit();
    try testing.expectError(error.InvalidOid, repo.git.createRef("refs/stakrr/state", "HEAD"));
    try testing.expectError(error.InvalidRefName, repo.git.createRef(
        "refs/heads/x\ndelete refs/heads/main",
        &@as([40]u8, @splat('a')),
    ));
    try repo.expectOutput(&.{ "for-each-ref", "--format=%(refname)" }, "");
    try repo.expectNoRef(layout.transaction_ref);
}

test "configGet returns null when key is missing" {
    var repo = try Repo.init();
    defer repo.deinit();

    const value = try repo.git.configGet("test.value");
    try testing.expect(value == null);
}

test "configGet returns a single config value" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.exec(&.{
        "config",     "--local",    "--add",
        "test.value", "test value",
    });

    const value = (try repo.git.configGet("test.value")).?;
    defer testing.allocator.free(value);

    try testing.expectEqualStrings("test value", value);
}

test "configGet rejects duplicate values" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.exec(&.{
        "config",     "--local", "--add",
        "test.value", "first",
    });

    try repo.exec(&.{
        "config",     "--local", "--add",
        "test.value", "second",
    });

    try testing.expectError(
        error.InvalidGitConfig,
        repo.git.configGet("test.value"),
    );
}

test "configGet rejects empty values" {
    var repo = try Repo.init();
    defer repo.deinit();

    try repo.exec(&.{
        "config",     "--local", "--add",
        "test.value", "",
    });

    try testing.expectError(
        error.InvalidGitConfig,
        repo.git.configGet("test.value"),
    );
}

test "listDirectRefs returns empty when the prefix has no refs" {
    var repo = try Repo.init();
    defer repo.deinit();

    var refs = try repo.git.listDirectRefs("refs/heads/stakrr/");
    defer refs.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), refs.refs.len);
}

test "listDirectRefs finds only branches under the requested prefix" {
    var repo = try Repo.init();
    defer repo.deinit();

    const oid = try repo.commit("base");
    defer testing.allocator.free(oid);

    try repo.exec(&.{ "branch", "stakrr/first" });
    try repo.exec(&.{ "branch", "stakrr/second" });
    try repo.exec(&.{ "branch", "stakrr-other" });

    var refs = try repo.git.listDirectRefs("refs/heads/stakrr/");
    defer refs.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), refs.refs.len);
    try testing.expectEqualStrings("refs/heads/stakrr/first", refs.refs[0].name.bytes);
    try testing.expectEqualStrings(oid, refs.refs[0].oid.hex());
    try testing.expectEqualStrings("refs/heads/stakrr/second", refs.refs[1].name.bytes);
    try testing.expectEqualStrings(oid, refs.refs[1].oid.hex());
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
    const merge = try repo.git.resolveCommitAlloc("HEAD");
    defer testing.allocator.free(merge);

    var linear = try repo.git.history(base, main);
    defer linear.deinit(testing.allocator);
    try testing.expect(linear.linear);

    var merged = try repo.git.history(base, merge);
    defer merged.deinit(testing.allocator);
    try testing.expect(!merged.linear);
}

test "history reports an unrelated root as non-linear" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);
    try repo.exec(&.{ "switch", "--orphan", "unrelated" });
    const root = try repo.commit("root");
    defer testing.allocator.free(root);

    var history = try repo.git.history(base, root);
    defer history.deinit(testing.allocator);
    try testing.expect(!history.linear);
    try testing.expectEqual(@as(usize, 1), history.commits.len);
    try testing.expectEqualStrings(root, history.commits[0]);
}

test "history propagates invalid revisions with diagnostics" {
    var repo = try Repo.init();
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);
    var diagnostics: stakrr_git.Diagnostics = .{};
    repo.git.diagnostics = &diagnostics;

    try testing.expectError(error.GitFailed, repo.git.history(base, "missing-revision"));
    try testing.expect(diagnostics.stderr().len > 0);
}

test "typed queries support packed refs and sha256 history" {
    var repo = try Repo.initOptions(.{ .object_format = "sha256" });
    defer repo.deinit();

    const base = try repo.commit("base");
    defer testing.allocator.free(base);
    const tip = try repo.commit("tip");
    defer testing.allocator.free(tip);
    try repo.exec(&.{ "update-ref", "refs/stakrr/test/z", base });
    try repo.exec(&.{ "update-ref", "refs/stakrr/test/a", tip });
    try repo.exec(&.{ "update-ref", "refs/stakrr/test-other", tip });
    try repo.exec(&.{ "pack-refs", "--all", "--prune" });

    var refs = try repo.git.listDirectRefs("refs/stakrr/test/");
    defer refs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), refs.refs.len);
    try testing.expectEqualStrings("refs/stakrr/test/a", refs.refs[0].name.bytes);
    try testing.expectEqualStrings(tip, refs.refs[0].oid.hex());
    try testing.expectEqualStrings("refs/stakrr/test/z", refs.refs[1].name.bytes);
    try testing.expectEqualStrings(base, refs.refs[1].oid.hex());

    var history = try repo.git.history(base, tip);
    defer history.deinit(testing.allocator);
    try testing.expect(history.linear);
    try testing.expectEqual(@as(usize, 1), history.commits.len);
    try testing.expectEqualStrings(tip, history.commits[0]);
}

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

test "writeTree and commitTree preserve object format parent order and the index" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const first = try repo.commit("first");
        defer testing.allocator.free(first);
        const second = try repo.commit("second");
        defer testing.allocator.free(second);
        const blob = try repo.git.writeBlob("journal\n");
        defer testing.allocator.free(blob);
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "dirty", .data = "staged\n" });
        try repo.exec(&.{ "add", "dirty" });
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "dirty", .data = "unstaged\n" });
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "untracked", .data = "keep me\n" });
        const before_index = try repo.git.output(&.{ "ls-files", "--stage" });
        defer testing.allocator.free(before_index);
        const before_status = try repo.git.outputRaw(&.{ "status", "--porcelain=v1", "-z" });
        defer testing.allocator.free(before_status);
        const before_refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(before_refs);
        const tree = try repo.git.writeTree(&.{ .{ .name = "session.json", .oid = blob }, .{ .name = "plan", .oid = blob } });
        defer testing.allocator.free(tree);
        const checkpoint = try repo.git.commitTree(tree, &.{ first, second, first }, "readable checkpoint label");
        defer testing.allocator.free(checkpoint);
        const parents = try std.fmt.allocPrint(testing.allocator, "{s} {s}", .{ first, second });
        defer testing.allocator.free(parents);
        try repo.expectOutput(&.{ "show", "--no-patch", "--format=%P", checkpoint }, parents);
        try repo.expectOutput(&.{ "show", "--no-patch", "--format=%s", checkpoint }, "readable checkpoint label");
        const path = try std.fmt.allocPrint(testing.allocator, "{s}:session.json", .{checkpoint});
        defer testing.allocator.free(path);
        try repo.expectOutput(&.{ "show", path }, "journal");
        try repo.expectOutput(&.{ "ls-files", "--stage" }, before_index);
        const after_status = try repo.git.outputRaw(&.{ "status", "--porcelain=v1", "-z" });
        defer testing.allocator.free(after_status);
        try testing.expectEqualStrings(before_status, after_status);
        try repo.expectOutput(&.{"show-ref"}, before_refs);
        try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, second);
    }
}

test "object plumbing works in bare repositories in both object formats" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        try repo.exec(&.{ "init", "--bare", "-q", "--object-format", format, "bare.git" });
        const dir = try repo.tmp.dir.openDir(testing.io, "bare.git", .{});
        defer dir.close(testing.io);
        var git = repo.git;
        git.cwd = dir;
        try git.exec(&.{ "config", "user.name", "Stakrr Test" });
        try git.exec(&.{ "config", "user.email", "test@stakrr.local" });

        const blob = try git.writeBlob("bare\x00bytes\xff\n");
        defer testing.allocator.free(blob);
        const tree = try git.writeTree(&.{.{ .name = "file\twith spaces", .oid = blob }});
        defer testing.allocator.free(tree);
        const commit = try git.commitTree(tree, &.{}, "bare checkpoint");
        defer testing.allocator.free(commit);
        var mutation = try @import("stakrr").mutation.begin(&git, .refs);
        defer mutation.deinit();
        try mutation.publish(.{ .message = "bare refs", .updates = &.{
            try git.createRef("refs/heads/main", commit),
            try git.createRef("refs/stakrr/test", commit),
        } });
        const bytes = try git.outputRaw(&.{ "cat-file", "blob", blob });
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings("bare\x00bytes\xff\n", bytes);
        try testing.expectError(error.NotWorkingTree, git.ensureWorkTree());
        try git.exec(&.{ "fsck", "--no-reflogs" });
    }
}

test "tree plumbing uses Git ordering and rejects duplicate or invalid entries" {
    var repo = try Repo.init();
    defer repo.deinit();
    const blob = try repo.git.writeBlob("tree contents");
    defer testing.allocator.free(blob);
    const subtree = try repo.git.writeTree(&.{.{ .name = "child", .oid = blob }});
    defer testing.allocator.free(subtree);
    const entries = [_]Git.TreeEntry{
        .{ .name = "foo", .oid = subtree, .tree = true },
        .{ .name = "foo.bar", .oid = blob },
        .{ .name = "a\t b", .oid = blob },
    };
    const tree = try repo.git.writeTree(&entries);
    defer testing.allocator.free(tree);
    const names = try repo.git.outputRaw(&.{ "ls-tree", "--name-only", "-z", tree });
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("a\t b\x00foo.bar\x00foo\x00", names);
    try testing.expectError(error.InvalidRefName, repo.git.writeTree(&.{ entries[1], entries[1] }));
    try testing.expectError(error.InvalidRefName, repo.git.writeTree(&.{.{ .name = "../file", .oid = blob }}));
    try testing.expectError(error.InvalidOid, repo.git.writeTree(&.{.{ .name = "bad", .oid = "HEAD" }}));
}

test "blob input larger than a pipe buffer preserves all bytes" {
    var repo = try Repo.init();
    defer repo.deinit();
    const data = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i);
    const oid = try repo.git.writeBlob(data);
    defer testing.allocator.free(oid);
    const actual = try repo.git.outputRaw(&.{ "cat-file", "blob", oid });
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, data, actual);
}

test "input transport drains output while feeding data larger than pipe buffers" {
    var repo = try Repo.init();
    defer repo.deinit();
    const oid = try repo.git.writeBlob("batch object");
    defer testing.allocator.free(oid);
    const line_len = oid.len + 1;
    const requests = try testing.allocator.alloc(u8, line_len * 8192);
    defer testing.allocator.free(requests);
    var offset: usize = 0;
    while (offset < requests.len) : (offset += line_len) {
        @memcpy(requests[offset..][0..oid.len], oid);
        requests[offset + oid.len] = '\n';
    }
    const actual = try repo.git.inputOutput(&.{ "cat-file", "--batch-check=%(objectname)" }, requests);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(requests[0 .. requests.len - 1], actual);
}

test "input transport preserves early Git refusal diagnostics with large input" {
    var repo = try Repo.init();
    defer repo.deinit();
    var diagnostics: stakrr_git.Diagnostics = .{};
    repo.git.diagnostics = &diagnostics;
    const data = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try testing.expectError(error.GitFailed, repo.git.inputOutput(
        &.{ "hash-object", "--invalid-stakrr-option", "--stdin" },
        data,
    ));
    try testing.expect(diagnostics.stderr().len != 0);
    try repo.expectOutput(&.{ "for-each-ref", "--format=%(refname)" }, "");
}

fn treeWithFile(repo: *const Repo, data: []const u8) ![]u8 {
    const blob = try repo.git.writeBlob(data);
    defer testing.allocator.free(blob);
    return repo.git.writeTree(&.{.{ .name = "file", .oid = blob }});
}

test "mergeTree uses the explicit base and preserves refs and dirty work" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const base = try repo.commit("base");
        defer testing.allocator.free(base);
        const ours_tree = try treeWithFile(&repo, "ours\n");
        defer testing.allocator.free(ours_tree);
        const ours = try repo.git.commitTree(ours_tree, &.{base}, "ours");
        defer testing.allocator.free(ours);
        const blob = try repo.git.writeBlob("theirs\n");
        defer testing.allocator.free(blob);
        const theirs_tree = try repo.git.writeTree(&.{.{ .name = "other", .oid = blob }});
        defer testing.allocator.free(theirs_tree);
        // These commits are related, but their actual merge base is `ours`.
        // The supplied base must still apply both independent changes.
        const theirs = try repo.git.commitTree(theirs_tree, &.{ours}, "theirs");
        defer testing.allocator.free(theirs);
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "dirty", .data = "staged\n" });
        try repo.exec(&.{ "add", "dirty" });
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "dirty", .data = "unstaged\n" });
        const before_index = try repo.git.output(&.{"write-tree"});
        defer testing.allocator.free(before_index);
        const before_status = try repo.git.outputRaw(&.{ "status", "--porcelain=v1", "-z" });
        defer testing.allocator.free(before_status);
        const before_refs = try repo.git.output(&.{"show-ref"});
        defer testing.allocator.free(before_refs);

        const merged = (try repo.git.mergeTree(base, ours, theirs)) orelse return error.TestExpectedTree;
        defer testing.allocator.free(merged);
        const contents = try std.fmt.allocPrint(testing.allocator, "{s}:file", .{merged});
        defer testing.allocator.free(contents);
        try repo.expectOutput(&.{ "show", contents }, "ours");
        const other = try std.fmt.allocPrint(testing.allocator, "{s}:other", .{merged});
        defer testing.allocator.free(other);
        try repo.expectOutput(&.{ "show", other }, "theirs");
        try repo.expectOutput(&.{"write-tree"}, before_index);
        try repo.expectOutput(&.{"show-ref"}, before_refs);
        const after_status = try repo.git.outputRaw(&.{ "status", "--porcelain=v1", "-z" });
        defer testing.allocator.free(after_status);
        try testing.expectEqualStrings(before_status, after_status);
        try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, base);
    }
}

test "mergeTree returns null on conflict without publishing refs" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        var commits: [3][]u8 = undefined;
        var created: usize = 0;
        defer for (commits[0..created]) |oid| testing.allocator.free(oid);
        for ([_][]const u8{ "base\n", "ours\n", "theirs\n" }, 0..) |data, i| {
            const tree = try treeWithFile(&repo, data);
            defer testing.allocator.free(tree);
            commits[i] = try repo.git.commitTree(tree, if (i == 0) &.{} else &.{commits[0]}, data);
            created += 1;
        }
        const merged = try repo.git.mergeTree(commits[0], commits[1], commits[2]);
        defer if (merged) |tree| testing.allocator.free(tree);
        try testing.expect(merged == null);
        try repo.expectOutput(&.{ "for-each-ref", "--format=%(refname)" }, "");
        try repo.expectOutput(&.{ "status", "--porcelain" }, "");
    }
}

test "rewriteCommit replaces links and drops signatures while preserving metadata and message bytes" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const first = try repo.commit("first");
        defer testing.allocator.free(first);
        const second = try repo.commit("second");
        defer testing.allocator.free(second);
        const old_tree = try repo.git.writeTree(&.{});
        defer testing.allocator.free(old_tree);
        const new_tree = try treeWithFile(&repo, "replacement\n");
        defer testing.allocator.free(new_tree);
        const metadata = "author Original Author <author@example.test> 1234567890 +0130\n" ++
            "committer Original Committer <committer@example.test> 1234567999 -0200\n" ++
            "encoding ISO-8859-1\nx-custom retained\n continued header\n";
        for ([_][]const u8{ "", "subject\n\nbinary \xff body\n\n" }) |message| {
            const raw = try std.fmt.allocPrint(testing.allocator, "tree {s}\nparent {s}\nparent {s}\n{s}" ++
                "gpgsig fake signature\n continued signature\n" ++
                "gpgsig-sha256 another signature\n continued signature\n" ++
                "mergetag fake tag\n continued tag\n\n{s}", .{ old_tree, first, second, metadata, message });
            defer testing.allocator.free(raw);
            const source = try repo.git.inputOutput(&.{ "hash-object", "-w", "-t", "commit", "--stdin" }, raw);
            defer testing.allocator.free(source);
            const rewritten = try repo.git.rewriteCommit(source, new_tree, second);
            defer testing.allocator.free(rewritten);
            const actual = try repo.git.outputRaw(&.{ "cat-file", "commit", rewritten });
            defer testing.allocator.free(actual);
            const expected = try std.fmt.allocPrint(testing.allocator, "tree {s}\nparent {s}\n{s}\n{s}", .{
                new_tree, second, metadata, message,
            });
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, actual);
            const original = try repo.git.outputRaw(&.{ "cat-file", "commit", source });
            defer testing.allocator.free(original);
            try testing.expectEqualStrings(raw, original);
            try repo.expectOutput(&.{ "rev-parse", "--verify", "HEAD" }, second);
        }
    }
}

test "object plumbing rejects invalid object IDs before spawning Git" {
    for ([_][]const u8{ "sha1", "sha256" }) |format_name| {
        var repo = try Repo.initOptions(.{ .object_format = format_name });
        defer repo.deinit();
        const format = try repo.git.objectFormat();
        // Once repository metadata is known, invalid input must not spawn Git.
        try repo.env.put("PATH", "/nonexistent/stakrr-test-bin");
        const block = try repo.env.createPosixBlock(testing.allocator, .{});
        defer block.deinit(testing.allocator);
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = .{ .block = block } });
        defer threaded.deinit();
        var git = repo.git;
        git.io = threaded.io();
        git.object_format = format;
        const hex: [64]u8 = @splat('a');
        const zero: [64]u8 = @splat('0');
        const valid = hex[0..format.hexLength()];
        const other_len: usize = if (format == .sha1) 64 else 40;
        for ([_][]const u8{ "HEAD", "--bad", "bad\nvalue", zero[0..valid.len], hex[0..other_len] }) |invalid| {
            try testing.expectError(error.InvalidOid, git.writeTree(&.{.{ .name = "file", .oid = invalid }}));
            try testing.expectError(error.InvalidOid, git.commitTree(invalid, &.{}, "invalid tree"));
            try testing.expectError(error.InvalidOid, git.commitTree(valid, &.{invalid}, "invalid parent"));
            for ([_][3][]const u8{
                .{ invalid, valid, valid }, .{ valid, invalid, valid }, .{ valid, valid, invalid },
            }) |args| {
                try testing.expectError(error.InvalidOid, git.mergeTree(args[0], args[1], args[2]));
                try testing.expectError(error.InvalidOid, git.rewriteCommit(args[0], args[1], args[2]));
            }
        }
    }
}

test "object plumbing preserves failure diagnostics and rejects invalid Git output" {
    var repo = try Repo.init();
    defer repo.deinit();
    const format = try repo.git.objectFormat();
    try repo.tmp.dir.createDir(testing.io, "bin", .default_dir);
    const bin = try repo.tmp.dir.realPathFileAlloc(testing.io, "bin", testing.allocator);
    defer testing.allocator.free(bin);
    try repo.env.put("PATH", bin);
    // Executable lookup uses the I/O instance's environment, not the child's.
    const block = try repo.env.createPosixBlock(testing.allocator, .{});
    defer block.deinit(testing.allocator);
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = .{ .block = block } });
    defer threaded.deinit();
    var git = repo.git;
    git.io = threaded.io();
    git.object_format = format;
    var diagnostics: stakrr_git.Diagnostics = .{};
    git.diagnostics = &diagnostics;
    const valid = &@as([40]u8, @splat('a'));
    for ([_]struct { script: []const u8, expected: anyerror }{
        .{ .script = "#!/bin/sh\nexit 129\n", .expected = error.UnsupportedGitVersion },
        .{ .script = "#!/bin/sh\necho 'fatal: injected failure' >&2\nexit 128\n", .expected = error.GitFailed },
        .{ .script = "#!/bin/sh\nkill -TERM $$\n", .expected = error.GitTerminated },
        .{
            .script = "#!/bin/sh\ncase \"$1\" in hash-object|mktree) while IFS= read -r line; do :; done ;; esac\nprintf '%040d\\n' 0\n",
            .expected = error.InvalidGitOutput,
        },
        .{
            .script = "#!/bin/sh\ncase \"$1\" in hash-object|mktree) while IFS= read -r line; do :; done ;; esac\nprintf '%064d\\n' 1\n",
            .expected = error.InvalidGitOutput,
        },
    }) |case| {
        try repo.tmp.dir.writeFile(testing.io, .{
            .sub_path = "bin/git",
            .data = case.script,
            .flags = .{ .permissions = .executable_file },
        });
        try testing.expectError(case.expected, git.mergeTree(valid, valid, valid));
        if (case.expected == error.InvalidGitOutput) {
            try testing.expectError(error.InvalidGitOutput, git.writeBlob("contents\n"));
            try testing.expectError(error.InvalidGitOutput, git.writeTree(&.{}));
            try testing.expectError(error.InvalidGitOutput, git.commitTree(valid, &.{}, "invalid output"));
        }
        if (case.expected == error.GitFailed)
            try testing.expectEqualStrings("fatal: injected failure", diagnostics.stderr());
    }
}

test "Git paths preserve trailing newline bytes" {
    var repo = try Repo.init();
    defer repo.deinit();
    const path = try repo.git.path(&.{ "rev-parse", "--git-path", "trailing\n\n" });
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(".git/trailing\n\n", path);
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

test "configGet rejects trailing empty values and embedded newlines" {
    var repo = try Repo.init();
    defer repo.deinit();

    for ([_][]const u8{ "", "\n", "\r\n" }) |suffix| {
        try repo.exec(&.{ "config", "--local", "--replace-all", "test.value", "configured value" });
        try repo.exec(&.{ "config", "--local", "--add", "test.value", suffix });
        try testing.expectError(error.InvalidGitConfig, repo.git.configGet("test.value"));
    }
    try repo.exec(&.{ "config", "--local", "--replace-all", "test.value", "configured value\n" });
    try testing.expectError(error.InvalidGitConfig, repo.git.configGet("test.value"));
}

test "publication intent retains annotated tags through pruning" {
    var repo = try Repo.init();
    defer repo.deinit();
    const commit = try repo.commit("target");
    defer testing.allocator.free(commit);
    try repo.exec(&.{ "tag", "-a", "snapshot", "-m", "annotated snapshot", commit });
    const tag = (try repo.readRef("refs/tags/snapshot")).?;
    defer testing.allocator.free(tag);
    try repo.tmp.dir.createDir(testing.io, ".git/ref-hooks", .default_dir);
    try repo.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git/ref-hooks/reference-transaction",
        .flags = .{ .permissions = .executable_file },
        // Permit the intent, then refuse both publication and cancellation.
        .data = "#!/bin/sh\n[ \"$1\" = prepared ] || exit 0\n" ++
            "while read -r old new ref; do\n" ++
            "  case \"$old $ref\" in\n" ++
            "    '0000000000000000000000000000000000000000 refs/stakrr/transaction') exit 0 ;;\n" ++
            "  esac\ndone\nexit 1\n",
    });
    try repo.exec(&.{ "config", "core.hooksPath", ".git/ref-hooks" });
    {
        var mutation = try @import("stakrr").mutation.begin(&repo.git, .refs);
        defer mutation.deinit();
        try testing.expectError(error.GitFailed, mutation.publish(.{ .message = "tag copies", .updates = &.{
            try repo.git.createRef("refs/stakrr/copy-a", tag),
            try repo.git.createRef("refs/stakrr/copy-b", tag),
        } }));
    }
    try testing.expect(try repo.hasRef(layout.transaction_ref));
    try repo.exec(&.{ "config", "core.hooksPath", "/dev/null" });
    try repo.exec(&.{ "update-ref", "-d", "refs/tags/snapshot", tag });
    try repo.exec(&.{ "reflog", "expire", "--expire=now", "--all" });
    try repo.exec(&.{ "gc", "--prune=now" });
    try testing.expectError(error.GitFailed, repo.git.output(&.{ "cat-file", "-t", tag }));
    var recovered = try @import("stakrr").mutation.begin(&repo.git, .refs);
    defer recovered.deinit();
    try testing.expect(recovered.recovered);
    try repo.expectRef("refs/stakrr/copy-a", tag);
    try repo.expectRef("refs/stakrr/copy-b", tag);
    try repo.expectNoRef(layout.transaction_ref);
    try repo.exec(&.{ "fsck", "--no-reflogs" });
}

test "journaled transactions encode explicit absence and deletion in both object formats" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var repo = try Repo.initOptions(.{ .object_format = format });
        defer repo.deinit();
        const blob = try repo.git.writeBlob("ref contents");
        defer testing.allocator.free(blob);
        var mutation = try @import("stakrr").mutation.begin(&repo.git, .refs);
        defer mutation.deinit();
        try mutation.publish(.{ .message = "verify absence and create", .updates = &.{
            try repo.git.verifyRef("refs/stakrr/absent", null),
            try repo.git.createRef("refs/stakrr/a", blob),
            try repo.git.createRef("refs/stakrr/b", blob),
        } });
        try repo.expectRef("refs/stakrr/a", blob);
        try repo.expectRef("refs/stakrr/b", blob);
        try mutation.publish(.{ .message = "delete refs", .updates = &.{
            try repo.git.deleteRef("refs/stakrr/a", blob),
            try repo.git.deleteRef("refs/stakrr/b", blob),
        } });
        try repo.expectNoRef("refs/stakrr/a");
        try repo.expectNoRef("refs/stakrr/b");
        try repo.expectNoRef(layout.transaction_ref);
    }
}
