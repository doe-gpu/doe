const std = @import("std");
const spec = @import("spirv_spec.zig");

pub const EmitError = spec.EmitError;
pub const WORD_BYTES = spec.WORD_BYTES;
pub const MAGIC = spec.MAGIC;
pub const Capability = spec.Capability;
pub const AddressingModel = spec.AddressingModel;
pub const MemoryModel = spec.MemoryModel;
pub const Dim = spec.Dim;
pub const ImageFormat = spec.ImageFormat;
pub const ImageOperandsMask = spec.ImageOperandsMask;
pub const ExecutionModel = spec.ExecutionModel;
pub const ExecutionMode = spec.ExecutionMode;
pub const Scope = spec.Scope;
pub const GroupOperation = spec.GroupOperation;
pub const MemorySemantics = spec.MemorySemantics;
pub const StorageClass = spec.StorageClass;
pub const Decoration = spec.Decoration;
pub const Builtin = spec.Builtin;
pub const FunctionControl = spec.FunctionControl;
pub const SelectionControl = spec.SelectionControl;
pub const LoopControl = spec.LoopControl;
pub const Opcode = spec.Opcode;

const VERSION_1_3: u32 = 0x00010300;
const GENERATOR_ID: u32 = 0;
const SCHEMA: u32 = 0;

const VecKey = struct { elem: u32, len: u32 };
const MatrixKey = struct { column_type: u32, columns: u32 };
const ArrayKey = struct { elem: u32, len_const: u32 };
const RuntimeArrayKey = struct { elem: u32 };
const ImageKey = struct {
    sampled_type: u32,
    dim: u32,
    depth: u32,
    arrayed: u32,
    multisampled: u32,
    sampled: u32,
    image_format: u32,
};
const PtrKey = struct { storage_class: u32, pointee: u32 };
const FnKey = struct { return_type: u32, params_start: u32, params_len: u32 };
const StructKey = struct { members_start: u32, members_len: u32 };
const ScalarConstKey = struct { ty: u32, bits: u32 };

pub const Builder = struct {
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    entry_point_fn: u32 = 0,
    entry_point_name: []const u8 = "main",
    glsl450_import: u32 = 0,

    params_scratch: std.ArrayListUnmanaged(u32) = .{},
    members_scratch: std.ArrayListUnmanaged(u32) = .{},

    capabilities: std.ArrayListUnmanaged(u32) = .{},
    ext_inst_imports: std.ArrayListUnmanaged(u32) = .{},
    memory_model: std.ArrayListUnmanaged(u32) = .{},
    entry_points: std.ArrayListUnmanaged(u32) = .{},
    execution_modes: std.ArrayListUnmanaged(u32) = .{},
    debug: std.ArrayListUnmanaged(u32) = .{},
    annotations: std.ArrayListUnmanaged(u32) = .{},
    types_globals: std.ArrayListUnmanaged(u32) = .{},
    functions: std.ArrayListUnmanaged(u32) = .{},

    vector_types: std.AutoHashMapUnmanaged(VecKey, u32) = .{},
    matrix_types: std.AutoHashMapUnmanaged(MatrixKey, u32) = .{},
    array_types: std.AutoHashMapUnmanaged(ArrayKey, u32) = .{},
    runtime_array_types: std.AutoHashMapUnmanaged(RuntimeArrayKey, u32) = .{},
    image_types: std.AutoHashMapUnmanaged(ImageKey, u32) = .{},
    pointer_types: std.AutoHashMapUnmanaged(PtrKey, u32) = .{},
    function_types: std.AutoHashMapUnmanaged(FnKey, u32) = .{},
    struct_types: std.AutoHashMapUnmanaged(StructKey, u32) = .{},
    scalar_constants: std.AutoHashMapUnmanaged(ScalarConstKey, u32) = .{},

    void_type: u32 = 0,
    bool_type: u32 = 0,
    u32_type: u32 = 0,
    i32_type: u32 = 0,
    f16_type: u32 = 0,
    f32_type: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        var builder = Builder{ .allocator = allocator };
        builder.emit_capability(Capability.Shader) catch {};
        builder.emit_memory_model() catch {};
        return builder;
    }

    pub fn deinit(self: *Builder) void {
        self.params_scratch.deinit(self.allocator);
        self.members_scratch.deinit(self.allocator);
        self.capabilities.deinit(self.allocator);
        self.ext_inst_imports.deinit(self.allocator);
        self.memory_model.deinit(self.allocator);
        self.entry_points.deinit(self.allocator);
        self.execution_modes.deinit(self.allocator);
        self.debug.deinit(self.allocator);
        self.annotations.deinit(self.allocator);
        self.types_globals.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.vector_types.deinit(self.allocator);
        self.matrix_types.deinit(self.allocator);
        self.array_types.deinit(self.allocator);
        self.runtime_array_types.deinit(self.allocator);
        self.image_types.deinit(self.allocator);
        self.pointer_types.deinit(self.allocator);
        self.function_types.deinit(self.allocator);
        self.struct_types.deinit(self.allocator);
        self.scalar_constants.deinit(self.allocator);
    }

    pub fn reserve_id(self: *Builder) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn append_inst(self: *Builder, list: *std.ArrayListUnmanaged(u32), opcode: u16, operands: []const u32) EmitError!void {
        const word_count: u32 = @intCast(operands.len + 1);
        try list.append(self.allocator, (@as(u32, word_count) << 16) | opcode);
        try list.appendSlice(self.allocator, operands);
    }

    pub fn append_function_inst(self: *Builder, opcode: u16, operands: []const u32) EmitError!void {
        try self.append_inst(&self.functions, opcode, operands);
    }

    pub fn emit_capability(self: *Builder, capability: u32) EmitError!void {
        var i: usize = 0;
        while (i < self.capabilities.items.len) : (i += 2) {
            if (self.capabilities.items[i + 1] == capability) return;
        }
        try self.append_inst(&self.capabilities, Opcode.Capability, &.{capability});
    }

    fn emit_memory_model(self: *Builder) EmitError!void {
        try self.append_inst(&self.memory_model, Opcode.OpMemoryModel, &.{ AddressingModel.Logical, MemoryModel.GLSL450 });
    }

    pub fn glsl450_import_id(self: *Builder) EmitError!u32 {
        if (self.glsl450_import != 0) return self.glsl450_import;
        const import_id = self.reserve_id();
        try self.ext_inst_imports.append(
            self.allocator,
            (@as(u32, @intCast(2 + string_word_len("GLSL.std.450"))) << 16) | Opcode.ExtInstImport,
        );
        try self.ext_inst_imports.append(self.allocator, import_id);
        try append_string_words(&self.ext_inst_imports, self.allocator, "GLSL.std.450");
        self.glsl450_import = import_id;
        return import_id;
    }

    pub fn emit_name(self: *Builder, target_id: u32, name: []const u8) EmitError!void {
        try self.debug.append(self.allocator, (@as(u32, @intCast(2 + string_word_len(name))) << 16) | Opcode.Name);
        try self.debug.append(self.allocator, target_id);
        try append_string_words(&self.debug, self.allocator, name);
    }

    pub fn emit_entry_point(self: *Builder, fn_id: u32, name: []const u8, interfaces: []const u32) EmitError!void {
        try self.emit_entry_point_with_model(ExecutionModel.GLCompute, fn_id, name, interfaces);
    }

    pub fn emit_entry_point_with_model(self: *Builder, execution_model: u32, fn_id: u32, name: []const u8, interfaces: []const u32) EmitError!void {
        self.entry_point_fn = fn_id;
        self.entry_point_name = name;
        try self.entry_points.append(self.allocator, (@as(u32, @intCast(3 + string_word_len(name) + interfaces.len)) << 16) | Opcode.EntryPoint);
        try self.entry_points.append(self.allocator, execution_model);
        try self.entry_points.append(self.allocator, fn_id);
        try append_string_words(&self.entry_points, self.allocator, name);
        try self.entry_points.appendSlice(self.allocator, interfaces);
    }

    pub fn emit_execution_mode_local_size(self: *Builder, fn_id: u32, x: u32, y: u32, z: u32) EmitError!void {
        try self.append_inst(&self.execution_modes, Opcode.ExecutionMode, &.{ fn_id, ExecutionMode.LocalSize, x, y, z });
    }

    pub fn emit_execution_mode(self: *Builder, fn_id: u32, mode: u32) EmitError!void {
        try self.append_inst(&self.execution_modes, Opcode.ExecutionMode, &.{ fn_id, mode });
    }

    pub fn type_void(self: *Builder) EmitError!u32 {
        if (self.void_type != 0) return self.void_type;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeVoid, &.{id});
        self.void_type = id;
        return id;
    }

    pub fn type_bool(self: *Builder) EmitError!u32 {
        if (self.bool_type != 0) return self.bool_type;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeBool, &.{id});
        self.bool_type = id;
        return id;
    }

    pub fn type_u32(self: *Builder) EmitError!u32 {
        if (self.u32_type != 0) return self.u32_type;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeInt, &.{ id, 32, 0 });
        self.u32_type = id;
        return id;
    }

    pub fn type_i32(self: *Builder) EmitError!u32 {
        if (self.i32_type != 0) return self.i32_type;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeInt, &.{ id, 32, 1 });
        self.i32_type = id;
        return id;
    }

    pub fn type_f16(self: *Builder) EmitError!u32 {
        if (self.f16_type != 0) return self.f16_type;
        try self.emit_capability(Capability.Float16);
        try self.emit_capability(Capability.StorageBuffer16BitAccess);
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeFloat, &.{ id, 16 });
        self.f16_type = id;
        return id;
    }

    pub fn type_f32(self: *Builder) EmitError!u32 {
        if (self.f32_type != 0) return self.f32_type;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeFloat, &.{ id, 32 });
        self.f32_type = id;
        return id;
    }

    pub fn type_vector(self: *Builder, elem_type: u32, len: u32) EmitError!u32 {
        const key = VecKey{ .elem = elem_type, .len = len };
        if (self.vector_types.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeVector, &.{ id, elem_type, len });
        try self.vector_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_matrix(self: *Builder, column_type: u32, columns: u32) EmitError!u32 {
        const key = MatrixKey{ .column_type = column_type, .columns = columns };
        if (self.matrix_types.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeMatrix, &.{ id, column_type, columns });
        try self.matrix_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_array(self: *Builder, elem_type: u32, len_const_id: u32) EmitError!u32 {
        const key = ArrayKey{ .elem = elem_type, .len_const = len_const_id };
        if (self.array_types.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeArray, &.{ id, elem_type, len_const_id });
        try self.array_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_runtime_array(self: *Builder, elem_type: u32) EmitError!u32 {
        const key = RuntimeArrayKey{ .elem = elem_type };
        if (self.runtime_array_types.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypeRuntimeArray, &.{ id, elem_type });
        try self.runtime_array_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_image(
        self: *Builder,
        sampled_type: u32,
        dim: u32,
        depth: u32,
        arrayed: u32,
        multisampled: u32,
        sampled: u32,
        image_format: u32,
    ) EmitError!u32 {
        const key = ImageKey{
            .sampled_type = sampled_type,
            .dim = dim,
            .depth = depth,
            .arrayed = arrayed,
            .multisampled = multisampled,
            .sampled = sampled,
            .image_format = image_format,
        };
        if (self.image_types.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(
            &self.types_globals,
            Opcode.TypeImage,
            &.{ id, sampled_type, dim, depth, arrayed, multisampled, sampled, image_format },
        );
        try self.image_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_struct(self: *Builder, member_types: []const u32) EmitError!u32 {
        const members_start: u32 = @intCast(self.members_scratch.items.len);
        try self.members_scratch.appendSlice(self.allocator, member_types);
        const key = StructKey{ .members_start = members_start, .members_len = @intCast(member_types.len) };
        if (self.find_struct_type(member_types)) |id| return id;
        const id = self.reserve_id();
        try self.types_globals.append(self.allocator, (@as(u32, @intCast(2 + member_types.len)) << 16) | Opcode.TypeStruct);
        try self.types_globals.append(self.allocator, id);
        try self.types_globals.appendSlice(self.allocator, member_types);
        try self.struct_types.put(self.allocator, key, id);
        return id;
    }

    /// Like `type_struct` but always allocates a fresh OpTypeStruct id even when
    /// an existing struct with identical member types is already known. Use for
    /// storage-buffer block wrappers where the RADV optimizer produces better
    /// ISA when each buffer binding has its own distinct struct type (matches
    /// Tint's emission shape). This improves driver alias analysis: same-type
    /// bindings would otherwise be treated as potentially aliased under the
    /// shared-struct shape.
    pub fn type_struct_fresh(self: *Builder, member_types: []const u32) EmitError!u32 {
        const members_start: u32 = @intCast(self.members_scratch.items.len);
        try self.members_scratch.appendSlice(self.allocator, member_types);
        const key = StructKey{ .members_start = members_start, .members_len = @intCast(member_types.len) };
        const id = self.reserve_id();
        try self.types_globals.append(self.allocator, (@as(u32, @intCast(2 + member_types.len)) << 16) | Opcode.TypeStruct);
        try self.types_globals.append(self.allocator, id);
        try self.types_globals.appendSlice(self.allocator, member_types);
        // Record the new id under the same key (overwriting any prior dedup
        // entry); callers who opt into fresh emission have already accepted
        // that subsequent `type_struct` calls will not reuse the same id.
        try self.struct_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_pointer(self: *Builder, storage_class: u32, pointee_type: u32) EmitError!u32 {
        const key = PtrKey{ .storage_class = storage_class, .pointee = pointee_type };
        if (self.pointer_types.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.TypePointer, &.{ id, storage_class, pointee_type });
        try self.pointer_types.put(self.allocator, key, id);
        return id;
    }

    pub fn type_function(self: *Builder, return_type: u32, params: []const u32) EmitError!u32 {
        const params_start: u32 = @intCast(self.params_scratch.items.len);
        try self.params_scratch.appendSlice(self.allocator, params);
        const key = FnKey{ .return_type = return_type, .params_start = params_start, .params_len = @intCast(params.len) };
        if (self.find_function_type(return_type, params)) |id| return id;
        const id = self.reserve_id();
        try self.types_globals.append(self.allocator, (@as(u32, @intCast(3 + params.len)) << 16) | Opcode.TypeFunction);
        try self.types_globals.append(self.allocator, id);
        try self.types_globals.append(self.allocator, return_type);
        try self.types_globals.appendSlice(self.allocator, params);
        try self.function_types.put(self.allocator, key, id);
        return id;
    }

    fn find_function_type(self: *Builder, return_type: u32, params: []const u32) ?u32 {
        var it = self.function_types.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.return_type != return_type or key.params_len != params.len) continue;
            const slice = self.params_scratch.items[key.params_start .. key.params_start + key.params_len];
            if (std.mem.eql(u32, slice, params)) return entry.value_ptr.*;
        }
        return null;
    }

    fn find_struct_type(self: *Builder, member_types: []const u32) ?u32 {
        var it = self.struct_types.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.members_len != member_types.len) continue;
            const slice = self.members_scratch.items[key.members_start .. key.members_start + key.members_len];
            if (std.mem.eql(u32, slice, member_types)) return entry.value_ptr.*;
        }
        return null;
    }

    pub fn const_bool(self: *Builder, value: bool) EmitError!u32 {
        const ty = try self.type_bool();
        const key = ScalarConstKey{ .ty = ty, .bits = if (value) 1 else 0 };
        if (self.scalar_constants.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, if (value) Opcode.ConstantTrue else Opcode.ConstantFalse, &.{ ty, id });
        try self.scalar_constants.put(self.allocator, key, id);
        return id;
    }

    pub fn const_u32(self: *Builder, value: u32) EmitError!u32 {
        const ty = try self.type_u32();
        return try self.scalar_constant(ty, value);
    }

    pub fn const_i32_bits(self: *Builder, bits: u32) EmitError!u32 {
        const ty = try self.type_i32();
        return try self.scalar_constant(ty, bits);
    }

    pub fn const_f32_bits(self: *Builder, bits: u32) EmitError!u32 {
        const ty = try self.type_f32();
        return try self.scalar_constant(ty, bits);
    }

    pub fn const_f16_bits(self: *Builder, bits: u16) EmitError!u32 {
        const ty = try self.type_f16();
        return try self.scalar_constant(ty, bits);
    }

    fn scalar_constant(self: *Builder, ty: u32, bits: u32) EmitError!u32 {
        const key = ScalarConstKey{ .ty = ty, .bits = bits };
        if (self.scalar_constants.get(key)) |id| return id;
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.Constant, &.{ ty, id, bits });
        try self.scalar_constants.put(self.allocator, key, id);
        return id;
    }

    pub fn variable_global(self: *Builder, ptr_type: u32, storage_class: u32) EmitError!u32 {
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.Variable, &.{ ptr_type, id, storage_class });
        return id;
    }

    pub fn variable_global_init(self: *Builder, ptr_type: u32, storage_class: u32, initializer: u32) EmitError!u32 {
        const id = self.reserve_id();
        try self.append_inst(&self.types_globals, Opcode.Variable, &.{ ptr_type, id, storage_class, initializer });
        return id;
    }

    pub fn variable_function(self: *Builder, ptr_type: u32) EmitError!u32 {
        const id = self.reserve_id();
        try self.append_function_inst(Opcode.Variable, &.{ ptr_type, id, StorageClass.Function });
        return id;
    }

    pub fn emit_builtin_decoration(self: *Builder, target_id: u32, builtin: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.BuiltIn, builtin });
    }

    pub fn emit_block_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Block });
    }

    pub fn emit_array_stride_decoration(self: *Builder, target_id: u32, stride: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.ArrayStride, stride });
    }

    pub fn emit_descriptor_set_decoration(self: *Builder, target_id: u32, descriptor_set: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.DescriptorSet, descriptor_set });
    }

    pub fn emit_binding_decoration(self: *Builder, target_id: u32, binding: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Binding, binding });
    }

    pub fn emit_non_writable_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.NonWritable });
    }

    pub fn emit_non_readable_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.NonReadable });
    }

    pub fn emit_location_decoration(self: *Builder, target_id: u32, location: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Location, location });
    }

    pub fn emit_flat_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Flat });
    }

    pub fn emit_noperspective_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.NoPerspective });
    }

    pub fn emit_centroid_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Centroid });
    }

    pub fn emit_sample_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Sample });
    }

    pub fn emit_index_decoration(self: *Builder, target_id: u32, index: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Index, index });
    }

    pub fn emit_invariant_decoration(self: *Builder, target_id: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.Decorate, &.{ target_id, Decoration.Invariant });
    }

    pub fn emit_member_offset_decoration(self: *Builder, target_id: u32, member_index: u32, offset: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.MemberDecorate, &.{ target_id, member_index, Decoration.Offset, offset });
    }

    pub fn emit_member_col_major_decoration(self: *Builder, target_id: u32, member_index: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.MemberDecorate, &.{ target_id, member_index, Decoration.ColMajor });
    }

    pub fn emit_member_matrix_stride_decoration(self: *Builder, target_id: u32, member_index: u32, stride: u32) EmitError!void {
        try self.append_inst(&self.annotations, Opcode.MemberDecorate, &.{ target_id, member_index, Decoration.MatrixStride, stride });
    }

    pub fn begin_function(self: *Builder, result_type: u32, fn_id: u32, function_type: u32) EmitError!void {
        try self.append_function_inst(Opcode.Function, &.{ result_type, fn_id, FunctionControl.None, function_type });
    }

    pub fn function_parameter(self: *Builder, param_type: u32) EmitError!u32 {
        const id = self.reserve_id();
        try self.append_function_inst(Opcode.FunctionParameter, &.{ param_type, id });
        return id;
    }

    pub fn label(self: *Builder) EmitError!u32 {
        const id = self.reserve_id();
        try self.append_function_inst(Opcode.Label, &.{id});
        return id;
    }

    pub fn finish_function(self: *Builder) EmitError!void {
        try self.append_function_inst(Opcode.FunctionEnd, &.{});
    }

    pub fn write_binary(self: *Builder, out: []u8) EmitError!usize {
        const total_words = 5 +
            self.capabilities.items.len +
            self.ext_inst_imports.items.len +
            self.memory_model.items.len +
            self.entry_points.items.len +
            self.execution_modes.items.len +
            self.debug.items.len +
            self.annotations.items.len +
            self.types_globals.items.len +
            self.functions.items.len;
        const total_bytes = total_words * WORD_BYTES;
        if (total_bytes > out.len) return error.OutputTooLarge;

        var cursor: usize = 0;
        const header = [_]u32{ MAGIC, VERSION_1_3, GENERATOR_ID, self.next_id, SCHEMA };
        cursor += write_words(out[cursor..], &header);
        cursor += write_words(out[cursor..], self.capabilities.items);
        cursor += write_words(out[cursor..], self.ext_inst_imports.items);
        cursor += write_words(out[cursor..], self.memory_model.items);
        cursor += write_words(out[cursor..], self.entry_points.items);
        cursor += write_words(out[cursor..], self.execution_modes.items);
        cursor += write_words(out[cursor..], self.debug.items);
        cursor += write_words(out[cursor..], self.annotations.items);
        cursor += write_words(out[cursor..], self.types_globals.items);
        cursor += write_words(out[cursor..], self.functions.items);
        return cursor;
    }
};

fn string_word_len(text: []const u8) usize {
    return (text.len + 1 + 3) / 4;
}

fn append_string_words(list: *std.ArrayListUnmanaged(u32), allocator: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 4) {
        var word: u32 = 0;
        var j: usize = 0;
        while (j < 4 and i + j < text.len) : (j += 1) {
            word |= @as(u32, text[i + j]) << @intCast(j * 8);
        }
        try list.append(allocator, word);
    }
    if ((text.len % 4) == 0) {
        try list.append(allocator, 0);
    } else {
        const last_index = list.items.len - 1;
        list.items[last_index] &= ~(@as(u32, 0xFF) << @intCast((text.len % 4) * 8));
    }
}

fn write_words(out: []u8, words: []const u32) usize {
    for (words, 0..) |word, i| {
        std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(out[i * 4 .. i * 4 + 4].ptr)), word, .little);
    }
    return words.len * WORD_BYTES;
}
