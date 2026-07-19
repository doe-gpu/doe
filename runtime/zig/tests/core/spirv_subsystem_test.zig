// spirv_subsystem_test.zig -- SPIR-V subsystem regression and structural tests.
//
// Covers: spirv_spec constant stability, spirv_builder instruction encoding,
// type emission, storage class mapping, binding decoration preservation,
// builtin variable mapping, and error handling for unsupported features.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const spec = @import("../../src/compiler/wgsl/emit/spirv/spirv_spec.zig");
const spirv_builder = @import("../../src/compiler/wgsl/emit/spirv/spirv_builder.zig");

const translateToSpirv = mod.translateToSpirv;
const MAX_SPIRV = mod.MAX_SPIRV_OUTPUT;
const testing = std.testing;
const alloc = testing.allocator;

// ============================================================
// Helpers
// ============================================================

fn read_u32_le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[offset .. offset + 4].ptr)), .little);
}

const SpirvInst = struct { opcode: u16, word_count: u16, offset: usize };

const SpirvIterator = struct {
    binary: []const u8,
    pos: usize,
    fn next(self: *SpirvIterator) ?SpirvInst {
        const wc = self.binary.len / 4;
        if (self.pos >= wc) return null;
        const w = read_u32_le(self.binary, self.pos * 4);
        const op: u16 = @intCast(w & 0xFFFF);
        const iwc: u16 = @intCast(w >> 16);
        if (iwc == 0) return null;
        const inst = SpirvInst{ .opcode = op, .word_count = iwc, .offset = self.pos };
        self.pos += iwc;
        return inst;
    }
};

fn iter_instructions(binary: []const u8) SpirvIterator {
    return .{ .binary = binary, .pos = 5 };
}

fn inst_word(binary: []const u8, inst: SpirvInst, idx: usize) u32 {
    return read_u32_le(binary, (inst.offset + idx) * 4);
}

fn compile_spirv(source: []const u8, out: []u8) ![]const u8 {
    const len = try translateToSpirv(alloc, source, out);
    return out[0..len];
}

fn find_inst(binary: []const u8, opcode: u16) ?SpirvInst {
    var it = iter_instructions(binary);
    while (it.next()) |inst| if (inst.opcode == opcode) return inst;
    return null;
}

fn count_insts(binary: []const u8, opcode: u16) usize {
    var it = iter_instructions(binary);
    var c: usize = 0;
    while (it.next()) |inst| if (inst.opcode == opcode) {
        c += 1;
    };
    return c;
}

fn find_decoration(binary: []const u8, decoration: u32) ?SpirvInst {
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.Decorate and inst.word_count >= 3)
            if (inst_word(binary, inst, 2) == decoration) return inst;
    }
    return null;
}

fn find_decoration_val(binary: []const u8, decoration: u32, value: u32) ?SpirvInst {
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.Decorate and inst.word_count >= 4)
            if (inst_word(binary, inst, 2) == decoration and inst_word(binary, inst, 3) == value)
                return inst;
    }
    return null;
}

// ============================================================
// 1. spirv_spec constant stability (regression pins)
// ============================================================

test "spec: magic and word size" {
    try testing.expectEqual(@as(u32, 0x07230203), spec.MAGIC);
    try testing.expectEqual(@as(usize, 4), spec.WORD_BYTES);
}

test "spec: core opcode values" {
    // Type opcodes
    try testing.expectEqual(@as(u16, 19), spec.Opcode.TypeVoid);
    try testing.expectEqual(@as(u16, 20), spec.Opcode.TypeBool);
    try testing.expectEqual(@as(u16, 21), spec.Opcode.TypeInt);
    try testing.expectEqual(@as(u16, 22), spec.Opcode.TypeFloat);
    try testing.expectEqual(@as(u16, 23), spec.Opcode.TypeVector);
    try testing.expectEqual(@as(u16, 24), spec.Opcode.TypeMatrix);
    try testing.expectEqual(@as(u16, 28), spec.Opcode.TypeArray);
    try testing.expectEqual(@as(u16, 30), spec.Opcode.TypeStruct);
    try testing.expectEqual(@as(u16, 32), spec.Opcode.TypePointer);
    try testing.expectEqual(@as(u16, 33), spec.Opcode.TypeFunction);
    // Module-level opcodes
    try testing.expectEqual(@as(u16, 14), spec.Opcode.OpMemoryModel);
    try testing.expectEqual(@as(u16, 15), spec.Opcode.EntryPoint);
    try testing.expectEqual(@as(u16, 16), spec.Opcode.ExecutionMode);
    try testing.expectEqual(@as(u16, 17), spec.Opcode.Capability);
    try testing.expectEqual(@as(u16, 11), spec.Opcode.ExtInstImport);
    try testing.expectEqual(@as(u16, 12), spec.Opcode.ExtInst);
    try testing.expectEqual(@as(u16, 5), spec.Opcode.Name);
    // Function/variable/memory opcodes
    try testing.expectEqual(@as(u16, 54), spec.Opcode.Function);
    try testing.expectEqual(@as(u16, 56), spec.Opcode.FunctionEnd);
    try testing.expectEqual(@as(u16, 59), spec.Opcode.Variable);
    try testing.expectEqual(@as(u16, 61), spec.Opcode.Load);
    try testing.expectEqual(@as(u16, 62), spec.Opcode.Store);
    try testing.expectEqual(@as(u16, 65), spec.Opcode.AccessChain);
    try testing.expectEqual(@as(u16, 43), spec.Opcode.Constant);
    // Decoration/annotation opcodes
    try testing.expectEqual(@as(u16, 71), spec.Opcode.Decorate);
    try testing.expectEqual(@as(u16, 72), spec.Opcode.MemberDecorate);
    // Control flow opcodes
    try testing.expectEqual(@as(u16, 248), spec.Opcode.Label);
    try testing.expectEqual(@as(u16, 249), spec.Opcode.Branch);
    try testing.expectEqual(@as(u16, 253), spec.Opcode.Return);
    try testing.expectEqual(@as(u16, 254), spec.Opcode.ReturnValue);
}

test "spec: arithmetic and comparison opcodes" {
    try testing.expectEqual(@as(u16, 128), spec.Opcode.IAdd);
    try testing.expectEqual(@as(u16, 129), spec.Opcode.FAdd);
    try testing.expectEqual(@as(u16, 130), spec.Opcode.ISub);
    try testing.expectEqual(@as(u16, 131), spec.Opcode.FSub);
    try testing.expectEqual(@as(u16, 132), spec.Opcode.IMul);
    try testing.expectEqual(@as(u16, 133), spec.Opcode.FMul);
    try testing.expectEqual(@as(u16, 136), spec.Opcode.FDiv);
    try testing.expectEqual(@as(u16, 148), spec.Opcode.Dot);
    try testing.expectEqual(@as(u16, 170), spec.Opcode.IEqual);
    try testing.expectEqual(@as(u16, 180), spec.Opcode.FOrdEqual);
    try testing.expectEqual(@as(u16, 182), spec.Opcode.FOrdNotEqual);
    try testing.expectEqual(@as(u16, 184), spec.Opcode.FOrdLessThan);
    try testing.expectEqual(@as(u16, 186), spec.Opcode.FOrdGreaterThan);
    try testing.expectEqual(@as(u16, 188), spec.Opcode.FOrdLessThanEqual);
    try testing.expectEqual(@as(u16, 190), spec.Opcode.FOrdGreaterThanEqual);
}

test "spec: atomic opcodes" {
    try testing.expectEqual(@as(u16, 227), spec.Opcode.AtomicLoad);
    try testing.expectEqual(@as(u16, 228), spec.Opcode.AtomicStore);
    try testing.expectEqual(@as(u16, 234), spec.Opcode.AtomicIAdd);
    try testing.expectEqual(@as(u16, 240), spec.Opcode.AtomicAnd);
    try testing.expectEqual(@as(u16, 242), spec.Opcode.AtomicXor);
}

test "spec: capabilities" {
    try testing.expectEqual(@as(u32, 1), spec.Capability.Shader);
    try testing.expectEqual(@as(u32, 9), spec.Capability.Float16);
    try testing.expectEqual(@as(u32, 35), spec.Capability.SampleRateShading);
    try testing.expectEqual(@as(u32, 49), spec.Capability.StorageImageExtendedFormats);
    try testing.expectEqual(@as(u32, 50), spec.Capability.ImageQuery);
    try testing.expectEqual(@as(u32, 61), spec.Capability.GroupNonUniform);
}

test "spec: storage classes" {
    try testing.expectEqual(@as(u32, 0), spec.StorageClass.UniformConstant);
    try testing.expectEqual(@as(u32, 1), spec.StorageClass.Input);
    try testing.expectEqual(@as(u32, 2), spec.StorageClass.Uniform);
    try testing.expectEqual(@as(u32, 3), spec.StorageClass.Output);
    try testing.expectEqual(@as(u32, 4), spec.StorageClass.Workgroup);
    try testing.expectEqual(@as(u32, 6), spec.StorageClass.Private);
    try testing.expectEqual(@as(u32, 7), spec.StorageClass.Function);
    try testing.expectEqual(@as(u32, 12), spec.StorageClass.StorageBuffer);
}

test "spec: decorations" {
    // Values from Khronos SPIR-V unified spec. Invariant / Index entries
    // are pinned here explicitly because prior code encoded Invariant=0
    // (actually RelaxedPrecision) and Index=31 (actually Component) --
    // latent bugs on vertex/fragment shaders with @invariant or @blend_src.
    try testing.expectEqual(@as(u32, 2), spec.Decoration.Block);
    try testing.expectEqual(@as(u32, 6), spec.Decoration.ArrayStride);
    try testing.expectEqual(@as(u32, 11), spec.Decoration.BuiltIn);
    try testing.expectEqual(@as(u32, 14), spec.Decoration.Flat);
    try testing.expectEqual(@as(u32, 18), spec.Decoration.Invariant);
    try testing.expectEqual(@as(u32, 30), spec.Decoration.Location);
    try testing.expectEqual(@as(u32, 32), spec.Decoration.Index);
    try testing.expectEqual(@as(u32, 33), spec.Decoration.Binding);
    try testing.expectEqual(@as(u32, 34), spec.Decoration.DescriptorSet);
    try testing.expectEqual(@as(u32, 35), spec.Decoration.Offset);
}

test "spec: builtins" {
    // Values from Khronos SPIR-V unified spec. LocalInvocationId / Index
    // previously asserted 29/30, which was off-by-one (landed in Doe's
    // emission as LocalInvocationIndex / uninitialized). 2D/3D compute
    // workloads reading local_invocation_id.y would silently get 0 on
    // RADV. Fixed along with spirv_spec.zig.
    try testing.expectEqual(@as(u32, 0), spec.Builtin.Position);
    try testing.expectEqual(@as(u32, 22), spec.Builtin.FragDepth);
    try testing.expectEqual(@as(u32, 24), spec.Builtin.NumWorkgroups);
    try testing.expectEqual(@as(u32, 27), spec.Builtin.LocalInvocationId);
    try testing.expectEqual(@as(u32, 28), spec.Builtin.GlobalInvocationId);
    try testing.expectEqual(@as(u32, 29), spec.Builtin.LocalInvocationIndex);
    try testing.expectEqual(@as(u32, 36), spec.Builtin.SubgroupSize);
    try testing.expectEqual(@as(u32, 42), spec.Builtin.VertexIndex);
    try testing.expectEqual(@as(u32, 43), spec.Builtin.InstanceIndex);
}

test "spec: execution models and modes" {
    try testing.expectEqual(@as(u32, 0), spec.ExecutionModel.Vertex);
    try testing.expectEqual(@as(u32, 4), spec.ExecutionModel.Fragment);
    try testing.expectEqual(@as(u32, 5), spec.ExecutionModel.GLCompute);
    try testing.expectEqual(@as(u32, 7), spec.ExecutionMode.OriginUpperLeft);
    try testing.expectEqual(@as(u32, 12), spec.ExecutionMode.DepthReplacing);
    try testing.expectEqual(@as(u32, 17), spec.ExecutionMode.LocalSize);
}

test "spec: dimensions" {
    try testing.expectEqual(@as(u32, 0), spec.Dim._1D);
    try testing.expectEqual(@as(u32, 1), spec.Dim._2D);
    try testing.expectEqual(@as(u32, 2), spec.Dim._3D);
    try testing.expectEqual(@as(u32, 3), spec.Dim.Cube);
}

test "spec: image formats" {
    // Values from Khronos SPIR-V unified spec. Integer/uint formats were
    // previously shifted up by ~15 (Rgba32i=36 actually meant Rg16ui in the
    // spec, R32i=40 was out of range). Pin the canonical values so any
    // future regression trips the test rather than silently emitting
    // out-of-range OpTypeImage.
    try testing.expectEqual(@as(u32, 0), spec.ImageFormat.Unknown);
    try testing.expectEqual(@as(u32, 1), spec.ImageFormat.Rgba32f);
    try testing.expectEqual(@as(u32, 4), spec.ImageFormat.Rgba8);
    try testing.expectEqual(@as(u32, 21), spec.ImageFormat.Rgba32i);
    try testing.expectEqual(@as(u32, 24), spec.ImageFormat.R32i);
    try testing.expectEqual(@as(u32, 30), spec.ImageFormat.Rgba32ui);
    try testing.expectEqual(@as(u32, 33), spec.ImageFormat.R32ui);
    try testing.expectEqual(@as(u32, 35), spec.ImageFormat.Rg32ui);
}

test "spec: memory semantics" {
    try testing.expectEqual(@as(u32, 0), spec.MemorySemantics.None);
    try testing.expectEqual(@as(u32, 0x002), spec.MemorySemantics.Acquire);
    try testing.expectEqual(@as(u32, 0x004), spec.MemorySemantics.Release);
    try testing.expectEqual(@as(u32, 0x008), spec.MemorySemantics.AcquireRelease);
    try testing.expectEqual(@as(u32, 0x100), spec.MemorySemantics.WorkgroupMemory);
}

// ============================================================
// 2. spirv_builder instruction encoding
// ============================================================

test "builder: init emits Shader capability and memory model" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    try testing.expect(b.capabilities.items.len >= 2);
    try testing.expectEqual(@as(u16, spec.Opcode.Capability), @as(u16, @intCast(b.capabilities.items[0] & 0xFFFF)));
    try testing.expectEqual(spec.Capability.Shader, b.capabilities.items[1]);
    try testing.expect(b.memory_model.items.len >= 3);
    try testing.expectEqual(spec.AddressingModel.Logical, b.memory_model.items[1]);
    try testing.expectEqual(spec.MemoryModel.GLSL450, b.memory_model.items[2]);
}

test "builder: reserve_id returns sequential IDs" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const start = b.next_id;
    const id1 = b.reserve_id();
    const id2 = b.reserve_id();
    try testing.expectEqual(start, id1);
    try testing.expectEqual(start + 1, id2);
}

test "builder: type_f32 produces OpTypeFloat 32" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const f32_id = try b.type_f32();
    var i: usize = 0;
    while (i < b.types_globals.items.len) {
        const w = b.types_globals.items[i];
        const op: u16 = @intCast(w & 0xFFFF);
        const wc: u16 = @intCast(w >> 16);
        if (op == spec.Opcode.TypeFloat and wc == 3 and b.types_globals.items[i + 1] == f32_id) {
            try testing.expectEqual(@as(u32, 32), b.types_globals.items[i + 2]);
            return;
        }
        i += wc;
    }
    return error.TestExpectedEqual;
}

test "builder: type_u32 produces OpTypeInt 32 0 and type_i32 produces OpTypeInt 32 1" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const u32_id = try b.type_u32();
    const i32_id = try b.type_i32();
    var found_u: bool = false;
    var found_i: bool = false;
    var i: usize = 0;
    while (i < b.types_globals.items.len) {
        const w = b.types_globals.items[i];
        const op: u16 = @intCast(w & 0xFFFF);
        const wc: u16 = @intCast(w >> 16);
        if (op == spec.Opcode.TypeInt and wc == 4) {
            const id = b.types_globals.items[i + 1];
            const width = b.types_globals.items[i + 2];
            const sign = b.types_globals.items[i + 3];
            if (id == u32_id and width == 32 and sign == 0) found_u = true;
            if (id == i32_id and width == 32 and sign == 1) found_i = true;
        }
        i += wc;
    }
    try testing.expect(found_u);
    try testing.expect(found_i);
}

test "builder: type_vector produces OpTypeVector" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const f32_id = try b.type_f32();
    const vec4f_id = try b.type_vector(f32_id, 4);
    var i: usize = 0;
    while (i < b.types_globals.items.len) {
        const w = b.types_globals.items[i];
        const op: u16 = @intCast(w & 0xFFFF);
        const wc: u16 = @intCast(w >> 16);
        if (op == spec.Opcode.TypeVector and wc == 4 and b.types_globals.items[i + 1] == vec4f_id) {
            try testing.expectEqual(f32_id, b.types_globals.items[i + 2]);
            try testing.expectEqual(@as(u32, 4), b.types_globals.items[i + 3]);
            return;
        }
        i += wc;
    }
    return error.TestExpectedEqual;
}

test "builder: type_matrix produces OpTypeMatrix" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const f32_id = try b.type_f32();
    const col_ty = try b.type_vector(f32_id, 4);
    const mat_id = try b.type_matrix(col_ty, 4);
    var i: usize = 0;
    while (i < b.types_globals.items.len) {
        const w = b.types_globals.items[i];
        const op: u16 = @intCast(w & 0xFFFF);
        const wc: u16 = @intCast(w >> 16);
        if (op == spec.Opcode.TypeMatrix and wc == 4 and b.types_globals.items[i + 1] == mat_id) {
            try testing.expectEqual(col_ty, b.types_globals.items[i + 2]);
            try testing.expectEqual(@as(u32, 4), b.types_globals.items[i + 3]);
            return;
        }
        i += wc;
    }
    return error.TestExpectedEqual;
}

test "builder: type_struct encodes member types" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const f32_id = try b.type_f32();
    const u32_id = try b.type_u32();
    const s_id = try b.type_struct(&.{ f32_id, u32_id });
    var i: usize = 0;
    while (i < b.types_globals.items.len) {
        const w = b.types_globals.items[i];
        const op: u16 = @intCast(w & 0xFFFF);
        const wc: u16 = @intCast(w >> 16);
        if (op == spec.Opcode.TypeStruct and wc == 4 and b.types_globals.items[i + 1] == s_id) {
            try testing.expectEqual(f32_id, b.types_globals.items[i + 2]);
            try testing.expectEqual(u32_id, b.types_globals.items[i + 3]);
            return;
        }
        i += wc;
    }
    return error.TestExpectedEqual;
}

test "builder: type_pointer encodes storage class" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const f32_id = try b.type_f32();
    const ptr_id = try b.type_pointer(spec.StorageClass.StorageBuffer, f32_id);
    var i: usize = 0;
    while (i < b.types_globals.items.len) {
        const w = b.types_globals.items[i];
        const op: u16 = @intCast(w & 0xFFFF);
        const wc: u16 = @intCast(w >> 16);
        if (op == spec.Opcode.TypePointer and wc == 4 and b.types_globals.items[i + 1] == ptr_id) {
            try testing.expectEqual(spec.StorageClass.StorageBuffer, b.types_globals.items[i + 2]);
            try testing.expectEqual(f32_id, b.types_globals.items[i + 3]);
            return;
        }
        i += wc;
    }
    return error.TestExpectedEqual;
}

test "builder: capability deduplication" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    try b.emit_capability(spec.Capability.Shader);
    try b.emit_capability(spec.Capability.Shader);
    try testing.expectEqual(@as(usize, 2), b.capabilities.items.len);
    try b.emit_capability(spec.Capability.ImageQuery);
    try testing.expectEqual(@as(usize, 4), b.capabilities.items.len);
}

test "builder: decoration encoding" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    try b.emit_binding_decoration(42, 7);
    try testing.expectEqual(@as(usize, 4), b.annotations.items.len);
    try testing.expectEqual(@as(u16, spec.Opcode.Decorate), @as(u16, @intCast(b.annotations.items[0] & 0xFFFF)));
    try testing.expectEqual(@as(u32, 42), b.annotations.items[1]);
    try testing.expectEqual(spec.Decoration.Binding, b.annotations.items[2]);
    try testing.expectEqual(@as(u32, 7), b.annotations.items[3]);
}

test "builder: descriptor set and builtin decorations" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    try b.emit_descriptor_set_decoration(10, 2);
    try b.emit_builtin_decoration(5, spec.Builtin.GlobalInvocationId);
    // First: DescriptorSet decoration
    try testing.expectEqual(spec.Decoration.DescriptorSet, b.annotations.items[2]);
    try testing.expectEqual(@as(u32, 2), b.annotations.items[3]);
    // Second: BuiltIn decoration
    try testing.expectEqual(spec.Decoration.BuiltIn, b.annotations.items[6]);
    try testing.expectEqual(spec.Builtin.GlobalInvocationId, b.annotations.items[7]);
}

test "builder: write_binary header and output-too-large" {
    var b = spirv_builder.Builder.init(alloc);
    defer b.deinit();
    const void_ty = try b.type_void();
    const fn_type = try b.type_function(void_ty, &.{});
    const fn_id = b.reserve_id();
    try b.emit_entry_point(fn_id, "main", &.{});
    try b.emit_execution_mode_local_size(fn_id, 1, 1, 1);
    try b.begin_function(void_ty, fn_id, fn_type);
    _ = try b.label();
    try b.append_function_inst(spec.Opcode.Return, &.{});
    try b.finish_function();

    var out: [4096]u8 = undefined;
    const len = try b.write_binary(&out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spec.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 0), read_u32_le(&out, 16));

    var tiny: [4]u8 = undefined;
    try testing.expectError(error.OutputTooLarge, b.write_binary(&tiny));
}

// ============================================================
// 3. Type emission via module API
// ============================================================

test "emit: f32 type appears as OpTypeFloat 32" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { buf[id.x] = 1.0; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    const inst = find_inst(binary, spec.Opcode.TypeFloat) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 32), inst_word(binary, inst, 2));
}

test "emit: vec4f appears as OpTypeVector(float, 4)" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = vec4f(1.0, 2.0, 3.0, 4.0); buf[id.x] = v.x;
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    var float_id: ?u32 = null;
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.TypeFloat and inst.word_count == 3 and inst_word(binary, inst, 2) == 32) {
            float_id = inst_word(binary, inst, 1);
            break;
        }
    }
    try testing.expect(float_id != null);
    it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.TypeVector and inst.word_count == 4)
            if (inst_word(binary, inst, 2) == float_id.? and inst_word(binary, inst, 3) == 4) return;
    }
    return error.TestExpectedEqual;
}

test "emit: mat4x4f appears as OpTypeMatrix with 4 columns" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var m: mat4x4<f32>; buf[id.x] = m[0].x;
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.TypeMatrix and inst.word_count == 4 and inst_word(binary, inst, 3) == 4) return;
    }
    return error.TestExpectedEqual;
}

// ============================================================
// 4. Storage class mapping
// ============================================================

test "emit: storage buffer uses StorageBuffer class" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { buf[id.x] = id.x; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.Variable and inst.word_count >= 4)
            if (inst_word(binary, inst, 3) == spec.StorageClass.StorageBuffer) return;
    }
    return error.TestExpectedEqual;
}

test "emit: uniform buffer uses Uniform class" {
    const source =
        \\struct P { x: f32 }
        \\@group(0) @binding(0) var<uniform> p: P;
        \\@group(0) @binding(1) var<storage, read_write> o: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { o[id.x] = p.x; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.Variable and inst.word_count >= 4)
            if (inst_word(binary, inst, 3) == spec.StorageClass.Uniform) return;
    }
    return error.TestExpectedEqual;
}

test "emit: workgroup variable uses Workgroup class" {
    const source =
        \\var<workgroup> shared: array<f32, 64>;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) lid: u32) {
        \\    shared[lid] = buf[lid]; workgroupBarrier(); buf[lid] = shared[63u - lid];
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    var it = iter_instructions(binary);
    while (it.next()) |inst| {
        if (inst.opcode == spec.Opcode.Variable and inst.word_count >= 4)
            if (inst_word(binary, inst, 3) == spec.StorageClass.Workgroup) return;
    }
    return error.TestExpectedEqual;
}

// ============================================================
// 5. Binding decoration preservation
// ============================================================

test "emit: group and binding numbers preserved" {
    const source =
        \\@group(2) @binding(5) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { buf[id.x] = id.x; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.DescriptorSet, 2) != null);
    try testing.expect(find_decoration_val(binary, spec.Decoration.Binding, 5) != null);
}

test "emit: multiple bindings in same group" {
    const source =
        \\@group(0) @binding(0) var<storage, read> a: array<f32>;
        \\@group(0) @binding(1) var<storage, read> b: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> c: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { c[id.x] = a[id.x] + b[id.x]; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.Binding, 0) != null);
    try testing.expect(find_decoration_val(binary, spec.Decoration.Binding, 1) != null);
    try testing.expect(find_decoration_val(binary, spec.Decoration.Binding, 2) != null);
}

test "emit: cross-group bindings preserved" {
    const source =
        \\@group(0) @binding(0) var<storage, read> a: array<f32>;
        \\@group(1) @binding(0) var<storage, read_write> b: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { b[id.x] = a[id.x]; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.DescriptorSet, 0) != null);
    try testing.expect(find_decoration_val(binary, spec.Decoration.DescriptorSet, 1) != null);
}

// ============================================================
// 6. Builtin variable mapping
// ============================================================

test "emit: global_invocation_id maps to BuiltIn 28" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) { buf[gid.x] = gid.x; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.BuiltIn, spec.Builtin.GlobalInvocationId) != null);
}

test "emit: local_invocation_index maps to BuiltIn 30" {
    const source =
        \\var<workgroup> s: array<u32, 64>;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) lid: u32) {
        \\    s[lid] = buf[lid]; workgroupBarrier(); buf[lid] = s[63u - lid];
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.BuiltIn, spec.Builtin.LocalInvocationIndex) != null);
}

test "emit: vertex_index maps to BuiltIn 42" {
    const source =
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.BuiltIn, spec.Builtin.VertexIndex) != null);
}

test "emit: position builtin maps to BuiltIn 0" {
    const source =
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.BuiltIn, spec.Builtin.Position) != null);
}

test "emit: instance_index maps to BuiltIn 43" {
    const source =
        \\@vertex
        \\fn main(@builtin(instance_index) iid: u32) -> @builtin(position) vec4f {
        \\    return vec4f(f32(iid), 0.0, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration_val(binary, spec.Decoration.BuiltIn, spec.Builtin.InstanceIndex) != null);
}

// ============================================================
// 7. Error handling
// ============================================================

test "emit: invalid WGSL source returns error" {
    const source = "this is not valid wgsl";
    var out: [MAX_SPIRV]u8 = undefined;
    try testing.expectError(error.UnexpectedToken, translateToSpirv(alloc, source, &out));
}

test "emit: shader with no entry point does not panic" {
    const source = "const x: f32 = 1.0;";
    var out: [MAX_SPIRV]u8 = undefined;
    _ = translateToSpirv(alloc, source, &out) catch return;
}

// ============================================================
// 8. Structural integrity
// ============================================================

test "emit: Function and FunctionEnd counts match" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { buf[id.x] = 1.0; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    const fn_count = count_insts(binary, spec.Opcode.Function);
    try testing.expect(fn_count > 0);
    try testing.expectEqual(fn_count, count_insts(binary, spec.Opcode.FunctionEnd));
}

test "emit: at least one Label per Function" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { buf[id.x] = id.x; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(count_insts(binary, spec.Opcode.Label) >= count_insts(binary, spec.Opcode.Function));
}

test "emit: binary size is word-aligned" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const len = try translateToSpirv(alloc, source, &out);
    try testing.expectEqual(@as(usize, 0), len % 4);
}

test "emit: GLSL.std.450 import and ExtInst appear for math builtins" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { buf[id.x] = sin(buf[id.x]); }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_inst(binary, spec.Opcode.ExtInstImport) != null);
    try testing.expect(find_inst(binary, spec.Opcode.ExtInst) != null);
}

test "emit: NonWritable decoration on read-only storage buffer" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) { out_buf[id.x] = data[id.x]; }
    ;
    var out: [MAX_SPIRV]u8 = undefined;
    const binary = try compile_spirv(source, &out);
    try testing.expect(find_decoration(binary, spec.Decoration.NonWritable) != null);
}
