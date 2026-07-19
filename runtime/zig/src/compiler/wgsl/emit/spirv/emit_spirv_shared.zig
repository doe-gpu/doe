const ir = @import("../../ir/ir.zig");
const spirv = @import("spirv_builder.zig");

pub const EmitError = spirv.EmitError || error{
    InvalidIr,
};

pub fn addr_space_to_storage_class(addr_space: ir.AddressSpace) u32 {
    return switch (addr_space) {
        .function => spirv.StorageClass.Function,
        .private => spirv.StorageClass.Private,
        .workgroup => spirv.StorageClass.Workgroup,
        .uniform => spirv.StorageClass.Uniform,
        .storage => spirv.StorageClass.StorageBuffer,
        .handle => spirv.StorageClass.UniformConstant,
    };
}

pub fn builtin_to_spirv(builtin: ir.Builtin) EmitError!u32 {
    return switch (builtin) {
        .position => spirv.Builtin.Position,
        .vertex_index => spirv.Builtin.VertexIndex,
        .instance_index => spirv.Builtin.InstanceIndex,
        .frag_depth => spirv.Builtin.FragDepth,
        .front_facing => spirv.Builtin.FrontFacing,
        .sample_index => spirv.Builtin.SampleIndex,
        .sample_mask => spirv.Builtin.SampleMask,
        .global_invocation_id => spirv.Builtin.GlobalInvocationId,
        .local_invocation_id => spirv.Builtin.LocalInvocationId,
        .local_invocation_index => spirv.Builtin.LocalInvocationIndex,
        .workgroup_id => spirv.Builtin.WorkgroupId,
        .num_workgroups => spirv.Builtin.NumWorkgroups,
        .subgroup_size => spirv.Builtin.SubgroupSize,
        .subgroup_invocation_id => spirv.Builtin.SubgroupLocalInvocationId,
        .clip_distances => spirv.Builtin.ClipDistance,
        .primitive_index => spirv.Builtin.PrimitiveId,
        .none => error.InvalidIr,
    };
}
