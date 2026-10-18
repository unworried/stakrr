const std = @import("std");

const Git = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    fn run(
        self: *Git,
        args: []const []const u8,
    ) !Result {
        // exec git with argv
        // cap stdout, stderr, exit code
        std.process.run(self.allocator, self.io, RunOptions);
    }
};

const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};
