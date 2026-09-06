// doe_external_texture_native.zig — ExternalTexture handle for the Doe WebGPU runtime.
//
// Wraps plane texture views and color conversion parameters from the
// WGPUExternalTextureDescriptor into an opaque handle that can be used
// in bind groups. Supports two creation paths:
//
// 1. DoeTextureView path: Chromium passes pre-imported texture views
//    through the descriptor's plane0/plane1 fields.
//
// 2. Native handle path: When the descriptor's nextInChain contains a
//    DoeExternalTextureNativeDescriptor (sType = 0xD0E10100), Doe imports
//    the IOSurface or CVPixelBuffer directly via the Metal bridge, creating
//    MTLTexture-backed planes without requiring pre-existing DoeTextureViews.

const std = @import("std");
const builtin = @import("builtin");
const external_texture_ops = @import("../../backend/dropin_external_texture.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_exports = @import("../support/doe_native_exports.zig");
const texture_sampler = @import("doe_texture_sampler_native.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");

const DoeTextureView = native_types.DoeTextureView;

const MAGIC_EXTERNAL_TEXTURE: u32 = 0xD0E1_0013;

// Doe-specific sType for native external texture import via nextInChain.
pub const STYPE_EXTERNAL_TEXTURE_NATIVE: u32 = 0xD0E1_0100;

// Source type tag for the native handle.
pub const NATIVE_SOURCE_IOSURFACE: u32 = 1;
pub const NATIVE_SOURCE_CVPIXELBUFFER: u32 = 2;

// ============================================================
// DoeExternalTextureNativeDescriptor — chained struct layout
// ============================================================
//
// Passed via nextInChain on WGPUExternalTextureDescriptor.
//   chain: WGPUChainedStruct  (offset 0, 16 bytes: next + sType)
//   sourceType: u32           (offset 16) — NATIVE_SOURCE_IOSURFACE or CVPIXELBUFFER
//   padding: u32              (offset 20) — alignment padding
//   handle: *anyopaque        (offset 24) — IOSurfaceRef or CVPixelBufferRef
const NATIVE_DESC_SOURCE_TYPE_OFFSET: usize = 16;
const NATIVE_DESC_HANDLE_OFFSET: usize = 24;

// ============================================================
// Instance-level external texture registry
// ============================================================

var instance_ext_counts: std.AutoHashMapUnmanaged(usize, u32) = .{};
var instance_ext_mutex: std.Thread.Mutex = .{};

fn registry_key(inst: *native_types.DoeInstance) usize {
    return @intFromPtr(inst);
}

fn instance_register(inst: *native_types.DoeInstance) void {
    instance_ext_mutex.lock();
    defer instance_ext_mutex.unlock();
    const key = registry_key(inst);
    if (instance_ext_counts.getPtr(key)) |slot| {
        slot.* +|= 1;
    } else {
        instance_ext_counts.put(std.heap.c_allocator, key, 1) catch {};
    }
}

fn instance_deregister(inst: *native_types.DoeInstance) void {
    instance_ext_mutex.lock();
    defer instance_ext_mutex.unlock();
    const key = registry_key(inst);
    if (instance_ext_counts.getPtr(key)) |slot| {
        if (slot.* <= 1) {
            _ = instance_ext_counts.remove(key);
        } else {
            slot.* -= 1;
        }
    }
}

pub fn instance_external_texture_count(inst_raw: ?*anyopaque) u32 {
    instance_ext_mutex.lock();
    defer instance_ext_mutex.unlock();
    const inst = native_helpers.cast(native_types.DoeInstance, inst_raw) orelse return 0;
    return instance_ext_counts.get(registry_key(inst)) orelse 0;
}

pub const DoeExternalTexture = struct {
    pub const TYPE_MAGIC = MAGIC_EXTERNAL_TEXTURE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    expired: bool = false,
    plane0: ?*anyopaque = null,
    plane1: ?*anyopaque = null,
    is_single_plane: bool = true,
    width: u32 = 0,
    height: u32 = 0,
    // True when plane0/plane1 are raw MTLTexture handles from the Metal import
    // bridge rather than DoeTextureView pointers. Affects release path.
    native_imported: bool = false,
    instance: ?*native_types.DoeInstance = null,
};

pub fn cast(raw: ?*anyopaque) ?*DoeExternalTexture {
    return native_helpers.cast(DoeExternalTexture, raw);
}

/// Check whether an external texture has multiple planes.
pub fn isMultiPlane(ext: *const DoeExternalTexture) bool {
    return !ext.is_single_plane and ext.plane1 != null;
}

/// Resolve plane0 to a raw MTLTexture handle suitable for Metal command encoding.
/// For native-imported external textures, plane0 IS the MTLTexture handle.
/// For DoeTextureView-backed external textures, extracts the MTL handle from the view.
pub fn resolvePlane0MtlHandle(ext: *const DoeExternalTexture) ?*anyopaque {
    const p0 = ext.plane0 orelse return null;
    if (ext.native_imported) return p0;
    const view = texture_sampler.registeredTextureView(p0) orelse return null;
    return if (view.handle) |h| h else view.tex.mtl;
}

/// Resolve plane1 to a raw MTLTexture handle.
pub fn resolvePlane1MtlHandle(ext: *const DoeExternalTexture) ?*anyopaque {
    const p1 = ext.plane1 orelse return null;
    if (ext.native_imported) return p1;
    const view = texture_sampler.registeredTextureView(p1) orelse return null;
    return if (view.handle) |h| h else view.tex.mtl;
}

/// Resolve plane0 to a DoeTexture pointer (for texture-to-texture copy paths).
/// Returns null for native-imported textures (they have no DoeTexture wrapper).
pub fn resolvePlane0DoeTexture(ext: *const DoeExternalTexture) ?*native_types.DoeTexture {
    if (ext.native_imported) return null;
    const view = texture_sampler.registeredTextureView(ext.plane0) orelse return null;
    return view.tex;
}

// -- Creation --

pub export fn doeNativeDeviceImportExternalTexture(
    dev_raw: ?*anyopaque,
    descriptor: ?*const anyopaque,
) callconv(.c) ?*anyopaque {
    return doeNativeDeviceCreateExternalTexture(dev_raw, descriptor);
}

/// WGPUExternalTextureDescriptor C ABI layout (Dawn, x86_64):
///   nextInChain: *WGPUChainedStruct  (offset 0, 8 bytes)
///   label: WGPUStringView            (offset 8, 16 bytes = ptr + size_t)
///   plane0: WGPUTextureView          (offset 24, 8 bytes)
///   plane1: WGPUTextureView          (offset 32, 8 bytes)
const NEXT_IN_CHAIN_OFFSET: usize = 0;
const PLANE0_OFFSET: usize = 24;
const PLANE1_OFFSET: usize = 32;

fn resolve_device_instance(dev_raw: ?*anyopaque) ?*native_types.DoeInstance {
    const dev = native_helpers.cast(native_types.DoeDevice, dev_raw) orelse return null;
    const adapter = dev.adapter orelse return null;
    return adapter.instance;
}

fn resolve_device_mtl(dev_raw: ?*anyopaque) ?*anyopaque {
    const dev = native_helpers.cast(native_types.DoeDevice, dev_raw) orelse return null;
    return dev.mtl_device;
}

const NativePlaneLayout = external_texture_ops.PlaneLayout;

/// Try to extract a native handle (IOSurface/CVPixelBuffer) from the
/// descriptor's nextInChain. Returns null if no native chain is present.
fn tryNativeImport(desc_ptr: [*]const u8, mtl_device: ?*anyopaque) ?NativePlaneLayout {
    if (comptime builtin.os.tag != .macos) return null;
    if (mtl_device == null) return null;

    // Read nextInChain pointer from descriptor offset 0.
    const chain_ptr_raw = @as(*const ?*anyopaque, @ptrCast(@alignCast(desc_ptr + NEXT_IN_CHAIN_OFFSET))).*;
    const chain_ptr = chain_ptr_raw orelse return null;

    // Interpret as WGPUChainedStruct to check sType.
    const chain: *const abi_callback.WGPUChainedStruct = @ptrCast(@alignCast(chain_ptr));
    if (chain.sType != STYPE_EXTERNAL_TEXTURE_NATIVE) return null;

    // Read source type and handle from the native descriptor.
    const chain_bytes: [*]const u8 = @ptrCast(chain_ptr);
    const source_type = @as(*const u32, @ptrCast(@alignCast(chain_bytes + NATIVE_DESC_SOURCE_TYPE_OFFSET))).*;
    const handle = @as(*const ?*anyopaque, @ptrCast(@alignCast(chain_bytes + NATIVE_DESC_HANDLE_OFFSET))).*;
    if (handle == null) return null;

    return switch (source_type) {
        NATIVE_SOURCE_IOSURFACE => external_texture_ops.importIOSurface(mtl_device, handle),
        NATIVE_SOURCE_CVPIXELBUFFER => external_texture_ops.importCVPixelBuffer(mtl_device, handle),
        else => null,
    };
}

pub export fn doeNativeDeviceCreateExternalTexture(
    dev_raw: ?*anyopaque,
    descriptor: ?*const anyopaque,
) callconv(.c) ?*anyopaque {
    const desc = descriptor orelse return null;
    const desc_ptr: [*]const u8 = @ptrCast(desc);
    const instance_ref = resolve_device_instance(dev_raw);

    // Try native import path first (IOSurface / CVPixelBuffer via nextInChain).
    if (tryNativeImport(desc_ptr, resolve_device_mtl(dev_raw))) |imported| {
        return createFromNativeImport(imported, instance_ref);
    }

    // Fall back to the DoeTextureView path (Chromium-style descriptor).
    return createFromTextureViews(desc_ptr, instance_ref);
}

fn createFromNativeImport(
    imported: NativePlaneLayout,
    instance_ref: ?*native_types.DoeInstance,
) ?*anyopaque {
    if (instance_ref) |inst| native_helpers.object_add_ref(native_types.DoeInstance, native_helpers.toOpaque(inst));

    const ext = std.heap.c_allocator.create(DoeExternalTexture) catch {
        if (instance_ref) |inst| {
            const last_reference = native_helpers.object_should_destroy(inst);
            std.debug.assert(!last_reference);
        }
        // Release the imported MTLTexture handles on allocation failure.
        external_texture_ops.releasePlanes(imported);
        return null;
    };
    ext.* = .{
        .plane0 = imported.plane0,
        .plane1 = imported.plane1,
        .is_single_plane = imported.is_single_plane,
        .width = imported.width,
        .height = imported.height,
        .native_imported = true,
        .instance = instance_ref,
    };
    if (instance_ref) |inst| instance_register(inst);
    return @ptrCast(ext);
}

fn createFromTextureViews(
    desc_ptr: [*]const u8,
    instance_ref: ?*native_types.DoeInstance,
) ?*anyopaque {
    const plane0 = @as(*const ?*anyopaque, @ptrCast(@alignCast(desc_ptr + PLANE0_OFFSET))).*;
    const plane1 = @as(*const ?*anyopaque, @ptrCast(@alignCast(desc_ptr + PLANE1_OFFSET))).*;
    const plane0_view = texture_sampler.registeredTextureView(plane0) orelse return null;
    const plane1_view = texture_sampler.registeredTextureView(plane1);

    if (instance_ref) |inst| native_helpers.object_add_ref(native_types.DoeInstance, native_helpers.toOpaque(inst));
    native_helpers.object_add_ref(DoeTextureView, native_helpers.toOpaque(plane0_view));
    if (plane1_view) |view| native_helpers.object_add_ref(DoeTextureView, native_helpers.toOpaque(view));

    const ext = std.heap.c_allocator.create(DoeExternalTexture) catch {
        if (instance_ref) |inst| {
            const last_reference = native_helpers.object_should_destroy(inst);
            std.debug.assert(!last_reference);
        }
        native_exports.doeNativeTextureViewRelease(native_helpers.toOpaque(plane0_view));
        if (plane1_view) |view| native_exports.doeNativeTextureViewRelease(native_helpers.toOpaque(view));
        return null;
    };
    ext.* = .{
        .plane0 = plane0,
        .plane1 = plane1,
        .is_single_plane = plane1 == null,
        .instance = instance_ref,
    };
    if (instance_ref) |inst| instance_register(inst);
    return @ptrCast(ext);
}

// -- Lifecycle --

pub export fn doeNativeExternalTextureAddRef(raw: ?*anyopaque) callconv(.c) void {
    native_helpers.object_add_ref(DoeExternalTexture, raw);
}

pub export fn doeNativeExternalTextureRelease(raw: ?*anyopaque) callconv(.c) void {
    const ext = cast(raw) orelse return;
    if (native_helpers.object_should_destroy(ext)) {
        const instance_ref = ext.instance;
        const plane0 = ext.plane0;
        const plane1 = ext.plane1;
        const is_native = ext.native_imported;
        if (instance_ref) |inst| instance_deregister(inst);
        std.heap.c_allocator.destroy(ext);
        if (is_native) {
            // Native-imported: plane0/plane1 are raw MTLTexture handles.
            if (comptime builtin.os.tag == .macos) {
                if (plane0 != null) external_texture_ops.metal_bridge_release(plane0);
                if (plane1 != null) external_texture_ops.metal_bridge_release(plane1);
            }
        } else {
            // DoeTextureView path: release via the standard view lifecycle.
            if (plane0 != null) native_exports.doeNativeTextureViewRelease(plane0);
            if (plane1 != null) native_exports.doeNativeTextureViewRelease(plane1);
        }
        if (instance_ref) |inst| {
            native_exports.doeNativeInstanceRelease(native_helpers.toOpaque(inst));
        }
        return;
    }
}

pub export fn doeNativeExternalTextureDestroy(raw: ?*anyopaque) callconv(.c) void {
    const ext = cast(raw) orelse return;
    ext.expired = true;
}

pub export fn doeNativeExternalTextureExpire(raw: ?*anyopaque) callconv(.c) void {
    const ext = cast(raw) orelse return;
    ext.expired = true;
}

pub export fn doeNativeExternalTextureRefresh(raw: ?*anyopaque) callconv(.c) void {
    const ext = cast(raw) orelse return;
    ext.expired = false;
}

pub export fn doeNativeExternalTextureSetLabel(
    raw: ?*anyopaque,
    _: [*]const u8,
    _: usize,
) callconv(.c) void {
    _ = cast(raw) orelse return;
}
