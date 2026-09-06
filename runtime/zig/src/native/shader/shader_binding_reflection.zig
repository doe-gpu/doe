//! One-way WGSL binding reflection shared by shader creation and native
//! backend pipeline preparation.

const std = @import("std");
const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");
const wgsl_bindings = @import("../../compiler/wgsl/pipeline/binding_reflection.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const alloc = native_helpers.alloc;
const DoeShaderModule = native_types.DoeShaderModule;

pub fn ensureShaderBindings(sm: *DoeShaderModule) wgsl_analysis.TranslateError!void {
    return ensureShaderBindingsWithAllocator(alloc, sm);
}

pub fn ensureShaderBindingsWithAllocator(allocator: std.mem.Allocator, sm: *DoeShaderModule) wgsl_analysis.TranslateError!void {
    sm.bindings_mutex.lock();
    defer sm.bindings_mutex.unlock();
    if (sm.bindings_ready) return;
    if (sm.bindings_error) |err| return err;
    const wgsl = sm.wgsl_source orelse return error.UnsupportedWgsl;
    var diagnostic = wgsl_analysis.Diagnostic{};
    var bind_meta: [native_shared.MAX_SHADER_BINDINGS]wgsl_bindings.BindingMeta = undefined;
    const count = wgsl_bindings.extractBindingsWithDiagnostic(allocator, wgsl, &bind_meta, &diagnostic) catch |err| {
        sm.bindings_error = err;
        setCompilationMessage(sm, .@"error", if (diagnostic.lastErrorMessage().len > 0) diagnostic.lastErrorMessage() else @errorName(err), diagnostic.lastErrorLine(), diagnostic.lastErrorColumn());
        return err;
    };
    for (bind_meta[0..count], 0..) |meta, i| sm.bindings[i] = bindingInfo(meta);
    sm.binding_count = @intCast(count);
    sm.bindings_ready = true;
}

pub fn bindingInfo(meta: wgsl_bindings.BindingMeta) native_shared.BindingInfo {
    return .{ .group = meta.group, .binding = meta.binding, .kind = @intFromEnum(meta.kind), .addr_space = @intFromEnum(meta.addr_space), .access = @intFromEnum(meta.access) };
}

pub fn setCompilationMessage(sm: *DoeShaderModule, kind: native_shared.CompilationMessageKind, message: []const u8, line: u32, column: u32) void {
    const len = @min(message.len, sm.compilation_message_storage.len);
    @memcpy(sm.compilation_message_storage[0..len], message[0..len]);
    sm.compilation_message = sm.compilation_message_storage[0..len];
    sm.compilation_message_kind = kind;
    sm.compilation_message_line = line;
    sm.compilation_message_column = column;
}

/// Only published shader metadata is consumed during command preparation.
pub fn shaderBufferBindingType(sm: ?*const DoeShaderModule, group: u32, binding: u32) u32 {
    const types = @import("../../contracts/model/model_binding_value_types.zig");
    const module = sm orelse return types.WGPUBufferBindingType_Storage;
    for (module.bindings[0..module.binding_count]) |meta| {
        if (meta.group == group and meta.binding == binding and meta.kind == @intFromEnum(wgsl_bindings.BindingKind.buffer)) return bufferBindingType(meta);
    }
    return types.WGPUBufferBindingType_Storage;
}

pub fn bufferBindingType(meta: native_shared.BindingInfo) u32 {
    const ir = @import("../../compiler/wgsl/ir/ir.zig");
    const types = @import("../../contracts/model/model_binding_value_types.zig");
    if (meta.kind != @intFromEnum(wgsl_bindings.BindingKind.buffer)) return types.WGPUBufferBindingType_Storage;
    if (meta.addr_space == @intFromEnum(ir.AddressSpace.uniform)) return types.WGPUBufferBindingType_Uniform;
    if (meta.addr_space == @intFromEnum(ir.AddressSpace.storage) and meta.access == @intFromEnum(ir.AccessMode.read)) return types.WGPUBufferBindingType_ReadOnlyStorage;
    return types.WGPUBufferBindingType_Storage;
}
