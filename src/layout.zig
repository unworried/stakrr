//! Every ref and config key stakrr persists in a repository.
const std = @import("std");

pub const branch_prefix = "refs/heads/";

/// namespace for stakrr-managed layer branches
pub const layer_prefix = branch_prefix ++ "stakrr/";

/// internal guard pointing at the highest layer
pub const tip_ref = "refs/stakrr/tip";

/// the stack's starting commit; also keeps it reachable for gc
pub const anchor_ref = "refs/stakrr/anchor";

/// git config key holding "<version> <base_ref> <work_ref>"
pub const state_key = "stakrr.state";
pub const state_version = "v1";

/// `refs/heads/x` → `x`; other refs are returned unchanged
pub fn shortBranch(ref_name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, ref_name, branch_prefix))
        ref_name[branch_prefix.len..]
    else
        ref_name;
}

const testing = std.testing;

test "shortBranch strips only the branch prefix" {
    try testing.expectEqualStrings("main", shortBranch("refs/heads/main"));
    try testing.expectEqualStrings("stakrr/p1", shortBranch("refs/heads/stakrr/p1"));
    try testing.expectEqualStrings("refs/stakrr/tip", shortBranch(tip_ref));
}
