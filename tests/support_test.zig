//! Test infrastructure must isolate Git and verify user bytes independently.
const std = @import("std");
const testing = std.testing;
const support = @import("support/repo.zig");
const Repo = support.Repo;

test "fixture environment removes inherited Git config paths identity and fault controls" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const inherited = [_][]const u8{
        "GIT_DIR",                     "GIT_COMMON_DIR",                   "GIT_WORK_TREE",            "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",            "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0",            "GIT_CONFIG_VALUE_0",               "GIT_CONFIG_PARAMETERS",    "GIT_AUTHOR_NAME",
        "GIT_AUTHOR_EMAIL",            "GIT_AUTHOR_DATE",                  "GIT_COMMITTER_DATE",       "GIT_DEFAULT_HASH",
        "GIT_TEST_DEFAULT_REF_FORMAT", "GIT_CONFIG_GLOBAL",                "GIT_CONFIG_NOSYSTEM",      "STAKRR_TEST_FAULT",
        "STAKRR_TEST_PARTIAL_LABEL",   "STAKRR_TEST_GIT",                  "STAKRR_TEST_SYMREF_LABEL", "NO_COLOR",
        "CLICOLOR_FORCE",
    };
    for (inherited) |key| try env.put(key, "inherited");
    try env.put("PATH", "/fixture/bin:/usr/bin:/bin");
    try env.put("LC_ALL", "unexpected-locale");
    try support.isolateEnv(&env);
    for (inherited) |key| {
        if (std.mem.eql(u8, key, "GIT_CONFIG_GLOBAL") or std.mem.eql(u8, key, "GIT_CONFIG_NOSYSTEM")) continue;
        try testing.expect(env.get(key) == null);
    }
    try testing.expectEqualStrings("/dev/null", env.get("GIT_CONFIG_GLOBAL").?);
    try testing.expectEqualStrings("1", env.get("GIT_CONFIG_NOSYSTEM").?);
    try testing.expectEqualStrings("/fixture/bin:/usr/bin:/bin", env.get("PATH").?);
    try testing.expectEqualStrings("C", env.get("LC_ALL").?);
}

test "ref assertions reject dangling aliases and preserve raw file bytes" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.exec(&.{ "symbolic-ref", "refs/stakrr/dangling", "refs/heads/missing" });
    try testing.expectError(error.SymbolicRef, repo.hasRef("refs/stakrr/dangling"));
    try repo.expectNoRef("refs/stakrr/absent");
    try repo.write("binary", "user\x00bytes\xff\n\n");
    try repo.expectFile("binary", "user\x00bytes\xff\n\n");
}
