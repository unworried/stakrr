const std = @import("std");

pub const Layer = struct {
    ref_name: []const u8,
    tip: []const u8,
};

pub const Stack = struct {
    base_ref: []const u8,
    work_ref: []const u8,
    base_oid: []const u8,
    work_oid: []const u8,
    layers: []Layer,
};

pub const CutPlan = struct {
    new_ref: []const u8,
    target_oid: []const u8,
    previous_oid: []const u8,
    expected_work_oid: []const u8,
};
