const std = @import("std");
const abi_base = @import("../wgpu_handle_types.zig");
const loader = @import("../wgpu_loader.zig");

pub const WGPUResourceTable = ?*anyopaque;
pub const WGPURenderBundleEncoder = ?*anyopaque;

pub const ResourceTableDescriptor = extern struct {
    nextInChain: ?*anyopaque,
    label: abi_base.WGPUStringView,
    size: u32,
};

pub const BindingResource = extern struct {
    nextInChain: ?*anyopaque,
    buffer: abi_base.WGPUBuffer,
    offset: u64,
    size: u64,
    sampler: abi_base.WGPUSampler,
    textureView: abi_base.WGPUTextureView,
};

pub const FnComputePassEncoderSetImmediates = *const fn (abi_base.WGPUComputePassEncoder, u32, ?*const anyopaque, usize) callconv(.c) void;
pub const FnComputePassEncoderSetResourceTable = *const fn (abi_base.WGPUComputePassEncoder, WGPUResourceTable) callconv(.c) void;
pub const FnDeviceCreateResourceTable = *const fn (abi_base.WGPUDevice, *const ResourceTableDescriptor) callconv(.c) WGPUResourceTable;
pub const FnRenderBundleEncoderSetImmediates = *const fn (WGPURenderBundleEncoder, u32, ?*const anyopaque, usize) callconv(.c) void;
pub const FnRenderBundleEncoderSetResourceTable = *const fn (WGPURenderBundleEncoder, WGPUResourceTable) callconv(.c) void;
pub const FnRenderPassEncoderSetImmediates = *const fn (abi_base.WGPURenderPassEncoder, u32, ?*const anyopaque, usize) callconv(.c) void;
pub const FnRenderPassEncoderSetResourceTable = *const fn (abi_base.WGPURenderPassEncoder, WGPUResourceTable) callconv(.c) void;
pub const FnResourceTableDestroy = *const fn (WGPUResourceTable) callconv(.c) void;
pub const FnResourceTableGetSize = *const fn (WGPUResourceTable) callconv(.c) u32;
pub const FnResourceTableInsertBinding = *const fn (WGPUResourceTable, *const BindingResource) callconv(.c) u32;
pub const FnResourceTableRemoveBinding = *const fn (WGPUResourceTable, u32) callconv(.c) abi_base.WGPUStatus;
pub const FnResourceTableUpdate = *const fn (WGPUResourceTable, u32, *const BindingResource) callconv(.c) abi_base.WGPUStatus;
pub const FnResourceTableAddRef = *const fn (WGPUResourceTable) callconv(.c) void;
pub const FnResourceTableRelease = *const fn (WGPUResourceTable) callconv(.c) void;

pub const ResourceTableProcs = struct {
    compute_pass_encoder_set_immediates: ?FnComputePassEncoderSetImmediates = null,
    compute_pass_encoder_set_resource_table: ?FnComputePassEncoderSetResourceTable = null,
    device_create_resource_table: ?FnDeviceCreateResourceTable = null,
    render_bundle_encoder_set_immediates: ?FnRenderBundleEncoderSetImmediates = null,
    render_bundle_encoder_set_resource_table: ?FnRenderBundleEncoderSetResourceTable = null,
    render_pass_encoder_set_immediates: ?FnRenderPassEncoderSetImmediates = null,
    render_pass_encoder_set_resource_table: ?FnRenderPassEncoderSetResourceTable = null,
    resource_table_destroy: ?FnResourceTableDestroy = null,
    resource_table_get_size: ?FnResourceTableGetSize = null,
    resource_table_insert_binding: ?FnResourceTableInsertBinding = null,
    resource_table_remove_binding: ?FnResourceTableRemoveBinding = null,
    resource_table_update: ?FnResourceTableUpdate = null,
    resource_table_add_ref: ?FnResourceTableAddRef = null,
    resource_table_release: ?FnResourceTableRelease = null,
};

fn loadProc(comptime T: type, lib: std.DynLib, comptime name: [:0]const u8) ?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn loadResourceTableProcs(dyn_lib: ?std.DynLib) ?ResourceTableProcs {
    const lib = dyn_lib orelse return null;
    return .{
        .compute_pass_encoder_set_immediates = loadProc(FnComputePassEncoderSetImmediates, lib, "wgpuComputePassEncoderSetImmediates"),
        .compute_pass_encoder_set_resource_table = loadProc(FnComputePassEncoderSetResourceTable, lib, "wgpuComputePassEncoderSetResourceTable"),
        .device_create_resource_table = loadProc(FnDeviceCreateResourceTable, lib, "wgpuDeviceCreateResourceTable"),
        .render_bundle_encoder_set_immediates = loadProc(FnRenderBundleEncoderSetImmediates, lib, "wgpuRenderBundleEncoderSetImmediates"),
        .render_bundle_encoder_set_resource_table = loadProc(FnRenderBundleEncoderSetResourceTable, lib, "wgpuRenderBundleEncoderSetResourceTable"),
        .render_pass_encoder_set_immediates = loadProc(FnRenderPassEncoderSetImmediates, lib, "wgpuRenderPassEncoderSetImmediates"),
        .render_pass_encoder_set_resource_table = loadProc(FnRenderPassEncoderSetResourceTable, lib, "wgpuRenderPassEncoderSetResourceTable"),
        .resource_table_destroy = loadProc(FnResourceTableDestroy, lib, "wgpuResourceTableDestroy"),
        .resource_table_get_size = loadProc(FnResourceTableGetSize, lib, "wgpuResourceTableGetSize"),
        .resource_table_insert_binding = loadProc(FnResourceTableInsertBinding, lib, "wgpuResourceTableInsertBinding"),
        .resource_table_remove_binding = loadProc(FnResourceTableRemoveBinding, lib, "wgpuResourceTableRemoveBinding"),
        .resource_table_update = loadProc(FnResourceTableUpdate, lib, "wgpuResourceTableUpdate"),
        .resource_table_add_ref = loadProc(FnResourceTableAddRef, lib, "wgpuResourceTableAddRef"),
        .resource_table_release = loadProc(FnResourceTableRelease, lib, "wgpuResourceTableRelease"),
    };
}

pub fn initResourceTableDescriptor(size: u32) ResourceTableDescriptor {
    return .{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .size = size,
    };
}

pub fn initBindingResource(buffer: abi_base.WGPUBuffer, offset: u64, size: u64) BindingResource {
    return .{
        .nextInChain = null,
        .buffer = buffer,
        .offset = offset,
        .size = size,
        .sampler = null,
        .textureView = null,
    };
}

pub fn isResourceTableReady(procs: ResourceTableProcs) bool {
    return procs.device_create_resource_table != null and
        procs.resource_table_destroy != null and
        procs.resource_table_get_size != null and
        procs.resource_table_insert_binding != null and
        procs.resource_table_remove_binding != null and
        procs.resource_table_update != null and
        procs.resource_table_release != null;
}

pub fn setComputeResourceTable(procs: ResourceTableProcs, compute_pass: abi_base.WGPUComputePassEncoder, table: WGPUResourceTable) void {
    if (compute_pass == null) return;
    if (procs.compute_pass_encoder_set_resource_table) |set_table| {
        set_table(compute_pass, table);
    }
}

pub fn setComputeImmediates(procs: ResourceTableProcs, compute_pass: abi_base.WGPUComputePassEncoder, offset: u32, data: ?*const anyopaque, size: usize) void {
    if (compute_pass == null) return;
    if (procs.compute_pass_encoder_set_immediates) |set_immediates| {
        set_immediates(compute_pass, offset, data, size);
    }
}

pub fn setRenderPassResourceTable(procs: ResourceTableProcs, render_pass: abi_base.WGPURenderPassEncoder, table: WGPUResourceTable) void {
    if (render_pass == null) return;
    if (procs.render_pass_encoder_set_resource_table) |set_table| {
        set_table(render_pass, table);
    }
}

pub fn setRenderPassImmediates(procs: ResourceTableProcs, render_pass: abi_base.WGPURenderPassEncoder, offset: u32, data: ?*const anyopaque, size: usize) void {
    if (render_pass == null) return;
    if (procs.render_pass_encoder_set_immediates) |set_immediates| {
        set_immediates(render_pass, offset, data, size);
    }
}

pub fn setRenderBundleResourceTable(procs: ResourceTableProcs, render_bundle_encoder: WGPURenderBundleEncoder, table: WGPUResourceTable) void {
    if (render_bundle_encoder == null) return;
    if (procs.render_bundle_encoder_set_resource_table) |set_table| {
        set_table(render_bundle_encoder, table);
    }
}

pub fn setRenderBundleImmediates(procs: ResourceTableProcs, render_bundle_encoder: WGPURenderBundleEncoder, offset: u32, data: ?*const anyopaque, size: usize) void {
    if (render_bundle_encoder == null) return;
    if (procs.render_bundle_encoder_set_immediates) |set_immediates| {
        set_immediates(render_bundle_encoder, offset, data, size);
    }
}
