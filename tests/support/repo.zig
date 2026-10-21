const std = @import("std");
const Git = @import("stakrr").git.Git;

const testing = std.testing;

pub const Options = struct {
    object_format: []const u8 = "sha1",
};

pub const Repo = struct {
    tmp: testing.TmpDir,
    // heap-allocated so git.environ_map stays valid when Repo is moved
    env: *std.process.Environ.Map,
    git: Git,

    pub fn init() !Repo {
        return initOptions(.{});
    }

    pub fn initOptions(options: Options) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const env = try hermeticEnv();
        errdefer destroyEnv(env);

        var repo = Repo{
            .tmp = tmp,
            .env = env,
            .git = .{
                .allocator = testing.allocator,
                .io = testing.io,
                .cwd = tmp.dir,
                .environ_map = env,
            },
        };

        try repo.exec(&.{
            "init", "-q", "-b", "main", "--object-format", options.object_format,
        });

        // never depend on identity/signing settings.
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
        destroyEnv(self.env);
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

/// the test process environment, isolated from global and system git
/// config, from any GIT_* variables of an enclosing git process, and from
/// colour overrides so output stays plain
pub fn hermeticEnv() !*std.process.Environ.Map {
    const env = try testing.allocator.create(std.process.Environ.Map);
    errdefer testing.allocator.destroy(env);

    env.* = try testing.environ.createMap(testing.allocator);
    errdefer env.deinit();

    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "NO_COLOR", "CLICOLOR_FORCE" }) |key| {
        _ = env.swapRemove(key);
    }
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    return env;
}

pub fn destroyEnv(env: *std.process.Environ.Map) void {
    env.deinit();
    testing.allocator.destroy(env);
}
