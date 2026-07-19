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

pub const wse3 = @import("wse3.zig");
pub const webgpu_generic = @import("webgpu_generic.zig");
pub const msl = @import("msl.zig");
pub const spir_v = @import("spir_v.zig");

pub const NumericalMode = enum { f32, f16, bf16, int8_quant, int4_quant };

pub const CollectiveCapability = struct {
    /// Must match tsir.schema.CollectiveKind. Kept as a string here to
    /// avoid a cyclic import between targets/ and tsir/; callers
    /// lookup the enum by name.
    kind_name: []const u8,
    /// Exactness this target can honor natively. Callers compare
    /// against the TSIR-declared exactness; non-match triggers either
    /// tree-shape search or TSIR_COLLECTIVE_NOT_REPRESENTABLE.
    exactness_name: []const u8,
};

pub const FusedIntrinsic = enum {
    q4k_dequant,
    q4k_dequant_then_gemv,
    rms_norm_fast,
    rope_pair,
};

pub const StreamingGemmPrimitive = enum {
    none,
    mpi_x_allreduce,
    mpi_y_allreduce,
    summa,
};

pub const RuntimeSizedBindingPolicy = enum {
    reject,
    host_copied,
    fabric_streamed_with_loader,
};

/// Correctness-affecting fields. These determine whether a kernel can
/// be represented on this target and what byte-for-byte output a
/// realization must produce. Every field here participates in the
/// descriptor hash that binds into `tsir.Realization.target_descriptor_hash`.
pub const CorrectnessFields = struct {
    name: []const u8,
    /// Free bytes on each PE that a kernel's locals can occupy. The
    /// residency pass refuses to place a tensor beyond this bound
    /// with TSIR_PE_BUDGET_EXHAUSTED.
    pe_working_memory_bytes: u64,
    /// Persistent pool per PE available across launches.
    pe_persistent_pool_bytes: u64,
    /// Number of independent fabric colors available for collective
    /// synthesis to allocate onto.
    fabric_color_count: u32,
    max_collective_group_size: u32,
    /// Sub-tile lane width for subgroup-style SIMD. WSE-3 uses this
    /// for in-PE reductions; WebGPU's native subgroup size.
    sub_tile_lane_width: u32,
    native_numerical_modes: []const NumericalMode,
    native_collectives: []const CollectiveCapability,
    fused_intrinsics: []const FusedIntrinsic,
    streaming_gemm: StreamingGemmPrimitive,
    /// How the target can legally realize storage bindings whose WGSL
    /// type has runtime-sized extents. This is correctness-affecting:
    /// choosing host-backed buffers versus fabric streaming changes the
    /// emitted lowering contract.
    runtime_sized_binding_policy: RuntimeSizedBindingPolicy,
};

/// Planner-only fields. These inform search quality (which plan is
/// preferred among multiple fitting plans) but do NOT define what is
/// representable or what byte-for-byte output must be. Changes to
/// planner fields must NOT invalidate existing manifests.
pub const PlannerFields = struct {
    /// Approximate per-hop fabric latency in nanoseconds. Used by the
    /// collective-synthesis pass to bias tree shape among equally-
    /// feasible realizations; it never forces rejection.
    fabric_per_hop_latency_ns: u32,
};

pub const TargetDescriptor = struct {
    correctness: CorrectnessFields,
    planner: PlannerFields,
};

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
