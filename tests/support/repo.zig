const std = @import("std");
const Git = @import("git").Git;

const testing = std.testing;

pub const Repo = struct {
    tmp: testing.TmpDir,
    git: Git,

    pub fn init() !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var repo = Repo{
            .tmp = tmp,
            .git = .{
                .allocator = testing.allocator,
                .io = testing.io,
                .cwd = tmp.dir,
            },
        };

        try repo.exec(&.{ "init", "-q", "-b", "main" });

        // never depend on global identity/signing settings.
        try repo.exec(&.{
            "config", "--local", "user.name", "Stakrr Test",
        });
        try repo.exec(&.{
            "config", "--local", "user.email", "test@stakrr.local",
        });
        try repo.exec(&.{
            "config", "--local", "commit.gpgsign", "false",
        });
        try repo.exec(&.{
            "config", "--local", "core.hooksPath", "/dev/null",
        });

        return repo;
    }

    pub fn deinit(self: *Repo) void {
        self.tmp.cleanup();
    }

    pub fn exec(
        self: *const Repo,
        args: []const []const u8,
    ) !void {
        const output = try self.git.output(args);
        defer self.git.allocator.free(output);
    }

    /// make an empty commit, returning its owned oid
    pub fn commit(
        self: *const Repo,
        message: []const u8,
    ) ![]u8 {
        try self.exec(&.{
            "commit", "-q", "--allow-empty", "-m", message,
        });
        return self.git.resolveCommit("HEAD");
    }
};
