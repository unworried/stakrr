//! Value validation and query ownership for the typed Git API.
const std = @import("std");
const testing = std.testing;
const git = @import("stakrr").git;
const Repo = @import("support/repo.zig").Repo;

// Check Git's own parser as well, so the expected rules stay independent of
// the implementation under test.
test "validated ref names agree with Git for valid names and protocol injection" {
    var repo = try Repo.init();
    defer repo.deinit();
    for ([_]struct { name: []const u8, valid: bool }{
        .{ .name = "refs/heads/main", .valid = true },
        .{ .name = "refs/heads/stakrr/nested/name", .valid = true },
        .{ .name = "refs/tags/release-1.0", .valid = true },
        .{ .name = "refs/heads/", .valid = false },
        .{ .name = "refs/heads/.hidden", .valid = false },
        .{ .name = "refs/heads/a..b", .valid = false },
        .{ .name = "refs/heads/a@{b", .valid = false },
        .{ .name = "refs/heads/a.lock/b", .valid = false },
        .{ .name = "refs//heads/main", .valid = false },
        .{ .name = "refs/heads/a.", .valid = false },
        .{ .name = "refs/heads/a b", .valid = false },
        .{ .name = "refs/heads/a\nverify refs/heads/main", .valid = false },
        .{ .name = "refs/heads/a\\b", .valid = false },
        .{ .name = "refs/heads/a?b", .valid = false },
        .{ .name = "refs/heads/a[b", .valid = false },
        .{ .name = "refs/heads/a\x7fb", .valid = false },
    }) |case| {
        if (case.valid) {
            const name = try git.RefName.init(case.name);
            try testing.expectEqualStrings(case.name, name.bytes);
        } else {
            try testing.expectError(error.InvalidRefName, git.RefName.init(case.name));
        }
        try testing.expectEqual(case.valid, try repo.git.check(&.{ "check-ref-format", case.name }, 1));
    }
    for ([_][]const u8{ "HEAD", "heads/main", "--help", "refs/heads/a\x00b" }) |name|
        try testing.expectError(error.InvalidRefName, git.RefName.init(name));
    for ([_][]const u8{ "refs/tags/v1", "refs/heads/-option", "refs/heads/" }) |name|
        try testing.expectError(error.InvalidRefName, git.BranchRef.init(name));
    const branch = try git.BranchRef.init("refs/heads/nested/work");
    try testing.expectEqualStrings("nested/work", branch.short());
}

test "object IDs own their bytes and reject zero IDs and the other object format" {
    for ([_][]const u8{ "sha1", "sha256" }) |format_name| {
        var repo = try Repo.initOptions(.{ .object_format = format_name });
        defer repo.deinit();
        const format = try repo.git.objectFormat();
        var text: [64]u8 = @splat('a');
        const oid = try git.Oid.init(format, text[0..format.hexLength()]);
        @memset(&text, 'b');
        const expected: [64]u8 = @splat('a');
        try testing.expectEqualStrings(expected[0..format.hexLength()], oid.hex());
        const zero: [64]u8 = @splat('0');
        const upper: [64]u8 = @splat('A');
        const other_length: usize = if (format == .sha1) 64 else 40;
        for ([_][]const u8{ "HEAD", "", zero[0..format.hexLength()], upper[0..format.hexLength()], text[0..other_length] }) |invalid|
            try testing.expectError(error.InvalidOid, repo.git.parseOid(invalid));
    }
}

test "typed query results outlive later queries and branch name storage is owned" {
    var repo = try Repo.init();
    defer repo.deinit();
    const base = try repo.commit("base");
    defer testing.allocator.free(base);
    const oid = try repo.git.resolveCommit("HEAD");
    var branch = try repo.git.currentBranch();
    defer branch.deinit(testing.allocator);
    try repo.exec(&.{ "branch", "-m", "renamed" });
    testing.allocator.free(try repo.commit("next"));
    const later = try repo.git.resolveCommit("HEAD");
    try testing.expect(!git.Oid.eql(oid, later));
    try testing.expectEqualStrings(base, oid.hex());
    try testing.expectEqualStrings("refs/heads/main", branch.value.name.bytes);
    const tip = try repo.git.branchCommit(try git.BranchRef.init("refs/heads/renamed"));
    try testing.expect(git.Oid.eql(later, tip));
}

test "user revisions resolve symbolic branches while managed branch queries refuse them" {
    var repo = try Repo.init();
    defer repo.deinit();
    const expected = try repo.commit("base");
    defer testing.allocator.free(expected);
    try repo.exec(&.{ "symbolic-ref", "refs/heads/alias", "refs/heads/main" });
    const revision = try repo.git.resolveCommit("refs/heads/alias");
    try testing.expectEqualStrings(expected, revision.hex());
    try testing.expectError(error.SymbolicRef, repo.git.branchCommit(try git.BranchRef.init("refs/heads/alias")));
    try repo.expectRef("refs/heads/main", expected);
}
