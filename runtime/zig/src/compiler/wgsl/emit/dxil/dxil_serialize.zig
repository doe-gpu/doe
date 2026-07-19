// DXIL bitcode serializer: takes a populated dxil_builder.Builder and writes
// it as LLVM 3.7 bitcode using the dxil_bitcode.Writer.
//
// Emits the MODULE block with TYPE, CONSTANTS, FUNCTION, METADATA, and
// VALUE_SYMTAB sub-blocks in the order required by LLVM's bitcode reader.

const std = @import("std");
const spec = @import("dxil_spec.zig");
const bc = @import("dxil_bitcode.zig");
const builder_mod = @import("dxil_builder.zig");

pub const EmitError = spec.EmitError;

const Builder = builder_mod.Builder;
const FunctionBody = builder_mod.FunctionBody;
const TypeIndex = builder_mod.TypeIndex;
const ValueIndex = builder_mod.ValueIndex;
const LlvmType = builder_mod.LlvmType;
const MdNode = builder_mod.MdNode;
const ConstValue = builder_mod.ConstValue;
const FunctionBodyOp = builder_mod.FunctionBodyOp;
const INVALID_TYPE = builder_mod.INVALID_TYPE;

const TYPE_BLOCK_ABBREV_WIDTH: u5 = 4;
const CONSTANTS_BLOCK_ABBREV_WIDTH: u5 = 4;
const FUNCTION_BLOCK_ABBREV_WIDTH: u5 = 4;
const METADATA_BLOCK_ABBREV_WIDTH: u5 = 4;
const SYMTAB_BLOCK_ABBREV_WIDTH: u5 = 4;
const MODULE_BLOCK_ABBREV_WIDTH: u5 = 3;

pub fn serialize(b: *const Builder, bodies: []const FunctionBody, out: []u8) EmitError!usize {
    var w = bc.Writer.init(out);

    // LLVM bitcode magic
    try w.emit_raw_bytes(&spec.LLVM_IR_MAGIC);

    // MODULE block
    try w.enter_block(spec.BlockId.MODULE, MODULE_BLOCK_ABBREV_WIDTH);

    // Module version
    try w.emit_record(spec.ModuleCode.VERSION, &.{1});

    // Target triple
    try w.emit_string_record(spec.ModuleCode.TRIPLE, spec.TARGET_TRIPLE_CS);

    // Data layout
    try w.emit_string_record(spec.ModuleCode.DATALAYOUT, spec.TARGET_DATALAYOUT);

    // TYPE block
    try emit_type_block(&w, b);

    // Function declarations (MODULE_CODE_FUNCTION records)
    try emit_function_decls(&w, b);

    // CONSTANTS block
    if (b.constant_count > 0) {
        try emit_constants_block(&w, b);
    }

    // METADATA block
    if (b.md_count > 0 or b.named_md_count > 0) {
        try emit_metadata_block(&w, b);
    }

    // Function bodies
    for (bodies) |*body| {
        try emit_function_body(&w, b, body);
    }

    // VALUE_SYMTAB block
    if (b.symtab_count > 0) {
        try emit_value_symtab(&w, b);
    }

    try w.exit_block(); // end MODULE
    return w.finalize();
}

fn emit_type_block(w: *bc.Writer, b: *const Builder) EmitError!void {
    try w.enter_block(spec.BlockId.TYPE, TYPE_BLOCK_ABBREV_WIDTH);

    // NUMENTRY record
    try w.emit_record(spec.TypeCode.NUMENTRY, &.{b.type_count});

    for (b.types[0..b.type_count]) |ty| {
        switch (ty) {
            .void_ty => try w.emit_record(spec.TypeCode.VOID, &.{}),
            .i1_ty => try w.emit_record(spec.TypeCode.INTEGER, &.{1}),
            .i8_ty => try w.emit_record(spec.TypeCode.INTEGER, &.{8}),
            .i16_ty => try w.emit_record(spec.TypeCode.INTEGER, &.{16}),
            .i32_ty => try w.emit_record(spec.TypeCode.INTEGER, &.{32}),
            .i64_ty => try w.emit_record(spec.TypeCode.INTEGER, &.{64}),
            .f16_ty => try w.emit_record(spec.TypeCode.HALF, &.{}),
            .f32_ty => try w.emit_record(spec.TypeCode.FLOAT, &.{}),
            .f64_ty => try w.emit_record(spec.TypeCode.DOUBLE, &.{}),
            .metadata_ty => try w.emit_record(spec.TypeCode.METADATA, &.{}),
            .label_ty => try w.emit_record(spec.TypeCode.LABEL, &.{}),
            .pointer_ty => |pointee| try w.emit_record(spec.TypeCode.POINTER, &.{ pointee, 0 }),
            .function_ty => |ft| {
                var ops: [12]u64 = undefined;
                ops[0] = @intFromBool(ft.is_vararg);
                ops[1] = ft.return_type;
                for (0..ft.param_count) |i| {
                    ops[2 + i] = ft.params[i];
                }
                try w.emit_record(spec.TypeCode.FUNCTION, ops[0 .. 2 + ft.param_count]);
            },
            .struct_ty => |st| {
                if (st.name) |name| {
                    try w.emit_string_record(spec.TypeCode.STRUCT_NAMED, name);
                }
                var ops: [18]u64 = undefined;
                ops[0] = 0; // ispacked
                for (0..st.member_count) |i| {
                    ops[1 + i] = st.members[i];
                }
                const code = if (st.name != null) spec.TypeCode.STRUCT_NAMED else spec.TypeCode.STRUCT_ANON;
                _ = code;
                try w.emit_record(spec.TypeCode.STRUCT_ANON, ops[0 .. 1 + st.member_count]);
            },
            .array_ty => |at| try w.emit_record(spec.TypeCode.ARRAY, &.{ at.len, at.elem }),
            .vector_ty => |vt| try w.emit_record(spec.TypeCode.VECTOR, &.{ vt.len, vt.elem }),
        }
    }

    try w.exit_block();
}

fn emit_function_decls(w: *bc.Writer, b: *const Builder) EmitError!void {
    for (b.functions[0..b.function_count]) |func| {
        // MODULE_CODE_FUNCTION: [type, callingconv, isproto, linkage, paramattr,
        //                        alignment, section, visibility, gc, unnamed_addr,
        //                        prologuedata, dllstorageclass, comdat, prefixdata,
        //                        personality]
        try w.emit_record(spec.ModuleCode.FUNCTION, &.{
            func.type_index, // type
            0, // calling convention (default=0)
            @intFromBool(!func.is_definition), // isproto
            func.linkage, // linkage
            0, // paramattr
            0, // alignment
            0, // section
            0, // visibility (default)
            0, // gc
            0, // unnamed_addr
            0, // prologuedata
            0, // dllstorageclass
            0, // comdat
            0, // prefixdata
            0, // personality
        });
    }
}

fn emit_constants_block(w: *bc.Writer, b: *const Builder) EmitError!void {
    try w.enter_block(spec.BlockId.CONSTANTS, CONSTANTS_BLOCK_ABBREV_WIDTH);

    var current_type: TypeIndex = INVALID_TYPE;
    for (b.constants[0..b.constant_count]) |entry| {
        if (entry.type_index != current_type) {
            try w.emit_record(spec.ConstantCode.SETTYPE, &.{entry.type_index});
            current_type = entry.type_index;
        }
        switch (entry.value) {
            .int_val => |v| {
                // LLVM uses signed VBR for integer constants
                const encoded: u64 = if (v >= 0)
                    @as(u64, @intCast(v)) << 1
                else
                    (@as(u64, @intCast(-v - 1)) << 1) | 1;
                try w.emit_record(spec.ConstantCode.INTEGER, &.{encoded});
            },
            .uint_val => |v| {
                try w.emit_record(spec.ConstantCode.INTEGER, &.{v << 1});
            },
            .float_val => |bits| {
                try w.emit_record(spec.ConstantCode.FLOAT, &.{bits});
            },
            .null_val => try w.emit_record(spec.ConstantCode.NULL, &.{}),
            .undef_val => try w.emit_record(spec.ConstantCode.UNDEF, &.{}),
        }
    }

    try w.exit_block();
}

fn emit_metadata_block(w: *bc.Writer, b: *const Builder) EmitError!void {
    try w.enter_block(spec.BlockId.METADATA, METADATA_BLOCK_ABBREV_WIDTH);

    for (b.metadata[0..b.md_count]) |md| {
        switch (md) {
            .string => |text| {
                try w.emit_string_record(spec.MetadataCode.STRING, text);
            },
            .value => |val| {
                try w.emit_record(spec.MetadataCode.VALUE, &.{ val.type_index, val.value_index });
            },
            .node => |node| {
                var ops: [16]u64 = undefined;
                for (0..node.count) |i| {
                    ops[i] = if (node.operands[i]) |idx|
                        idx + 1 // metadata indices are 1-based (0 = null)
                    else
                        0;
                }
                try w.emit_record(spec.MetadataCode.NODE, ops[0..node.count]);
            },
        }
    }

    // Named metadata
    for (b.named_md[0..b.named_md_count]) |named| {
        try w.emit_string_record(spec.MetadataCode.NAME, named.name);
        var ops: [16]u64 = undefined;
        for (0..named.count) |i| {
            ops[i] = named.node_indices[i];
        }
        try w.emit_record(spec.MetadataCode.NAMED_NODE, ops[0..named.count]);
    }

    try w.exit_block();
}

fn emit_function_body(w: *bc.Writer, b: *const Builder, body: *const FunctionBody) EmitError!void {
    try w.enter_block(spec.BlockId.FUNCTION, FUNCTION_BLOCK_ABBREV_WIDTH);

    // DECLAREBLOCKS
    try w.emit_record(spec.FunctionCode.DECLAREBLOCKS, &.{body.num_blocks});

    // Emit all instructions
    // Value numbering: global values first, then local values in order
    const base_value = body.next_local_value - body.op_count;
    _ = base_value;

    for (body.ops[0..body.op_count]) |op| {
        switch (op) {
            .ret_void => try w.emit_record(spec.FunctionCode.INST_RET, &.{}),
            .ret_value => |val| {
                try w.emit_record(spec.FunctionCode.INST_RET, &.{val});
            },
            .call => |call| {
                var ops: [12]u64 = undefined;
                ops[0] = 0; // attribute list
                const func = b.functions[call.callee];
                _ = func;
                ops[1] = call.result_type;
                ops[2] = call.callee;
                for (0..call.arg_count) |i| {
                    ops[3 + i] = call.args[i];
                }
                try w.emit_record(spec.FunctionCode.INST_CALL, ops[0 .. 3 + call.arg_count]);
            },
            .binop => |binop| {
                try w.emit_record(spec.FunctionCode.INST_BINOP, &.{
                    binop.lhs,
                    binop.rhs,
                    binop.opcode,
                });
            },
            .cast => |cast_op| {
                try w.emit_record(spec.FunctionCode.INST_CAST, &.{
                    cast_op.operand,
                    cast_op.dest_type,
                    cast_op.opcode,
                });
            },
            .load => |ld| {
                try w.emit_record(spec.FunctionCode.INST_LOAD, &.{
                    ld.ptr,
                    ld.type_index,
                    ld.align_log2,
                    0, // isvolatile
                });
            },
            .store => |st| {
                try w.emit_record(spec.FunctionCode.INST_STORE, &.{
                    st.ptr,
                    st.value,
                    st.align_log2,
                    0, // isvolatile
                });
            },
            .alloca => |alloc| {
                try w.emit_record(spec.FunctionCode.INST_ALLOCA, &.{
                    alloc.type_index,
                    alloc.type_index, // type of size
                    alloc.count,
                    alloc.align_log2 | (1 << 5), // explicit type flag
                });
            },
            .gep => |gep| {
                var ops: [10]u64 = undefined;
                ops[0] = @intFromBool(gep.inbounds);
                ops[1] = gep.base_type;
                ops[2] = gep.ptr;
                for (0..gep.index_count) |i| {
                    ops[3 + i] = gep.indices[i];
                }
                try w.emit_record(spec.FunctionCode.INST_GEP, ops[0 .. 3 + gep.index_count]);
            },
            .extract_value => |ev| {
                try w.emit_record(spec.FunctionCode.INST_EXTRACTVAL, &.{ ev.aggregate, ev.index });
            },
            .insert_value => |iv| {
                try w.emit_record(spec.FunctionCode.INST_INSERTVAL, &.{ iv.aggregate, iv.value, iv.index });
            },
            .cmp => |cmp_op| {
                try w.emit_record(spec.FunctionCode.INST_CMP, &.{ cmp_op.lhs, cmp_op.rhs, cmp_op.predicate });
            },
            .br => |target| {
                try w.emit_record(spec.FunctionCode.INST_BR, &.{target});
            },
            .br_cond => |br| {
                try w.emit_record(spec.FunctionCode.INST_BR, &.{ br.true_block, br.false_block, br.cond });
            },
            .phi => |phi| {
                var ops: [20]u64 = undefined;
                ops[0] = phi.type_index;
                for (0..phi.count) |i| {
                    ops[1 + i * 2] = phi.incoming[i].value;
                    ops[2 + i * 2] = phi.incoming[i].block;
                }
                try w.emit_record(spec.FunctionCode.INST_PHI, ops[0 .. 1 + @as(usize, phi.count) * 2]);
            },
            .switch_op => |sw| {
                var ops: [36]u64 = undefined;
                ops[0] = sw.cond;
                ops[1] = sw.default_block;
                for (0..sw.case_count) |i| {
                    ops[2 + i * 2] = sw.cases[i].value;
                    ops[3 + i * 2] = sw.cases[i].block;
                }
                try w.emit_record(spec.FunctionCode.INST_SWITCH, ops[0 .. 2 + @as(usize, sw.case_count) * 2]);
            },
        }
    }

    try w.exit_block();
}

fn emit_value_symtab(w: *bc.Writer, b: *const Builder) EmitError!void {
    try w.enter_block(spec.BlockId.VALUE_SYMTAB, SYMTAB_BLOCK_ABBREV_WIDTH);

    for (b.symtab[0..b.symtab_count]) |entry| {
        try w.emit_record_with_string(spec.ValueSymtabCode.ENTRY, &.{entry.value_index}, entry.name);
    }

    try w.exit_block();
}

test "serialize empty module produces valid bitcode" {
    var b = Builder.init();
    _ = try b.type_void();
    _ = try b.type_i32();

    var out: [4096]u8 = .{0} ** 4096;
    const size = try serialize(&b, &.{}, &out);
    try std.testing.expect(size > 4);
    try std.testing.expectEqualSlices(u8, &spec.LLVM_IR_MAGIC, out[0..4]);
}
