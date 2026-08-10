const std = @import("std");
const ir = @import("../../ir/ir.zig");
const spirv = @import("spirv_builder.zig");
const emit_spirv_shared = @import("emit_spirv_shared.zig");
const texture = @import("emit_spirv_texture.zig");

pub fn emit_builtin(self: anytype, call: anytype, result_ty: ir.TypeId) !?u32 {
    if (std.mem.eql(u8, call.name, "workgroupBarrier")) {
        try emit_control_barrier(self, spirv.MemorySemantics.AcquireRelease | spirv.MemorySemantics.WorkgroupMemory);
        return 0;
    }
    if (std.mem.eql(u8, call.name, "storageBarrier")) {
        try emit_control_barrier(self, spirv.MemorySemantics.AcquireRelease | spirv.MemorySemantics.UniformMemory | spirv.MemorySemantics.ImageMemory);
        return 0;
    }
    if (std.mem.eql(u8, call.name, "textureBarrier")) {
        try emit_control_barrier(self, spirv.MemorySemantics.AcquireRelease | spirv.MemorySemantics.ImageMemory);
        return 0;
    }
    if (std.mem.startsWith(u8, call.name, "atomic")) {
        return try emit_atomic_call(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "arrayLength")) {
        return try emit_array_length(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureLoad")) {
        return try texture.emit_texture_load(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureSample")) {
        return try texture.emit_texture_sample(self, call, result_ty, false);
    }
    if (std.mem.eql(u8, call.name, "textureSampleBaseClampToEdge")) {
        return try texture.emit_texture_sample(self, call, result_ty, false);
    }
    if (std.mem.eql(u8, call.name, "textureSampleLevel")) {
        return try texture.emit_texture_sample(self, call, result_ty, true);
    }
    if (std.mem.eql(u8, call.name, "textureSampleBias")) {
        return try texture.emit_texture_sample_bias(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureSampleCompare")) {
        return try texture.emit_texture_sample_compare(self, call, result_ty, false);
    }
    if (std.mem.eql(u8, call.name, "textureSampleCompareLevel")) {
        return try texture.emit_texture_sample_compare(self, call, result_ty, true);
    }
    if (std.mem.eql(u8, call.name, "textureGather")) {
        return try texture.emit_texture_gather(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureGatherCompare")) {
        return try texture.emit_texture_gather_compare(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureSampleGrad")) {
        return try texture.emit_texture_sample_grad(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureSampleOffset")) {
        return try texture.emit_texture_sample_offset(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureSampleLevelOffset")) {
        return try texture.emit_texture_sample_level_offset(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureStore")) {
        try texture.emit_texture_store(self, call);
        return 0;
    }
    if (std.mem.eql(u8, call.name, "textureDimensions")) {
        return try texture.emit_texture_dimensions(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureNumLevels")) {
        return try texture.emit_texture_num_levels(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "textureNumLayers")) {
        return try texture.emit_texture_num_layers(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "dot")) {
        return try emit_dot(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "any")) {
        return try emit_bool_vector_reduce(self, call, result_ty, spirv.Opcode.Any);
    }
    if (std.mem.eql(u8, call.name, "all")) {
        return try emit_bool_vector_reduce(self, call, result_ty, spirv.Opcode.All);
    }
    if (std.mem.eql(u8, call.name, "bitcast")) {
        if (call.args.len != 1) return error.InvalidIr;
        const result_type = try self.emitter.lower_type(result_ty);
        const result_id = self.emitter.builder.reserve_id();
        try self.emitter.builder.append_function_inst(
            spirv.Opcode.Bitcast,
            &.{ result_type, result_id, try self.emit_value_expr(self.function.expr_args.items[call.args.start]) },
        );
        return result_id;
    }
    if (std.mem.eql(u8, call.name, "pack2x16float")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 60);
    }
    if (std.mem.eql(u8, call.name, "unpack2x16float")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 62);
    }
    if (std.mem.eql(u8, call.name, "pack4x8unorm")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 58);
    }
    if (std.mem.eql(u8, call.name, "pack4x8snorm")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 59);
    }
    if (std.mem.eql(u8, call.name, "unpack4x8snorm")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 63);
    }
    if (std.mem.eql(u8, call.name, "unpack4x8unorm")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 64);
    }
    if (std.mem.eql(u8, call.name, "subgroupAdd")) {
        return try emit_subgroup_reduce(self, call, result_ty, subgroup_arithmetic_opcode(self.scalar_kind(result_ty), .add) orelse return error.UnsupportedConstruct);
    }
    if (std.mem.eql(u8, call.name, "subgroupExclusiveAdd")) {
        return try emit_subgroup_exclusive_scan(self, call, result_ty, subgroup_arithmetic_opcode(self.scalar_kind(result_ty), .add) orelse return error.UnsupportedConstruct);
    }
    if (std.mem.eql(u8, call.name, "subgroupMin")) {
        return try emit_subgroup_reduce(self, call, result_ty, subgroup_arithmetic_opcode(self.scalar_kind(result_ty), .min) orelse return error.UnsupportedConstruct);
    }
    if (std.mem.eql(u8, call.name, "subgroupMax")) {
        return try emit_subgroup_reduce(self, call, result_ty, subgroup_arithmetic_opcode(self.scalar_kind(result_ty), .max) orelse return error.UnsupportedConstruct);
    }
    if (std.mem.eql(u8, call.name, "subgroupBroadcast")) {
        return try emit_subgroup_shuffle_like(self, call, result_ty, spirv.Opcode.GroupNonUniformBroadcast);
    }
    if (std.mem.eql(u8, call.name, "subgroupShuffle")) {
        return try emit_subgroup_shuffle_like(self, call, result_ty, spirv.Opcode.GroupNonUniformShuffle);
    }
    if (std.mem.eql(u8, call.name, "subgroupShuffleXor")) {
        return try emit_subgroup_shuffle_like(self, call, result_ty, spirv.Opcode.GroupNonUniformShuffleXor);
    }
    if (std.mem.eql(u8, call.name, "select")) {
        if (call.args.len != 3) return error.InvalidIr;
        const result_type = try self.emitter.lower_type(result_ty);
        const result_id = self.emitter.builder.reserve_id();
        try self.emitter.builder.append_function_inst(
            spirv.Opcode.Select,
            &.{
                result_type,
                result_id,
                try self.emit_value_expr(self.function.expr_args.items[call.args.start + 2]),
                try self.emit_value_expr(self.function.expr_args.items[call.args.start + 1]),
                try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
            },
        );
        return result_id;
    }

    // Bit manipulation builtins — native SPIR-V opcodes.
    if (std.mem.eql(u8, call.name, "countOneBits")) {
        if (call.args.len != 1) return error.InvalidIr;
        return try emit_result_inst(self, spirv.Opcode.BitCount, try self.emitter.lower_type(result_ty), &.{
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    if (std.mem.eql(u8, call.name, "reverseBits")) {
        if (call.args.len != 1) return error.InvalidIr;
        return try emit_result_inst(self, spirv.Opcode.BitReverse, try self.emitter.lower_type(result_ty), &.{
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    if (std.mem.eql(u8, call.name, "extractBits")) {
        if (call.args.len != 3) return error.InvalidIr;
        const opcode: u16 = switch (self.scalar_kind(result_ty)) {
            .signed => spirv.Opcode.BitFieldSExtract,
            else => spirv.Opcode.BitFieldUExtract,
        };
        return try emit_result_inst(self, opcode, try self.emitter.lower_type(result_ty), &.{
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
            try self.emit_value_expr(self.function.expr_args.items[call.args.start + 1]),
            try self.emit_value_expr(self.function.expr_args.items[call.args.start + 2]),
        });
    }
    if (std.mem.eql(u8, call.name, "insertBits")) {
        if (call.args.len != 4) return error.InvalidIr;
        return try emit_result_inst(self, spirv.Opcode.BitFieldInsert, try self.emitter.lower_type(result_ty), &.{
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
            try self.emit_value_expr(self.function.expr_args.items[call.args.start + 1]),
            try self.emit_value_expr(self.function.expr_args.items[call.args.start + 2]),
            try self.emit_value_expr(self.function.expr_args.items[call.args.start + 3]),
        });
    }
    if (std.mem.eql(u8, call.name, "transpose")) {
        if (call.args.len != 1) return error.InvalidIr;
        return try emit_result_inst(self, spirv.Opcode.Transpose, try self.emitter.lower_type(result_ty), &.{
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    // saturate(x) = clamp(x, 0.0, 1.0) via NClamp(x, 0, 1) GLSL.std.450 inst 44
    if (std.mem.eql(u8, call.name, "saturate")) {
        if (call.args.len != 1) return error.InvalidIr;
        const result_type = try self.emitter.lower_type(result_ty);
        const result_id = self.emitter.builder.reserve_id();
        const import_id = try self.emitter.builder.glsl450_import_id();
        const zero = try self.emitter.builder.const_f32_bits(@as(u32, @bitCast(@as(f32, 0.0))));
        const one = try self.emitter.builder.const_f32_bits(@as(u32, @bitCast(@as(f32, 1.0))));
        var operands = std.ArrayListUnmanaged(u32){};
        defer operands.deinit(self.emitter.alloc);
        try operands.append(self.emitter.alloc, result_type);
        try operands.append(self.emitter.alloc, result_id);
        try operands.append(self.emitter.alloc, import_id);
        try operands.append(self.emitter.alloc, 44); // NClamp
        try operands.append(self.emitter.alloc, try self.emit_value_expr(self.function.expr_args.items[call.args.start]));
        try operands.append(self.emitter.alloc, zero);
        try operands.append(self.emitter.alloc, one);
        try self.emitter.builder.append_function_inst(spirv.Opcode.ExtInst, operands.items);
        return result_id;
    }
    // Subgroup vote builtins.
    if (std.mem.eql(u8, call.name, "subgroupAll")) {
        if (call.args.len != 1) return error.InvalidIr;
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformVote);
        const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
        return try emit_result_inst(self, spirv.Opcode.GroupNonUniformAll, try self.emitter.lower_type(result_ty), &.{
            scope_id,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    if (std.mem.eql(u8, call.name, "subgroupAny")) {
        if (call.args.len != 1) return error.InvalidIr;
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformVote);
        const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
        return try emit_result_inst(self, spirv.Opcode.GroupNonUniformAny, try self.emitter.lower_type(result_ty), &.{
            scope_id,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    if (std.mem.eql(u8, call.name, "subgroupBallot")) {
        if (call.args.len != 1) return error.InvalidIr;
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformBallot);
        const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
        return try emit_result_inst(self, spirv.Opcode.GroupNonUniformBallot, try self.emitter.lower_type(result_ty), &.{
            scope_id,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    if (std.mem.eql(u8, call.name, "subgroupMul")) {
        return try emit_subgroup_reduce(self, call, result_ty, subgroup_arithmetic_opcode(self.scalar_kind(result_ty), .mul) orelse return error.UnsupportedConstruct);
    }
    if (std.mem.eql(u8, call.name, "subgroupInclusiveAdd")) {
        return try emit_subgroup_inclusive_scan(self, call, result_ty, subgroup_arithmetic_opcode(self.scalar_kind(result_ty), .add) orelse return error.UnsupportedConstruct);
    }
    if (std.mem.eql(u8, call.name, "subgroupAnd")) {
        return try emit_subgroup_reduce(self, call, result_ty, spirv.Opcode.GroupNonUniformBitwiseAnd);
    }
    if (std.mem.eql(u8, call.name, "subgroupOr")) {
        return try emit_subgroup_reduce(self, call, result_ty, spirv.Opcode.GroupNonUniformBitwiseOr);
    }
    if (std.mem.eql(u8, call.name, "subgroupXor")) {
        return try emit_subgroup_reduce(self, call, result_ty, spirv.Opcode.GroupNonUniformBitwiseXor);
    }
    if (std.mem.eql(u8, call.name, "subgroupShuffleDown")) {
        return try emit_subgroup_shuffle_like(self, call, result_ty, spirv.Opcode.GroupNonUniformShuffleDown);
    }
    if (std.mem.eql(u8, call.name, "subgroupShuffleUp")) {
        return try emit_subgroup_shuffle_like(self, call, result_ty, spirv.Opcode.GroupNonUniformShuffleUp);
    }
    if (std.mem.eql(u8, call.name, "subgroupBroadcastFirst")) {
        if (call.args.len != 1) return error.InvalidIr;
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformBallot);
        const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
        return try emit_result_inst(self, spirv.Opcode.GroupNonUniformBroadcastFirst, try self.emitter.lower_type(result_ty), &.{
            scope_id,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }
    if (std.mem.eql(u8, call.name, "subgroupElect")) {
        if (call.args.len != 0) return error.InvalidIr;
        try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
        const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
        return try emit_result_inst(self, spirv.Opcode.GroupNonUniformElect, try self.emitter.lower_type(result_ty), &.{
            scope_id,
        });
    }

    if (derivative_opcode(call.name)) |opcode| {
        if (call.args.len != 1) return error.InvalidIr;
        if (derivative_requires_control(opcode)) {
            try self.emitter.builder.emit_capability(spirv.Capability.DerivativeControl);
        }
        return try emit_result_inst(self, opcode, try self.emitter.lower_type(result_ty), &.{
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        });
    }

    if (builtin_inst_1(call.name, self.scalar_kind(result_ty))) |inst| {
        return try emit_glsl_ext_inst_args(self, call, result_ty, inst);
    }
    if (builtin_inst_2(call.name, self.scalar_kind(result_ty))) |inst| {
        return try emit_glsl_ext_inst_args(self, call, result_ty, inst);
    }
    if (builtin_inst_3(call.name, self.scalar_kind(result_ty))) |inst| {
        return try emit_glsl_ext_inst_args(self, call, result_ty, inst);
    }

    if (std.mem.eql(u8, call.name, "length")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 66);
    }
    if (std.mem.eql(u8, call.name, "distance")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 67);
    }
    if (std.mem.eql(u8, call.name, "cross")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 68);
    }
    if (std.mem.eql(u8, call.name, "reflect")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 71);
    }
    if (std.mem.eql(u8, call.name, "refract")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 72);
    }
    if (std.mem.eql(u8, call.name, "determinant")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 33);
    }
    // GLSL.std.450 FindSMsb / FindUMsb for firstLeadingBit.
    if (std.mem.eql(u8, call.name, "firstLeadingBit")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, switch (self.scalar_kind(result_ty)) {
            .signed => 44, // FindSMsb
            else => 42, // FindUMsb
        });
    }
    if (std.mem.eql(u8, call.name, "firstTrailingBit")) {
        return try emit_glsl_ext_inst_args(self, call, result_ty, 73); // FindILsb
    }
    // countLeadingZeros and countTrailingZeros are not direct GLSL.std.450 ops,
    // but WGSL specifies them. For SPIR-V we can approximate using FindUMsb/FindILsb
    // but the exact semantics differ. For now, map them through GLSL.std.450.
    if (std.mem.eql(u8, call.name, "countLeadingZeros")) {
        // CLZ(x) = x == 0 ? 32 : (31 - FindUMsb(x))
        // For simplicity and correctness, emit as a single FindUMsb and subtract.
        return try emit_count_leading_zeros(self, call, result_ty);
    }
    if (std.mem.eql(u8, call.name, "countTrailingZeros")) {
        // CTZ(x) = x == 0 ? 32 : FindILsb(x)
        return try emit_count_trailing_zeros(self, call, result_ty);
    }

    return null;
}

const SubgroupArithmeticOp = enum { add, mul, min, max };

fn emit_glsl_ext_inst_args(self: anytype, call: anytype, result_ty: ir.TypeId, inst: u32) !u32 {
    const result_type = try self.emitter.lower_type(result_ty);
    const result_id = self.emitter.builder.reserve_id();
    const import_id = try self.emitter.builder.glsl450_import_id();

    var operands = std.ArrayListUnmanaged(u32){};
    defer operands.deinit(self.emitter.alloc);
    try operands.append(self.emitter.alloc, result_type);
    try operands.append(self.emitter.alloc, result_id);
    try operands.append(self.emitter.alloc, import_id);
    try operands.append(self.emitter.alloc, inst);

    var i: u32 = 0;
    while (i < call.args.len) : (i += 1) {
        try operands.append(self.emitter.alloc, try self.emit_value_expr(self.function.expr_args.items[call.args.start + i]));
    }

    try self.emitter.builder.append_function_inst(spirv.Opcode.ExtInst, operands.items);
    return result_id;
}

fn emit_subgroup_reduce(self: anytype, call: anytype, result_ty: ir.TypeId, opcode: u16) !u32 {
    if (call.args.len != 1) return error.InvalidIr;
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformArithmetic);
    const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
    return try emit_result_inst(
        self,
        opcode,
        try self.emitter.lower_type(result_ty),
        &.{
            scope_id,
            spirv.GroupOperation.Reduce,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        },
    );
}

fn emit_subgroup_exclusive_scan(self: anytype, call: anytype, result_ty: ir.TypeId, opcode: u16) !u32 {
    if (call.args.len != 1) return error.InvalidIr;
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformArithmetic);
    const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
    return try emit_result_inst(
        self,
        opcode,
        try self.emitter.lower_type(result_ty),
        &.{
            scope_id,
            spirv.GroupOperation.ExclusiveScan,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        },
    );
}

fn emit_subgroup_shuffle_like(self: anytype, call: anytype, result_ty: ir.TypeId, opcode: u16) !u32 {
    if (call.args.len != 2) return error.InvalidIr;
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformShuffle);
    const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
    return try emit_result_inst(
        self,
        opcode,
        try self.emitter.lower_type(result_ty),
        &.{
            scope_id,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
            try self.emit_value_expr(self.function.expr_args.items[call.args.start + 1]),
        },
    );
}

fn emit_subgroup_inclusive_scan(self: anytype, call: anytype, result_ty: ir.TypeId, opcode: u16) !u32 {
    if (call.args.len != 1) return error.InvalidIr;
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniform);
    try self.emitter.builder.emit_capability(spirv.Capability.GroupNonUniformArithmetic);
    const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Subgroup);
    return try emit_result_inst(
        self,
        opcode,
        try self.emitter.lower_type(result_ty),
        &.{
            scope_id,
            spirv.GroupOperation.InclusiveScan,
            try self.emit_value_expr(self.function.expr_args.items[call.args.start]),
        },
    );
}

fn subgroup_arithmetic_opcode(kind: anytype, op: SubgroupArithmeticOp) ?u16 {
    return switch (op) {
        .add => switch (kind) {
            .float => spirv.Opcode.GroupNonUniformFAdd,
            .signed, .unsigned => spirv.Opcode.GroupNonUniformIAdd,
            else => null,
        },
        .mul => switch (kind) {
            .float => spirv.Opcode.GroupNonUniformFMul,
            .signed, .unsigned => spirv.Opcode.GroupNonUniformIMul,
            else => null,
        },
        .min => switch (kind) {
            .float => spirv.Opcode.GroupNonUniformFMin,
            .signed => spirv.Opcode.GroupNonUniformSMin,
            .unsigned => spirv.Opcode.GroupNonUniformUMin,
            else => null,
        },
        .max => switch (kind) {
            .float => spirv.Opcode.GroupNonUniformFMax,
            .signed => spirv.Opcode.GroupNonUniformSMax,
            .unsigned => spirv.Opcode.GroupNonUniformUMax,
            else => null,
        },
    };
}

fn emit_result_inst(self: anytype, opcode: u16, result_type: u32, operands: []const u32) !u32 {
    return emit_spirv_shared.emitUncachedResultInst(
        &self.emitter.builder,
        self.emitter.alloc,
        opcode,
        result_type,
        operands,
    );
}

fn derivative_opcode(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "dpdx")) return spirv.Opcode.DPdx;
    if (std.mem.eql(u8, name, "dpdy")) return spirv.Opcode.DPdy;
    if (std.mem.eql(u8, name, "fwidth")) return spirv.Opcode.Fwidth;
    if (std.mem.eql(u8, name, "dpdxFine")) return spirv.Opcode.DPdxFine;
    if (std.mem.eql(u8, name, "dpdyFine")) return spirv.Opcode.DPdyFine;
    if (std.mem.eql(u8, name, "fwidthFine")) return spirv.Opcode.FwidthFine;
    if (std.mem.eql(u8, name, "dpdxCoarse")) return spirv.Opcode.DPdxCoarse;
    if (std.mem.eql(u8, name, "dpdyCoarse")) return spirv.Opcode.DPdyCoarse;
    if (std.mem.eql(u8, name, "fwidthCoarse")) return spirv.Opcode.FwidthCoarse;
    return null;
}

fn derivative_requires_control(opcode: u16) bool {
    return opcode == spirv.Opcode.DPdxFine or
        opcode == spirv.Opcode.DPdyFine or
        opcode == spirv.Opcode.FwidthFine or
        opcode == spirv.Opcode.DPdxCoarse or
        opcode == spirv.Opcode.DPdyCoarse or
        opcode == spirv.Opcode.FwidthCoarse;
}

fn builtin_inst_1(name: []const u8, kind: anytype) ?u32 {
    if (std.mem.eql(u8, name, "sin")) return 13;
    if (std.mem.eql(u8, name, "fract")) return 10;
    if (std.mem.eql(u8, name, "cos")) return 14;
    if (std.mem.eql(u8, name, "exp")) return 27;
    if (std.mem.eql(u8, name, "log")) return 28;
    if (std.mem.eql(u8, name, "exp2")) return 29;
    if (std.mem.eql(u8, name, "log2")) return 30;
    if (std.mem.eql(u8, name, "sqrt")) return 31;
    if (std.mem.eql(u8, name, "inverseSqrt")) return 32;
    if (std.mem.eql(u8, name, "floor")) return 8;
    if (std.mem.eql(u8, name, "ceil")) return 9;
    if (std.mem.eql(u8, name, "round")) return 1;
    if (std.mem.eql(u8, name, "trunc")) return 3;
    if (std.mem.eql(u8, name, "tanh")) return 21;
    if (std.mem.eql(u8, name, "normalize")) return 69;
    if (std.mem.eql(u8, name, "degrees")) return 11;
    if (std.mem.eql(u8, name, "radians")) return 12;
    if (std.mem.eql(u8, name, "tan")) return 15;
    if (std.mem.eql(u8, name, "asin")) return 16;
    if (std.mem.eql(u8, name, "acos")) return 17;
    if (std.mem.eql(u8, name, "atan")) return 18;
    if (std.mem.eql(u8, name, "sinh")) return 19;
    if (std.mem.eql(u8, name, "cosh")) return 20;
    if (std.mem.eql(u8, name, "sign")) return switch (kind) {
        .float => 6,
        .signed => 7,
        else => null,
    };
    if (std.mem.eql(u8, name, "abs")) return switch (kind) {
        .float => 4,
        .signed => 5,
        else => null,
    };
    return null;
}

fn builtin_inst_2(name: []const u8, kind: anytype) ?u32 {
    if (std.mem.eql(u8, name, "pow")) return 26;
    if (std.mem.eql(u8, name, "step")) return 48;
    if (std.mem.eql(u8, name, "atan2")) return 25;
    if (std.mem.eql(u8, name, "ldexp")) return 71;
    if (std.mem.eql(u8, name, "min")) return switch (kind) {
        .float => 37,
        .unsigned => 38,
        .signed => 39,
        else => null,
    };
    if (std.mem.eql(u8, name, "max")) return switch (kind) {
        .float => 40,
        .unsigned => 41,
        .signed => 42,
        else => null,
    };
    return null;
}

fn builtin_inst_3(name: []const u8, kind: anytype) ?u32 {
    if (std.mem.eql(u8, name, "clamp")) return switch (kind) {
        .float => 43,
        .unsigned => 44,
        .signed => 45,
        else => null,
    };
    if (std.mem.eql(u8, name, "mix")) return 46;
    if (std.mem.eql(u8, name, "smoothstep")) return 49;
    if (std.mem.eql(u8, name, "fma")) return 50;
    return null;
}

fn emit_control_barrier(self: anytype, memory_semantics: u32) !void {
    const scope_id = try self.emitter.builder.const_u32(spirv.Scope.Workgroup);
    const semantics_id = try self.emitter.builder.const_u32(memory_semantics);
    try self.emitter.builder.append_function_inst(
        spirv.Opcode.ControlBarrier,
        &.{ scope_id, scope_id, semantics_id },
    );
}

const AtomicMemoryOperands = struct {
    scope_id: u32,
    semantics_id: u32,
};

fn emit_atomic_call(self: anytype, call: anytype, result_ty: ir.TypeId) !u32 {
    if (call.args.len == 0) return error.InvalidIr;
    const ptr_expr = self.function.expr_args.items[call.args.start];
    const ptr_id = try self.emit_ref_expr(ptr_expr);
    const memory = try atomic_memory_operands(self, ptr_expr);

    if (std.mem.eql(u8, call.name, "atomicLoad")) {
        return try emit_result_inst(
            self,
            spirv.Opcode.AtomicLoad,
            try self.emitter.lower_type(result_ty),
            &.{ ptr_id, memory.scope_id, memory.semantics_id },
        );
    }

    if (call.args.len < 2) return error.InvalidIr;
    const value_id = try self.emit_value_expr(self.function.expr_args.items[call.args.start + 1]);

    if (std.mem.eql(u8, call.name, "atomicStore")) {
        try self.emitter.builder.append_function_inst(
            spirv.Opcode.AtomicStore,
            &.{ ptr_id, memory.scope_id, memory.semantics_id, value_id },
        );
        return 0;
    }

    const opcode: u16 = if (std.mem.eql(u8, call.name, "atomicAdd"))
        spirv.Opcode.AtomicIAdd
    else if (std.mem.eql(u8, call.name, "atomicSub"))
        spirv.Opcode.AtomicISub
    else if (std.mem.eql(u8, call.name, "atomicMax")) switch (self.scalar_kind(result_ty)) {
        .signed => spirv.Opcode.AtomicSMax,
        .unsigned => spirv.Opcode.AtomicUMax,
        else => return error.UnsupportedConstruct,
    } else if (std.mem.eql(u8, call.name, "atomicMin")) switch (self.scalar_kind(result_ty)) {
        .signed => spirv.Opcode.AtomicSMin,
        .unsigned => spirv.Opcode.AtomicUMin,
        else => return error.UnsupportedConstruct,
    } else if (std.mem.eql(u8, call.name, "atomicAnd"))
        spirv.Opcode.AtomicAnd
    else if (std.mem.eql(u8, call.name, "atomicOr"))
        spirv.Opcode.AtomicOr
    else if (std.mem.eql(u8, call.name, "atomicXor"))
        spirv.Opcode.AtomicXor
    else if (std.mem.eql(u8, call.name, "atomicExchange"))
        spirv.Opcode.AtomicExchange
    else
        return error.UnsupportedConstruct;

    return try emit_result_inst(
        self,
        opcode,
        try self.emitter.lower_type(result_ty),
        &.{ ptr_id, memory.scope_id, memory.semantics_id, value_id },
    );
}

fn emit_array_length(self: anytype, call: anytype, result_ty: ir.TypeId) !u32 {
    if (call.args.len != 1) return error.InvalidIr;
    const ref_expr_id = self.function.expr_args.items[call.args.start];
    const ref_expr = self.function.exprs.items[ref_expr_id];

    const struct_ptr_id, const member_index = switch (ref_expr.data) {
        .global_ref => |global_index| blk: {
            if (!self.emitter.global_buffer_wrapped[global_index]) return error.UnsupportedConstruct;
            const global = self.emitter.module.globals.items[global_index];
            switch (self.emitter.module.types.get(global.ty)) {
                .array => |arr| {
                    if (arr.len != null) return error.UnsupportedConstruct;
                },
                else => return error.UnsupportedConstruct,
            }
            break :blk .{ self.emitter.global_ids[global_index], @as(u32, 0) };
        },
        .member => |member| blk: {
            const base_expr = self.function.exprs.items[member.base];
            // The base type may be the struct type directly (from sema) or
            // wrapped in a .ref (pointer) type — handle both.
            const base_ty = switch (self.emitter.module.types.get(base_expr.ty)) {
                .ref => |ref_ty| ref_ty.elem,
                else => base_expr.ty,
            };
            switch (self.emitter.module.types.get(base_ty)) {
                .struct_ => {},
                else => return error.UnsupportedConstruct,
            }
            break :blk .{ try self.emit_ref_expr(member.base), member.field_index };
        },
        else => return error.UnsupportedConstruct,
    };

    return try emit_result_inst(
        self,
        spirv.Opcode.ArrayLength,
        try self.emitter.lower_type(result_ty),
        &.{ struct_ptr_id, member_index },
    );
}

fn emit_dot(self: anytype, call: anytype, result_ty: ir.TypeId) !u32 {
    if (call.args.len != 2) return error.InvalidIr;

    const lhs_expr = self.function.expr_args.items[call.args.start];
    const rhs_expr = self.function.expr_args.items[call.args.start + 1];
    const lhs_ty = self.function.exprs.items[lhs_expr].ty;
    const rhs_ty = self.function.exprs.items[rhs_expr].ty;

    switch (self.emitter.module.types.get(lhs_ty)) {
        .vector => |lhs_vec| {
            const rhs_vec = switch (self.emitter.module.types.get(rhs_ty)) {
                .vector => |vec| vec,
                else => return error.UnsupportedConstruct,
            };
            if (lhs_vec.len != rhs_vec.len) return error.UnsupportedConstruct;
            if (lhs_vec.elem != rhs_vec.elem) return error.UnsupportedConstruct;
            switch (self.emitter.module.types.get(lhs_vec.elem)) {
                .scalar => |scalar| if (scalar != .f32 and scalar != .f16 and scalar != .abstract_float) return error.UnsupportedConstruct,
                else => return error.UnsupportedConstruct,
            }
        },
        else => return error.UnsupportedConstruct,
    }

    return try emit_result_inst(
        self,
        spirv.Opcode.Dot,
        try self.emitter.lower_type(result_ty),
        &.{
            try self.emit_value_expr(lhs_expr),
            try self.emit_value_expr(rhs_expr),
        },
    );
}

fn emit_bool_vector_reduce(self: anytype, call: anytype, result_ty: ir.TypeId, opcode: u16) !u32 {
    if (call.args.len != 1) return error.InvalidIr;
    return try emit_result_inst(
        self,
        opcode,
        try self.emitter.lower_type(result_ty),
        &.{try self.emit_value_expr(self.function.expr_args.items[call.args.start])},
    );
}

fn emit_count_leading_zeros(self: anytype, call: anytype, result_ty: ir.TypeId) !u32 {
    // CLZ(x) = select(31u - FindUMsb(x), 32u, x == 0u)
    if (call.args.len != 1) return error.InvalidIr;
    const result_type = try self.emitter.lower_type(result_ty);
    const val_id = try self.emit_value_expr(self.function.expr_args.items[call.args.start]);

    // FindUMsb(x)
    const import_id = try self.emitter.builder.glsl450_import_id();
    const msb_id = self.emitter.builder.reserve_id();
    {
        var ops = std.ArrayListUnmanaged(u32){};
        defer ops.deinit(self.emitter.alloc);
        try ops.append(self.emitter.alloc, result_type);
        try ops.append(self.emitter.alloc, msb_id);
        try ops.append(self.emitter.alloc, import_id);
        try ops.append(self.emitter.alloc, 42); // FindUMsb
        try ops.append(self.emitter.alloc, val_id);
        try self.emitter.builder.append_function_inst(spirv.Opcode.ExtInst, ops.items);
    }

    // 31u - FindUMsb(x)
    const const_31 = try self.emitter.builder.const_u32(31);
    const sub_id = try emit_result_inst(self, spirv.Opcode.ISub, result_type, &.{ const_31, msb_id });

    // x == 0u
    const const_0 = try self.emitter.builder.const_u32(0);
    const bool_type = try self.emitter.builder.type_bool();
    const is_zero = try emit_result_inst(self, spirv.Opcode.IEqual, bool_type, &.{ val_id, const_0 });

    // select(31u - msb, 32u, x == 0u)
    const const_32 = try self.emitter.builder.const_u32(32);
    return try emit_result_inst(self, spirv.Opcode.Select, result_type, &.{ is_zero, const_32, sub_id });
}

fn emit_count_trailing_zeros(self: anytype, call: anytype, result_ty: ir.TypeId) !u32 {
    // CTZ(x) = select(FindILsb(x), 32u, x == 0u)
    if (call.args.len != 1) return error.InvalidIr;
    const result_type = try self.emitter.lower_type(result_ty);
    const val_id = try self.emit_value_expr(self.function.expr_args.items[call.args.start]);

    // FindILsb(x)
    const import_id = try self.emitter.builder.glsl450_import_id();
    const lsb_id = self.emitter.builder.reserve_id();
    {
        var ops = std.ArrayListUnmanaged(u32){};
        defer ops.deinit(self.emitter.alloc);
        try ops.append(self.emitter.alloc, result_type);
        try ops.append(self.emitter.alloc, lsb_id);
        try ops.append(self.emitter.alloc, import_id);
        try ops.append(self.emitter.alloc, 73); // FindILsb
        try ops.append(self.emitter.alloc, val_id);
        try self.emitter.builder.append_function_inst(spirv.Opcode.ExtInst, ops.items);
    }

    // x == 0u
    const const_0 = try self.emitter.builder.const_u32(0);
    const bool_type = try self.emitter.builder.type_bool();
    const is_zero = try emit_result_inst(self, spirv.Opcode.IEqual, bool_type, &.{ val_id, const_0 });

    // select(lsb, 32u, x == 0u)
    const const_32 = try self.emitter.builder.const_u32(32);
    return try emit_result_inst(self, spirv.Opcode.Select, result_type, &.{ is_zero, const_32, lsb_id });
}

fn atomic_memory_operands(self: anytype, ref_expr_id: ir.ExprId) !AtomicMemoryOperands {
    const storage_class = try self.ref_storage_class(ref_expr_id);
    const scope = switch (storage_class) {
        spirv.StorageClass.Workgroup => spirv.Scope.Workgroup,
        spirv.StorageClass.StorageBuffer => spirv.Scope.Device,
        else => return error.UnsupportedConstruct,
    };
    const semantics = switch (storage_class) {
        spirv.StorageClass.Workgroup,
        spirv.StorageClass.StorageBuffer,
        => spirv.MemorySemantics.None,
        else => return error.UnsupportedConstruct,
    };
    return .{
        .scope_id = try self.emitter.builder.const_u32(scope),
        .semantics_id = try self.emitter.builder.const_u32(semantics),
    };
}
