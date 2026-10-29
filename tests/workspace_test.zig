const std = @import("std");
const testing = std.testing;
const stakrr = @import("stakrr");
const edit = stakrr.edit;
const stack = stakrr.stack;
const Repo = @import("support/repo.zig").Repo;
const fixture = @import("support/edit_fixture.zig");

fn hooks(repo: *const Repo) !void {
    try repo.tmp.dir.createDir(testing.io, ".git/test-hooks", .default_dir);
    const script = "#!/bin/sh\nprintf hook > \"$(git rev-parse --git-common-dir)/hook-fired\"\n";
    for ([_][]const u8{ ".git/test-hooks/post-checkout", ".git/test-hooks/pre-commit" }) |path| try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = script, .flags = .{ .permissions = .executable_file } });
    const path = try repo.tmp.dir.realPathFileAlloc(testing.io, ".git/test-hooks", testing.allocator);
    defer testing.allocator.free(path);
    try repo.exec(&.{ "config", "core.hooksPath", path });
}

test "automated workspace operations bypass hooks while normal navigation runs them" {
    for ([_]bool{ false, true }) |conflict| {
        var repo = try Repo.init();
        defer repo.deinit();
        if (conflict) try fixture.conflictSetup(&repo) else {
            try fixture.setup(&repo);
            try fixture.correctModels(&repo);
        }
        try hooks(&repo);
        if (conflict) {
            try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
            var workspace = try fixture.workspace(&repo);
            defer workspace.tmp.dir.close(testing.io);
            try workspace.write("shared", "resolved\n");
            try workspace.exec(&.{ "add", "shared" });
            try edit.run(&repo.git, .continue_edit);
        } else try edit.run(&repo.git, .restack);
        try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, ".git/hook-fired", .{}));
        try stack.go(&repo.git, "api");
        try repo.expectFile(".git/hook-fired", "hook");
    }
}

test "replay is independent of the invoking sparse checkout" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    try fixture.correctModels(&repo);
    try repo.exec(&.{ "config", "extensions.worktreeConfig", "true" });
    try repo.exec(&.{ "sparse-checkout", "init", "--no-cone" });
    try repo.exec(&.{ "sparse-checkout", "set", "--no-cone", "model" });
    const sparse_path = try repo.git.path(&.{ "rev-parse", "--git-path", "info/sparse-checkout" });
    defer testing.allocator.free(sparse_path);
    const patterns = try repo.tmp.dir.readFileAlloc(testing.io, sparse_path, testing.allocator, .limited(4096));
    defer testing.allocator.free(patterns);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "api", .{}));
    try edit.run(&repo.git, .restack);
    try repo.expectOutput(&.{ "show", "work:api" }, "api");
    try repo.expectOutput(&.{ "show", "work:model" }, "corrected");
    try repo.expectFile(sparse_path, patterns);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "api", .{}));
    try fixture.valid(&repo);
}

test "gitlinks replay without automatic submodule initialization or forced cleanup" {
    var repo = try Repo.init();
    defer repo.deinit();
    try fixture.setup(&repo);
    const target = try repo.git.resolveCommitAlloc("main");
    defer testing.allocator.free(target);
    const cacheinfo = try std.fmt.allocPrint(testing.allocator, "160000,{s},vendor", .{target});
    defer testing.allocator.free(cacheinfo);
    try repo.exec(&.{ "update-index", "--add", "--cacheinfo", cacheinfo });
    try repo.write(".gitmodules", "[submodule \"vendor\"]\n\tpath = vendor\n\turl = https://invalid.example/never-initialize\n");
    try repo.exec(&.{ "add", ".gitmodules" });
    testing.allocator.free(try repo.commit("gitlink"));
    try repo.exec(&.{ "config", "submodule.recurse", "true" });
    try fixture.correctModels(&repo);
    edit.run(&repo.git, .restack) catch |err| switch (err) {
        error.WorkspaceCleanupPending => {
            var workspace = try fixture.workspace(&repo);
            defer workspace.tmp.dir.close(testing.io);
            try testing.expectError(error.FileNotFound, workspace.tmp.dir.access(testing.io, "vendor/.git", .{}));
            try edit.run(&repo.git, .quit);
        },
        else => return err,
    };
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "vendor/.git", .{}));
    const entry = try repo.git.output(&.{ "ls-tree", "work", "vendor" });
    defer testing.allocator.free(entry);
    try testing.expect(std.mem.startsWith(u8, entry, "160000 commit "));
    try fixture.noSession(&repo);
}

test "completed replay and abort history retain original edited and resolved objects after pruning" {
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        for ([_]bool{ false, true }) |abort| {
            var repo = try Repo.initOptions(.{ .object_format = format });
            defer repo.deinit();
            if (abort) try fixture.conflictSetup(&repo) else {
                try fixture.setup(&repo);
                try fixture.correctModels(&repo);
            }
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const git = repo.git.withAllocator(arena.allocator());
            const old_work = try git.resolveCommitAlloc("work");
            const edited = try git.resolveCommitAlloc("stakrr/models");
            var resolved: ?[]const u8 = null;
            if (abort) {
                try testing.expectError(error.ReplayConflict, edit.run(&repo.git, .restack));
                var workspace = try fixture.workspace(&repo);
                defer workspace.tmp.dir.close(testing.io);
                try workspace.write("shared", "resolved\n");
                try workspace.exec(&.{ "add", "shared" });
                try workspace.exec(&.{ "commit", "--quiet", "--no-edit" });
                resolved = try workspace.git.resolveCommitAlloc("HEAD");
                try edit.run(&repo.git, .abort);
            } else try edit.run(&repo.git, .restack);
            defer if (resolved) |oid| testing.allocator.free(oid);
            const new_work = try git.resolveCommitAlloc("work");
            try repo.exec(&.{ "switch", "--quiet", "work" });
            _ = try stack.reset(&repo.git, .{ .delete_layers = true });
            try repo.exec(&.{ "switch", "--quiet", "--orphan", "replacement" });
            const root = try repo.commit("unrelated");
            defer testing.allocator.free(root);
            try repo.exec(&.{ "update-ref", "refs/heads/main", root });
            try repo.exec(&.{ "update-ref", "refs/heads/work", root });
            try repo.exec(&.{ "reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all" });
            try repo.exec(&.{ "gc", "--prune=now" });
            for ([_][]const u8{ old_work, edited, new_work }) |oid| try repo.exec(&.{ "cat-file", "-e", oid });
            if (resolved) |oid| try repo.exec(&.{ "cat-file", "-e", oid });
            try repo.exec(&.{ "fsck", "--no-reflogs", "--full" });
        }
    }
}
