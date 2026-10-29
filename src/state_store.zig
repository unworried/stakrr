//! Git-backed manifest storage; the codec itself has no repository dependency.
const std = @import("std");
const Git = @import("git.zig").Git;
const RefName = @import("git_types.zig").RefName;
const model = @import("stack_state.zig");
const layout = @import("layout.zig");
pub const Loaded = struct { oid: []const u8, state: model.Owned };
pub fn identity(git: *const Git) ![]u8 {
    return (try git.readDirectRefAlloc(try RefName.init(layout.state_ref))) orelse error.NotInitialized;
}
pub fn load(git: *const Git) !Loaded {
    const oid = try identity(git);
    errdefer git.allocator.free(oid);
    return .{ .oid = oid, .state = try loadAt(git, oid) };
}
pub fn loadAt(git: *const Git, oid: []const u8) !model.Owned {
    _ = try git.parseOid(oid);
    const kind = git.output(&.{ "cat-file", "-t", oid }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidManifest,
        else => return err,
    };
    defer git.allocator.free(kind);
    if (!std.mem.eql(u8, kind, "commit")) return error.InvalidManifest;
    const path = try std.fmt.allocPrint(git.allocator, "{s}:stack.json", .{oid});
    defer git.allocator.free(path);
    const raw = git.outputRaw(&.{ "cat-file", "blob", path }) catch |err| switch (err) {
        error.GitFailed => return error.InvalidManifest,
        else => return err,
    };
    defer git.allocator.free(raw);
    return model.decode(git.allocator, try git.objectFormat(), raw);
}
/// All metadata OIDs are actual parents, in anchor/layer order without duplicates.
pub fn create(git: *const Git, state: model.StackState) ![]u8 {
    try state.validate(try git.objectFormat());
    const raw = try model.encode(git.allocator, state);
    defer git.allocator.free(raw);
    const blob = try git.writeBlob(raw);
    defer git.allocator.free(blob);
    const tree = try git.writeTree(&.{.{ .name = "stack.json", .oid = blob }});
    defer git.allocator.free(tree);
    var parents: std.ArrayList([]const u8) = .empty;
    defer parents.deinit(git.allocator);
    try parents.append(git.allocator, state.anchor_oid.hex());
    for (state.layers) |*layer| {
        const oid = layer.recorded_boundary_oid.hex();
        var found = false;
        for (parents.items) |prior| if (std.mem.eql(u8, oid, prior)) {
            found = true;
            break;
        };
        if (!found) try parents.append(git.allocator, oid);
    }
    return git.commitTreeWithOptions(tree, parents.items, "stakrr: stack state", .{ .identity = .{ .name = "stakrr", .email = "stakrr@localhost" } });
}
