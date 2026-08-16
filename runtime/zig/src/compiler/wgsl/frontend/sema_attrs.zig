const std = @import("std");
const ast_mod = @import("ast.zig");
const ir = @import("../ir/ir.zig");
const sema_helpers = @import("sema_helpers.zig");
const sema_type_syntax = @import("sema_type_syntax.zig");
const sema_types = @import("sema_types.zig");

const Ast = ast_mod.Ast;
const AnalyzeError = sema_types.AnalyzeError;

pub const parse_access = sema_type_syntax.parseAccess;
pub const parse_address_space = sema_type_syntax.parseAddressSpace;

pub fn parse_stage(self: anytype, attrs_start: u32, attrs_len: u32) !?ir.ShaderStage {
    var stage: ?ir.ShaderStage = null;
    for (self.module.tree.extra_data.items[attrs_start .. attrs_start + attrs_len]) |attr_idx| {
        const attr = self.module.tree.nodes.items[attr_idx];
        const name = self.module.tree.tokenSlice(attr.data.lhs);
        if (std.mem.eql(u8, name, "compute")) stage = .compute;
        if (std.mem.eql(u8, name, "vertex")) stage = .vertex;
        if (std.mem.eql(u8, name, "fragment")) stage = .fragment;
    }
    return stage;
}

pub fn parse_workgroup_size(self: anytype, attrs_start: u32, attrs_len: u32) ![3]u32 {
    var result: [3]u32 = .{ 1, 1, 1 };
    for (self.module.tree.extra_data.items[attrs_start .. attrs_start + attrs_len]) |attr_idx| {
        const attr = self.module.tree.nodes.items[attr_idx];
        if (!std.mem.eql(u8, self.module.tree.tokenSlice(attr.data.lhs), "workgroup_size")) continue;
        const span = decode_packed_span(attr.data.rhs);
        var i: usize = 0;
        while (i < span.len and i < result.len) : (i += 1) {
            result[i] = try resolve_attr_u32_const(self, self.module.tree.extra_data.items[span.start + i], 0);
        }
    }
    return result;
}

const MAX_ATTR_CONST_DEPTH: u8 = 32;

fn resolve_attr_u32_const(self: anytype, node_idx: u32, depth: u8) AnalyzeError!u32 {
    if (depth >= MAX_ATTR_CONST_DEPTH) return error.InvalidAttribute;
    const tree = self.module.tree;
    const node = tree.nodes.items[node_idx];
    return switch (node.tag) {
        .int_literal => sema_helpers.parse_wgsl_int_literal(u32, tree.tokenSlice(node.main_token)) catch error.InvalidAttribute,
        .ident_expr => resolve_named_attr_u32_const(self, tree.tokenSlice(node.main_token), depth + 1),
        .binary_expr => resolve_attr_u32_binary(self, node, depth + 1),
        else => error.InvalidAttribute,
    };
}

fn resolve_named_attr_u32_const(self: anytype, name: []const u8, depth: u8) AnalyzeError!u32 {
    const global_index = self.module.global_map.get(name) orelse return error.InvalidAttribute;
    const global_info = self.module.globals.items[global_index];
    if (global_info.class != .const_ and global_info.class != .override_) return error.InvalidAttribute;
    if (global_info.class == .override_) {
        if (resolve_override_u32(self, global_info) catch return error.InvalidAttribute) |value| return value;
    }
    const global_node = self.module.tree.nodes.items[global_info.node_idx];
    const init_node = switch (global_node.tag) {
        .const_decl => global_node.data.rhs,
        .override_decl => self.module.tree.extra_data.items[global_node.data.lhs + 2],
        else => ast_mod.NULL_NODE,
    };
    if (init_node == ast_mod.NULL_NODE) return error.InvalidAttribute;
    return resolve_attr_u32_const(self, init_node, depth);
}

fn resolve_override_u32(self: anytype, global_info: sema_types.GlobalInfo) AnalyzeError!?u32 {
    for (self.overrides) |entry| {
        const numeric_id = std.fmt.parseInt(u32, entry.key, 10) catch null;
        const matches = if (numeric_id) |id|
            global_info.override_id != null and global_info.override_id.? == id
        else
            std.mem.eql(u8, global_info.name, entry.key);
        if (!matches) continue;
        if (!std.math.isFinite(entry.value) or
            entry.value < 1.0 or
            entry.value > @as(f64, @floatFromInt(std.math.maxInt(u32))) or
            @floor(entry.value) != entry.value)
        {
            return error.InvalidAttribute;
        }
        return @as(u32, @intFromFloat(entry.value));
    }
    return null;
}

fn resolve_attr_u32_binary(self: anytype, node: ast_mod.Node, depth: u8) AnalyzeError!u32 {
    const lhs = try resolve_attr_u32_const(self, node.data.lhs, depth);
    const rhs = try resolve_attr_u32_const(self, node.data.rhs, depth);
    const op = self.module.tree.tokens.items[node.main_token].tag;
    return switch (op) {
        .@"+" => std.math.add(u32, lhs, rhs) catch error.InvalidAttribute,
        .@"-" => std.math.sub(u32, lhs, rhs) catch error.InvalidAttribute,
        .@"*" => std.math.mul(u32, lhs, rhs) catch error.InvalidAttribute,
        .@"/" => if (rhs == 0) error.InvalidAttribute else @divTrunc(lhs, rhs),
        .@"%" => if (rhs == 0) error.InvalidAttribute else @mod(lhs, rhs),
        .shift_left => if (rhs >= @bitSizeOf(u32)) error.InvalidAttribute else lhs << @as(std.math.Log2Int(u32), @intCast(rhs)),
        .shift_right => if (rhs >= @bitSizeOf(u32)) error.InvalidAttribute else lhs >> @as(std.math.Log2Int(u32), @intCast(rhs)),
        .@"&" => lhs & rhs,
        .@"|" => lhs | rhs,
        .@"^" => lhs ^ rhs,
        else => error.InvalidAttribute,
    };
}

pub fn parse_binding(self: anytype, attrs_start: u32, attrs_len: u32) !?ir.BindingPoint {
    var group: ?u32 = null;
    var binding: ?u32 = null;
    for (self.module.tree.extra_data.items[attrs_start .. attrs_start + attrs_len]) |attr_idx| {
        const attr = self.module.tree.nodes.items[attr_idx];
        const name = self.module.tree.tokenSlice(attr.data.lhs);
        const value = try parse_single_int_attr(self.module.tree, attr_idx);
        if (std.mem.eql(u8, name, "group")) group = value;
        if (std.mem.eql(u8, name, "binding")) binding = value;
    }
    if (group != null and binding != null) return .{ .group = group.?, .binding = binding.? };
    return null;
}

pub fn parse_io_attr(self: anytype, attrs_start: u32, attrs_len: u32) !?ir.IoAttr {
    if (attrs_len == 0) return null;
    var result = ir.IoAttr{};
    var seen = false;
    for (self.module.tree.extra_data.items[attrs_start .. attrs_start + attrs_len]) |attr_idx| {
        const attr = self.module.tree.nodes.items[attr_idx];
        const name = self.module.tree.tokenSlice(attr.data.lhs);
        if (std.mem.eql(u8, name, "builtin")) {
            result.builtin = try parse_builtin_attr(self.module.tree, attr_idx);
            seen = true;
        } else if (std.mem.eql(u8, name, "location")) {
            result.location = try parse_single_int_attr(self.module.tree, attr_idx);
            seen = true;
        } else if (std.mem.eql(u8, name, "blend_src")) {
            result.blend_src = try parse_single_int_attr(self.module.tree, attr_idx);
            seen = true;
        } else if (std.mem.eql(u8, name, "flat")) {
            result.interpolation = .flat;
            seen = true;
        } else if (std.mem.eql(u8, name, "interpolate")) {
            const interp_result = try parse_interpolation_attr(self.module.tree, attr_idx);
            result.interpolation = interp_result.interpolation;
            result.sampling = interp_result.sampling;
            seen = true;
        } else if (std.mem.eql(u8, name, "invariant")) {
            result.invariant = true;
            seen = true;
        }
    }
    return if (seen) result else null;
}

pub fn infer_builtin_call(self: anytype, name: []const u8, arg_types: []const ir.TypeId) !ir.TypeId {
    if (std.mem.eql(u8, name, "workgroupBarrier") or std.mem.eql(u8, name, "storageBarrier") or std.mem.eql(u8, name, "textureBarrier")) return self.module.void_type;
    if (std.mem.eql(u8, name, "arrayLength")) return self.module.u32_type;
    if (std.mem.eql(u8, name, "textureStore")) return self.module.void_type;
    if (std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "all")) {
        if (arg_types.len != 1) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .vector => |vec| if (vec.elem == self.module.bool_type) self.module.bool_type else error.UnsupportedBuiltin,
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "textureSample") or std.mem.eql(u8, name, "textureSampleBaseClampToEdge") or std.mem.eql(u8, name, "textureSampleLevel") or std.mem.eql(u8, name, "textureSampleGrad") or std.mem.eql(u8, name, "textureSampleOffset") or std.mem.eql(u8, name, "textureSampleLevelOffset")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .texture_1d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_2d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_3d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_cube => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_2d_array => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "textureSampleCompare") or std.mem.eql(u8, name, "textureSampleCompareLevel")) {
        return try self.module.types.intern(.{ .scalar = .f32 });
    }
    if (std.mem.eql(u8, name, "textureGather")) {
        if (arg_types.len < 2) return error.UnsupportedBuiltin;
        // textureGather(component, texture, sampler, coords) — first arg is component u32
        return switch (self.module.types.get(arg_types[1])) {
            .texture_1d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_2d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_cube => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_2d_array => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "textureGatherCompare")) {
        return try self.module.types.intern(.{ .vector = .{ .elem = try self.module.types.intern(.{ .scalar = .f32 }), .len = 4 } });
    }
    if (std.mem.eql(u8, name, "textureDimensions")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .texture_1d => try self.module.types.intern(.{ .scalar = .u32 }),
            .texture_2d, .texture_2d_array, .texture_depth_2d, .texture_multisampled_2d, .storage_texture_2d => blk: {
                const u32_ty = try self.module.types.intern(.{ .scalar = .u32 });
                break :blk try self.module.types.intern(.{ .vector = .{ .elem = u32_ty, .len = 2 } });
            },
            .texture_3d, .texture_cube, .texture_depth_cube => blk: {
                const u32_ty = try self.module.types.intern(.{ .scalar = .u32 });
                break :blk try self.module.types.intern(.{ .vector = .{ .elem = u32_ty, .len = 3 } });
            },
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "dot")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        const first = self.module.types.get(arg_types[0]);
        return switch (first) {
            .vector => |vec| vec.elem,
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "distance")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .vector => |vec| vec.elem,
            .scalar => arg_types[0],
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "textureLoad")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        const first = self.module.types.get(arg_types[0]);
        return switch (first) {
            .texture_1d, .texture_2d, .texture_3d, .texture_2d_array => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_multisampled_2d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .storage_texture_2d => |storage| {
                const elem_scalar = storage_format_scalar(storage.format);
                const elem_ty = try self.module.types.intern(.{ .scalar = elem_scalar });
                return try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = 4 } });
            },
            else => error.UnsupportedBuiltin,
        };
    }
    if (std.mem.eql(u8, name, "atomicLoad") or std.mem.eql(u8, name, "atomicStore") or std.mem.eql(u8, name, "atomicAdd") or std.mem.eql(u8, name, "atomicSub") or std.mem.eql(u8, name, "atomicMax") or std.mem.eql(u8, name, "atomicMin") or std.mem.eql(u8, name, "atomicAnd") or std.mem.eql(u8, name, "atomicOr") or std.mem.eql(u8, name, "atomicXor") or std.mem.eql(u8, name, "atomicExchange") or std.mem.eql(u8, name, "atomicCompareExchangeWeak")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        const target_ty = switch (self.module.types.get(arg_types[0])) {
            .ref => |ref_ty| ref_ty.elem,
            else => arg_types[0],
        };
        const value_ty = switch (self.module.types.get(target_ty)) {
            .atomic => |inner| inner,
            else => target_ty,
        };
        if (std.mem.eql(u8, name, "atomicStore")) return self.module.void_type;
        if (std.mem.eql(u8, name, "atomicCompareExchangeWeak")) {
            return try atomic_compare_exchange_result_type(self, value_ty);
        }
        return value_ty;
    }
    if (is_passthrough_math(name)) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return arg_types[0];
    }
    // Subgroup reduction/scan built-ins return the same type as their input.
    if (is_subgroup_value_op(name)) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return arg_types[0];
    }
    // subgroupBallot returns vec4<u32> (128-bit ballot result).
    if (std.mem.eql(u8, name, "subgroupBallot")) {
        const u32_ty = try self.module.types.intern(.{ .scalar = .u32 });
        return try self.module.types.intern(.{ .vector = .{ .elem = u32_ty, .len = 4 } });
    }
    // subgroupAll / subgroupAny / subgroupElect return bool.
    if (std.mem.eql(u8, name, "subgroupAll") or std.mem.eql(u8, name, "subgroupAny") or std.mem.eql(u8, name, "subgroupElect")) {
        return try self.module.types.intern(.{ .scalar = .bool });
    }
    // Pack builtins return u32.
    if (is_pack_builtin(name)) {
        return try self.module.types.intern(.{ .scalar = .u32 });
    }
    // Unpack builtins return vec2f or vec4f.
    if (is_unpack_2_builtin(name)) {
        const f32_ty = try self.module.types.intern(.{ .scalar = .f32 });
        return try self.module.types.intern(.{ .vector = .{ .elem = f32_ty, .len = 2 } });
    }
    if (is_unpack_4_builtin(name)) {
        const f32_ty = try self.module.types.intern(.{ .scalar = .f32 });
        return try self.module.types.intern(.{ .vector = .{ .elem = f32_ty, .len = 4 } });
    }
    // transpose(mat<C,R>) returns mat<R,C> (dimensions swapped).
    if (std.mem.eql(u8, name, "transpose")) {
        if (arg_types.len != 1) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .matrix => |mat| try self.module.types.intern(.{ .matrix = .{ .elem = mat.elem, .columns = mat.rows, .rows = mat.columns } }),
            else => error.UnsupportedBuiltin,
        };
    }
    // determinant(mat<N,N>) returns the scalar element type.
    if (std.mem.eql(u8, name, "determinant")) {
        if (arg_types.len != 1) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .matrix => |mat| mat.elem,
            else => error.UnsupportedBuiltin,
        };
    }
    // textureNumLevels / textureNumLayers / textureNumSamples return u32.
    if (std.mem.eql(u8, name, "textureNumLevels") or std.mem.eql(u8, name, "textureNumLayers") or std.mem.eql(u8, name, "textureNumSamples")) {
        return self.module.u32_type;
    }
    if (std.mem.eql(u8, name, "textureSampleBias")) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return switch (self.module.types.get(arg_types[0])) {
            .texture_1d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_2d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_3d => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_cube => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            .texture_2d_array => |sample_ty| try self.module.types.intern(.{ .vector = .{ .elem = sample_ty, .len = 4 } }),
            else => error.UnsupportedBuiltin,
        };
    }
    // Derivative builtins return the same type as their input.
    if (is_derivative_builtin(name)) {
        if (arg_types.len == 0) return error.UnsupportedBuiltin;
        return arg_types[0];
    }
    // quantizeToF16 returns f32 (the input rounded to f16 precision).
    if (std.mem.eql(u8, name, "quantizeToF16")) {
        return try self.module.types.intern(.{ .scalar = .f32 });
    }
    return error.UnsupportedBuiltin;
}

fn atomic_compare_exchange_result_type(self: anytype, value_ty: ir.TypeId) !ir.TypeId {
    const suffix: []const u8 = switch (self.module.types.get(value_ty)) {
        .scalar => |scalar| switch (scalar) {
            .i32 => "i32",
            .u32 => "u32",
            else => return error.UnsupportedBuiltin,
        },
        else => return error.UnsupportedBuiltin,
    };
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "__doe_atomic_compare_exchange_result_{s}", .{suffix}) catch return error.UnsupportedBuiltin;
    for (self.module.structs.items) |struct_info| {
        if (std.mem.eql(u8, struct_info.name, name)) return struct_info.ty;
    }

    const allocator = self.module.allocator;
    const name_copy = try ir.dup_string(allocator, name);
    var fields = std.ArrayListUnmanaged(sema_types.StructFieldInfo){};
    var committed = false;
    defer if (!committed) {
        allocator.free(name_copy);
        for (fields.items) |field| allocator.free(field.name);
        fields.deinit(allocator);
    };
    try fields.append(allocator, .{
        .name = try ir.dup_string(allocator, "old_value"),
        .ty = value_ty,
    });
    try fields.append(allocator, .{
        .name = try ir.dup_string(allocator, "exchanged"),
        .ty = self.module.bool_type,
    });

    const struct_id: ir.StructId = @intCast(self.module.structs.items.len);
    const result_ty = try self.module.types.intern(.{ .struct_ = struct_id });
    try self.module.structs.append(allocator, .{
        .name = name_copy,
        .struct_id = struct_id,
        .ty = result_ty,
        .fields = fields,
    });
    committed = true;
    return result_ty;
}

fn is_subgroup_value_op(name: []const u8) bool {
    const ops = [_][]const u8{
        "subgroupAdd",          "subgroupMin",       "subgroupMax",            "subgroupMul",
        "subgroupAnd",          "subgroupOr",        "subgroupXor",            "subgroupExclusiveAdd",
        "subgroupInclusiveAdd", "subgroupShuffle",   "subgroupShuffleDown",    "subgroupShuffleUp",
        "subgroupShuffleXor",   "subgroupBroadcast", "subgroupBroadcastFirst",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

/// Math/comparison builtins that return the same type as their first argument.
fn is_passthrough_math(name: []const u8) bool {
    const ops = [_][]const u8{
        "min",               "max",                "clamp",           "select",           "abs",
        "sqrt",              "sin",                "cos",             "normalize",        "length",
        "distance",          "fract",              "mix",             "inverseSqrt",      "degrees",
        "radians",           "atan2",              "ldexp",           "fma",              "smoothstep",
        "sign",              "floor",              "ceil",            "round",            "trunc",
        "exp",               "exp2",               "log",             "log2",             "pow",
        "step",              "tan",                "asin",            "acos",             "atan",
        "sinh",              "cosh",               "tanh",            "saturate",         "dot",
        "cross",             "faceForward",        "reflect",         "refract",          "modf",
        "frexp",             "countOneBits",       "reverseBits",     "extractBits",      "insertBits",
        "countLeadingZeros", "countTrailingZeros", "firstLeadingBit", "firstTrailingBit",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn is_pack_builtin(name: []const u8) bool {
    const ops = [_][]const u8{ "pack2x16float", "pack4x8unorm", "pack4x8snorm", "pack2x16snorm", "pack2x16unorm" };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn is_unpack_2_builtin(name: []const u8) bool {
    const ops = [_][]const u8{ "unpack2x16float", "unpack2x16snorm", "unpack2x16unorm" };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn is_unpack_4_builtin(name: []const u8) bool {
    const ops = [_][]const u8{ "unpack4x8unorm", "unpack4x8snorm" };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn is_derivative_builtin(name: []const u8) bool {
    const ops = [_][]const u8{
        "dpdx",   "dpdxCoarse",   "dpdxFine",
        "dpdy",   "dpdyCoarse",   "dpdyFine",
        "fwidth", "fwidthCoarse", "fwidthFine",
    };
    for (ops) |op| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

fn storage_format_scalar(format: ir.TextureFormat) ir.ScalarType {
    return switch (format) {
        .rgba8unorm, .rgba8snorm, .rgba16float, .r32float, .rg32float, .rgba32float => .f32,
        .rgba8uint, .rgba16uint, .r32uint, .rg32uint, .rgba32uint => .u32,
        .rgba8sint, .rgba16sint, .r32sint, .rg32sint, .rgba32sint => .i32,
    };
}

pub fn parse_override_id(self: anytype, attrs_start: u32, attrs_len: u32) !?u32 {
    for (self.module.tree.extra_data.items[attrs_start .. attrs_start + attrs_len]) |attr_idx| {
        const attr = self.module.tree.nodes.items[attr_idx];
        const name = self.module.tree.tokenSlice(attr.data.lhs);
        if (std.mem.eql(u8, name, "id")) {
            return try parse_single_int_attr(self.module.tree, attr_idx);
        }
    }
    return null;
}

fn decode_packed_span(raw: u32) struct { start: u32, len: u32 } {
    return .{ .start = raw & 0xFFFF, .len = raw >> 16 };
}

fn parse_single_int_attr(tree: *const Ast, attr_idx: u32) !u32 {
    const attr = tree.nodes.items[attr_idx];
    const span = decode_packed_span(attr.data.rhs);
    if (span.len == 0) return error.InvalidAttribute;
    const arg = tree.nodes.items[tree.extra_data.items[span.start]];
    if (arg.tag != .int_literal) return error.InvalidAttribute;
    return try sema_helpers.parse_wgsl_int_literal(u32, tree.tokenSlice(arg.main_token));
}

const InterpolationResult = struct {
    interpolation: ir.Interpolation,
    sampling: ?ir.InterpolationSampling,
};

fn parse_interpolation_attr(tree: *const Ast, attr_idx: u32) !InterpolationResult {
    const attr = tree.nodes.items[attr_idx];
    const span = decode_packed_span(attr.data.rhs);
    if (span.len == 0) return error.InvalidAttribute;
    const arg = tree.nodes.items[tree.extra_data.items[span.start]];
    if (arg.tag != .ident_expr) return error.InvalidAttribute;
    const name = tree.tokenSlice(arg.main_token);
    const interp: ir.Interpolation = if (std.mem.eql(u8, name, "flat"))
        .flat
    else if (std.mem.eql(u8, name, "linear"))
        .linear
    else if (std.mem.eql(u8, name, "perspective"))
        .perspective
    else
        return error.InvalidAttribute;

    var sampling: ?ir.InterpolationSampling = null;
    if (span.len >= 2) {
        const sampling_arg = tree.nodes.items[tree.extra_data.items[span.start + 1]];
        if (sampling_arg.tag != .ident_expr) return error.InvalidAttribute;
        const sampling_name = tree.tokenSlice(sampling_arg.main_token);
        if (std.mem.eql(u8, sampling_name, "center")) {
            sampling = .center;
        } else if (std.mem.eql(u8, sampling_name, "centroid")) {
            sampling = .centroid;
        } else if (std.mem.eql(u8, sampling_name, "sample")) {
            sampling = .sample;
        } else if (std.mem.eql(u8, sampling_name, "either")) {
            sampling = null;
        } else {
            return error.InvalidAttribute;
        }
    }

    return .{ .interpolation = interp, .sampling = sampling };
}

fn parse_builtin_attr(tree: *const Ast, attr_idx: u32) !ir.Builtin {
    const attr = tree.nodes.items[attr_idx];
    const span = decode_packed_span(attr.data.rhs);
    if (span.len == 0) return error.InvalidAttribute;
    const arg = tree.nodes.items[tree.extra_data.items[span.start]];
    if (arg.tag != .ident_expr) return error.InvalidAttribute;
    const name = tree.tokenSlice(arg.main_token);
    if (std.mem.eql(u8, name, "position")) return .position;
    if (std.mem.eql(u8, name, "frag_depth")) return .frag_depth;
    if (std.mem.eql(u8, name, "front_facing")) return .front_facing;
    if (std.mem.eql(u8, name, "global_invocation_id")) return .global_invocation_id;
    if (std.mem.eql(u8, name, "local_invocation_id")) return .local_invocation_id;
    if (std.mem.eql(u8, name, "local_invocation_index")) return .local_invocation_index;
    if (std.mem.eql(u8, name, "workgroup_id")) return .workgroup_id;
    if (std.mem.eql(u8, name, "num_workgroups")) return .num_workgroups;
    if (std.mem.eql(u8, name, "sample_index")) return .sample_index;
    if (std.mem.eql(u8, name, "sample_mask")) return .sample_mask;
    if (std.mem.eql(u8, name, "vertex_index")) return .vertex_index;
    if (std.mem.eql(u8, name, "instance_index")) return .instance_index;
    if (std.mem.eql(u8, name, "subgroup_size")) return .subgroup_size;
    if (std.mem.eql(u8, name, "subgroup_invocation_id")) return .subgroup_invocation_id;
    if (std.mem.eql(u8, name, "clip_distances")) return .clip_distances;
    if (std.mem.eql(u8, name, "primitive_index")) return .primitive_index;
    return error.InvalidAttribute;
}
