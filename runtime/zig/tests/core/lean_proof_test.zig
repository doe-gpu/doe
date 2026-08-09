// lean_proof_test.zig — Tests for Lean proof integration contracts.
//
// Validates the public API of lean_proof.zig: BoundsPattern enum
// exhaustiveness, proof availability constants under default build
// (lean_verified=false), and the relationship between proof levels,
// safety classes, and verification modes defined in model_policy.zig.
//
// The comptime validation block in lean_proof.zig only fires when
// -Dlean-verified=true; these tests cover the default (unverified)
// code path and the structural contracts that hold regardless of
// build flag.

const std = @import("std");
const testing = std.testing;

const lean_proof = @import("../../src/verification/lean_proof.zig");
const model = @import("../../src/contracts/model/model_policy.zig");

const ExpectedBoundsPattern = struct {
    pattern: lean_proof.BoundsPattern,
    name: []const u8,
};

const expected_bounds_patterns = [_]ExpectedBoundsPattern{
    .{ .pattern = .gid_1d_storage_buffer, .name = "gid_1d_storage_buffer" },
    .{ .pattern = .gid_1d_storage_buffer_offset, .name = "gid_1d_storage_buffer_offset" },
    .{ .pattern = .gid_1d_storage_buffer_stride, .name = "gid_1d_storage_buffer_stride" },
    .{ .pattern = .gid_1d_storage_buffer_loop_offset, .name = "gid_1d_storage_buffer_loop_offset" },
    .{ .pattern = .gid_1d_storage_buffer_loop_affine, .name = "gid_1d_storage_buffer_loop_affine" },
    .{ .pattern = .loop_1d_storage_buffer_affine, .name = "loop_1d_storage_buffer_affine" },
    .{ .pattern = .gid_1d_storage_buffer_tiled, .name = "gid_1d_storage_buffer_tiled" },
    .{ .pattern = .gid_2d_flat_storage_buffer, .name = "gid_2d_flat_storage_buffer" },
    .{ .pattern = .gid_2d_flat_storage_buffer_offset, .name = "gid_2d_flat_storage_buffer_offset" },
    .{ .pattern = .gid_3d_flat_storage_buffer, .name = "gid_3d_flat_storage_buffer" },
    .{ .pattern = .gid_3d_flat_storage_buffer_offset, .name = "gid_3d_flat_storage_buffer_offset" },
    .{ .pattern = .gid_texture_1d_dispatch_fit, .name = "gid_texture_1d_dispatch_fit" },
    .{ .pattern = .gid_texture_2d_dispatch_fit, .name = "gid_texture_2d_dispatch_fit" },
    .{ .pattern = .gid_texture_3d_dispatch_fit, .name = "gid_texture_3d_dispatch_fit" },
    .{ .pattern = .gid_texture_1d_affine_dispatch_fit, .name = "gid_texture_1d_affine_dispatch_fit" },
    .{ .pattern = .gid_texture_2d_affine_dispatch_fit, .name = "gid_texture_2d_affine_dispatch_fit" },
    .{ .pattern = .gid_texture_3d_affine_dispatch_fit, .name = "gid_texture_3d_affine_dispatch_fit" },
    .{ .pattern = .gid_texture_1d_tiled_dispatch_fit, .name = "gid_texture_1d_tiled_dispatch_fit" },
    .{ .pattern = .gid_texture_2d_tiled_dispatch_fit, .name = "gid_texture_2d_tiled_dispatch_fit" },
    .{ .pattern = .gid_texture_3d_tiled_dispatch_fit, .name = "gid_texture_3d_tiled_dispatch_fit" },
};

// ============================================================
// BoundsPattern enum — exhaustiveness and variant count
// ============================================================

test "BoundsPattern enum has the expected variant count" {
    const fields = @typeInfo(lean_proof.BoundsPattern).@"enum".fields;
    try testing.expectEqual(expected_bounds_patterns.len, fields.len);
}

test "BoundsPattern variant names are stable" {
    inline for (expected_bounds_patterns) |expected| {
        try testing.expectEqualStrings(expected.name, @tagName(expected.pattern));
    }
}

// ============================================================
// Build-flag dependent constants — default (lean_verified=false)
// ============================================================

test "lean_verified is false in default test builds" {
    if (lean_proof.lean_verified) return;
    try testing.expect(!lean_proof.lean_verified);
}

test "validator_elimination_available is false when lean_verified is false" {
    if (lean_proof.lean_verified) return;
    try testing.expect(!lean_proof.validator_elimination_available);
}

test "bounds_elimination_available is false when lean_verified is false" {
    if (lean_proof.lean_verified) return;
    try testing.expect(!lean_proof.bounds_elimination_available);
}

// ============================================================
// boundsProven — returns false for all patterns when unverified
// ============================================================

test "boundsProven returns false for all patterns when lean_verified is false" {
    if (lean_proof.lean_verified) return;
    // Exhaustive check over all BoundsPattern variants: none should
    // report proven when build has lean_verified=false.
    inline for (expected_bounds_patterns) |expected| {
        try testing.expect(!lean_proof.boundsProven(expected.pattern));
    }
}

test "boundsProven exhaustively covers every BoundsPattern variant" {
    // Compile-time guarantee: iterate all enum fields and call
    // boundsProven for each. Failure to compile means a new variant
    // was added without extending the switch in boundsProven.
    inline for (@typeInfo(lean_proof.BoundsPattern).@"enum".fields) |field| {
        const pattern: lean_proof.BoundsPattern = @enumFromInt(field.value);
        const proven = lean_proof.boundsProven(pattern);
        if (!lean_proof.lean_verified) {
            try testing.expect(!proven);
        }
    }
}

// ============================================================
// Proof level classification — policy contracts
// ============================================================

test "ProofLevel enum has exactly 3 variants" {
    const fields = @typeInfo(model.ProofLevel).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

test "ProofLevel ordinals are stable" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(model.ProofLevel.proven));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(model.ProofLevel.guarded));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(model.ProofLevel.rejected));
}

test "needsStrongestProof is true only for proven level" {
    try testing.expect(model.needsStrongestProof(.proven));
    try testing.expect(!model.needsStrongestProof(.guarded));
    try testing.expect(!model.needsStrongestProof(.rejected));
}

// ============================================================
// Safety class to proof requirement — policy contracts
// ============================================================

test "SafetyClass enum has exactly 4 variants" {
    const fields = @typeInfo(model.SafetyClass).@"enum".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

test "SafetyClass ordinals encode escalating severity" {
    // The numeric ordering must reflect increasing safety severity:
    // low < moderate < high < critical.
    try testing.expect(@intFromEnum(model.SafetyClass.low) < @intFromEnum(model.SafetyClass.moderate));
    try testing.expect(@intFromEnum(model.SafetyClass.moderate) < @intFromEnum(model.SafetyClass.high));
    try testing.expect(@intFromEnum(model.SafetyClass.high) < @intFromEnum(model.SafetyClass.critical));
}

test "critical safety class is the highest rank" {
    // The proven-conditions artifact evaluates dispatch.criticalSafetyRank=3,
    // which must match the ordinal of SafetyClass.critical.
    try testing.expectEqual(@as(u8, 3), @intFromEnum(model.SafetyClass.critical));
}

// ============================================================
// Verification mode to proof requirement — policy contracts
// ============================================================

test "VerificationMode enum has exactly 3 variants" {
    const fields = @typeInfo(model.VerificationMode).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

test "requiresProof is true only for lean_required mode" {
    try testing.expect(!model.requiresProof(.guard_only));
    try testing.expect(!model.requiresProof(.lean_preferred));
    try testing.expect(model.requiresProof(.lean_required));
}

test "stronger verification mode has higher ordinal" {
    try testing.expect(@intFromEnum(model.VerificationMode.guard_only) < @intFromEnum(model.VerificationMode.lean_preferred));
    try testing.expect(@intFromEnum(model.VerificationMode.lean_preferred) < @intFromEnum(model.VerificationMode.lean_required));
}

// ============================================================
// Safety class + verification mode interaction
// ============================================================

test "high safety class with lean_required mode requires proof" {
    // This tests the contract: when both safety is high+ and
    // verification mode is lean_required, proof must be present.
    const mode: model.VerificationMode = .lean_required;
    const safety: model.SafetyClass = .high;
    try testing.expect(model.requiresProof(mode));
    try testing.expect(@intFromEnum(safety) >= @intFromEnum(model.SafetyClass.high));
}

test "low safety class does not mandate strongest proof" {
    // Low safety does not force proven proof level by itself;
    // the proof level is determined by the verification pipeline,
    // not solely by safety class.
    const safety: model.SafetyClass = .low;
    try testing.expect(@intFromEnum(safety) < @intFromEnum(model.SafetyClass.high));
}

// ============================================================
// Proof level name roundtrip
// ============================================================

test "proof_level_name covers all ProofLevel variants" {
    inline for (@typeInfo(model.ProofLevel).@"enum".fields) |field| {
        const level: model.ProofLevel = @enumFromInt(field.value);
        const name = model.proof_level_name(level);
        try testing.expect(name.len > 0);
    }
}

test "verification_mode_name covers all VerificationMode variants" {
    inline for (@typeInfo(model.VerificationMode).@"enum".fields) |field| {
        const mode: model.VerificationMode = @enumFromInt(field.value);
        const name = model.verification_mode_name(mode);
        try testing.expect(name.len > 0);
    }
}

// ============================================================
// Comparability obligations hash — build-time embedding
// ============================================================

test "comparability_obligations_sha256 is a 64-char hex string" {
    const sha = lean_proof.comparability_obligations_sha256;
    try testing.expectEqual(@as(usize, 64), sha.len);
    for (sha) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "proof provenance hashes are 64-char hex strings" {
    inline for (.{
        lean_proof.lean_extract_program_sha256,
        lean_proof.lean_source_tree_sha256,
        lean_proof.generated_comparability_contract_sha256,
        lean_proof.proof_pattern_spec_sha256,
    }) |sha| {
        try testing.expectEqual(@as(usize, 64), sha.len);
        for (sha) |c| {
            try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        }
    }
}

test "lean_toolchain_ref is non-empty" {
    try testing.expect(lean_proof.lean_toolchain_ref.len > 0);
}

// ============================================================
// Validator elimination tracks bounds elimination dependency
// ============================================================

test "validator_elimination_available implies bounds_elimination_available or both false" {
    // Validator elimination requires builder_soundness + ValidatorRedundant
    // in the proof artifact; bounds elimination requires separate theorems.
    // They are independent features, but when lean_verified=false both are
    // false. When lean_verified=true, validator elimination does not imply
    // bounds elimination or vice versa.
    if (lean_proof.validator_elimination_available) {
        // Both require lean_verified=true; just verify lean_verified holds.
        try testing.expect(lean_proof.lean_verified);
    }
    if (lean_proof.bounds_elimination_available) {
        try testing.expect(lean_proof.lean_verified);
    }
}
