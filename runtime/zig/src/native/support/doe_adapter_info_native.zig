// doe_adapter_info_native.zig — GPUAdapter.info native implementation.

const std = @import("std");
const native_types = @import("doe_native_object_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;

const cast = native_helpers.cast;
const DoeAdapter = native_types.DoeAdapter;

const VULKAN_VENDOR_AMD: u32 = 0x1002;
const VULKAN_VENDOR_NVIDIA: u32 = 0x10de;
const VULKAN_VENDOR_INTEL: u32 = 0x8086;

// ============================================================
// Bridge imports
// ============================================================

const metal_bridge_adapter_get_info_string = bridge.metal_bridge_adapter_get_info_string;

fn vulkan_vendor_name(vendor_id: u32) []const u8 {
    return switch (vendor_id) {
        VULKAN_VENDOR_AMD => "AMD",
        VULKAN_VENDOR_NVIDIA => "NVIDIA",
        VULKAN_VENDOR_INTEL => "Intel",
        else => "Unknown Vulkan vendor",
    };
}

fn write_packed_info(
    vendor: []const u8,
    architecture: []const u8,
    device: []const u8,
    description: []const u8,
) ?[*]u8 {
    const fields = [_][]const u8{ vendor, architecture, device, description };
    var total: usize = 0;
    for (fields) |field| total = std.math.add(usize, total, field.len + 1) catch return null;
    const block = std.heap.c_allocator.alloc(u8, total) catch return null;
    var offset: usize = 0;
    for (fields) |field| {
        @memcpy(block[offset..][0..field.len], field);
        offset += field.len;
        block[offset] = 0;
        offset += 1;
    }
    return block.ptr;
}

fn packed_info_size(block: [*]u8) usize {
    var cursor = block;
    var total: usize = 0;
    for (0..4) |_| {
        const field_len = std.mem.len(@as([*:0]u8, @ptrCast(cursor)));
        total += field_len + 1;
        cursor += field_len + 1;
    }
    return total;
}

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
    const block = switch (adapter.backend) {
        .metal => metal_bridge_adapter_get_info_string(adapter.mtl_device),
        .vulkan => write_packed_info(
            vulkan_vendor_name(adapter.vendor_id),
            "vulkan",
            adapter.device_name[0..adapter.device_name_len],
            adapter.device_name[0..adapter.device_name_len],
        ),
        .d3d12 => write_packed_info("Doe", "d3d12", "Doe D3D12 Adapter", "Doe D3D12 Adapter"),
    } orelse return;

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
    const root = block orelse return;
    std.heap.c_allocator.free(root[0..packed_info_size(root)]);
}

pub export fn doeNativeAdapterGetPciIdentity(
    adapter_raw: ?*anyopaque,
    out_vendor_id: *u32,
    out_device_id: *u32,
    out_driver_version: *u32,
) callconv(.c) void {
    out_vendor_id.* = 0;
    out_device_id.* = 0;
    out_driver_version.* = 0;
    const adapter = cast(DoeAdapter, adapter_raw) orelse return;
    out_vendor_id.* = adapter.vendor_id;
    out_device_id.* = adapter.device_id;
    out_driver_version.* = adapter.driver_version;
}
