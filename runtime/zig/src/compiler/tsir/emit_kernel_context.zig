//! One-way state and primitive contract shared by the TSIR kernel-body router
//! and specialized body emitters.

const std = @import("std");
const schema = @import("schema.zig");
const dtype_routing = @import("emit_dtype_routing.zig");

pub const EmitError = std.mem.Allocator.Error || error{
    InvalidBodyContract,
    MissingBindingRole,
    UnsupportedKernelBody,
    UnsupportedScalarKind,
};

pub const KvCachePeStrategy = enum { full_per_pe, slot_sharded };
pub const AttentionPeStrategy = enum { full_per_pe, kv_axis_sharded };
pub const AttentionPeIdSource = enum { tile_param, layout_coordinates };

pub const Config = struct {
    var_prefix: []const u8 = "tsir_",
    chunk_size_default: ?u32 = null,
    hidden_size_default: ?u32 = null,
    gemma_one_plus_weight_offset: bool = false,
    head_dim_default: ?u32 = null,
    max_seq_len_default: ?u32 = null,
    read_len_default: ?u32 = null,
    kv_cache_pe_strategy: KvCachePeStrategy = .full_per_pe,
    kv_slots_per_pe_default: ?u32 = null,
    attention_pe_strategy: AttentionPeStrategy = .full_per_pe,
    attention_pe_id_source: AttentionPeIdSource = .tile_param,
    attention_slots_per_pe_default: ?u32 = null,
};

pub const default_config: Config = .{};
pub const cslElemName = dtype_routing.cslElemName;

pub fn requireSupportedComputeElem(elem: schema.ScalarKind) EmitError!void {
    if (!dtype_routing.isSupportedComputeElem(elem)) return error.UnsupportedScalarKind;
}

pub fn bindingForRole(func: schema.SemanticFunction, role: schema.SemanticBindingRole) EmitError!schema.BufferBinding {
    for (func.body.binding_roles) |binding_role| {
        if (binding_role.role == role) return bindingForIndex(func, binding_role.binding_index);
    }
    return error.MissingBindingRole;
}

pub fn bindingForIndex(func: schema.SemanticFunction, binding_index: u32) EmitError!schema.BufferBinding {
    if (binding_index >= func.bindings.len) return error.InvalidBodyContract;
    return func.bindings[@intCast(binding_index)];
}

pub fn requireElem(binding: schema.BufferBinding, elem: schema.ScalarKind) EmitError!void {
    if (binding.elem != elem) return error.UnsupportedScalarKind;
}

pub fn writeCslSqrtNr(writer: anytype, elem: schema.ScalarKind) !void {
    const ty = cslElemName(elem);
    if (elem == .f32) {
        try writer.writeAll("fn sqrt_nr(x: f32) f32 {\n");
        try writer.writeAll("    const y0: f32 = math.sqrt(x);\n");
        try writer.writeAll("    return 0.5 * (y0 + x / y0);\n");
        try writer.writeAll("}\n\n");
        return;
    }
    try writer.print("fn sqrt_nr(x: {s}) {s} {{\n", .{ ty, ty });
    try writer.writeAll("    const x32: f32 = @as(f32, x);\n");
    try writer.writeAll("    const y0: f32 = math.sqrt(x32);\n");
    try writer.writeAll("    const refined: f32 = 0.5 * (y0 + x32 / y0);\n");
    try writer.print("    return @as({s}, refined);\n", .{ty});
    try writer.writeAll("}\n\n");
}

pub fn writeCslBufferArray(writer: anytype, prefix: []const u8, name: []const u8, extent: []const u8, elem_type: []const u8) !void {
    try writer.print(
        "var {s}{s}: [{s}]{s} = @zeros([{s}]{s});\n",
        .{ prefix, name, extent, elem_type, extent, elem_type },
    );
}

pub fn writeCslBufferPointer(writer: anytype, prefix: []const u8, name: []const u8, elem_type: []const u8) !void {
    try writer.print(
        "var {s}{s}_ptr: [*]{s} = &{s}{s};\n",
        .{ prefix, name, elem_type, prefix, name },
    );
}

pub fn writeCslExportSymbol(writer: anytype, prefix: []const u8, name: []const u8) !void {
    try writer.print(
        "    @export_symbol({s}{s}_ptr, \"{s}\");\n",
        .{ prefix, name, name },
    );
}
