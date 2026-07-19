const std = @import("std");
const wgsl = @import("doe").compiler.wgsl();
const host_plan = wgsl.emit_csl_host_plan;
const dense_gemv_host_plan = @import("csl_dense_gemv_host_plan.zig");

const CHUNK_SHAPE = host_plan.BindingShape{ .elements = "chunk_size" };
const HIDDEN_SHAPE = host_plan.BindingShape{ .elements = "hidden_size" };
const SSM_TOKEN_CHANNEL_SHAPE = host_plan.BindingShape{ .elements = "num_tokens * channels" };
const SSM_CHANNEL_KERNEL_SHAPE = host_plan.BindingShape{ .elements = "channels * kernel_size" };
const SSM_CHANNEL_SHAPE = host_plan.BindingShape{ .elements = "channels" };
const SSM_KEY_SHAPE = host_plan.BindingShape{ .elements = "key_dim" };
const SSM_VALUE_SHAPE = host_plan.BindingShape{ .elements = "value_dim" };
const SSM_VALUE_PER_PE_SHAPE = host_plan.BindingShape{ .elements = "value_dim_per_pe" };
const SSM_STATE_SHAPE = host_plan.BindingShape{ .elements = "value_dim * key_dim" };
const SSM_STATE_PER_PE_SHAPE = host_plan.BindingShape{ .elements = "value_dim_per_pe * key_dim" };
const SUMMA_A_SHAPE = host_plan.BindingShape{ .elements = "Mt * Kt" };
const SUMMA_B_SHAPE = host_plan.BindingShape{ .elements = "Kt * Nt" };
const SUMMA_C_SHAPE = host_plan.BindingShape{ .elements = "Mt * Nt" };
const Q4K_BLOCK_BYTES_TEXT: []const u8 = "144";
const PREFILL_Q4K_GEMV_ACTIVATION_SHAPE = host_plan.BindingShape{ .elements = "in_dim_per_pe" };
const PREFILL_Q4K_GEMV_WEIGHT_SHAPE = host_plan.BindingShape{ .elements = "out_dim_per_pe * num_blocks_per_row * " ++ Q4K_BLOCK_BYTES_TEXT };
const PREFILL_Q4K_GEMV_OUTPUT_SHAPE = host_plan.BindingShape{ .elements = "out_dim_per_pe" };

const RMSNORM_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "input", .access = "read", .elem_type = "f32", .binding_shape = HIDDEN_SHAPE, .per_pe_shape = HIDDEN_SHAPE },
    .{ .symbol = "weight", .access = "read", .elem_type = "f32", .binding_shape = HIDDEN_SHAPE, .per_pe_shape = HIDDEN_SHAPE, .weight_source = "runtime_weight_mapping" },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = HIDDEN_SHAPE, .per_pe_shape = HIDDEN_SHAPE },
};
const RESIDUAL_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "input", .access = "read", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
    .{ .symbol = "residual", .access = "read", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
};
const GELU_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "input", .access = "read", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
};
const GATED_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "gate", .access = "read", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
    .{ .symbol = "input", .access = "read", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = CHUNK_SHAPE, .per_pe_shape = CHUNK_SHAPE },
};
const L2_NORMALIZE_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "input", .access = "read", .elem_type = "f32", .binding_shape = HIDDEN_SHAPE, .per_pe_shape = HIDDEN_SHAPE },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = HIDDEN_SHAPE, .per_pe_shape = HIDDEN_SHAPE },
};
const CONV1D_DEPTHWISE_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "input", .access = "read", .elem_type = "f32", .binding_shape = SSM_TOKEN_CHANNEL_SHAPE, .per_pe_shape = SSM_TOKEN_CHANNEL_SHAPE },
    .{ .symbol = "weight", .access = "read", .elem_type = "f32", .binding_shape = SSM_CHANNEL_KERNEL_SHAPE, .per_pe_shape = SSM_CHANNEL_KERNEL_SHAPE, .weight_source = "runtime_weight_mapping" },
    .{ .symbol = "bias", .access = "read", .elem_type = "f32", .binding_shape = SSM_CHANNEL_SHAPE, .per_pe_shape = SSM_CHANNEL_SHAPE, .weight_source = "runtime_weight_mapping" },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = SSM_TOKEN_CHANNEL_SHAPE, .per_pe_shape = SSM_TOKEN_CHANNEL_SHAPE },
};
const LINEAR_ATTENTION_BINDINGS = [_]host_plan.BindingMetadata{
    .{ .symbol = "query", .access = "read", .elem_type = "f32", .binding_shape = SSM_VALUE_SHAPE, .per_pe_shape = SSM_VALUE_PER_PE_SHAPE },
    .{ .symbol = "key", .access = "read", .elem_type = "f32", .binding_shape = SSM_KEY_SHAPE, .per_pe_shape = SSM_KEY_SHAPE },
    .{ .symbol = "value", .access = "read", .elem_type = "f32", .binding_shape = SSM_KEY_SHAPE, .per_pe_shape = SSM_KEY_SHAPE },
    .{ .symbol = "gate", .access = "read", .elem_type = "f32", .binding_shape = SSM_VALUE_SHAPE, .per_pe_shape = SSM_VALUE_PER_PE_SHAPE },
    .{ .symbol = "linear_state", .access = "read_write", .elem_type = "f32", .binding_shape = SSM_STATE_SHAPE, .per_pe_shape = SSM_STATE_PER_PE_SHAPE },
    .{ .symbol = "output", .access = "read_write", .elem_type = "f32", .binding_shape = SSM_VALUE_SHAPE, .per_pe_shape = SSM_VALUE_PER_PE_SHAPE },
};
const TILED_BINDINGS = [_]host_plan.BindingMetadata{
    .{
        .symbol = "a",
        .access = "read",
        .elem_type = "f32",
        .binding_shape = SUMMA_A_SHAPE,
        .per_pe_shape = SUMMA_A_SHAPE,
        .staging_transform = .{ .kind = "logical_matrix_to_summa_tiles", .matrix_role = "a" },
    },
    .{
        .symbol = "b",
        .access = "read",
        .elem_type = "f32",
        .binding_shape = SUMMA_B_SHAPE,
        .per_pe_shape = SUMMA_B_SHAPE,
        .staging_transform = .{ .kind = "weight_matrix_to_summa_tiles", .matrix_role = "b" },
        .weight_source = "runtime_weight_mapping",
    },
    .{
        .symbol = "c",
        .access = "read_write",
        .elem_type = "f32",
        .binding_shape = SUMMA_C_SHAPE,
        .per_pe_shape = SUMMA_C_SHAPE,
        .detile_transform = .{ .kind = "summa_tiles_to_logical_matrix", .matrix_role = "c", .rows_from_input = "a" },
    },
};
const PREFILL_Q4K_GEMV_BINDINGS = [_]host_plan.BindingMetadata{
    .{
        .symbol = "activation",
        .access = "read",
        .elem_type = "f16",
        .binding_shape = PREFILL_Q4K_GEMV_ACTIVATION_SHAPE,
        .per_pe_shape = PREFILL_Q4K_GEMV_ACTIVATION_SHAPE,
        .staging_transform = .{ .kind = "logical_matrix_to_prefill_q4k_gemv_activation_shards" },
    },
    .{
        .symbol = "weight",
        .access = "read",
        .elem_type = "u8",
        .binding_shape = PREFILL_Q4K_GEMV_WEIGHT_SHAPE,
        .per_pe_shape = PREFILL_Q4K_GEMV_WEIGHT_SHAPE,
        .staging_transform = .{ .kind = "q4km_rowwise_to_prefill_q4k_gemv_weight_tiles" },
        .weight_source = "runtime_weight_mapping",
    },
    .{
        .symbol = "output",
        .access = "read_write",
        .elem_type = "f16",
        .binding_shape = PREFILL_Q4K_GEMV_OUTPUT_SHAPE,
        .per_pe_shape = PREFILL_Q4K_GEMV_OUTPUT_SHAPE,
        .detile_transform = .{ .kind = "prefill_q4k_gemv_row_tiles_to_logical_matrix" },
    },
};

pub fn metadataForPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    target_phase: []const u8,
    activation_elem: wgsl.ir.ScalarType,
) !?host_plan.CompileTargetMetadata {
    if (std.mem.eql(u8, pattern, "rms_norm") or std.mem.eql(u8, pattern, "reduction")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &RMSNORM_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "residual")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &RESIDUAL_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "gelu")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &GELU_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "gelu_gated") or
        std.mem.eql(u8, pattern, "silu_gated") or
        std.mem.eql(u8, pattern, "sigmoid_gated"))
    {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &GATED_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "l2_normalize")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &L2_NORMALIZE_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "conv1d_depthwise")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &CONV1D_DEPTHWISE_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "linear_attention")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &LINEAR_ATTENTION_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "tiled_matmul")) {
        return .{ .target_phase = target_phase, .bindings = try laneBindings(allocator, &TILED_BINDINGS, activation_elem) };
    }
    if (std.mem.eql(u8, pattern, "prefill_q4k_gemv")) {
        return .{ .target_phase = target_phase, .bindings = &PREFILL_Q4K_GEMV_BINDINGS };
    }
    if (std.mem.eql(u8, pattern, "dense_gemv")) {
        return .{ .target_phase = target_phase, .bindings = &dense_gemv_host_plan.BINDINGS };
    }
    return null;
}

fn laneBindings(
    allocator: std.mem.Allocator,
    bindings: []const host_plan.BindingMetadata,
    activation_elem: wgsl.ir.ScalarType,
) ![]const host_plan.BindingMetadata {
    if (activation_elem == .f32) return bindings;
    if (activation_elem != .f16) return error.InvalidArgument;
    const routed = try allocator.alloc(host_plan.BindingMetadata, bindings.len);
    for (bindings, 0..) |binding, idx| {
        routed[idx] = binding;
        if (std.mem.eql(u8, binding.elem_type, "f32")) {
            routed[idx].elem_type = "f16";
        }
    }
    return routed;
}
