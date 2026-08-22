//! Replay identity verification adapter.

const std = @import("std");
const identity = @import("../contracts/identity.zig");

pub const ReplayValidationResult = struct {
    matched: bool,
    expected_hash: identity.Sha256Digest,
    observed_hash: identity.Sha256Digest,
    mismatch_step: ?u64 = null,
};

pub fn validateReplayHashes(expected: []const identity.Sha256Digest, observed: []const identity.Sha256Digest) ReplayValidationResult {
    if (expected.len != observed.len) {
        return .{
            .matched = false,
            .expected_hash = if (expected.len > 0) expected[0] else [_]u8{0} ** 32,
            .observed_hash = if (observed.len > 0) observed[0] else [_]u8{0} ** 32,
            .mismatch_step = @min(expected.len, observed.len),
        };
    }

    for (expected, observed, 0..) |exp, obs, idx| {
        if (!std.mem.eql(u8, &exp, &obs)) {
            return .{
                .matched = false,
                .expected_hash = exp,
                .observed_hash = obs,
                .mismatch_step = idx,
            };
        }
    }

    const last = if (expected.len > 0) expected[expected.len - 1] else [_]u8{0} ** 32;
    return .{
        .matched = true,
        .expected_hash = last,
        .observed_hash = last,
        .mismatch_step = null,
    };
}
