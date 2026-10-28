//! Every ref and config key stakrr persists in a repository.
const std = @import("std");

pub const branch_prefix = "refs/heads/";

/// namespace for stakrr-managed layer branches
pub const layer_prefix = branch_prefix ++ "stakrr/";

/// where each layer's boundary was last published, one ref per layer; the layer
/// branch differing from it means commits were made on the layer since then
pub const record_prefix = "refs/stakrr/layers/";

/// internal guard pointing at the highest layer
pub const tip_ref = "refs/stakrr/tip";

/// the stack's starting commit; also keeps it reachable for gc
pub const anchor_ref = "refs/stakrr/anchor";

/// commit journal of the active edit session
pub const session_ref = "refs/stakrr/edit";

/// completed edit histories, linked through checkpoint parents
pub const oplog_ref = "refs/stakrr/oplog";

/// write-ahead intent retained until every ref in a transaction is published
pub const transaction_ref = "refs/stakrr/transaction";

/// git config key holding "<version> <base_ref> <work_ref>"
pub const state_key = "stakrr.state";
pub const state_version = "v1";
pub const checkpoint_version: u8 = 1;
pub const transaction_version: u8 = 1;

/// `refs/heads/x` → `x`; other refs are returned unchanged
pub fn shortBranch(ref_name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, ref_name, branch_prefix))
        ref_name[branch_prefix.len..]
    else
        ref_name;
}

/// `refs/heads/stakrr/x` → `x`, or null outside the layer namespace
pub fn layerName(ref_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, ref_name, layer_prefix)) return null;
    return ref_name[layer_prefix.len..];
}

/// `refs/heads/stakrr/x` → `refs/stakrr/layers/x`, owned by `allocator`
pub fn recordRef(allocator: std.mem.Allocator, layer_ref: []const u8) ![]u8 {
    const name = layerName(layer_ref) orelse return error.InvalidRefName;
    return std.fmt.allocPrint(allocator, record_prefix ++ "{s}", .{name});
}

const testing = std.testing;

test "shortBranch strips only the branch prefix" {
    try testing.expectEqualStrings("main", shortBranch("refs/heads/main"));
    try testing.expectEqualStrings("stakrr/p1", shortBranch("refs/heads/stakrr/p1"));
    try testing.expectEqualStrings("refs/stakrr/tip", shortBranch(tip_ref));
}

test "recordRef" {
    const ref = try recordRef(testing.allocator, "refs/heads/stakrr/p1");
    defer testing.allocator.free(ref);
    try testing.expectEqualStrings("refs/stakrr/layers/p1", ref);
    try testing.expectError(error.InvalidRefName, recordRef(testing.allocator, "refs/heads/main"));
}

test "layerName" {
    try testing.expectEqualStrings("p1", layerName("refs/heads/stakrr/p1").?);
    try testing.expect(layerName("refs/heads/main") == null);
}
