// doe_adapter_info_native.zig — GPUAdapter.info native implementation.
//
// Retrieves vendor, architecture, device name, and description from the
// underlying MTLDevice via the metal bridge.  Callers receive four
// NUL-terminated C string pointers backed by a single heap block; they
// must call doeNativeAdapterFreeInfo to release it.

const std = @import("std");
const native_types = @import("doe_native_object_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;

const cast = native_helpers.cast;
const DoeAdapter = native_types.DoeAdapter;

// ============================================================
// Bridge imports
// ============================================================

// The bridge function returns a heap block of four NUL-terminated strings
// (vendor, arch, device, description) packed consecutively.
// Caller owns the block and must release it with metal_bridge_free_string.
const metal_bridge_adapter_get_info_string = bridge.metal_bridge_adapter_get_info_string;
const metal_bridge_free_string = bridge.metal_bridge_free_string;

// ============================================================
// Exported API
// ============================================================

// doeNativeAdapterGetInfo — populate four out-pointers with NUL-terminated
// string pointers backed by a single heap block.
//
// adapter_raw: opaque pointer to DoeAdapter (as handed out by requestAdapter).
// out_vendor / out_arch / out_device / out_desc: receive pointers into the
//   block; valid until doeNativeAdapterFreeInfo is called with the block root.
// out_block: receives the root pointer of the heap block; pass this to
//   doeNativeAdapterFreeInfo when done.
//
// On failure all out-pointers are set to null.
pub export fn doeNativeAdapterGetInfo(
    adapter_raw: ?*anyopaque,
    out_vendor: *?[*]const u8,
    out_arch: *?[*]const u8,
    out_device: *?[*]const u8,
    out_desc: *?[*]const u8,
    out_block: *?[*]u8,
) callconv(.c) void {
    out_vendor.* = null;
    out_arch.* = null;
    out_device.* = null;
    out_desc.* = null;
    out_block.* = null;

    const adapter = cast(DoeAdapter, adapter_raw) orelse return;
    const block = metal_bridge_adapter_get_info_string(adapter.mtl_device) orelse return;

    // Parse four consecutive NUL-terminated strings from the block.
    var p: [*]u8 = block;
    const vendor_ptr: [*]const u8 = p;
    p += std.mem.len(@as([*:0]u8, @ptrCast(p))) + 1;
    const arch_ptr: [*]const u8 = p;
    p += std.mem.len(@as([*:0]u8, @ptrCast(p))) + 1;
    const device_ptr: [*]const u8 = p;
    p += std.mem.len(@as([*:0]u8, @ptrCast(p))) + 1;
    const desc_ptr: [*]const u8 = p;

    out_vendor.* = vendor_ptr;
    out_arch.* = arch_ptr;
    out_device.* = device_ptr;
    out_desc.* = desc_ptr;
    out_block.* = block;
}

// doeNativeAdapterFreeInfo — release the heap block returned via out_block by
// doeNativeAdapterGetInfo.  Safe to call with null.
pub export fn doeNativeAdapterFreeInfo(block: ?[*]u8) callconv(.c) void {
    metal_bridge_free_string(block);
}
