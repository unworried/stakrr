//! Persisted ref names and format versions.
const std = @import("std");

pub const branch_prefix = "refs/heads/";

/// namespace for stakrr-managed layer branches
pub const layer_prefix = branch_prefix ++ "stakrr/";

/// commit journal of the active edit session
pub const session_ref = "refs/stakrr/edit";

/// Completed operation records and retained execution checkpoints.
pub const oplog_ref = "refs/stakrr/oplog";

/// write-ahead intent retained until every ref in a transaction is published
pub const transaction_ref = "refs/stakrr/transaction";

pub const state_ref = "refs/stakrr/state";
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

const testing = std.testing;

test "shortBranch strips only the branch prefix" {
    try testing.expectEqualStrings("main", shortBranch("refs/heads/main"));
    try testing.expectEqualStrings("stakrr/p1", shortBranch("refs/heads/stakrr/p1"));
    try testing.expectEqualStrings("refs/stakrr/state", shortBranch(state_ref));
}

test "layerName" {
    try testing.expectEqualStrings("p1", layerName("refs/heads/stakrr/p1").?);
    try testing.expect(layerName("refs/heads/main") == null);
}
