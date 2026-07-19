const doe = @import("doe");
const wgsl = doe.compiler.wgsl();
const csl_spec = doe.compiler.wgsl_csl.spec();
const host_plan = wgsl.emit_csl_host_plan;

pub const TARGET_IN_PER_PE: u32 = 32;
pub const OUT_SHARD_PES: u32 = csl_spec.MAX_RECT_DIM;

const ACTIVATION_SHAPE = host_plan.BindingShape{ .elements = "in_dim_per_pe" };
const WEIGHT_SHAPE = host_plan.BindingShape{ .elements = "out_dim_per_pe * in_dim_per_pe" };
const OUTPUT_SHAPE = host_plan.BindingShape{ .elements = "out_dim_per_pe" };

pub const BINDINGS = [_]host_plan.BindingMetadata{
    .{
        .symbol = "activation",
        .access = "read",
        .elem_type = "f16",
        .binding_shape = ACTIVATION_SHAPE,
        .per_pe_shape = ACTIVATION_SHAPE,
        .staging_transform = .{ .kind = "logical_vector_to_dense_gemv_activation_shards" },
    },
    .{
        .symbol = "weight",
        .access = "read",
        .elem_type = "f16",
        .binding_shape = WEIGHT_SHAPE,
        .per_pe_shape = WEIGHT_SHAPE,
        .staging_transform = .{ .kind = "tied_f16_embedding_to_dense_gemv_shards" },
        .weight_source = "runtime_weight_mapping",
    },
    .{
        .symbol = "output",
        .access = "read_write",
        .elem_type = "f32",
        .binding_shape = OUTPUT_SHAPE,
        .per_pe_shape = OUTPUT_SHAPE,
        .detile_transform = .{ .kind = "dense_gemv_row_shards_to_logits" },
    },
};

pub fn width(hidden_dim: u32) u32 {
    return @min(
        @as(u32, csl_spec.MAX_RECT_DIM),
        @max(@as(u32, 1), ceilDivU32(hidden_dim, TARGET_IN_PER_PE)),
    );
}

pub fn height(vocab_size: u32) u32 {
    return @min(OUT_SHARD_PES, vocab_size);
}

pub fn inDimPerPe(hidden_dim: u32) u32 {
    return evenCeilDivU32(hidden_dim, width(hidden_dim));
}

fn ceilDivU32(lhs: u32, rhs: u32) u32 {
    return (lhs + rhs - 1) / rhs;
}

fn evenCeilDivU32(lhs: u32, rhs: u32) u32 {
    const value = ceilDivU32(lhs, rhs);
    return if (value % 2 == 0) value else value + 1;
}
