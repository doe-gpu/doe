const std = @import("std");
const ir = @import("../../ir/ir.zig");
const spirv = @import("spirv_builder.zig");
const emit_spirv_shared = @import("emit_spirv_shared.zig");
const emit_spirv_fn = @import("emit_spirv_fn.zig");
const emit_spirv_stages = @import("emit_spirv_stages.zig");

pub const EmitError = emit_spirv_shared.EmitError;

pub const MAX_OUTPUT: usize = 256 * 1024;

pub fn emit(module: *const ir.Module, out: []u8) EmitError!usize {
    return emitImpl(module, null, out);
}

/// Emit SPIR-V for a single shader stage. Globals and helper functions are
/// emitted in full; only the specified stage's entry wrapper is included.
pub fn emitForStage(module: *const ir.Module, stage: ir.ShaderStage, out: []u8) EmitError!usize {
    return emitImpl(module, stage, out);
}

fn emitImpl(module: *const ir.Module, stage_filter: ?ir.ShaderStage, out: []u8) EmitError!usize {
    var emitter = try Emitter.init(module);
    defer emitter.deinit();
    try emitter.emit_module_impl(stage_filter);
    return emitter.builder.write_binary(out);
}

pub const Emitter = struct {
    module: *const ir.Module,
    alloc: std.mem.Allocator,
    builder: spirv.Builder,
    type_ids: []u32,
    global_ids: []u32,
    global_buffer_wrapped: []bool,
    /// Parallel to `global_ids`. For WGSL `const` globals with a compile-time
    /// literal initializer, holds the SPIR-V constant id directly. Zero means
    /// "not a lowered const global".
    global_constant_ids: []u32,
    function_ids: []u32,
    entry_wrapper_ids: []u32,
    decorated_array_types: std.AutoHashMapUnmanaged(u32, void) = .{},
    decorated_block_types: std.AutoHashMapUnmanaged(u32, void) = .{},
    decorated_struct_types: std.AutoHashMapUnmanaged(u32, void) = .{},
    sampled_image_types: std.AutoHashMapUnmanaged(u32, u32) = .{},
    sampler_type: u32 = 0,

    fn init(module: *const ir.Module) EmitError!Emitter {
        const alloc = module.allocator;
        const type_ids = try alloc.alloc(u32, module.types.items.items.len);
        errdefer alloc.free(type_ids);
        @memset(type_ids, 0);

        const global_ids = try alloc.alloc(u32, module.globals.items.len);
        errdefer alloc.free(global_ids);
        @memset(global_ids, 0);

        const global_buffer_wrapped = try alloc.alloc(bool, module.globals.items.len);
        errdefer alloc.free(global_buffer_wrapped);
        @memset(global_buffer_wrapped, false);

        const global_constant_ids = try alloc.alloc(u32, module.globals.items.len);
        errdefer alloc.free(global_constant_ids);
        @memset(global_constant_ids, 0);

        const function_ids = try alloc.alloc(u32, module.functions.items.len);
        errdefer alloc.free(function_ids);
        @memset(function_ids, 0);

        const entry_wrapper_ids = try alloc.alloc(u32, module.functions.items.len);
        errdefer alloc.free(entry_wrapper_ids);
        @memset(entry_wrapper_ids, 0);

        return .{
            .module = module,
            .alloc = alloc,
            .builder = spirv.Builder.init(alloc),
            .type_ids = type_ids,
            .global_ids = global_ids,
            .global_buffer_wrapped = global_buffer_wrapped,
            .global_constant_ids = global_constant_ids,
            .function_ids = function_ids,
            .entry_wrapper_ids = entry_wrapper_ids,
        };
    }

    fn deinit(self: *Emitter) void {
        self.sampled_image_types.deinit(self.alloc);
        self.decorated_struct_types.deinit(self.alloc);
        self.decorated_block_types.deinit(self.alloc);
        self.decorated_array_types.deinit(self.alloc);
        self.alloc.free(self.entry_wrapper_ids);
        self.alloc.free(self.function_ids);
        self.alloc.free(self.global_constant_ids);
        self.alloc.free(self.global_buffer_wrapped);
        self.alloc.free(self.global_ids);
        self.alloc.free(self.type_ids);
        self.builder.deinit();
    }

    /// Emit globals, functions, and entry point wrappers. When stage_filter is
    /// non-null, only entry points matching that stage are wrapped.
    fn emit_module_impl(self: *Emitter, stage_filter: ?ir.ShaderStage) EmitError!void {
        for (self.function_ids) |*slot| slot.* = self.builder.reserve_id();
        for (self.module.entry_points.items) |entry| {
            self.entry_wrapper_ids[entry.function] = self.builder.reserve_id();
        }

        try self.emit_globals();

        var function_index: usize = 0;
        while (function_index < self.module.functions.items.len) : (function_index += 1) {
            try self.emit_function(@intCast(function_index));
        }

        for (self.module.entry_points.items) |entry| {
            if (stage_filter) |filter| {
                if (entry.stage != filter) continue;
            }
            switch (entry.stage) {
                .compute => try self.emit_compute_entry_wrapper(entry),
                .vertex, .fragment => try emit_spirv_stages.emit_stage_entry_wrapper(self, entry),
            }
        }
    }

    fn emit_globals(self: *Emitter) EmitError!void {
        for (self.module.globals.items, 0..) |global, index| {
            if (global.class == .input or global.class == .output) {
                self.global_ids[index] = try emit_spirv_stages.emit_io_global(self, global);
                continue;
            }

            if (self.is_bound_buffer_global(global)) {
                self.global_ids[index] = try self.emit_bound_buffer_global(global);
                self.global_buffer_wrapped[index] = true;
                continue;
            }
            if (self.is_bound_handle_global(global)) {
                self.global_ids[index] = try self.emit_bound_handle_global(global);
                continue;
            }
            if (global.binding != null) return error.UnsupportedConstruct;

            if (global.class == .const_) {
                if (global.initializer) |initializer| {
                    const constant_id = try self.lower_constant(initializer, global.ty);
                    self.global_constant_ids[index] = constant_id;
                    self.global_ids[index] = constant_id;
                    continue;
                }
            }

            const value_type = try self.lower_type(global.ty);
            const storage_class = try self.global_storage_class(global);
            const ptr_type = try self.builder.type_pointer(storage_class, value_type);

            const var_id = if (global.initializer) |initializer|
                try self.builder.variable_global_init(ptr_type, storage_class, try self.lower_constant(initializer, global.ty))
            else
                try self.builder.variable_global(ptr_type, storage_class);

            try self.builder.emit_name(var_id, global.name);
            self.global_ids[index] = var_id;
        }
    }

    fn emit_bound_handle_global(self: *Emitter, global: ir.Global) EmitError!u32 {
        const binding = global.binding orelse return error.InvalidIr;
        if (global.initializer != null) return error.UnsupportedConstruct;

        const storage_class = try self.global_storage_class(global);
        if (storage_class != spirv.StorageClass.UniformConstant) return error.InvalidIr;

        const value_type = try self.lower_type(global.ty);
        const ptr_type = try self.builder.type_pointer(storage_class, value_type);
        const var_id = try self.builder.variable_global(ptr_type, storage_class);
        try self.builder.emit_name(var_id, global.name);
        try self.builder.emit_descriptor_set_decoration(var_id, binding.group);
        try self.builder.emit_binding_decoration(var_id, binding.binding);

        switch (self.module.types.get(global.ty)) {
            .storage_texture_2d => |storage_tex| switch (storage_tex.access) {
                .read => try self.builder.emit_non_writable_decoration(var_id),
                .write => try self.builder.emit_non_readable_decoration(var_id),
                .read_write => {},
            },
            else => {},
        }

        return var_id;
    }

    fn emit_bound_buffer_global(self: *Emitter, global: ir.Global) EmitError!u32 {
        const binding = global.binding orelse return error.InvalidIr;
        if (global.initializer != null) return error.UnsupportedConstruct;
        const addr_space = global.addr_space orelse return error.InvalidIr;
        if (addr_space != .uniform and addr_space != .storage) return error.UnsupportedConstruct;

        _ = try self.decorate_memory_type(global.ty, addr_space);
        const block_member_type = try self.lower_type(global.ty);
        // Emit a distinct block struct per storage-buffer binding so the
        // driver's alias analysis does not treat same-type bindings as
        // potentially aliased.
        const block_type = try self.builder.type_struct_fresh(&.{block_member_type});
        try self.builder.emit_block_decoration(block_type);
        try self.builder.emit_member_offset_decoration(block_type, 0, 0);

        const storage_class = try self.global_storage_class(global);
        const ptr_type = try self.builder.type_pointer(storage_class, block_type);
        const var_id = try self.builder.variable_global(ptr_type, storage_class);
        try self.builder.emit_name(var_id, global.name);
        try self.builder.emit_descriptor_set_decoration(var_id, binding.group);
        try self.builder.emit_binding_decoration(var_id, binding.binding);
        if (addr_space == .storage and (global.access orelse .read_write) == .read) {
            try self.builder.emit_non_writable_decoration(var_id);
        }
        return var_id;
    }

    pub fn emit_function(self: *Emitter, function_index: ir.FunctionId) EmitError!void {
        const function = &self.module.functions.items[function_index];
        const fn_id = self.function_ids[function_index];
        const return_type = try self.lower_type(function.return_type);

        var param_types = std.ArrayListUnmanaged(u32){};
        defer param_types.deinit(self.alloc);
        for (function.params.items) |param| {
            try param_types.append(self.alloc, try self.lower_param_type(param.ty));
        }

        const fn_type = try self.builder.type_function(return_type, param_types.items);
        try self.builder.emit_name(fn_id, function.name);
        try self.builder.begin_function(return_type, fn_id, fn_type);

        const param_value_ids = try self.alloc.alloc(u32, function.params.items.len);
        defer self.alloc.free(param_value_ids);
        for (param_value_ids, function.params.items) |*slot, param| {
            slot.* = try self.builder.function_parameter(try self.lower_param_type(param.ty));
        }

        _ = try self.builder.label();

        var state = try emit_spirv_fn.FunctionState(Emitter).init(self, function_index);
        defer state.deinit();

        for (function.params.items, 0..) |param, param_index| {
            switch (self.module.types.get(param.ty)) {
                .ref => {
                    // Pointer parameters are already pointers; use them directly.
                    state.param_ptr_ids[param_index] = param_value_ids[param_index];
                    try self.builder.emit_name(param_value_ids[param_index], param.name);
                },
                else => {
                    if (state.is_ssa_promotable_param(@intCast(param_index))) {
                        // SSA-promoted: skip the Function OpVariable + OpStore
                        // and cache the raw param id. Reads go through the
                        // param_value_ids short-circuit in emit_load_from_ref.
                        state.param_value_ids[param_index] = param_value_ids[param_index];
                        try self.builder.emit_name(param_value_ids[param_index], param.name);
                    } else {
                        const ptr_type = try self.builder.type_pointer(spirv.StorageClass.Function, try self.lower_type(param.ty));
                        const ptr_id = try self.builder.variable_function(ptr_type);
                        state.param_ptr_ids[param_index] = ptr_id;
                        try self.builder.emit_name(ptr_id, param.name);
                    }
                },
            }
        }

        for (function.locals.items, 0..) |local, local_index| {
            if (state.is_ssa_promotable_local(@intCast(local_index))) continue;
            const ptr_type = try self.builder.type_pointer(spirv.StorageClass.Function, try self.lower_type(local.ty));
            const ptr_id = try self.builder.variable_function(ptr_type);
            state.local_ptr_ids[local_index] = ptr_id;
            try self.builder.emit_name(ptr_id, local.name);
        }

        for (function.params.items, 0..) |param, param_index| {
            switch (self.module.types.get(param.ty)) {
                .ref => {},
                else => {
                    if (state.param_ptr_ids[param_index] != 0) {
                        try self.emit_store(state.param_ptr_ids[param_index], param_value_ids[param_index]);
                    }
                },
            }
        }

        const terminated = try state.emit_stmt(function.root_stmt);
        if (!terminated) {
            if (ir.is_scalar(&self.module.types, function.return_type, .void)) {
                try self.builder.append_function_inst(spirv.Opcode.Return, &.{});
            } else {
                return error.InvalidIr;
            }
        }

        try self.builder.finish_function();
    }

    fn emit_compute_entry_wrapper(self: *Emitter, entry: ir.EntryPoint) EmitError!void {
        const function = &self.module.functions.items[entry.function];
        if (!ir.is_scalar(&self.module.types, function.return_type, .void)) return error.UnsupportedConstruct;

        const wrapper_id = self.entry_wrapper_ids[entry.function];
        const void_type = try self.builder.type_void();
        const fn_type = try self.builder.type_function(void_type, &.{});
        const wrapper_name = try std.fmt.allocPrint(self.alloc, "{s}_entry", .{function.name});
        defer self.alloc.free(wrapper_name);

        var interface_ids = std.ArrayListUnmanaged(u32){};
        defer interface_ids.deinit(self.alloc);

        for (function.params.items) |param| {
            const io_attr = param.io orelse return error.UnsupportedConstruct;
            if (io_attr.builtin == .none) return error.UnsupportedConstruct;
            if (io_attr.builtin == .subgroup_size or io_attr.builtin == .subgroup_invocation_id) {
                try self.builder.emit_capability(spirv.Capability.GroupNonUniform);
            }
            const value_type = try self.lower_type(param.ty);
            const ptr_type = try self.builder.type_pointer(spirv.StorageClass.Input, value_type);
            const var_id = try self.builder.variable_global(ptr_type, spirv.StorageClass.Input);
            try self.builder.emit_name(var_id, param.name);
            try self.builder.emit_builtin_decoration(var_id, try emit_spirv_shared.builtin_to_spirv(io_attr.builtin));
            try interface_ids.append(self.alloc, var_id);
        }
        const param_interface_len = interface_ids.items.len;

        for (self.module.globals.items, 0..) |global, index| {
            if (global.class != .input and global.class != .output) continue;
            const global_id = self.global_ids[index];
            if (global_id == 0) return error.InvalidIr;
            try interface_ids.append(self.alloc, global_id);
        }

        try self.builder.emit_name(wrapper_id, wrapper_name);
        try self.builder.emit_entry_point(wrapper_id, function.name, interface_ids.items);
        try self.builder.emit_execution_mode_local_size(wrapper_id, entry.workgroup_size[0], entry.workgroup_size[1], entry.workgroup_size[2]);

        try self.builder.begin_function(void_type, wrapper_id, fn_type);
        _ = try self.builder.label();
        var call_args = std.ArrayListUnmanaged(u32){};
        defer call_args.deinit(self.alloc);
        for (function.params.items, interface_ids.items[0..param_interface_len]) |param, interface_id| {
            try call_args.append(self.alloc, try self.emit_function_load(try self.lower_type(param.ty), interface_id));
        }
        _ = try self.emit_function_call(void_type, self.function_ids[entry.function], call_args.items);
        try self.builder.append_function_inst(spirv.Opcode.Return, &.{});
        try self.builder.finish_function();
    }

    pub fn lower_type(self: *Emitter, ty: ir.TypeId) EmitError!u32 {
        if (ty == ir.INVALID_TYPE) return error.InvalidIr;
        if (self.type_ids[ty] != 0) return self.type_ids[ty];

        const lowered = switch (self.module.types.get(ty)) {
            .scalar => |scalar| switch (scalar) {
                .void => try self.builder.type_void(),
                .bool => try self.builder.type_bool(),
                .i32, .abstract_int => try self.builder.type_i32(),
                .u32 => try self.builder.type_u32(),
                .f16 => try self.builder.type_f16(),
                .f32, .abstract_float => try self.builder.type_f32(),
            },
            .vector => |vec| try self.builder.type_vector(try self.lower_type(vec.elem), vec.len),
            .matrix => |mat| try self.builder.type_matrix(
                try self.builder.type_vector(try self.lower_type(mat.elem), mat.rows),
                mat.columns,
            ),
            .array => |arr| if (arr.len) |len|
                try self.builder.type_array(try self.lower_type(arr.elem), try self.builder.const_u32(len))
            else
                try self.builder.type_runtime_array(try self.lower_type(arr.elem)),
            .texture_1d => |sample_ty| try self.lower_sampled_texture_type(sample_ty, spirv.Dim._1D, 0, 0),
            .texture_2d => |sample_ty| try self.lower_sampled_texture_type(sample_ty, spirv.Dim._2D, 0, 0),
            .storage_texture_2d => |storage_tex| blk: {
                const sampled_type = try storage_texture_sampled_type(self, storage_tex.format);
                const image_format = storage_texture_format_to_spirv(storage_tex.format);
                if (image_format != spirv.ImageFormat.Rgba8) {
                    try self.builder.emit_capability(spirv.Capability.StorageImageExtendedFormats);
                }
                break :blk try self.builder.type_image(sampled_type, spirv.Dim._2D, 0, 0, 0, 2, image_format);
            },
            .texture_3d => |sample_ty| try self.lower_sampled_texture_type(sample_ty, spirv.Dim._3D, 0, 0),
            .texture_2d_array => |sample_ty| try self.lower_sampled_texture_type(sample_ty, spirv.Dim._2D, 1, 0),
            .texture_cube => |sample_ty| try self.lower_sampled_texture_type(sample_ty, spirv.Dim.Cube, 0, 0),
            .texture_multisampled_2d => |sample_ty| try self.lower_sampled_texture_type(sample_ty, spirv.Dim._2D, 0, 1),
            .texture_depth_2d => blk: {
                break :blk try self.builder.type_image(
                    try self.builder.type_f32(),
                    spirv.Dim._2D,
                    1,
                    0,
                    0,
                    1,
                    spirv.ImageFormat.Unknown,
                );
            },
            .texture_depth_cube => blk: {
                break :blk try self.builder.type_image(
                    try self.builder.type_f32(),
                    spirv.Dim.Cube,
                    1,
                    0,
                    0,
                    1,
                    spirv.ImageFormat.Unknown,
                );
            },
            .sampler, .sampler_comparison => try self.lower_sampler_type(),
            .struct_ => |struct_id| blk: {
                const struct_def = self.module.structs.items[struct_id];
                var member_types = std.ArrayListUnmanaged(u32){};
                defer member_types.deinit(self.alloc);
                for (struct_def.fields.items) |field| {
                    try member_types.append(self.alloc, try self.lower_type(field.ty));
                }
                break :blk try self.builder.type_struct(member_types.items);
            },
            .atomic => |inner| try self.lower_type(inner),
            .ref => |ref_ty| try self.lower_type(ref_ty.elem),
        };

        self.type_ids[ty] = lowered;
        return lowered;
    }

    /// Lower a parameter type. For ref types, produces OpTypePointer with the
    /// correct storage class; for all other types, delegates to lower_type.
    pub fn lower_param_type(self: *Emitter, ty: ir.TypeId) EmitError!u32 {
        return switch (self.module.types.get(ty)) {
            .ref => |ref_ty| try self.builder.type_pointer(
                emit_spirv_shared.addr_space_to_storage_class(ref_ty.addr_space),
                try self.lower_type(ref_ty.elem),
            ),
            else => try self.lower_type(ty),
        };
    }

    fn lower_sampled_texture_type(self: *Emitter, sample_ty: ir.TypeId, dim: u32, arrayed: u32, ms: u32) EmitError!u32 {
        switch (self.module.types.get(sample_ty)) {
            .scalar => |scalar| if (scalar != .f32) return error.UnsupportedConstruct,
            else => return error.UnsupportedConstruct,
        }
        return try self.builder.type_image(try self.lower_type(sample_ty), dim, 0, arrayed, ms, 1, spirv.ImageFormat.Unknown);
    }

    pub fn lower_sampler_type(self: *Emitter) EmitError!u32 {
        if (self.sampler_type != 0) return self.sampler_type;
        const id = self.builder.reserve_id();
        try append_types_globals_inst(&self.builder, self.alloc, TextureOpcode.TypeSampler, &.{id});
        self.sampler_type = id;
        return id;
    }

    pub fn lower_sampled_image_type(self: *Emitter, image_type: u32) EmitError!u32 {
        if (self.sampled_image_types.get(image_type)) |id| return id;
        const id = self.builder.reserve_id();
        try append_types_globals_inst(&self.builder, self.alloc, TextureOpcode.TypeSampledImage, &.{ id, image_type });
        try self.sampled_image_types.put(self.alloc, image_type, id);
        return id;
    }

    pub fn lower_constant(self: *Emitter, constant: ir.ConstantValue, ty: ir.TypeId) EmitError!u32 {
        switch (constant) {
            .bool => |value| return try self.builder.const_bool(value),
            .int => |value| switch (self.module.types.get(ty)) {
                .scalar => |scalar| switch (scalar) {
                    .u32 => return try self.builder.const_u32(@truncate(value)),
                    .i32, .abstract_int => return try self.builder.const_i32_bits(@truncate(value)),
                    else => return error.InvalidIr,
                },
                else => return error.InvalidIr,
            },
            .float => |value| switch (self.module.types.get(ty)) {
                .scalar => |scalar| switch (scalar) {
                    .f16 => return try self.builder.const_f16_bits(@as(u16, @bitCast(@as(f16, @floatCast(value))))),
                    .f32, .abstract_float => return try self.builder.const_f32_bits(@bitCast(@as(f32, @floatCast(value)))),
                    else => return error.InvalidIr,
                },
                else => return error.InvalidIr,
            },
        }
    }

    pub fn global_storage_class(self: *Emitter, global: ir.Global) EmitError!u32 {
        _ = self;
        return switch (global.class) {
            .const_, .override_ => spirv.StorageClass.Private,
            .input => spirv.StorageClass.Input,
            .output => spirv.StorageClass.Output,
            .var_ => switch (global.addr_space orelse .private) {
                .handle => spirv.StorageClass.UniformConstant,
                .private => spirv.StorageClass.Private,
                .workgroup => spirv.StorageClass.Workgroup,
                .uniform => spirv.StorageClass.Uniform,
                .storage => spirv.StorageClass.StorageBuffer,
                else => error.UnsupportedConstruct,
            },
        };
    }

    fn is_bound_buffer_global(self: *Emitter, global: ir.Global) bool {
        _ = self;
        if (global.binding == null) return false;
        const addr_space = global.addr_space orelse return false;
        return addr_space == .uniform or addr_space == .storage;
    }

    fn is_bound_handle_global(self: *Emitter, global: ir.Global) bool {
        if (global.binding == null) return false;
        const addr_space = global.addr_space orelse return false;
        if (addr_space != .handle) return false;
        return switch (self.module.types.get(global.ty)) {
            .sampler, .sampler_comparison, .texture_1d, .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d, .storage_texture_2d => true,
            else => false,
        };
    }

    const Layout = struct {
        alignment: u32,
        size: u32,
    };

    pub fn decorate_memory_type(self: *Emitter, ty: ir.TypeId, addr_space: ir.AddressSpace) EmitError!Layout {
        return switch (self.module.types.get(ty)) {
            .scalar => |scalar| switch (scalar) {
                .bool, .i32, .u32, .f32, .abstract_int, .abstract_float => .{ .alignment = 4, .size = 4 },
                .f16 => .{ .alignment = 2, .size = 2 },
                else => return error.UnsupportedConstruct,
            },
            .vector => |vec| blk: {
                const elem_layout = try self.decorate_memory_type(vec.elem, addr_space);
                break :blk try vector_layout_from_elem(elem_layout, vec.len);
            },
            .matrix => |mat| blk: {
                const elem_layout = try self.decorate_memory_type(mat.elem, addr_space);
                const column_layout = try vector_layout_from_elem(elem_layout, mat.rows);
                const column_alignment = adjusted_memory_align(addr_space, .{ .vector = .{ .elem = mat.elem, .len = mat.rows } }, column_layout.alignment);
                const stride = round_up(column_alignment, column_layout.size);
                break :blk .{
                    .alignment = column_alignment,
                    .size = stride * mat.columns,
                };
            },
            .array => |arr| blk: {
                const elem_layout = try self.decorate_memory_type(arr.elem, addr_space);
                const alignment = adjusted_memory_align(addr_space, self.module.types.get(arr.elem), elem_layout.alignment);
                const stride = round_up(alignment, elem_layout.size);
                const array_type = try self.lower_type(ty);
                const gop = try self.decorated_array_types.getOrPut(self.alloc, array_type);
                if (!gop.found_existing) {
                    try self.builder.emit_array_stride_decoration(array_type, stride);
                }
                if (arr.len == null) {
                    if (addr_space != .storage) return error.UnsupportedConstruct;
                    break :blk .{
                        .alignment = alignment,
                        .size = stride,
                    };
                }
                const len = arr.len.?;
                break :blk .{
                    .alignment = alignment,
                    .size = stride * len,
                };
            },
            .struct_ => |struct_id| blk: {
                const struct_type = try self.lower_type(ty);
                const gop = try self.decorated_struct_types.getOrPut(self.alloc, struct_type);
                const struct_def = self.module.structs.items[struct_id];
                var offset: u32 = 0;
                var max_align: u32 = 1;
                for (struct_def.fields.items, 0..) |field, field_index| {
                    const field_layout = try self.decorate_memory_type(field.ty, addr_space);
                    const field_alignment = adjusted_memory_align(addr_space, self.module.types.get(field.ty), field_layout.alignment);
                    offset = round_up(field_alignment, offset);
                    if (!gop.found_existing) {
                        try self.builder.emit_member_offset_decoration(struct_type, @intCast(field_index), offset);
                        if (matrix_member_layout(self.module, field.ty)) |mat| {
                            const elem_layout = try self.decorate_memory_type(mat.elem, addr_space);
                            const column_layout = try vector_layout_from_elem(elem_layout, mat.rows);
                            const column_alignment = adjusted_memory_align(addr_space, .{ .vector = .{ .elem = mat.elem, .len = mat.rows } }, column_layout.alignment);
                            const stride = round_up(column_alignment, column_layout.size);
                            try self.builder.emit_member_col_major_decoration(struct_type, @intCast(field_index));
                            try self.builder.emit_member_matrix_stride_decoration(struct_type, @intCast(field_index), stride);
                        }
                    }
                    max_align = @max(max_align, field_alignment);
                    offset += field_layout.size;
                }
                max_align = adjusted_memory_align(addr_space, .{ .struct_ = struct_id }, max_align);
                break :blk .{
                    .alignment = max_align,
                    .size = round_up(max_align, offset),
                };
            },
            .atomic => |inner| try self.decorate_memory_type(inner, addr_space),
            .sampler, .sampler_comparison, .texture_1d, .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d, .storage_texture_2d, .ref => return error.UnsupportedConstruct,
        };
    }

    pub fn emit_function_load(self: *Emitter, value_type: u32, ptr_id: u32) EmitError!u32 {
        const result_id = self.builder.reserve_id();
        try self.builder.append_function_inst(spirv.Opcode.Load, &.{ value_type, result_id, ptr_id });
        return result_id;
    }

    pub fn emit_store(self: *Emitter, ptr_id: u32, value_id: u32) EmitError!void {
        try self.builder.append_function_inst(spirv.Opcode.Store, &.{ ptr_id, value_id });
    }

    pub fn emit_function_call(self: *Emitter, result_type: u32, fn_id: u32, args: []const u32) EmitError!u32 {
        var operands = std.ArrayListUnmanaged(u32){};
        defer operands.deinit(self.alloc);
        const result_id = self.builder.reserve_id();
        try operands.append(self.alloc, result_type);
        try operands.append(self.alloc, result_id);
        try operands.append(self.alloc, fn_id);
        try operands.appendSlice(self.alloc, args);
        try self.builder.append_function_inst(spirv.Opcode.FunctionCall, operands.items);
        return result_id;
    }

    pub fn function_id_by_name(self: *Emitter, name: []const u8) ?u32 {
        for (self.module.functions.items, 0..) |function, index| {
            if (std.mem.eql(u8, function.name, name)) return self.function_ids[index];
        }
        return null;
    }
};

const TextureOpcode = struct {
    const TypeSampler: u16 = 26;
    const TypeSampledImage: u16 = 27;
};

fn append_types_globals_inst(builder: *spirv.Builder, alloc: std.mem.Allocator, opcode: u16, operands: []const u32) EmitError!void {
    const word_count: u32 = @intCast(operands.len + 1);
    try builder.types_globals.append(alloc, (@as(u32, word_count) << 16) | opcode);
    try builder.types_globals.appendSlice(alloc, operands);
}

fn adjusted_memory_align(addr_space: ir.AddressSpace, ty: ir.Type, base_align: u32) u32 {
    return switch (addr_space) {
        .uniform => switch (ty) {
            .array, .struct_ => @max(base_align, 16),
            else => base_align,
        },
        else => base_align,
    };
}

const MatrixMemberLayout = struct {
    elem: ir.TypeId,
    rows: u8,
};

fn matrix_member_layout(module: *const ir.Module, ty: ir.TypeId) ?MatrixMemberLayout {
    return switch (module.types.get(ty)) {
        .matrix => |mat| .{ .elem = mat.elem, .rows = mat.rows },
        .array => |arr| matrix_member_layout(module, arr.elem),
        else => null,
    };
}

fn vector_layout_from_elem(elem_layout: Emitter.Layout, len: u8) EmitError!Emitter.Layout {
    return switch (len) {
        2 => .{ .alignment = elem_layout.alignment * 2, .size = elem_layout.size * 2 },
        3 => .{ .alignment = elem_layout.alignment * 4, .size = elem_layout.size * 3 },
        4 => .{ .alignment = elem_layout.alignment * 4, .size = elem_layout.size * 4 },
        else => error.UnsupportedConstruct,
    };
}

fn round_up(alignment: u32, value: u32) u32 {
    if (alignment <= 1) return value;
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return value + alignment - remainder;
}

pub const addr_space_to_storage_class = emit_spirv_shared.addr_space_to_storage_class;
pub const builtin_to_spirv = emit_spirv_shared.builtin_to_spirv;

fn storage_texture_sampled_type(self: *Emitter, format: ir.TextureFormat) EmitError!u32 {
    return switch (format) {
        .rgba8unorm, .rgba8snorm, .rgba16float, .r32float, .rg32float, .rgba32float => try self.builder.type_f32(),
        .rgba8uint, .rgba16uint, .r32uint, .rg32uint, .rgba32uint => try self.builder.type_u32(),
        .rgba8sint, .rgba16sint, .r32sint, .rg32sint, .rgba32sint => try self.builder.type_i32(),
    };
}

fn storage_texture_format_to_spirv(format: ir.TextureFormat) u32 {
    return switch (format) {
        .rgba8unorm => spirv.ImageFormat.Rgba8,
        .rgba8snorm => spirv.ImageFormat.Rgba8Snorm,
        .rgba8uint => spirv.ImageFormat.Rgba8ui,
        .rgba8sint => spirv.ImageFormat.Rgba8i,
        .rgba16uint => spirv.ImageFormat.Rgba16ui,
        .rgba16sint => spirv.ImageFormat.Rgba16i,
        .rgba16float => spirv.ImageFormat.Rgba16f,
        .r32uint => spirv.ImageFormat.R32ui,
        .r32sint => spirv.ImageFormat.R32i,
        .r32float => spirv.ImageFormat.R32f,
        .rg32uint => spirv.ImageFormat.Rg32ui,
        .rg32sint => spirv.ImageFormat.Rg32i,
        .rg32float => spirv.ImageFormat.Rg32f,
        .rgba32uint => spirv.ImageFormat.Rgba32ui,
        .rgba32sint => spirv.ImageFormat.Rgba32i,
        .rgba32float => spirv.ImageFormat.Rgba32f,
    };
}
