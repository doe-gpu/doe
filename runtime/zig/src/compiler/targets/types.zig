//! Shared target descriptor identities. Descriptor instances import this
//! module directly; the aggregate target registry only re-exports it.

pub const NumericalMode = enum { f32, f16, bf16, int8_quant, int4_quant };

pub const CollectiveCapability = struct {
    kind_name: []const u8,
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

pub const CorrectnessFields = struct {
    name: []const u8,
    pe_working_memory_bytes: u64,
    pe_persistent_pool_bytes: u64,
    fabric_color_count: u32,
    max_collective_group_size: u32,
    sub_tile_lane_width: u32,
    native_numerical_modes: []const NumericalMode,
    native_collectives: []const CollectiveCapability,
    fused_intrinsics: []const FusedIntrinsic,
    streaming_gemm: StreamingGemmPrimitive,
    runtime_sized_binding_policy: RuntimeSizedBindingPolicy,
};

pub const PlannerFields = struct {
    fabric_per_hop_latency_ns: u32,
};

pub const TargetDescriptor = struct {
    correctness: CorrectnessFields,
    planner: PlannerFields,
};
