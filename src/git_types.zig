//! Validated Git names and object IDs. Names borrow their input; OIDs are values.
const std = @import("std");

pub const ObjectFormat = enum {
    sha1,
    sha256,

    pub fn hexLength(self: ObjectFormat) usize {
        return if (self == .sha1) 40 else 64;
    }
};

pub const RefName = struct {
    bytes: []const u8,

    /// Git's full ref-name rules, restricted to the refs/ namespace.
    pub fn init(bytes: []const u8) error{InvalidRefName}!RefName {
        if (!std.mem.startsWith(u8, bytes, "refs/") or bytes.len <= 5 or
            bytes[bytes.len - 1] == '.' or
            std.mem.indexOf(u8, bytes, "..") != null or
            std.mem.indexOf(u8, bytes, "@{") != null)
            return error.InvalidRefName;
        for (bytes) |c| {
            if (c <= ' ' or c == 0x7f or std.mem.indexOfScalar(u8, "~^:?*[\\", c) != null)
                return error.InvalidRefName;
        }
        var parts = std.mem.splitScalar(u8, bytes, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or part[0] == '.' or std.mem.endsWith(u8, part, ".lock"))
                return error.InvalidRefName;
        }
        return .{ .bytes = bytes };
    }
};

pub const BranchRef = struct {
    name: RefName,

    pub fn init(bytes: []const u8) error{InvalidRefName}!BranchRef {
        const name = try RefName.init(bytes);
        const prefix = "refs/heads/";
        if (!std.mem.startsWith(u8, bytes, prefix) or bytes.len == prefix.len or bytes[prefix.len] == '-')
            return error.InvalidRefName;
        return .{ .name = name };
    }

    pub fn short(self: BranchRef) []const u8 {
        return self.name.bytes["refs/heads/".len..];
    }
};

/// A nonzero full object ID, stored inline so returning it never borrows a local buffer.
pub const Oid = struct {
    bytes: [64]u8,
    format: ObjectFormat,

    pub fn init(format: ObjectFormat, text: []const u8) error{InvalidOid}!Oid {
        if (text.len != format.hexLength() or std.mem.allEqual(u8, text, '0'))
            return error.InvalidOid;
        for (text) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return error.InvalidOid,
        };
        var oid: Oid = .{ .bytes = @splat(0), .format = format };
        @memcpy(oid.bytes[0..text.len], text);
        return oid;
    }

    pub fn hex(self: *const Oid) []const u8 {
        return self.bytes[0..self.format.hexLength()];
    }

    pub fn dupeHex(self: *const Oid, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.hex());
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return a.format == b.format and std.mem.eql(u8, a.hex(), b.hex());
    }
};

pub const ExpectedRef = struct {
    name: RefName,
    oid: Oid,

    pub fn verify(self: ExpectedRef) RefUpdate {
        return .{ .verify = .{ .name = self.name, .expected = self.oid } };
    }

    pub fn create(self: ExpectedRef) RefUpdate {
        return .{ .create = .{ .name = self.name, .new = self.oid } };
    }

    pub fn delete(self: ExpectedRef) RefUpdate {
        return .{ .delete = .{ .name = self.name, .old = self.oid } };
    }
};

/// Absence is explicit. Only the Git protocol backend emits zero-OID sentinels.
pub const RefUpdate = union(enum) {
    verify: struct { name: RefName, expected: ?Oid },
    create: struct { name: RefName, new: Oid },
    update: struct { name: RefName, old: Oid, new: Oid },
    delete: struct { name: RefName, old: Oid },

    pub fn name(self: RefUpdate) RefName {
        return switch (self) {
            inline else => |ref| ref.name,
        };
    }

    pub fn oldOid(self: RefUpdate) ?Oid {
        return switch (self) {
            .verify => |ref| ref.expected,
            .create => null,
            .update => |ref| ref.old,
            .delete => |ref| ref.old,
        };
    }

    pub fn newOid(self: RefUpdate) ?Oid {
        return switch (self) {
            .verify => |ref| ref.expected,
            .create => |ref| ref.new,
            .update => |ref| ref.new,
            .delete => null,
        };
    }

    pub fn writes(self: RefUpdate) bool {
        return !equalOids(self.oldOid(), self.newOid());
    }
};

pub fn equalOids(a: ?Oid, b: ?Oid) bool {
    if (a == null or b == null) return a == null and b == null;
    return Oid.eql(a.?, b.?);
}

pub const CurrentBranchPolicy = union(enum) {
    forbid,
    allow: BranchRef,
};

pub const PublishOptions = struct {
    message: []const u8,
    updates: []const RefUpdate,
    current_branch: CurrentBranchPolicy = .forbid,
};
