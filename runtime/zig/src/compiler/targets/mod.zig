// Target descriptors — configuration consumed by TSIR residency and
// collective-synthesis passes.
//
// New hardware is a new descriptor file, NEVER a compiler change.
// Every field that varies by chip or runtime is declared here and
// categorized as either correctness-affecting (hashed into the TSIR
// realization identity) or planner-only (consumed by search heuristics
// but NOT part of lowering identity).
//
// The split matters: a change to a latency hint must NOT invalidate
// existing manifests, because latency hints are search quality, not
// semantic identity. Only correctness fields flow into the hash that
// binds a realization to a target.
//
// Rules:
//   - No value lives in code outside the descriptor struct.
//   - Every field is either a concrete number, a fixed enum, or a
//     pointer into a const array declared in the descriptor file.
//   - Descriptors are pure const — no builders, no derivation.
//   - Moving a field between `correctness` and `planner` is a
//     lowering-identity-breaking change: the correctness hash changes,
//     so existing manifests need refreshed lowerings.

const std = @import("std");
const types = @import("types.zig");

pub const wse3 = @import("wse3.zig");
pub const webgpu_generic = @import("webgpu_generic.zig");
pub const msl = @import("msl.zig");
pub const spir_v = @import("spir_v.zig");

pub const NumericalMode = types.NumericalMode;
pub const CollectiveCapability = types.CollectiveCapability;
pub const FusedIntrinsic = types.FusedIntrinsic;
pub const StreamingGemmPrimitive = types.StreamingGemmPrimitive;
pub const RuntimeSizedBindingPolicy = types.RuntimeSizedBindingPolicy;
pub const CorrectnessFields = types.CorrectnessFields;
pub const PlannerFields = types.PlannerFields;
pub const TargetDescriptor = types.TargetDescriptor;

/// Compute the SHA-256 hash of the correctness fields only. The
/// planner fields are deliberately excluded: tuning a latency hint
/// must not invalidate existing lowerings. This hash participates in
/// `tsir.Realization.target_descriptor_hash`; any change to it forces
/// realization re-emission.
pub fn descriptorHash(desc: TargetDescriptor) [32]u8 {
    const c = desc.correctness;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(c.name);
    updateU64(&h, c.pe_working_memory_bytes);
    updateU64(&h, c.pe_persistent_pool_bytes);
    updateU32(&h, c.fabric_color_count);
    updateU32(&h, c.max_collective_group_size);
    updateU32(&h, c.sub_tile_lane_width);
    for (c.native_numerical_modes) |mode| h.update(@tagName(mode));
    for (c.native_collectives) |cap| {
        h.update(cap.kind_name);
        h.update("|");
        h.update(cap.exactness_name);
    }
    for (c.fused_intrinsics) |intr| h.update(@tagName(intr));
    h.update(@tagName(c.streaming_gemm));
    h.update(@tagName(c.runtime_sized_binding_policy));
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn updateU64(h: *std.crypto.hash.sha2.Sha256, v: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    h.update(&bytes);
}

fn updateU32(h: *std.crypto.hash.sha2.Sha256, v: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    h.update(&bytes);
}

test "distinct descriptors have distinct hashes" {
    const wse3_hash = descriptorHash(wse3.descriptor);
    const webgpu_hash = descriptorHash(webgpu_generic.descriptor);
    const msl_hash = descriptorHash(msl.descriptor);
    const spirv_hash = descriptorHash(spir_v.descriptor);
    try std.testing.expect(!std.mem.eql(u8, &wse3_hash, &webgpu_hash));
    try std.testing.expect(!std.mem.eql(u8, &wse3_hash, &msl_hash));
    try std.testing.expect(!std.mem.eql(u8, &wse3_hash, &spirv_hash));
    try std.testing.expect(!std.mem.eql(u8, &webgpu_hash, &msl_hash));
    try std.testing.expect(!std.mem.eql(u8, &webgpu_hash, &spirv_hash));
    try std.testing.expect(!std.mem.eql(u8, &msl_hash, &spirv_hash));
}

test "descriptor hash is stable" {
    const a = descriptorHash(wse3.descriptor);
    const b = descriptorHash(wse3.descriptor);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "planner field change does not affect descriptor hash" {
    // Planner-only fields must not participate in correctness identity.
    // This invariant protects existing manifests from being invalidated
    // by a latency-hint tuning change.
    const base = wse3.descriptor;
    const tweaked = TargetDescriptor{
        .correctness = base.correctness,
        .planner = .{
            .fabric_per_hop_latency_ns = base.planner.fabric_per_hop_latency_ns + 999,
        },
    };
    const base_hash = descriptorHash(base);
    const tweaked_hash = descriptorHash(tweaked);
    try std.testing.expectEqualSlices(u8, &base_hash, &tweaked_hash);
}

test "correctness field change does change descriptor hash" {
    const base = wse3.descriptor;
    const tweaked = TargetDescriptor{
        .correctness = .{
            .name = base.correctness.name,
            .pe_working_memory_bytes = base.correctness.pe_working_memory_bytes + 1,
            .pe_persistent_pool_bytes = base.correctness.pe_persistent_pool_bytes,
            .fabric_color_count = base.correctness.fabric_color_count,
            .max_collective_group_size = base.correctness.max_collective_group_size,
            .sub_tile_lane_width = base.correctness.sub_tile_lane_width,
            .native_numerical_modes = base.correctness.native_numerical_modes,
            .native_collectives = base.correctness.native_collectives,
            .fused_intrinsics = base.correctness.fused_intrinsics,
            .streaming_gemm = base.correctness.streaming_gemm,
            .runtime_sized_binding_policy = base.correctness.runtime_sized_binding_policy,
        },
        .planner = base.planner,
    };
    const base_hash = descriptorHash(base);
    const tweaked_hash = descriptorHash(tweaked);
    try std.testing.expect(!std.mem.eql(u8, &base_hash, &tweaked_hash));
}
