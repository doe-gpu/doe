//! Canonical identity contracts for programs, operations, and execution instances.
//!
//! Provides typed, content-addressed identity records linking WGSL sources,
//! lowered artifacts, dispatch shapes, and execution receipts.

const std = @import("std");

pub const Sha256Digest = [32]u8;

pub const HexDigestString = [64]u8;

pub fn formatHexDigest(digest: Sha256Digest) HexDigestString {
    return std.fmt.bytesToHex(digest, .lower);
}

pub const ProgramIdentity = struct {
    source_sha256: Sha256Digest = [_]u8{0} ** 32,
    lowered_sha256: Sha256Digest = [_]u8{0} ** 32,
    entry_point: []const u8 = "main",

    pub fn isNull(self: ProgramIdentity) bool {
        const zero = [_]u8{0} ** 32;
        return std.mem.eql(u8, &self.source_sha256, &zero) and std.mem.eql(u8, &self.lowered_sha256, &zero);
    }
};

pub const OperationIdentity = struct {
    operation_id: u64 = 0,
    program: ProgramIdentity = .{},
    dispatch_hash: Sha256Digest = [_]u8{0} ** 32,
};

pub const ExecutionIdentity = struct {
    operation: OperationIdentity = .{},
    instance_id: u64 = 0,
    timestamp_mono_ns: u64 = 0,
};
