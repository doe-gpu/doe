// doe_texture_sampler_native.zig — Texture and Sampler C ABI exports.
// Sharded from doe_render_native.zig for file-size compliance.

const std = @import("std");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");
const error_scope = @import("../../runtime/diagnostics/error_scope.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_exports = @import("../support/doe_native_exports.zig");
const texture_validation = @import("doe_texture_validation.zig");
const vulkan_lifetime = @import("../vulkan/vulkan_lifetime.zig");
const d3d12_formats = resource_ops.d3d12_formats;

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const label_store = native_helpers.label_store;

const DoeDevice = native_types.DoeDevice;
const DoeBuffer = native_types.DoeBuffer;
const DoeTexture = native_types.DoeTexture;
const DoeTextureView = native_types.DoeTextureView;
const DoeSampler = native_types.DoeSampler;

// Metal bridge externs (resolved at link time from metal_bridge.m).
extern fn metal_bridge_release(obj: ?*anyopaque) callconv(.c) void;
extern fn d3d12_bridge_release(obj: ?*anyopaque) callconv(.c) void;
extern fn d3d12_bridge_device_create_texture_2d_layered(
    device: ?*anyopaque,
    width: u32,
    height: u32,
    array_layers: u32,
    mip_levels: u32,
    sample_count: u32,
    format: u32,
    usage_flags: u32,
) callconv(.c) ?*anyopaque;
extern fn d3d12_bridge_device_create_texture_3d(
    device: ?*anyopaque,
    width: u32,
    height: u32,
    depth: u32,
    mip_levels: u32,
    format: u32,
    usage_flags: u32,
) callconv(.c) ?*anyopaque;
extern fn d3d12_bridge_texture_create_view(
    texture: ?*anyopaque,
    format: u32,
    dimension: u32,
    aspect: u32,
    base_mip: u32,
    mip_count: u32,
    base_array_layer: u32,
    array_layer_count: u32,
    usage_flags: u64,
) callconv(.c) ?*anyopaque;
extern fn d3d12_bridge_device_create_sampler(
    device: ?*anyopaque,
    min_filter: u32,
    mag_filter: u32,
    mipmap_filter: u32,
    address_mode_u: u32,
    address_mode_v: u32,
    address_mode_w: u32,
    lod_min_clamp: f32,
    lod_max_clamp: f32,
    compare: u32,
    max_anisotropy: u16,
) callconv(.c) ?*anyopaque;
extern fn metal_bridge_device_new_texture(device: ?*anyopaque, width: u32, height: u32, depth_or_array_layers: u32, mip_levels: u32, sample_count: u32, pixel_format: u32, usage: u32, dimension: u32) callconv(.c) ?*anyopaque;
extern fn metal_bridge_texture_new_view(texture: ?*anyopaque, pixel_format: u32, dimension: u32, base_mip_level: u32, mip_level_count: u32, base_array_layer: u32, array_layer_count: u32, swizzle_r: u32, swizzle_g: u32, swizzle_b: u32, swizzle_a: u32) callconv(.c) ?*anyopaque;
extern fn metal_bridge_device_new_sampler(device: ?*anyopaque, min_f: u32, mag_f: u32, mip_f: u32, addr_u: u32, addr_v: u32, addr_w: u32, lod_min: f32, lod_max: f32, max_aniso: u16) callconv(.c) ?*anyopaque;

pub const OpaqueRegistry = struct {
    map: std.AutoHashMapUnmanaged(usize, void) = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn insert(self: *OpaqueRegistry, raw: ?*anyopaque) !void {
        const key = @intFromPtr(raw orelse return error.InvalidState);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(alloc, key, {});
    }

    pub fn contains(self: *OpaqueRegistry, raw: ?*anyopaque) bool {
        const key = @intFromPtr(raw orelse return false);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.contains(key);
    }

    pub fn remove(self: *OpaqueRegistry, raw: ?*anyopaque) void {
        const key = @intFromPtr(raw orelse return);
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(key);
    }
};

pub var d3d12_texture_registry: OpaqueRegistry = .{};
pub var d3d12_texture_view_registry: OpaqueRegistry = .{};
pub var d3d12_sampler_registry: OpaqueRegistry = .{};
var texture_registry: OpaqueRegistry = .{};
var texture_view_registry: OpaqueRegistry = .{};

fn registerTexture(raw: ?*anyopaque) bool {
    texture_registry.insert(raw) catch return false;
    return true;
}

pub fn registerImportedTexture(raw: ?*anyopaque) bool {
    return registerTexture(raw);
}

fn registerTextureView(raw: ?*anyopaque) bool {
    texture_view_registry.insert(raw) catch return false;
    return true;
}

pub fn registeredTexture(raw: ?*anyopaque) ?*DoeTexture {
    if (!texture_registry.contains(raw)) return null;
    return cast(DoeTexture, raw);
}

test "imported textures participate in normal texture lookup" {
    var texture: DoeTexture = .{};
    const raw = toOpaque(&texture);
    defer texture_registry.remove(raw);

    try std.testing.expect(registeredTexture(raw) == null);
    try std.testing.expect(registerImportedTexture(raw));
    try std.testing.expectEqual(&texture, registeredTexture(raw).?);
}

pub fn registeredTextureView(raw: ?*anyopaque) ?*DoeTextureView {
    if (!texture_view_registry.contains(raw)) return null;
    return cast(DoeTextureView, raw);
}

pub fn default_texture_view_dimension(tex: *const DoeTexture) u32 {
    if (tex.texture_binding_view_dimension != 0) return tex.texture_binding_view_dimension;
    return switch (tex.dimension) {
        abi_texture.WGPUTextureDimension_1D => abi_texture.WGPUTextureViewDimension_1D,
        abi_texture.WGPUTextureDimension_3D => abi_texture.WGPUTextureViewDimension_3D,
        else => if (tex.depth_or_array_layers > 1)
            abi_texture.WGPUTextureViewDimension_2DArray
        else
            abi_texture.WGPUTextureViewDimension_2D,
    };
}

pub fn resolveTextureViewMipLevelCount(tex: *const DoeTexture, base_mip_level: u32, requested_count: u32) ?u32 {
    if (base_mip_level >= tex.mip_level_count) return null;
    const remaining = tex.mip_level_count - base_mip_level;
    const resolved = if (requested_count == 0 or requested_count == abi_core.WGPU_MIP_LEVEL_COUNT_UNDEFINED)
        remaining
    else
        requested_count;
    if (resolved == 0 or resolved > remaining) return null;
    return resolved;
}

pub fn resolveTextureViewArrayLayerCount(tex: *const DoeTexture, base_array_layer: u32, requested_count: u32) ?u32 {
    const full_count = if (tex.dimension == abi_texture.WGPUTextureDimension_3D)
        1
    else
        tex.depth_or_array_layers;
    if (base_array_layer >= full_count) return null;
    const remaining = full_count - base_array_layer;
    const resolved = if (requested_count == 0 or requested_count == abi_core.WGPU_ARRAY_LAYER_COUNT_UNDEFINED)
        remaining
    else
        requested_count;
    if (resolved == 0 or resolved > remaining) return null;
    return resolved;
}

fn is_depth_format(format: u32) bool {
    return switch (format) {
        abi_texture.WGPUTextureFormat_Stencil8,
        abi_texture.WGPUTextureFormat_Depth16Unorm,
        abi_texture.WGPUTextureFormat_Depth24Plus,
        abi_texture.WGPUTextureFormat_Depth24PlusStencil8,
        abi_texture.WGPUTextureFormat_Depth32Float,
        abi_texture.WGPUTextureFormat_Depth32FloatStencil8,
        => true,
        else => false,
    };
}

fn is_combined_depth_stencil_format(format: u32) bool {
    return switch (format) {
        abi_texture.WGPUTextureFormat_Depth24PlusStencil8,
        abi_texture.WGPUTextureFormat_Depth32FloatStencil8,
        => true,
        else => false,
    };
}

fn view_aspect_supported(format: u32, aspect: u32) bool {
    const resolved_aspect = if (aspect == 0) abi_texture.WGPUTextureAspect_All else aspect;
    return switch (resolved_aspect) {
        abi_texture.WGPUTextureAspect_All => true,
        abi_texture.WGPUTextureAspect_DepthOnly => switch (format) {
            abi_texture.WGPUTextureFormat_Depth16Unorm, abi_texture.WGPUTextureFormat_Depth24Plus, abi_texture.WGPUTextureFormat_Depth24PlusStencil8, abi_texture.WGPUTextureFormat_Depth32Float, abi_texture.WGPUTextureFormat_Depth32FloatStencil8 => true,
            else => false,
        },
        abi_texture.WGPUTextureAspect_StencilOnly => switch (format) {
            abi_texture.WGPUTextureFormat_Stencil8, abi_texture.WGPUTextureFormat_Depth24PlusStencil8, abi_texture.WGPUTextureFormat_Depth32FloatStencil8 => true,
            else => false,
        },
        else => false,
    };
}

fn d3d12_sampled_aspect(format: u32, aspect: u32) u32 {
    const resolved_aspect = if (aspect == 0) abi_texture.WGPUTextureAspect_All else aspect;
    if (is_combined_depth_stencil_format(format)) {
        return if (resolved_aspect == abi_texture.WGPUTextureAspect_StencilOnly)
            abi_texture.WGPUTextureAspect_StencilOnly
        else
            abi_texture.WGPUTextureAspect_DepthOnly;
    }
    if (format == abi_texture.WGPUTextureFormat_Stencil8) return abi_texture.WGPUTextureAspect_StencilOnly;
    return resolved_aspect;
}

fn identity_swizzle(swizzle_r: u32, swizzle_g: u32, swizzle_b: u32, swizzle_a: u32) bool {
    return swizzle_r == abi_texture.WGPUTextureComponentSwizzle_Red and
        swizzle_g == abi_texture.WGPUTextureComponentSwizzle_Green and
        swizzle_b == abi_texture.WGPUTextureComponentSwizzle_Blue and
        swizzle_a == abi_texture.WGPUTextureComponentSwizzle_Alpha;
}

const TextureViewSwizzle = struct { r: u32, g: u32, b: u32, a: u32 };

pub fn resolveTextureViewSwizzle(desc: *const abi_pipeline.WGPUTextureViewDescriptor) TextureViewSwizzle {
    var result = TextureViewSwizzle{
        .r = abi_texture.WGPUTextureComponentSwizzle_Red,
        .g = abi_texture.WGPUTextureComponentSwizzle_Green,
        .b = abi_texture.WGPUTextureComponentSwizzle_Blue,
        .a = abi_texture.WGPUTextureComponentSwizzle_Alpha,
    };
    var chain = desc.nextInChain;
    while (chain != null) {
        const item: *const abi_pipeline.WGPUChainedStruct = @ptrCast(chain);
        if (item.sType == abi_core.WGPUSType_TextureComponentSwizzleDescriptor) {
            const extension: *const abi_pipeline.WGPUTextureComponentSwizzleDescriptor = @ptrCast(item);
            if (extension.swizzle.r != 0) result.r = extension.swizzle.r;
            if (extension.swizzle.g != 0) result.g = extension.swizzle.g;
            if (extension.swizzle.b != 0) result.b = extension.swizzle.b;
            if (extension.swizzle.a != 0) result.a = extension.swizzle.a;
        }
        chain = item.next;
    }
    return result;
}

pub fn canBorrowMetalTextureForFullView(
    tex: *const DoeTexture,
    resolved_format: u32,
    resolved_dimension: u32,
    base_mip_level: u32,
    resolved_mip_level_count: u32,
    base_array_layer: u32,
    resolved_array_layer_count: u32,
    resolved_aspect: u32,
    resolved_usage: u64,
    resolved_swizzle_r: u32,
    resolved_swizzle_g: u32,
    resolved_swizzle_b: u32,
    resolved_swizzle_a: u32,
) bool {
    const full_array_layer_count = if (tex.dimension == abi_texture.WGPUTextureDimension_3D)
        1
    else
        tex.depth_or_array_layers;
    return tex.mtl != null and
        resolved_format == tex.format and
        resolved_dimension == default_texture_view_dimension(tex) and
        base_mip_level == 0 and
        resolved_mip_level_count == tex.mip_level_count and
        base_array_layer == 0 and
        resolved_array_layer_count == full_array_layer_count and
        resolved_aspect == abi_texture.WGPUTextureAspect_All and
        (resolved_usage & ~tex.usage) == 0 and
        identity_swizzle(resolved_swizzle_r, resolved_swizzle_g, resolved_swizzle_b, resolved_swizzle_a);
}

fn d3d12_texture_descriptor_supported(desc: *const abi_pipeline.WGPUTextureDescriptor) bool {
    if ((desc.usage & (abi_texture.WGPUTextureUsage_TransientAttachment | abi_texture.WGPUTextureUsage_StorageAttachment)) != 0) return false;
    if (desc.dimension == abi_texture.WGPUTextureDimension_1D) return false;
    if (desc.dimension == abi_texture.WGPUTextureDimension_3D and desc.sampleCount > 1) return false;
    if (desc.viewFormatCount > 0) {
        const view_formats = desc.viewFormats orelse return false;
        var i: usize = 0;
        while (i < desc.viewFormatCount) : (i += 1) {
            if (view_formats[i] != desc.format) return false;
        }
    }
    return true;
}

fn d3d12_view_dimension_supported(tex: *const DoeTexture, view_dimension: u32) bool {
    return switch (tex.dimension) {
        abi_texture.WGPUTextureDimension_3D => view_dimension == abi_texture.WGPUTextureViewDimension_3D,
        abi_texture.WGPUTextureDimension_2D => switch (view_dimension) {
            abi_texture.WGPUTextureViewDimension_2D,
            abi_texture.WGPUTextureViewDimension_2DArray,
            => true,
            abi_texture.WGPUTextureViewDimension_2DDepth,
            abi_texture.WGPUTextureViewDimension_2DArrayDepth,
            => is_depth_format(tex.format),
            abi_texture.WGPUTextureViewDimension_Cube,
            abi_texture.WGPUTextureViewDimension_CubeArray,
            => tex.depth_or_array_layers >= 6 and (tex.depth_or_array_layers % 6) == 0,
            else => false,
        },
        else => false,
    };
}

fn d3d12_register_texture(raw: ?*anyopaque) bool {
    d3d12_texture_registry.insert(raw) catch return false;
    return true;
}

fn d3d12_register_texture_view(raw: ?*anyopaque) bool {
    d3d12_texture_view_registry.insert(raw) catch return false;
    return true;
}

fn d3d12_register_sampler(raw: ?*anyopaque) bool {
    d3d12_sampler_registry.insert(raw) catch return false;
    return true;
}

// ============================================================
// Texture
// ============================================================

test "texture usage parser includes Dawn internal usage" {
    var internal = abi_pipeline.WGPUDawnTextureInternalUsageDescriptor{
        .chain = .{
            .next = null,
            .sType = abi_pipeline.WGPUSType_DawnTextureInternalUsageDescriptor,
        },
        .internalUsage = abi_texture.WGPUTextureUsage_CopySrc | abi_texture.WGPUTextureUsage_CopyDst,
    };
    var desc = abi_pipeline.WGPUTextureDescriptor{
        .nextInChain = @ptrCast(&internal.chain),
        .label = .{ .data = null, .length = 0 },
        .usage = abi_texture.WGPUTextureUsage_RenderAttachment,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .size = .{ .width = 64, .height = 64, .depthOrArrayLayers = 1 },
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    };

    try std.testing.expectEqual(
        abi_texture.WGPUTextureUsage_RenderAttachment |
            abi_texture.WGPUTextureUsage_CopySrc |
            abi_texture.WGPUTextureUsage_CopyDst,
        texture_validation.effectiveTextureUsage(&desc),
    );
}

pub export fn doeNativeDeviceValidateTextureDescriptor(
    dev_raw: ?*anyopaque,
    desc: ?*const abi_pipeline.WGPUTextureDescriptor,
) callconv(.c) void {
    const dev = cast(DoeDevice, dev_raw) orelse return;
    const d = desc orelse {
        dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "texture descriptor is null");
        return;
    };
    if (texture_validation.validateTextureDescriptor(dev, d)) |message| {
        dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, message);
    }
}

pub export fn doeNativeDeviceCreateTexture(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUTextureDescriptor) callconv(.c) ?*anyopaque {
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse {
        dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "texture descriptor is null");
        return null;
    };
    if (texture_validation.validateTextureDescriptor(dev, d)) |message| {
        dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, message);
        return null;
    }
    const usage = texture_validation.effectiveTextureUsage(d);
    const tex = make(DoeTexture) orelse return null;
    tex.* = .{
        .format = d.format,
        .width = d.size.width,
        .height = d.size.height,
        .depth_or_array_layers = d.size.depthOrArrayLayers,
        .dimension = d.dimension,
        .mip_level_count = d.mipLevelCount,
        .sample_count = d.sampleCount,
        .usage = usage,
        .texture_binding_view_dimension = 0,
        .view_format_count = d.viewFormatCount,
    };
    if (dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        if (!vk_render.vulkan_create_texture(dev, tex, d)) {
            alloc.destroy(tex);
            return null;
        }
        const result = toOpaque(tex);
        if (!registerTexture(result)) {
            vk_render.vulkan_destroy_texture(tex);
            alloc.destroy(tex);
            return null;
        }
        label_store.set(result, d.label.data, d.label.length);
        return result;
    }
    if (dev.backend == .d3d12) {
        if (!d3d12_texture_descriptor_supported(d)) {
            alloc.destroy(tex);
            return null;
        }
        const d3d12_texture = switch (d.dimension) {
            abi_texture.WGPUTextureDimension_2D => d3d12_bridge_device_create_texture_2d_layered(
                dev.mtl_device,
                d.size.width,
                d.size.height,
                d.size.depthOrArrayLayers,
                d.mipLevelCount,
                d.sampleCount,
                d.format,
                @intCast(usage),
            ),
            abi_texture.WGPUTextureDimension_3D => d3d12_bridge_device_create_texture_3d(
                dev.mtl_device,
                d.size.width,
                d.size.height,
                d.size.depthOrArrayLayers,
                d.mipLevelCount,
                d.format,
                @intCast(usage),
            ),
            else => null,
        } orelse {
            alloc.destroy(tex);
            return null;
        };
        tex.mtl = d3d12_texture;
        const result = toOpaque(tex);
        if (!registerTexture(result)) {
            d3d12_bridge_release(d3d12_texture);
            alloc.destroy(tex);
            return null;
        }
        if (!d3d12_register_texture(result)) {
            texture_registry.remove(result);
            d3d12_bridge_release(d3d12_texture);
            alloc.destroy(tex);
            return null;
        }
        label_store.set(result, d.label.data, d.label.length);
        return result;
    }
    // Metal path.
    const mtl = metal_bridge_device_new_texture(dev.mtl_device, d.size.width, d.size.height, d.size.depthOrArrayLayers, d.mipLevelCount, d.sampleCount, d.format, @intCast(usage), d.dimension) orelse {
        alloc.destroy(tex);
        return null;
    };
    tex.mtl = mtl;
    const result = toOpaque(tex);
    if (!registerTexture(result)) {
        metal_bridge_release(mtl);
        alloc.destroy(tex);
        return null;
    }
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeTextureCreateView(tex_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUTextureViewDescriptor) callconv(.c) ?*anyopaque {
    const tex = cast(DoeTexture, tex_raw) orelse return null;
    if (tex.error_object) return null;
    var default_desc = abi_pipeline.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .format = tex.format,
        .dimension = default_texture_view_dimension(tex),
        .baseMipLevel = 0,
        .mipLevelCount = tex.mip_level_count,
        .baseArrayLayer = 0,
        .arrayLayerCount = if (tex.dimension == abi_texture.WGPUTextureDimension_3D) 1 else tex.depth_or_array_layers,
        .aspect = abi_texture.WGPUTextureAspect_All,
        .usage = tex.usage,
    };
    const requested = desc orelse &default_desc;
    const resolved_mip_level_count = resolveTextureViewMipLevelCount(tex, requested.baseMipLevel, requested.mipLevelCount) orelse return null;
    const resolved_array_layer_count = resolveTextureViewArrayLayerCount(tex, requested.baseArrayLayer, requested.arrayLayerCount) orelse return null;
    var normalized_desc = requested.*;
    normalized_desc.mipLevelCount = resolved_mip_level_count;
    normalized_desc.arrayLayerCount = resolved_array_layer_count;
    const d = &normalized_desc;
    const resolved_format = if (d.format != 0) d.format else tex.format;
    const resolved_dimension = if (d.dimension != 0) d.dimension else default_texture_view_dimension(tex);
    const resolved_usage = if (d.usage != 0) d.usage else tex.usage;
    const resolved_swizzle = resolveTextureViewSwizzle(d);
    const resolved_swizzle_r = resolved_swizzle.r;
    const resolved_swizzle_g = resolved_swizzle.g;
    const resolved_swizzle_b = resolved_swizzle.b;
    const resolved_swizzle_a = resolved_swizzle.a;
    const tv = make(DoeTextureView) orelse return null;
    native_helpers.object_add_ref(DoeTexture, tex_raw);
    if (tex.mtl == null and tex.vk_id != 0) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        if (!vk_render.vulkan_create_texture_view(tex, tv, d, resolved_swizzle_r, resolved_swizzle_g, resolved_swizzle_b, resolved_swizzle_a)) {
            native_exports.doeNativeTextureRelease(tex_raw);
            alloc.destroy(tv);
            return null;
        }
    }
    const is_d3d12_texture = d3d12_texture_registry.contains(tex_raw);
    var view_handle: ?*anyopaque = tv.handle;
    if (is_d3d12_texture) {
        const resolved_aspect = if (d.aspect != 0) d.aspect else abi_texture.WGPUTextureAspect_All;
        const wants_storage_only =
            (resolved_usage & abi_texture.WGPUTextureUsage_StorageBinding) != 0 and
            (resolved_usage & abi_texture.WGPUTextureUsage_TextureBinding) == 0;

        if (resolved_format != tex.format or
            !identity_swizzle(resolved_swizzle_r, resolved_swizzle_g, resolved_swizzle_b, resolved_swizzle_a) or
            !d3d12_view_dimension_supported(tex, resolved_dimension) or
            !view_aspect_supported(tex.format, resolved_aspect))
        {
            native_exports.doeNativeTextureRelease(tex_raw);
            alloc.destroy(tv);
            return null;
        }
        if ((resolved_dimension == abi_texture.WGPUTextureViewDimension_Cube or
            resolved_dimension == abi_texture.WGPUTextureViewDimension_CubeArray) and
            ((d.baseArrayLayer % 6) != 0 or (resolved_array_layer_count % 6) != 0))
        {
            native_exports.doeNativeTextureRelease(tex_raw);
            alloc.destroy(tv);
            return null;
        }
        if ((resolved_usage & abi_texture.WGPUTextureUsage_StorageBinding) != 0 and
            (resolved_usage & abi_texture.WGPUTextureUsage_TextureBinding) != 0)
        {
            native_exports.doeNativeTextureRelease(tex_raw);
            alloc.destroy(tv);
            return null;
        }
        if (wants_storage_only) {
            if (tex.sample_count > 1 or is_depth_format(tex.format) or resolved_mip_level_count != 1) {
                native_exports.doeNativeTextureRelease(tex_raw);
                alloc.destroy(tv);
                return null;
            }
            view_handle = d3d12_bridge_texture_create_view(
                tex.mtl,
                resolved_format,
                resolved_dimension,
                resolved_aspect,
                d.baseMipLevel,
                resolved_mip_level_count,
                d.baseArrayLayer,
                resolved_array_layer_count,
                abi_texture.WGPUTextureUsage_StorageBinding,
            ) orelse {
                native_exports.doeNativeTextureRelease(tex_raw);
                alloc.destroy(tv);
                return null;
            };
        } else if (tex.sample_count == 1) {
            view_handle = d3d12_bridge_texture_create_view(
                tex.mtl,
                resolved_format,
                resolved_dimension,
                d3d12_sampled_aspect(tex.format, resolved_aspect),
                d.baseMipLevel,
                resolved_mip_level_count,
                d.baseArrayLayer,
                resolved_array_layer_count,
                abi_texture.WGPUTextureUsage_TextureBinding,
            );
        } else {
            view_handle = null;
        }
    } else if (tex.mtl != null) {
        const resolved_aspect = if (d.aspect != 0) d.aspect else abi_texture.WGPUTextureAspect_All;
        if (canBorrowMetalTextureForFullView(
            tex,
            resolved_format,
            resolved_dimension,
            d.baseMipLevel,
            resolved_mip_level_count,
            d.baseArrayLayer,
            resolved_array_layer_count,
            resolved_aspect,
            resolved_usage,
            resolved_swizzle_r,
            resolved_swizzle_g,
            resolved_swizzle_b,
            resolved_swizzle_a,
        )) {
            view_handle = tex.mtl;
        } else {
            view_handle = metal_bridge_texture_new_view(
                tex.mtl,
                resolved_format,
                resolved_dimension,
                d.baseMipLevel,
                resolved_mip_level_count,
                d.baseArrayLayer,
                resolved_array_layer_count,
                resolved_swizzle_r,
                resolved_swizzle_g,
                resolved_swizzle_b,
                resolved_swizzle_a,
            ) orelse {
                native_exports.doeNativeTextureRelease(tex_raw);
                alloc.destroy(tv);
                return null;
            };
        }
    }
    tv.* = .{
        .tex = tex,
        .handle = view_handle,
        .format = resolved_format,
        .dimension = resolved_dimension,
        .base_mip_level = d.baseMipLevel,
        .mip_level_count = resolved_mip_level_count,
        .base_array_layer = d.baseArrayLayer,
        .array_layer_count = resolved_array_layer_count,
        .aspect = if (d.aspect != 0) d.aspect else abi_texture.WGPUTextureAspect_All,
        .usage = resolved_usage,
    };
    const result = toOpaque(tv);
    if (!registerTextureView(result)) {
        if (view_handle) |handle| {
            if (is_d3d12_texture) {
                d3d12_bridge_release(handle);
            } else if (tex.mtl == null or handle != tex.mtl) {
                metal_bridge_release(handle);
            }
        }
        native_exports.doeNativeTextureRelease(tex_raw);
        alloc.destroy(tv);
        return null;
    }
    if (is_d3d12_texture and !d3d12_register_texture_view(result)) {
        texture_view_registry.remove(result);
        if (view_handle) |handle| d3d12_bridge_release(handle);
        native_exports.doeNativeTextureRelease(tex_raw);
        alloc.destroy(tv);
        return null;
    }
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeTextureDestroy(raw: ?*anyopaque) callconv(.c) void {
    _ = cast(DoeTexture, raw) orelse return;
}

pub export fn doeNativeTextureRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeTexture, raw)) |t| {
        if (!native_helpers.object_should_destroy(t)) return;
        texture_registry.remove(raw);
        label_store.remove(raw);
        if (d3d12_texture_registry.contains(raw)) {
            d3d12_texture_registry.remove(raw);
            if (t.mtl) |m| d3d12_bridge_release(m);
            alloc.destroy(t);
            return;
        }
        if (t.vk_id != 0) {
            vulkan_lifetime.flushBeforeDestroy(t.vk_runtime_ref);
            const vk_render = @import("../vulkan/vulkan_render_native.zig");
            vk_render.vulkan_destroy_texture(t);
            alloc.destroy(t);
            return;
        }
        if (t.mtl) |m| metal_bridge_release(m);
        alloc.destroy(t);
    }
}

pub export fn doeNativeTextureViewRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeTextureView, raw)) |tv| {
        if (!native_helpers.object_should_destroy(tv)) return;
        const texture = tv.tex;
        texture_view_registry.remove(raw);
        label_store.remove(raw);
        if (d3d12_texture_view_registry.contains(raw)) {
            d3d12_texture_view_registry.remove(raw);
            if (tv.handle) |handle| d3d12_bridge_release(handle);
            alloc.destroy(tv);
            native_exports.doeNativeTextureRelease(toOpaque(texture));
            return;
        }
        if (tv.tex.vk_id != 0) {
            vulkan_lifetime.flushBeforeDestroy(tv.tex.vk_runtime_ref);
            const vk_render = @import("../vulkan/vulkan_render_native.zig");
            vk_render.vulkan_destroy_texture_view(tv);
            alloc.destroy(tv);
            native_exports.doeNativeTextureRelease(toOpaque(texture));
            return;
        }
        if (tv.handle) |handle| {
            if (tv.tex.mtl == null or handle != tv.tex.mtl) metal_bridge_release(handle);
        }
        alloc.destroy(tv);
        native_exports.doeNativeTextureRelease(toOpaque(texture));
    }
}

// ============================================================
// Sampler
// ============================================================

pub export fn doeNativeDeviceCreateSampler(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUSamplerDescriptor) callconv(.c) ?*anyopaque {
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;
    const s = make(DoeSampler) orelse return null;
    s.* = .{};
    if (dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        if (!vk_render.vulkan_create_sampler(dev, s, d)) {
            alloc.destroy(s);
            return null;
        }
        const result = toOpaque(s);
        label_store.set(result, d.label.data, d.label.length);
        return result;
    }
    if (dev.backend == .d3d12) {
        const sampler = d3d12_bridge_device_create_sampler(
            dev.mtl_device,
            d.minFilter,
            d.magFilter,
            d.mipmapFilter,
            d.addressModeU,
            d.addressModeV,
            d.addressModeW,
            d.lodMinClamp,
            d.lodMaxClamp,
            d.compare,
            d.maxAnisotropy,
        ) orelse {
            alloc.destroy(s);
            return null;
        };
        s.* = .{ .mtl = sampler };
        const result = toOpaque(s);
        if (!d3d12_register_sampler(result)) {
            d3d12_bridge_release(sampler);
            alloc.destroy(s);
            return null;
        }
        label_store.set(result, d.label.data, d.label.length);
        return result;
    }
    // Metal path.
    const mtl = metal_bridge_device_new_sampler(dev.mtl_device, d.minFilter, d.magFilter, d.mipmapFilter, d.addressModeU, d.addressModeV, d.addressModeW, d.lodMinClamp, d.lodMaxClamp, d.maxAnisotropy) orelse {
        alloc.destroy(s);
        return null;
    };
    s.* = .{ .mtl = mtl };
    const result = toOpaque(s);
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeSamplerRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeSampler, raw)) |s| {
        if (!native_helpers.object_should_destroy(s)) return;
        label_store.remove(raw);
        if (d3d12_sampler_registry.contains(raw)) {
            d3d12_sampler_registry.remove(raw);
            if (s.mtl) |m| d3d12_bridge_release(m);
            alloc.destroy(s);
            return;
        }
        if (s.vk_runtime_ref) |rt_ptr| {
            const NativeVulkanRuntime = native_shared.NativeVulkanRuntime;
            vulkan_lifetime.flushBeforeDestroy(rt_ptr);
            const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
            const vk_render = @import("../vulkan/vulkan_render_native.zig");
            vk_render.vulkan_destroy_sampler(s, rt);
            alloc.destroy(s);
            return;
        }
        if (s.mtl) |m| metal_bridge_release(m);
        alloc.destroy(s);
    }
}
