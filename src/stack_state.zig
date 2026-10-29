//! Pure persisted stack model. Names borrow owned arena storage; OIDs are values.
const std = @import("std");
const types = @import("git_types.zig");
const layout = @import("layout.zig");
pub const Error = error{ InvalidManifest, UnsupportedManifestVersion };
pub const Layer = struct { branch: types.BranchRef, recorded_boundary_oid: types.Oid };
pub const StackState = struct {
    base_branch: types.BranchRef,
    work_branch: types.BranchRef,
    anchor_oid: types.Oid,
    layers: []const Layer,

    pub fn validate(self: StackState, format: types.ObjectFormat) Error!void {
        _ = types.BranchRef.init(self.base_branch.name.bytes) catch return error.InvalidManifest;
        _ = types.BranchRef.init(self.work_branch.name.bytes) catch return error.InvalidManifest;
        if (conflict(self.base_branch.name.bytes, self.work_branch.name.bytes) or
            reserved(self.base_branch) or reserved(self.work_branch)) return error.InvalidManifest;
        _ = types.Oid.init(format, self.anchor_oid.hex()) catch return error.InvalidManifest;
        for (self.layers, 0..) |layer, i| {
            _ = types.BranchRef.init(layer.branch.name.bytes) catch return error.InvalidManifest;
            const name = layout.layerName(layer.branch.name.bytes) orelse return error.InvalidManifest;
            if (name.len == 0 or conflict(layer.branch.name.bytes, self.base_branch.name.bytes) or
                conflict(layer.branch.name.bytes, self.work_branch.name.bytes)) return error.InvalidManifest;
            _ = types.Oid.init(format, layer.recorded_boundary_oid.hex()) catch return error.InvalidManifest;
            for (self.layers[0..i]) |prior| if (conflict(prior.branch.name.bytes, layer.branch.name.bytes)) return error.InvalidManifest;
        }
    }
};
fn reserved(branch: types.BranchRef) bool {
    return conflict(branch.name.bytes, std.mem.trimEnd(u8, layout.layer_prefix, "/"));
}
pub fn conflict(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or pathPrefix(a, b) or pathPrefix(b, a);
}
fn pathPrefix(a: []const u8, b: []const u8) bool {
    return b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/';
}
const WireLayer = struct { branch: []const u8, recorded_boundary_oid: []const u8 };
const Wire = struct { version: u32, base_branch: []const u8, work_branch: []const u8, anchor_oid: []const u8, layers: []const WireLayer };

/// Deterministic compact JSON, with field order fixed by Wire and declared layer order.
pub fn encode(allocator: std.mem.Allocator, state: StackState) ![]u8 {
    try state.validate(state.anchor_oid.format);
    const layers = try allocator.alloc(WireLayer, state.layers.len);
    defer allocator.free(layers);
    for (state.layers, layers) |*layer, *wire| wire.* = .{ .branch = layer.branch.name.bytes, .recorded_boundary_oid = layer.recorded_boundary_oid.hex() };
    return std.json.Stringify.valueAlloc(allocator, Wire{
        .version = 1,
        .base_branch = state.base_branch.name.bytes,
        .work_branch = state.work_branch.name.bytes,
        .anchor_oid = state.anchor_oid.hex(),
        .layers = layers,
    }, .{});
}

pub const Owned = struct {
    value: StackState,
    _arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Owned) void {
        self._arena.deinit();
        self.* = undefined;
    }
};
/// Independent owned lifetime, including when the input bytes are freed.
pub fn decode(allocator: std.mem.Allocator, format: types.ObjectFormat, raw: []const u8) !Owned {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Read version first so future schemas receive a precise diagnostic.
    const header = std.json.parseFromSlice(struct { version: u32 }, a, raw, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidManifest,
    };
    if (header.value.version != 1) return error.UnsupportedManifestVersion;
    const parsed = std.json.parseFromSlice(Wire, a, raw, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidManifest,
    };
    const wire = parsed.value;
    const layers = try a.alloc(Layer, wire.layers.len);
    for (wire.layers, layers) |layer, *out| out.* = .{
        .branch = types.BranchRef.init(layer.branch) catch return error.InvalidManifest,
        .recorded_boundary_oid = types.Oid.init(format, layer.recorded_boundary_oid) catch return error.InvalidManifest,
    };
    const state: StackState = .{
        .base_branch = types.BranchRef.init(wire.base_branch) catch return error.InvalidManifest,
        .work_branch = types.BranchRef.init(wire.work_branch) catch return error.InvalidManifest,
        .anchor_oid = types.Oid.init(format, wire.anchor_oid) catch return error.InvalidManifest,
        .layers = layers,
    };
    try state.validate(format);
    return .{ .value = state, ._arena = arena };
}

const testing = std.testing;
const sample = "{\"version\":1,\"base_branch\":\"refs/heads/main\",\"work_branch\":\"refs/heads/work\",\"anchor_oid\":\"1111111111111111111111111111111111111111\",\"layers\":[{\"branch\":\"refs/heads/stakrr/z\",\"recorded_boundary_oid\":\"2222222222222222222222222222222222222222\"},{\"branch\":\"refs/heads/stakrr/a\",\"recorded_boundary_oid\":\"3333333333333333333333333333333333333333\"}]}";
test "manifest exact bytes, declared order and independent owned round trips" {
    const raw = try testing.allocator.dupe(u8, sample);
    var first = try decode(testing.allocator, .sha1, raw);
    testing.allocator.free(raw);
    const encoded = try encode(testing.allocator, first.value);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(sample, encoded);
    var second = try decode(testing.allocator, .sha1, encoded);
    defer second.deinit();
    first.deinit();
    try testing.expectEqualStrings("refs/heads/stakrr/z", second.value.layers[0].branch.name.bytes);
    try testing.expectEqualStrings("refs/heads/stakrr/a", second.value.layers[1].branch.name.bytes);
}
test "manifest rejects malformed, unsupported, missing, unknown and wrong-format fields" {
    for ([_][]const u8{ "", "{}", "{\"version\":1}", "{\"version\":1,\"version\":1}" }) |raw|
        try testing.expectError(error.InvalidManifest, decode(testing.allocator, .sha1, raw));
    try testing.expectError(error.UnsupportedManifestVersion, decode(testing.allocator, .sha1, "{\"version\":2}"));
    try testing.expectError(error.InvalidManifest, decode(testing.allocator, .sha256, sample));
}
test "manifest structural validation refuses reserved, duplicate and conflicting branches" {
    var owned = try decode(testing.allocator, .sha1, sample);
    defer owned.deinit();
    var state = owned.value;
    state.work_branch = state.base_branch;
    try testing.expectError(error.InvalidManifest, state.validate(.sha1));
    state = owned.value;
    state.base_branch = try types.BranchRef.init("refs/heads/stakrr");
    try testing.expectError(error.InvalidManifest, state.validate(.sha1));
    state = owned.value;
    var layers = [_]Layer{ state.layers[0], state.layers[0] };
    state.layers = &layers;
    try testing.expectError(error.InvalidManifest, state.validate(.sha1));
    layers[1].branch = try types.BranchRef.init("refs/heads/stakrr/z/child");
    try testing.expectError(error.InvalidManifest, state.validate(.sha1));
}

test "SHA-256 manifest round trip and OID format validation" {
    const state: StackState = .{
        .base_branch = try types.BranchRef.init("refs/heads/main"),
        .work_branch = try types.BranchRef.init("refs/heads/work"),
        .anchor_oid = try types.Oid.init(.sha256, "1111111111111111111111111111111111111111111111111111111111111111"),
        .layers = &.{.{ .branch = try types.BranchRef.init("refs/heads/stakrr/one"), .recorded_boundary_oid = try types.Oid.init(.sha256, "2222222222222222222222222222222222222222222222222222222222222222") }},
    };
    const raw = try encode(testing.allocator, state);
    defer testing.allocator.free(raw);
    var owned = try decode(testing.allocator, .sha256, raw);
    defer owned.deinit();
    const encoded = try encode(testing.allocator, owned.value);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(raw, encoded);
    try testing.expectError(error.InvalidManifest, decode(testing.allocator, .sha1, raw));
    try testing.expectError(error.InvalidManifest, state.validate(.sha1));
}

test "decoding validates unsafe branch names, missing required fields and extra keys" {
    const cases = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "refs/heads/main", .to = "refs/heads/stakrr/base" },
        .{ .from = "refs/heads/work", .to = "refs/heads/main" },
        .{ .from = "refs/heads/stakrr/a", .to = "refs/heads/stakrr/z" },
        .{ .from = "refs/heads/stakrr/a", .to = "refs/heads/stakrr/z/child" },
        .{ .from = "refs/heads/stakrr/a", .to = "refs/heads/not-layer" },
        .{ .from = "refs/heads/work", .to = "refs/heads/-option" },
        .{ .from = "refs/heads/work", .to = "refs/heads/../unsafe" },
        .{ .from = "1111111111111111111111111111111111111111", .to = "0000000000000000000000000000000000000000" },
        .{ .from = "\"anchor_oid\"", .to = "\"unknown_anchor\"" },
    };
    for (cases) |case| {
        const changed = try std.mem.replaceOwned(u8, testing.allocator, sample, case.from, case.to);
        defer testing.allocator.free(changed);
        try testing.expectError(error.InvalidManifest, decode(testing.allocator, .sha1, changed));
    }
}
