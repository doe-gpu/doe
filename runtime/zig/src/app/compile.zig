//! Application compilation adapter.
//!
//! Orchestrates pure source lowering and hashing into program artifacts.

const std = @import("std");
const identity = @import("../contracts/identity.zig");

pub const CompiledArtifact = struct {
    program_identity: identity.ProgramIdentity,
    source_bytes_len: usize,
    entry_point: []const u8,
};

pub fn compileKernelSource(source: []const u8, entry_point: []const u8) CompiledArtifact {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source);
    var source_sha: identity.Sha256Digest = undefined;
    hasher.final(&source_sha);

    return .{
        .program_identity = .{
            .source_sha256 = source_sha,
            .lowered_sha256 = source_sha,
            .entry_point = entry_point,
        },
        .source_bytes_len = source.len,
        .entry_point = entry_point,
    };
}
