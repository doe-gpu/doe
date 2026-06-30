// Vertex and fragment shader stage emission for the SPIR-V backend.
//
// Handles entry point wrappers, stage I/O variable creation with location
// and built-in decorations, and struct-typed return value decomposition for
// vertex/fragment pipelines.

const std = @import("std");
const ir = @import("ir.zig");
const spirv = @import("spirv_builder.zig");
const emit_spirv_shared = @import("emit_spirv_shared.zig");
const EmitError = emit_spirv_shared.EmitError;

/// Maximum number of I/O variables per entry point (params + return fields).
const MAX_IO_VARS: usize = 64;

/// Emit a module-scope Input or Output variable with IO decorations.
pub fn emit_io_global(emitter: anytype, global: ir.Global) EmitError!u32 {
    const storage_class = try emitter.global_storage_class(global);
    const value_type = try emitter.lower_type(global.ty);
    const ptr_type = try emitter.builder.type_pointer(storage_class, value_type);
    const var_id = try emitter.builder.variable_global(ptr_type, storage_class);
    try emitter.builder.emit_name(var_id, global.name);

    const io = global.io orelse return error.InvalidIr;
    try decorate_io_var(&emitter.builder, var_id, io);

    return var_id;
}

/// Emit a vertex or fragment entry point wrapper function with stage-appropriate
/// execution model, I/O variable binding, and return value decomposition.
///
/// Descriptor-bound resources are decorated at module scope, but SPIR-V 1.3
/// OpEntryPoint interfaces list only Input/Output variables.
pub fn emit_stage_entry_wrapper(emitter: anytype, entry: ir.EntryPoint) EmitError!void {
    const function = &emitter.module.functions.items[entry.function];
    const wrapper_id = emitter.entry_wrapper_ids[entry.function];
    const void_type = try emitter.builder.type_void();
    const fn_type = try emitter.builder.type_function(void_type, &.{});
    const wrapper_name = try std.fmt.allocPrint(emitter.alloc, "{s}_entry", .{function.name});
    defer emitter.alloc.free(wrapper_name);

    var interface_ids = std.ArrayListUnmanaged(u32){};
    defer interface_ids.deinit(emitter.alloc);

    // Phase 1: create all Input/Output variables at module scope.
    // Track per-param input var IDs for later reconstruction in the body.
    var param_input_ranges = std.ArrayListUnmanaged(IoRange){};
    defer param_input_ranges.deinit(emitter.alloc);

    for (function.params.items) |param| {
        const range_start: u32 = @intCast(interface_ids.items.len);
        const is_struct = switch (emitter.module.types.get(param.ty)) {
            .struct_ => true,
            else => false,
        };
        if (is_struct) {
            if (param.io != null) return error.UnsupportedConstruct;
            try emit_struct_io_vars(emitter, param.ty, spirv.StorageClass.Input, &interface_ids);
        } else {
            const io = param.io orelse return error.UnsupportedConstruct;
            const value_type = try emitter.lower_type(param.ty);
            const ptr_type = try emitter.builder.type_pointer(spirv.StorageClass.Input, value_type);
            const var_id = try emitter.builder.variable_global(ptr_type, spirv.StorageClass.Input);
            try emitter.builder.emit_name(var_id, param.name);
            try decorate_io_var(&emitter.builder, var_id, io);
            try interface_ids.append(emitter.alloc, var_id);
        }
        const range_end: u32 = @intCast(interface_ids.items.len);
        try param_input_ranges.append(emitter.alloc, .{
            .start = range_start,
            .len = range_end - range_start,
            .is_struct = is_struct,
        });
    }

    // Emit output variables for the return type.
    const output_range_start: u32 = @intCast(interface_ids.items.len);
    const has_return = !ir.is_scalar(&emitter.module.types, function.return_type, .void);
    if (has_return) {
        try emit_return_output_vars(emitter, function.return_type, function.return_io, &interface_ids);
    }
    const output_range_len: u32 = @as(u32, @intCast(interface_ids.items.len)) - output_range_start;

    // Include only module-scope I/O globals in the entry-point interface.
    for (emitter.module.globals.items, 0..) |global, index| {
        if (global.class != .input and global.class != .output) continue;
        const global_id = emitter.global_ids[index];
        if (global_id == 0) return error.InvalidIr;
        try interface_ids.append(emitter.alloc, global_id);
    }

    // Emit entry point instruction and execution modes.
    const execution_model = stage_to_execution_model(entry.stage);
    try emitter.builder.emit_name(wrapper_id, wrapper_name);
    try emitter.builder.emit_entry_point_with_model(execution_model, wrapper_id, function.name, interface_ids.items);

    if (entry.stage == .fragment) {
        try emitter.builder.emit_execution_mode(wrapper_id, spirv.ExecutionMode.OriginUpperLeft);
        if (return_has_frag_depth(emitter, function.return_type)) {
            try emitter.builder.emit_execution_mode(wrapper_id, spirv.ExecutionMode.DepthReplacing);
        }
    }

    // Phase 2: generate wrapper function body.
    try emitter.builder.begin_function(void_type, wrapper_id, fn_type);
    _ = try emitter.builder.label();

    // Build call arguments by loading from input variables.
    var call_args = std.ArrayListUnmanaged(u32){};
    defer call_args.deinit(emitter.alloc);

    for (function.params.items, param_input_ranges.items) |param, range| {
        const input_vars = interface_ids.items[range.start .. range.start + range.len];
        if (range.is_struct) {
            // Struct-typed: load each field and CompositeConstruct.
            const composite = try load_and_construct_struct(emitter, param.ty, input_vars);
            try call_args.append(emitter.alloc, composite);
        } else {
            // Direct IO param: single load.
            try call_args.append(emitter.alloc, try emitter.emit_function_load(try emitter.lower_type(param.ty), input_vars[0]));
        }
    }

    if (has_return) {
        const return_type = try emitter.lower_type(function.return_type);
        const result = try emitter.emit_function_call(return_type, emitter.function_ids[entry.function], call_args.items);
        const output_vars = interface_ids.items[output_range_start .. output_range_start + output_range_len];
        try store_return_to_outputs(emitter, function.return_type, function.return_io, result, output_vars);
    } else {
        _ = try emitter.emit_function_call(void_type, emitter.function_ids[entry.function], call_args.items);
    }

    try emitter.builder.append_function_inst(spirv.Opcode.Return, &.{});
    try emitter.builder.finish_function();
}

// -- Internal types --

const IoRange = struct {
    start: u32,
    len: u32,
    is_struct: bool,
};

// -- I/O variable helpers --

/// Create individual Input or Output variables for each field of a struct type.
fn emit_struct_io_vars(
    emitter: anytype,
    ty: ir.TypeId,
    storage_class: u32,
    interface_ids: *std.ArrayListUnmanaged(u32),
) EmitError!void {
    const struct_id = switch (emitter.module.types.get(ty)) {
        .struct_ => |sid| sid,
        else => return error.UnsupportedConstruct,
    };
    const struct_def = emitter.module.structs.items[struct_id];

    for (struct_def.fields.items) |field| {
        const io = field.io orelse return error.InvalidIr;
        const value_type = try emitter.lower_type(field.ty);
        const ptr_type = try emitter.builder.type_pointer(storage_class, value_type);
        const var_id = try emitter.builder.variable_global(ptr_type, storage_class);
        try emitter.builder.emit_name(var_id, field.name);
        try decorate_io_var(&emitter.builder, var_id, io);
        try interface_ids.append(emitter.alloc, var_id);
    }
}

/// Emit Output variables for the return type. For struct returns, one Output
/// variable per field. For non-struct returns with return_io, a single Output.
fn emit_return_output_vars(
    emitter: anytype,
    return_type: ir.TypeId,
    return_io: ?ir.IoAttr,
    interface_ids: *std.ArrayListUnmanaged(u32),
) EmitError!void {
    switch (emitter.module.types.get(return_type)) {
        .struct_ => |struct_id| {
            const struct_def = emitter.module.structs.items[struct_id];
            for (struct_def.fields.items) |field| {
                const io = field.io orelse return error.InvalidIr;
                const value_type = try emitter.lower_type(field.ty);
                const ptr_type = try emitter.builder.type_pointer(spirv.StorageClass.Output, value_type);
                const var_id = try emitter.builder.variable_global(ptr_type, spirv.StorageClass.Output);
                try emitter.builder.emit_name(var_id, field.name);
                try decorate_io_var(&emitter.builder, var_id, io);
                try interface_ids.append(emitter.alloc, var_id);
            }
        },
        else => {
            // Non-struct return: single output variable with return_io decorations.
            const io = return_io orelse return error.UnsupportedConstruct;
            const value_type = try emitter.lower_type(return_type);
            const ptr_type = try emitter.builder.type_pointer(spirv.StorageClass.Output, value_type);
            const var_id = try emitter.builder.variable_global(ptr_type, spirv.StorageClass.Output);
            try emitter.builder.emit_name(var_id, "return_value");
            try decorate_io_var(&emitter.builder, var_id, io);
            try interface_ids.append(emitter.alloc, var_id);
        },
    }
}

/// Load each field from individual Input variables and CompositeConstruct.
fn load_and_construct_struct(
    emitter: anytype,
    ty: ir.TypeId,
    field_var_ids: []const u32,
) EmitError!u32 {
    const struct_id = switch (emitter.module.types.get(ty)) {
        .struct_ => |sid| sid,
        else => return error.UnsupportedConstruct,
    };
    const struct_def = emitter.module.structs.items[struct_id];
    if (struct_def.fields.items.len != field_var_ids.len) return error.InvalidIr;

    var operands = std.ArrayListUnmanaged(u32){};
    defer operands.deinit(emitter.alloc);
    const struct_type = try emitter.lower_type(ty);
    const result_id = emitter.builder.reserve_id();
    try operands.append(emitter.alloc, struct_type);
    try operands.append(emitter.alloc, result_id);

    for (struct_def.fields.items, field_var_ids) |field, var_id| {
        const field_type = try emitter.lower_type(field.ty);
        try operands.append(emitter.alloc, try emitter.emit_function_load(field_type, var_id));
    }

    try emitter.builder.append_function_inst(spirv.Opcode.CompositeConstruct, operands.items);
    return result_id;
}

/// Store a function return value into Output variables. For struct returns,
/// decompose via CompositeExtract. For non-struct, store directly.
fn store_return_to_outputs(
    emitter: anytype,
    return_type: ir.TypeId,
    return_io: ?ir.IoAttr,
    value_id: u32,
    output_var_ids: []const u32,
) EmitError!void {
    switch (emitter.module.types.get(return_type)) {
        .struct_ => |struct_id| {
            const struct_def = emitter.module.structs.items[struct_id];
            if (struct_def.fields.items.len != output_var_ids.len) return error.InvalidIr;
            for (struct_def.fields.items, 0..) |field, field_index| {
                const field_type = try emitter.lower_type(field.ty);
                const result_id = emitter.builder.reserve_id();
                try emitter.builder.append_function_inst(
                    spirv.Opcode.CompositeExtract,
                    &.{ field_type, result_id, value_id, @as(u32, @intCast(field_index)) },
                );
                try emitter.emit_store(output_var_ids[field_index], result_id);
            }
        },
        else => {
            // Non-struct return: direct store to the single output variable.
            if (return_io == null) return error.InvalidIr;
            if (output_var_ids.len != 1) return error.InvalidIr;
            try emitter.emit_store(output_var_ids[0], value_id);
        },
    }
}

/// Apply IO decorations (builtin, location, interpolation, invariant, blend_src) to a variable.
fn decorate_io_var(builder: *spirv.Builder, var_id: u32, io: ir.IoAttr) EmitError!void {
    if (io.builtin != .none) {
        if (io.builtin == .subgroup_size or io.builtin == .subgroup_invocation_id) {
            try builder.emit_capability(spirv.Capability.GroupNonUniform);
        }
        if (io.builtin == .clip_distances) {
            try builder.emit_capability(spirv.Capability.ClipDistance);
        }
        try builder.emit_builtin_decoration(var_id, try emit_spirv_shared.builtin_to_spirv(io.builtin));
    }
    if (io.location) |loc| {
        try builder.emit_location_decoration(var_id, loc);
    }
    if (io.blend_src) |src_index| {
        try builder.emit_index_decoration(var_id, src_index);
    }
    if (io.interpolation) |interp| {
        switch (interp) {
            .flat => try builder.emit_flat_decoration(var_id),
            .linear => try builder.emit_noperspective_decoration(var_id),
            .perspective => {},
        }
    }
    if (io.sampling) |sampling| {
        switch (sampling) {
            .centroid => try builder.emit_centroid_decoration(var_id),
            .sample => {
                try builder.emit_capability(spirv.Capability.SampleRateShading);
                try builder.emit_sample_decoration(var_id);
            },
            .center => {},
        }
    }
    if (io.invariant) {
        try builder.emit_invariant_decoration(var_id);
    }
}

fn stage_to_execution_model(stage: ir.ShaderStage) u32 {
    return switch (stage) {
        .vertex => spirv.ExecutionModel.Vertex,
        .fragment => spirv.ExecutionModel.Fragment,
        .compute => spirv.ExecutionModel.GLCompute,
    };
}

/// Check whether the return type includes a frag_depth field.
fn return_has_frag_depth(emitter: anytype, return_type: ir.TypeId) bool {
    switch (emitter.module.types.get(return_type)) {
        .struct_ => |struct_id| {
            const struct_def = emitter.module.structs.items[struct_id];
            for (struct_def.fields.items) |field| {
                const io = field.io orelse continue;
                if (io.builtin == .frag_depth) return true;
            }
        },
        else => {},
    }
    return false;
}
