const std = @import("std");
const ir = @import("ir.zig");
const spirv = @import("spirv_spec.zig");

pub const AccessChainEntry = struct {
    root_id: u32,
    ptr_type: u32,
    result_id: u32,
    indices: []u32,
};

pub const LoadCacheRoot = enum {
    local,
};

pub const LoadCacheEntry = struct {
    root: LoadCacheRoot,
    index: u32,
    value_id: u32,
};

pub const ResultInstEntry = struct {
    opcode: u16,
    result_type: u32,
    result_id: u32,
    operands: []u32,
};

pub fn clearResultInstEntries(allocator: std.mem.Allocator, entries: *std.ArrayListUnmanaged(ResultInstEntry)) void {
    for (entries.items) |entry| allocator.free(entry.operands);
    entries.clearRetainingCapacity();
}

pub fn findResultInstEntry(entries: []const ResultInstEntry, opcode: u16, result_type: u32, operands: []const u32) ?u32 {
    for (entries) |entry| {
        if (entry.opcode != opcode) continue;
        if (entry.result_type != result_type) continue;
        if (entry.operands.len != operands.len) continue;
        if (std.mem.eql(u32, entry.operands, operands)) return entry.result_id;
    }
    return null;
}

pub fn appendResultInstEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ResultInstEntry),
    opcode: u16,
    result_type: u32,
    result_id: u32,
    operands: []const u32,
) !void {
    const owned_operands = try allocator.dupe(u32, operands);
    errdefer allocator.free(owned_operands);
    try entries.append(allocator, .{
        .opcode = opcode,
        .result_type = result_type,
        .result_id = result_id,
        .operands = owned_operands,
    });
}

pub fn cacheableResultOpcode(opcode: u16) bool {
    return switch (opcode) {
        spirv.Opcode.SNegate,
        spirv.Opcode.FNegate,
        spirv.Opcode.Not,
        spirv.Opcode.IAdd,
        spirv.Opcode.FAdd,
        spirv.Opcode.ISub,
        spirv.Opcode.FSub,
        spirv.Opcode.IMul,
        spirv.Opcode.FMul,
        spirv.Opcode.UDiv,
        spirv.Opcode.SDiv,
        spirv.Opcode.FDiv,
        spirv.Opcode.UMod,
        spirv.Opcode.SRem,
        spirv.Opcode.FRem,
        spirv.Opcode.VectorTimesScalar,
        spirv.Opcode.MatrixTimesScalar,
        spirv.Opcode.VectorTimesMatrix,
        spirv.Opcode.MatrixTimesVector,
        spirv.Opcode.MatrixTimesMatrix,
        spirv.Opcode.BitwiseAnd,
        spirv.Opcode.BitwiseOr,
        spirv.Opcode.BitwiseXor,
        spirv.Opcode.ShiftLeftLogical,
        spirv.Opcode.ShiftRightLogical,
        spirv.Opcode.ShiftRightArithmetic,
        spirv.Opcode.LogicalEqual,
        spirv.Opcode.LogicalNotEqual,
        spirv.Opcode.IEqual,
        spirv.Opcode.INotEqual,
        spirv.Opcode.ULessThan,
        spirv.Opcode.ULessThanEqual,
        spirv.Opcode.UGreaterThan,
        spirv.Opcode.UGreaterThanEqual,
        spirv.Opcode.SLessThan,
        spirv.Opcode.SLessThanEqual,
        spirv.Opcode.SGreaterThan,
        spirv.Opcode.SGreaterThanEqual,
        spirv.Opcode.FOrdEqual,
        spirv.Opcode.FOrdNotEqual,
        spirv.Opcode.FOrdLessThan,
        spirv.Opcode.FOrdLessThanEqual,
        spirv.Opcode.FOrdGreaterThan,
        spirv.Opcode.FOrdGreaterThanEqual,
        spirv.Opcode.LogicalAnd,
        spirv.Opcode.LogicalOr,
        spirv.Opcode.Bitcast,
        spirv.Opcode.ConvertFToS,
        spirv.Opcode.ConvertFToU,
        spirv.Opcode.ConvertSToF,
        spirv.Opcode.ConvertUToF,
        spirv.Opcode.FConvert,
        spirv.Opcode.CompositeExtract,
        spirv.Opcode.VectorExtractDynamic,
        spirv.Opcode.Dot,
        => true,
        else => false,
    };
}

pub fn removeLoadCacheEntry(entries: *std.ArrayListUnmanaged(LoadCacheEntry), root: LoadCacheRoot, index: u32) void {
    var i: usize = 0;
    while (i < entries.items.len) {
        const entry = entries.items[i];
        if (entry.root == root and entry.index == index) {
            _ = entries.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn emitZeroValue(self: anytype, ty: ir.TypeId) !u32 {
    return switch (self.emitter.module.types.get(ty)) {
        .scalar => |scalar| switch (scalar) {
            .bool => try self.emitter.builder.const_bool(false),
            .i32, .abstract_int => try self.emitter.builder.const_i32_bits(0),
            .u32 => try self.emitter.builder.const_u32(0),
            .f16 => try self.emitter.builder.const_f16_bits(0),
            .f32, .abstract_float => try self.emitter.builder.const_f32_bits(0),
            .void => error.UnsupportedConstruct,
        },
        .vector => |vec| blk: {
            const zero = try emitZeroValue(self, vec.elem);
            var components = std.ArrayListUnmanaged(u32){};
            defer components.deinit(self.emitter.alloc);
            var i: u32 = 0;
            while (i < vec.len) : (i += 1) try components.append(self.emitter.alloc, zero);
            break :blk try self.emit_construct_from_operands(ty, components.items);
        },
        else => error.UnsupportedConstruct,
    };
}

pub fn ref_chain_roots_at_local(function: *const ir.Function, expr_id: ir.ExprId) ?u32 {
    var current = expr_id;
    while (true) {
        const expr = function.exprs.items[current];
        switch (expr.data) {
            .local_ref => |index| return index,
            .member => |m| current = m.base,
            .index => |idx| current = idx.base,
            .load => |inner| current = inner,
            else => return null,
        }
    }
}

pub const ScalarKind = enum { bool, signed, unsigned, float };

pub fn scalar_construct_kind(scalar: ir.ScalarType) ScalarKind {
    return switch (scalar) {
        .bool => .bool,
        .u32 => .unsigned,
        .f16, .f32, .abstract_float => .float,
        else => .signed,
    };
}

pub fn assign_op_to_binary(op: ir.AssignOp) ir.BinaryOp {
    return switch (op) {
        .assign => .add,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
    };
}

// Returns true if any `.assign` statement in the function has an lhs chain
// that roots at `param_ref(param_index)`. Used to decide whether a param is
// safe to SSA-promote (WGSL params are locally mutable by default).
pub fn param_is_assigned(function: *const ir.Function, param_index: u32) bool {
    for (function.stmts.items) |stmt| {
        switch (stmt) {
            .assign => |assign| {
                if (ref_chain_roots_at_param(function, assign.lhs, param_index)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn ref_chain_roots_at_param(function: *const ir.Function, expr_id: ir.ExprId, param_index: u32) bool {
    var current = expr_id;
    while (true) {
        const expr = function.exprs.items[current];
        switch (expr.data) {
            .param_ref => |index| return index == param_index,
            .member => |m| current = m.base,
            .index => |idx| current = idx.base,
            .load => |inner| current = inner,
            else => return false,
        }
    }
}
