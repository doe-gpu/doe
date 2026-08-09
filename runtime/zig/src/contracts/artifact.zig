//! Neutral artifact identity, hashing, and evidence-comparability contracts.

const std = @import("std");

pub const SHA256_HEX_SIZE: usize = 64;
pub const Sha256Hex = [SHA256_HEX_SIZE]u8;
pub const Path = []const u8;
pub const Sha256Text = []const u8;

pub const TraceLink = struct {
    moduleIdentity: []const u8,
    requestHash: []const u8,
    policyHash: []const u8,
    resultHash: []const u8,
};

pub const Reference = struct {
    path: ?Path = null,
    sha256: ?Sha256Text = null,

    pub fn present(self: Reference) bool {
        return self.path != null or self.sha256 != null;
    }
};

pub const BackendKind = enum {
    native_vulkan,
    native_metal,
    native_d3d12,
    dawn_delegate,
    cost_model,

    pub fn name(self: BackendKind) []const u8 {
        return @tagName(self);
    }

    pub fn is_native(self: BackendKind) bool {
        return switch (self) {
            .native_vulkan, .native_metal, .native_d3d12 => true,
            .dawn_delegate, .cost_model => false,
        };
    }

    pub fn is_claimable(self: BackendKind) bool {
        return self.is_native();
    }
};

pub const TimingSource = enum {
    gpu_timestamp,
    cpu_submit_wait,
    cpu_wall_clock,
    cost_model,

    pub fn name(self: TimingSource) []const u8 {
        return @tagName(self);
    }

    pub fn is_gpu_measured(self: TimingSource) bool {
        return self == .gpu_timestamp;
    }
};

pub const ComparabilityClass = enum {
    strict,
    directional,
    diagnostic,

    pub fn name(self: ComparabilityClass) []const u8 {
        return @tagName(self);
    }

    pub fn is_claimable(self: ComparabilityClass) bool {
        return self == .strict;
    }
};

pub const ArtifactMeta = struct {
    backend_kind: BackendKind,
    timing_source: TimingSource,
    comparability: ComparabilityClass,

    pub fn is_claimable(self: ArtifactMeta) bool {
        return self.backend_kind.is_claimable() and
            self.comparability.is_claimable() and
            self.timing_source != .cost_model;
    }
};

pub fn classify(
    backend_kind: BackendKind,
    gpu_timestamp_valid: bool,
    gpu_timestamp_attempted: bool,
) ArtifactMeta {
    const timing_source: TimingSource = if (backend_kind == .cost_model)
        .cost_model
    else if (gpu_timestamp_valid)
        .gpu_timestamp
    else if (gpu_timestamp_attempted)
        .cpu_submit_wait
    else
        .cpu_wall_clock;

    const comparability: ComparabilityClass = if (backend_kind == .cost_model)
        .diagnostic
    else if (gpu_timestamp_valid)
        .strict
    else if (backend_kind.is_native() or backend_kind == .dawn_delegate)
        .directional
    else
        .diagnostic;

    return .{
        .backend_kind = backend_kind,
        .timing_source = timing_source,
        .comparability = comparability,
    };
}

const HEX = "0123456789abcdef";

pub fn sha256_hex(input: []const u8) Sha256Hex {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    return sha256_digest_hex(digest);
}

pub fn sha256_digest_hex(digest: [32]u8) Sha256Hex {
    var output: Sha256Hex = undefined;
    for (digest, 0..) |byte, index| {
        const output_index = index * 2;
        output[output_index] = HEX[(byte >> 4) & 0x0F];
        output[output_index + 1] = HEX[byte & 0x0F];
    }
    return output;
}

pub fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

pub fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digest = sha256_hex(bytes);
    return try allocator.dupe(u8, &digest);
}

pub fn stableHashJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const encoded = try jsonStringifyAlloc(allocator, value);
    defer allocator.free(encoded);
    return try sha256HexAlloc(allocator, encoded);
}

test "artifact identity and hash are stable" {
    try std.testing.expectEqual(@as(usize, 64), SHA256_HEX_SIZE);
    try std.testing.expectEqual(sha256_hex("deterministic input"), sha256_hex("deterministic input"));
    try std.testing.expect((Reference{ .path = "artifact.json", .sha256 = "abc" }).present());
}
