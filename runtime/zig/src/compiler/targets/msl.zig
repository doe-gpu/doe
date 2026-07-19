// Metal Shading Language (MSL) target descriptor.
//
// Represents a portable Apple-Metal compute profile across the Apple
// GPU families (Apple7+/M1+ baseline). Values here must compile and
// execute under Metal's MSL 3.0+ compute pipeline without relying on
// vendor-specific extensions outside the Metal core spec.
//
// Apple's GPU memory model is threadgroup memory; "per-PE" here means
// per-thread private memory inside a threadgroup. Apple SIMD-group
// width is 32 on Apple Silicon (M1/M2/M3/M4), but the baseline
// descriptor declares sub_tile_lane_width=1 since SIMD-group ops are
// emitted on a separate (future) descriptor when Doe advertises
// SIMD-group caps.
//
// Note: bf16 lands natively on M2+ but is not in the MSL 3.0 baseline
// shader profile, so it is omitted here. f32+f16 cover the portable
// numerical surface; richer modes belong on a SIMD/family-specific
// descriptor.

const std = @import("std");
const common = @import("mod.zig");

const native_numerical_modes = &[_]common.NumericalMode{ .f32, .f16 };

const native_collectives = &[_]common.CollectiveCapability{
    // Metal threadgroup_barrier is native and bit-exact.
    .{ .kind_name = "workgroup_barrier", .exactness_name = "bit_exact_solo" },
    // SIMD-group collectives (simd_sum, simd_broadcast, etc.) live on
    // a future Apple-SIMD-enabled descriptor. On the baseline profile,
    // collective synthesis rejects subgroup_* with
    // TSIR_COLLECTIVE_NOT_REPRESENTABLE.
};

const fused_intrinsics = &[_]common.FusedIntrinsic{
    // No native q4k-dequant intrinsic on Metal; emitter unpacks then
    // multiplies as separate ops. Intentionally empty.
};

pub const descriptor: common.TargetDescriptor = .{
    .correctness = .{
        .name = "msl",
        // Apple Metal threadgroup memory floor on the baseline shader
        // profile is 16 KiB. Per-thread private is effectively large;
        // the workgroup-storage floor is the binding constraint that
        // matches the residency pass's budget check.
        .pe_working_memory_bytes = 16 * 1024,
        .pe_persistent_pool_bytes = 0,
        .fabric_color_count = 0,
        .max_collective_group_size = 1024,
        // Conservative: SIMD-group ops not enabled on the baseline.
        .sub_tile_lane_width = 1,
        .native_numerical_modes = native_numerical_modes,
        .native_collectives = native_collectives,
        .fused_intrinsics = fused_intrinsics,
        .streaming_gemm = .none,
        .runtime_sized_binding_policy = .host_copied,
    },
    .planner = .{
        // Apple GPU threadgroup-barrier is sub-microsecond; the heuristic
        // treats it as a single hop equivalent.
        .fabric_per_hop_latency_ns = 150,
    },
};
