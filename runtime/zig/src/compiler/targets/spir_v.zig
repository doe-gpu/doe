// SPIR-V (Vulkan compute) target descriptor.
//
// Represents a conservative Vulkan-1.1-baseline SPIR-V compute profile
// portable across desktop GPU drivers (NVIDIA, AMD, Intel, Apple via
// MoltenVK, Mesa). Values here must compile and execute without relying
// on extensions outside the Vulkan 1.1 core surface.
//
// SPIR-V's PE memory model is workgroup memory; "per-PE" here means
// per-invocation private memory inside a workgroup. Subgroup-size on
// real hardware varies (NVIDIA 32, AMD 32/64, Intel 8/16/32); the
// baseline descriptor declares sub_tile_lane_width=1 since
// VK_KHR_shader_subgroup ops are emitted on a separate (future)
// descriptor when Doe advertises subgroup caps.
//
// f16 is gated on VK_KHR_shader_float16_int8; the baseline profile
// declares f32 + f16 because float16 has been mandatory under
// Vulkan 1.2 / shaderFloat16 in practice for compute shaders. bf16
// remains gated on VK_KHR_shader_bfloat16 (post-1.2 extension) and
// is omitted from the baseline.

const std = @import("std");
const common = @import("mod.zig");

const native_numerical_modes = &[_]common.NumericalMode{ .f32, .f16 };

const native_collectives = &[_]common.CollectiveCapability{
    // OpControlBarrier with WorkgroupMemory scope is native and bit-exact.
    .{ .kind_name = "workgroup_barrier", .exactness_name = "bit_exact_solo" },
    // VK_KHR_shader_subgroup collectives (subgroupAdd, subgroupBroadcast,
    // subgroupBallot, etc.) live on a future subgroup-enabled descriptor.
    // On this baseline profile, collective synthesis rejects subgroup_*
    // with TSIR_COLLECTIVE_NOT_REPRESENTABLE.
};

const fused_intrinsics = &[_]common.FusedIntrinsic{
    // No native q4k-dequant intrinsic on portable SPIR-V; emitter
    // unpacks then multiplies as separate ops. Intentionally empty.
};

pub const descriptor: common.TargetDescriptor = .{
    .correctness = .{
        .name = "spir-v",
        // Vulkan 1.1 maxComputeSharedMemorySize floor is 16 KiB
        // (NVIDIA/Intel/AMD desktop drivers all support 32+ KiB; floor
        // for portability is the spec minimum). Per-invocation private
        // memory is effectively large; the workgroup-storage floor is
        // the binding constraint matching the residency pass's check.
        .pe_working_memory_bytes = 16 * 1024,
        .pe_persistent_pool_bytes = 0,
        .fabric_color_count = 0,
        // Vulkan 1.1 maxComputeWorkGroupInvocations floor is 128.
        .max_collective_group_size = 128,
        // Conservative: subgroup ops not enabled on the baseline.
        .sub_tile_lane_width = 1,
        .native_numerical_modes = native_numerical_modes,
        .native_collectives = native_collectives,
        .fused_intrinsics = fused_intrinsics,
        .streaming_gemm = .none,
        .runtime_sized_binding_policy = .host_copied,
    },
    .planner = .{
        // SPIR-V workgroup barrier on desktop drivers is on the same
        // order as WebGPU's; the heuristic treats it as a single hop
        // equivalent.
        .fabric_per_hop_latency_ns = 200,
    },
};
