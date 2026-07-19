// DXIL module builder: constructs the LLVM 3.7 bitcode module structure
// for DXIL shader programs. Manages type IDs, value IDs, function
// declarations, constants, metadata nodes, and the value symbol table.

const std = @import("std");
const spec = @import("dxil_spec.zig");
const bitcode = @import("dxil_bitcode.zig");

pub const EmitError = spec.EmitError;

const MAX_TYPES: usize = 128;
const MAX_VALUES: usize = 512;
const MAX_METADATA: usize = 256;
const MAX_FUNCTIONS: usize = 32;
const MAX_NAMED_MD: usize = 32;
const MAX_SYMTAB_ENTRIES: usize = 64;
const MAX_FUNCTION_BODY_OPS: usize = 1024;

pub const TypeIndex = u32;
pub const ValueIndex = u32;
pub const MdIndex = u32;

pub const INVALID_TYPE: TypeIndex = std.math.maxInt(u32);

pub const LlvmType = union(enum) {
    void_ty: void,
    i1_ty: void,
    i8_ty: void,
    i16_ty: void,
    i32_ty: void,
    i64_ty: void,
    f16_ty: void,
    f32_ty: void,
    f64_ty: void,
    pointer_ty: TypeIndex,
    function_ty: struct {
        return_type: TypeIndex,
        params: [8]TypeIndex,
        param_count: u8,
        is_vararg: bool,
    },
    struct_ty: struct {
        members: [16]TypeIndex,
        member_count: u8,
        name: ?[]const u8,
    },
    array_ty: struct {
        elem: TypeIndex,
        len: u64,
    },
    vector_ty: struct {
        elem: TypeIndex,
        len: u32,
    },
    metadata_ty: void,
    label_ty: void,
};

pub const FuncDecl = struct {
    name: []const u8,
    type_index: TypeIndex,
    linkage: u32 = spec.Linkage.EXTERNAL,
    value_index: ValueIndex = 0,
    is_definition: bool = false,
};

pub const ConstantEntry = struct {
    type_index: TypeIndex,
    value: ConstValue,
};

pub const ConstValue = union(enum) {
    int_val: i64,
    uint_val: u64,
    float_val: u64,
    null_val: void,
    undef_val: void,
};

pub const MdNode = union(enum) {
    string: []const u8,
    value: struct { type_index: TypeIndex, value_index: ValueIndex },
    node: struct { operands: [16]?MdIndex, count: u8 },
};

pub const NamedMd = struct {
    name: []const u8,
    node_indices: [16]MdIndex,
    count: u8,
};

pub const SymtabEntry = struct {
    value_index: ValueIndex,
    name: []const u8,
};

pub const FunctionBodyOp = union(enum) {
    ret_void: void,
    ret_value: ValueIndex,
    call: struct {
        result_type: TypeIndex,
        callee: ValueIndex,
        args: [8]ValueIndex,
        arg_count: u8,
    },
    binop: struct {
        lhs: ValueIndex,
        rhs: ValueIndex,
        opcode: u32,
    },
    cast: struct {
        operand: ValueIndex,
        dest_type: TypeIndex,
        opcode: u32,
    },
    load: struct {
        ptr: ValueIndex,
        type_index: TypeIndex,
        align_log2: u32,
    },
    store: struct {
        ptr: ValueIndex,
        value: ValueIndex,
        align_log2: u32,
    },
    alloca: struct {
        type_index: TypeIndex,
        count: ValueIndex,
        align_log2: u32,
    },
    gep: struct {
        base_type: TypeIndex,
        ptr: ValueIndex,
        indices: [4]ValueIndex,
        index_count: u8,
        inbounds: bool,
    },
    extract_value: struct {
        aggregate: ValueIndex,
        index: u32,
    },
    insert_value: struct {
        aggregate: ValueIndex,
        value: ValueIndex,
        index: u32,
    },
    cmp: struct {
        lhs: ValueIndex,
        rhs: ValueIndex,
        predicate: u32,
    },
    br: u32,
    br_cond: struct {
        cond: ValueIndex,
        true_block: u32,
        false_block: u32,
    },
    phi: struct {
        type_index: TypeIndex,
        incoming: [8]struct { value: ValueIndex, block: u32 },
        count: u8,
    },
    switch_op: struct {
        cond: ValueIndex,
        default_block: u32,
        cases: [16]struct { value: ValueIndex, block: u32 },
        case_count: u8,
    },
};

pub const FunctionBody = struct {
    func_index: u32,
    num_blocks: u32 = 1,
    ops: [MAX_FUNCTION_BODY_OPS]FunctionBodyOp = undefined,
    op_types: [MAX_FUNCTION_BODY_OPS]TypeIndex = undefined,
    op_count: u32 = 0,
    next_local_value: ValueIndex = 0,

    pub fn add_op(self: *FunctionBody, op: FunctionBodyOp, result_type: TypeIndex) EmitError!ValueIndex {
        if (self.op_count >= MAX_FUNCTION_BODY_OPS) return error.OutputTooLarge;
        self.ops[self.op_count] = op;
        self.op_types[self.op_count] = result_type;
        self.op_count += 1;
        const val = self.next_local_value;
        self.next_local_value += 1;
        return val;
    }

    pub fn add_void_op(self: *FunctionBody, op: FunctionBodyOp) EmitError!void {
        if (self.op_count >= MAX_FUNCTION_BODY_OPS) return error.OutputTooLarge;
        self.ops[self.op_count] = op;
        self.op_types[self.op_count] = INVALID_TYPE;
        self.op_count += 1;
    }
};

pub const Builder = struct {
    types: [MAX_TYPES]LlvmType = undefined,
    type_count: u32 = 0,

    functions: [MAX_FUNCTIONS]FuncDecl = undefined,
    function_count: u32 = 0,

    constants: [MAX_VALUES]ConstantEntry = undefined,
    constant_count: u32 = 0,

    metadata: [MAX_METADATA]MdNode = undefined,
    md_count: u32 = 0,

    named_md: [MAX_NAMED_MD]NamedMd = undefined,
    named_md_count: u32 = 0,

    symtab: [MAX_SYMTAB_ENTRIES]SymtabEntry = undefined,
    symtab_count: u32 = 0,

    next_value_id: ValueIndex = 0,

    pub fn init() Builder {
        return .{};
    }

    pub fn add_type(self: *Builder, ty: LlvmType) EmitError!TypeIndex {
        if (self.type_count >= MAX_TYPES) return error.OutputTooLarge;
        const idx: TypeIndex = self.type_count;
        self.types[self.type_count] = ty;
        self.type_count += 1;
        return idx;
    }

    pub fn find_or_add_type(self: *Builder, ty: LlvmType) EmitError!TypeIndex {
        for (self.types[0..self.type_count], 0..) |existing, i| {
            if (type_eql(existing, ty)) return @intCast(i);
        }
        return self.add_type(ty);
    }

    pub fn type_void(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .void_ty = {} });
    }

    pub fn type_i1(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .i1_ty = {} });
    }

    pub fn type_i8(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .i8_ty = {} });
    }

    pub fn type_i32(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .i32_ty = {} });
    }

    pub fn type_i64(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .i64_ty = {} });
    }

    pub fn type_f16(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .f16_ty = {} });
    }

    pub fn type_f32(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .f32_ty = {} });
    }

    pub fn type_pointer(self: *Builder, pointee: TypeIndex) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .pointer_ty = pointee });
    }

    pub fn type_function(self: *Builder, ret: TypeIndex, params: []const TypeIndex, is_vararg: bool) EmitError!TypeIndex {
        if (params.len > 8) return error.OutputTooLarge;
        var ft: LlvmType = .{ .function_ty = .{
            .return_type = ret,
            .params = undefined,
            .param_count = @intCast(params.len),
            .is_vararg = is_vararg,
        } };
        for (params, 0..) |p, i| {
            ft.function_ty.params[i] = p;
        }
        return self.find_or_add_type(ft);
    }

    pub fn type_struct(self: *Builder, members: []const TypeIndex, name: ?[]const u8) EmitError!TypeIndex {
        if (members.len > 16) return error.OutputTooLarge;
        var st: LlvmType = .{ .struct_ty = .{
            .members = undefined,
            .member_count = @intCast(members.len),
            .name = name,
        } };
        for (members, 0..) |m, i| {
            st.struct_ty.members[i] = m;
        }
        return self.add_type(st);
    }

    pub fn type_array(self: *Builder, elem: TypeIndex, len: u64) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .array_ty = .{ .elem = elem, .len = len } });
    }

    pub fn type_vector(self: *Builder, elem: TypeIndex, len: u32) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .vector_ty = .{ .elem = elem, .len = len } });
    }

    pub fn type_metadata(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .metadata_ty = {} });
    }

    pub fn type_label(self: *Builder) EmitError!TypeIndex {
        return self.find_or_add_type(.{ .label_ty = {} });
    }

    pub fn add_function(self: *Builder, decl: FuncDecl) EmitError!u32 {
        if (self.function_count >= MAX_FUNCTIONS) return error.OutputTooLarge;
        const idx = self.function_count;
        var d = decl;
        d.value_index = self.next_value_id;
        self.next_value_id += 1;
        self.functions[self.function_count] = d;
        self.function_count += 1;
        return idx;
    }

    pub fn add_constant(self: *Builder, type_index: TypeIndex, value: ConstValue) EmitError!ValueIndex {
        if (self.constant_count >= MAX_VALUES) return error.OutputTooLarge;
        self.constants[self.constant_count] = .{ .type_index = type_index, .value = value };
        self.constant_count += 1;
        const val = self.next_value_id;
        self.next_value_id += 1;
        return val;
    }

    pub fn add_const_i32(self: *Builder, value: i32) EmitError!ValueIndex {
        const ty = try self.type_i32();
        return self.add_constant(ty, .{ .int_val = value });
    }

    pub fn add_const_u32(self: *Builder, value: u32) EmitError!ValueIndex {
        const ty = try self.type_i32();
        return self.add_constant(ty, .{ .uint_val = value });
    }

    pub fn add_const_f32(self: *Builder, value: f32) EmitError!ValueIndex {
        const ty = try self.type_f32();
        return self.add_constant(ty, .{ .float_val = @as(u64, @as(u32, @bitCast(value))) });
    }

    pub fn add_metadata_string(self: *Builder, text: []const u8) EmitError!MdIndex {
        if (self.md_count >= MAX_METADATA) return error.OutputTooLarge;
        const idx: MdIndex = self.md_count;
        self.metadata[self.md_count] = .{ .string = text };
        self.md_count += 1;
        return idx;
    }

    pub fn add_metadata_value(self: *Builder, type_index: TypeIndex, value_index: ValueIndex) EmitError!MdIndex {
        if (self.md_count >= MAX_METADATA) return error.OutputTooLarge;
        const idx: MdIndex = self.md_count;
        self.metadata[self.md_count] = .{ .value = .{ .type_index = type_index, .value_index = value_index } };
        self.md_count += 1;
        return idx;
    }

    pub fn add_metadata_node(self: *Builder, operands: []const ?MdIndex) EmitError!MdIndex {
        if (self.md_count >= MAX_METADATA) return error.OutputTooLarge;
        if (operands.len > 16) return error.OutputTooLarge;
        const idx: MdIndex = self.md_count;
        var node = MdNode{ .node = .{ .operands = undefined, .count = @intCast(operands.len) } };
        for (operands, 0..) |op, i| {
            node.node.operands[i] = op;
        }
        self.metadata[self.md_count] = node;
        self.md_count += 1;
        return idx;
    }

    pub fn add_named_metadata(self: *Builder, name: []const u8, nodes: []const MdIndex) EmitError!void {
        if (self.named_md_count >= MAX_NAMED_MD) return error.OutputTooLarge;
        if (nodes.len > 16) return error.OutputTooLarge;
        var entry = NamedMd{ .name = name, .node_indices = undefined, .count = @intCast(nodes.len) };
        for (nodes, 0..) |n, i| {
            entry.node_indices[i] = n;
        }
        self.named_md[self.named_md_count] = entry;
        self.named_md_count += 1;
    }

    pub fn add_symtab_entry(self: *Builder, value_index: ValueIndex, name: []const u8) EmitError!void {
        if (self.symtab_count >= MAX_SYMTAB_ENTRIES) return error.OutputTooLarge;
        self.symtab[self.symtab_count] = .{ .value_index = value_index, .name = name };
        self.symtab_count += 1;
    }

    pub fn create_function_body(self: *Builder, func_index: u32) FunctionBody {
        const func = self.functions[func_index];
        _ = func;
        return .{
            .func_index = func_index,
            .next_local_value = self.next_value_id,
        };
    }
};

fn type_eql(a: LlvmType, b: LlvmType) bool {
    return switch (a) {
        .void_ty => b == .void_ty,
        .i1_ty => b == .i1_ty,
        .i8_ty => b == .i8_ty,
        .i16_ty => b == .i16_ty,
        .i32_ty => b == .i32_ty,
        .i64_ty => b == .i64_ty,
        .f16_ty => b == .f16_ty,
        .f32_ty => b == .f32_ty,
        .f64_ty => b == .f64_ty,
        .metadata_ty => b == .metadata_ty,
        .label_ty => b == .label_ty,
        .pointer_ty => |pa| switch (b) {
            .pointer_ty => |pb| pa == pb,
            else => false,
        },
        .function_ty => |fa| switch (b) {
            .function_ty => |fb| {
                if (fa.return_type != fb.return_type) return false;
                if (fa.param_count != fb.param_count) return false;
                if (fa.is_vararg != fb.is_vararg) return false;
                for (0..fa.param_count) |i| {
                    if (fa.params[i] != fb.params[i]) return false;
                }
                return true;
            },
            else => false,
        },
        .array_ty => |aa| switch (b) {
            .array_ty => |ab| aa.elem == ab.elem and aa.len == ab.len,
            else => false,
        },
        .vector_ty => |va| switch (b) {
            .vector_ty => |vb| va.elem == vb.elem and va.len == vb.len,
            else => false,
        },
        .struct_ty => false, // structs are always unique
    };
}

test "builder creates basic types" {
    var b = Builder.init();
    const void_ty = try b.type_void();
    const i32_ty = try b.type_i32();
    const f32_ty = try b.type_f32();
    try std.testing.expect(void_ty != i32_ty);
    try std.testing.expect(i32_ty != f32_ty);

    // Deduplication
    const i32_again = try b.type_i32();
    try std.testing.expectEqual(i32_ty, i32_again);
}

test "builder adds function and constant" {
    var b = Builder.init();
    const i32_ty = try b.type_i32();
    const void_ty = try b.type_void();
    const fn_ty = try b.type_function(void_ty, &.{i32_ty}, false);
    _ = try b.add_function(.{ .name = "main", .type_index = fn_ty });
    _ = try b.add_const_i32(42);
    try std.testing.expectEqual(@as(u32, 1), b.function_count);
    try std.testing.expectEqual(@as(u32, 1), b.constant_count);
}
