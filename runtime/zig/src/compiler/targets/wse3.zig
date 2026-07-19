// WSE-3 target descriptor.
//
// Every field is a declared value, not an inferred default. Numbers
// below are the working baseline taken from Cerebras SDK 2.10 public
// documentation and the Doe e2b-full-graph runtime-config reference.
// When the descriptor is refined, bump the hash by changing any
// correctness field — it is illegal to silently re-interpret a value.
// Planner-only fields can be tuned without invalidating existing
// manifests.

const std = @import("std");
const common = @import("mod.zig");

const native_numerical_modes = &[_]common.NumericalMode{
    .f32, .f16, .bf16, .int8_quant, .int4_quant,
};

const native_collectives = &[_]common.CollectiveCapability{
    // Same-PE SIMD reductions over the sub-tile lane width.
    .{ .kind_name = "subgroup_add", .exactness_name = "algorithm_exact" },
    .{ .kind_name = "subgroup_min", .exactness_name = "algorithm_exact" },
    .{ .kind_name = "subgroup_max", .exactness_name = "algorithm_exact" },
    .{ .kind_name = "subgroup_broadcast", .exactness_name = "bit_exact_solo" },
    // Fabric collectives reachable via mpi_x / mpi_y primitives in
    // collectives_2d; exactness is algorithm_exact because associativity
    // is declared by the realization tree shape, not preserved byte-wise.
    .{ .kind_name = "fabric_reduce", .exactness_name = "algorithm_exact" },
    .{ .kind_name = "fabric_broadcast", .exactness_name = "bit_exact_solo" },
    .{ .kind_name = "fabric_allreduce", .exactness_name = "algorithm_exact" },
    // workgroupBarrier lowers to a fabric sync on a declared barrier color.
    .{ .kind_name = "workgroup_barrier", .exactness_name = "bit_exact_solo" },
};

const fused_intrinsics = &[_]common.FusedIntrinsic{
    .q4k_dequant,
    .q4k_dequant_then_gemv,
    .rms_norm_fast,
    .rope_pair,
};

/// Public WSE-3 descriptor. The residency and collective passes read
/// ONLY this struct; no WSE-3-specific logic is allowed outside this
/// file plus the one mechanical TSIR-to-CSL emitter.
pub const descriptor: common.TargetDescriptor = .{
    .correctness = .{
        .name = "wse3",
        // Conservative per-PE working budget. Real kernels measure their
        // footprint against this; over-shoot rejects with
        // TSIR_PE_BUDGET_EXHAUSTED. Tighter than the physical upper bound
        // intentionally — the emitter reserves headroom for task table,
        // .data.hi, and filters sections.
        .pe_working_memory_bytes = 38 * 1024,
        .pe_persistent_pool_bytes = 10 * 1024,
        // SDK 2.10 default color pool. Collective synthesis allocates onto
        // these.
        .fabric_color_count = 24,
        .max_collective_group_size = 256,
        .sub_tile_lane_width = 1,
        .native_numerical_modes = native_numerical_modes,
        .native_collectives = native_collectives,
        .fused_intrinsics = fused_intrinsics,
        .streaming_gemm = .summa,
        .runtime_sized_binding_policy = .fabric_streamed_with_loader,
    },
    .planner = .{
        .fabric_per_hop_latency_ns = 2,
    },
};
