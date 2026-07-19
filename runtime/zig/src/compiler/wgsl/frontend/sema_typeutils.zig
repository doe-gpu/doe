const ast_mod = @import("ast.zig");
const ir = @import("../ir/ir.zig");
const sema_types = @import("sema_types.zig");
const sema_helpers = @import("sema_helpers.zig");

const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NULL_NODE = ast_mod.NULL_NODE;
const SemanticModule = sema_types.SemanticModule;
const AnalyzeError = sema_types.AnalyzeError;

const int_literal_suffix = sema_helpers.int_literal_suffix;
const float_literal_suffix = sema_helpers.float_literal_suffix;
const parse_wgsl_int_literal = sema_helpers.parse_wgsl_int_literal;
const parse_wgsl_float_literal = sema_helpers.parse_wgsl_float_literal;

pub fn analyze_int_literal(module: *SemanticModule, node: Node) AnalyzeError!ir.TypeId {
    const literal = module.tree.tokenSlice(node.main_token);
    _ = parse_wgsl_int_literal(u64, literal) catch return error.InvalidWgsl;
    return switch (int_literal_suffix(literal)) {
        .i => module.i32_type,
        .u => module.u32_type,
        .none => module.abstract_int_type,
    };
}

pub fn analyze_float_literal(module: *SemanticModule, node: Node) AnalyzeError!ir.TypeId {
    const literal = module.tree.tokenSlice(node.main_token);
    _ = parse_wgsl_float_literal(literal) catch return error.InvalidWgsl;
    return switch (float_literal_suffix(literal)) {
        .f => module.f32_type,
        .h => module.f16_type,
        .none => module.abstract_float_type,
    };
}

pub fn bitcast_types_compatible(module: *SemanticModule, target_ty: ir.TypeId, source_ty: ir.TypeId) bool {
    const target_bits = bitcast_type_bits(module, target_ty) orelse return false;
    const source_bits = bitcast_type_bits(module, source_ty) orelse return false;
    return target_bits == source_bits;
}

pub fn bitcast_type_bits(module: *SemanticModule, ty: ir.TypeId) ?u32 {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| switch (scalar) {
            .i32, .u32, .f32 => 32,
            .f16 => 16,
            else => null,
        },
        .vector => |vec| blk: {
            const elem_bits = bitcast_type_bits(module, vec.elem) orelse return null;
            break :blk elem_bits * vec.len;
        },
        else => null,
    };
}

pub fn is_handle_type(ty: ir.Type) bool {
    return switch (ty) {
        .sampler, .sampler_comparison, .texture_1d, .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d, .storage_texture_2d => true,
        else => false,
    };
}

pub fn captureFailureNode(tree: *const Ast, node_idx: u32, last_failure_context: anytype) void {
    if (node_idx == NULL_NODE or node_idx >= tree.nodes.items.len) return;
    const node = tree.nodes.items[node_idx];
    last_failure_context.* = .{
        .node_idx = node_idx,
        .token_idx = if (node.main_token < tree.tokens.items.len) node.main_token else null,
    };
}

pub fn materialize_inferred_local_type(module: *SemanticModule, ty: ir.TypeId) ir.TypeId {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| switch (scalar) {
            .abstract_int => module.i32_type,
            .abstract_float => module.f32_type,
            else => ty,
        },
        else => ty,
    };
}
