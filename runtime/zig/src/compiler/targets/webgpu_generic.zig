// WebGPU generic target descriptor.
//
// Represents a conservative, portable WebGPU profile — values here
// must compile and execute on Chrome/Edge/Safari/Firefox's WebGPU
// implementations without subgroup-extension reliance. Subgroup-using
// kernels lower through a separate descriptor when Doe advertises
// subgroup caps; that descriptor is a future file.
//
// WebGPU's PE memory model is workgroup memory; "per-PE" here means
// per-thread private memory in a workgroup.

const std = @import("std");
const common = @import("mod.zig");

const native_numerical_modes = &[_]common.NumericalMode{ .f32, .f16 };

const native_collectives = &[_]common.CollectiveCapability{
    // workgroupBarrier is native and bit-exact.
    .{ .kind_name = "workgroup_barrier", .exactness_name = "bit_exact_solo" },
    // Subgroup collectives live on a separate (future) subgroup-enabled
    // descriptor. On this baseline descriptor, the collective-synthesis
    // pass rejects subgroup_* with TSIR_COLLECTIVE_NOT_REPRESENTABLE
    // unless the caller has declared a legal emulation.
};

const fused_intrinsics = &[_]common.FusedIntrinsic{
    // WebGPU has no true fused q4k-dequant intrinsic; emitter unpacks
    // then multiplies as separate ops. Intentionally empty.
};

pub const descriptor: common.TargetDescriptor = .{
    .correctness = .{
        .name = "webgpu-generic",
        // Per-thread private budget is effectively large on WebGPU; the
        // real constraint is workgroup storage. Use the workgroup storage
        // floor so the residency pass's budget check matches the real
        // device limit.
        .pe_working_memory_bytes = 16 * 1024,
        .pe_persistent_pool_bytes = 0,
        .fabric_color_count = 0,
        .max_collective_group_size = 256,
        // WebGPU spec baseline minimum subgroup size is 4; conservatively
        // 1 here since the baseline profile does not enable subgroup ops.
        .sub_tile_lane_width = 1,
        .native_numerical_modes = native_numerical_modes,
        .native_collectives = native_collectives,
        .fused_intrinsics = fused_intrinsics,
        .streaming_gemm = .none,
        .runtime_sized_binding_policy = .host_copied,
    },
    .planner = .{
        // WebGPU: workgroup barrier cost is roughly a few hundred ns;
        // stored here as a single "hop" equivalent for the heuristic.
        .fabric_per_hop_latency_ns = 200,
    },
};
