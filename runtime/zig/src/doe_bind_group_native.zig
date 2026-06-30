// doe_bind_group_native.zig — Bind group, bind group layout, and pipeline layout
// C ABI exports for the Doe native Metal/Vulkan backend. Sharded from doe_wgpu_native.zig.

const std = @import("std");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_exports = @import("doe_native_exports.zig");
const abi_core = @import("core/abi/wgpu_core_base_types.zig");
const abi_texture = @import("core/abi/wgpu_texture_base_types.zig");
const abi_binding = @import("core/abi/wgpu_binding_base_types.zig");
const abi_callback = @import("core/abi/wgpu_callback_descriptor_types.zig");
const abi_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
const texture_sampler = @import("doe_texture_sampler_native.zig");

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const MAX_BIND = native_shared.MAX_BIND;
const MAX_COMPUTE_BIND_GROUPS = native_shared.MAX_COMPUTE_BIND_GROUPS;
const label_store = native_helpers.label_store;

const DoeDevice = native_types.DoeDevice;
const DoeBuffer = native_types.DoeBuffer;
const DoeTexture = native_types.DoeTexture;
const DoeSampler = native_types.DoeSampler;
const DoeBindGroupLayoutEntry = native_shared.DoeBindGroupLayoutEntry;
const DoeBindGroupLayout = native_types.DoeBindGroupLayout;
const DoeBindGroup = native_types.DoeBindGroup;
const DoePipelineLayout = native_types.DoePipelineLayout;
const DoeTextureView = native_types.DoeTextureView;
const DoeExternalTexture = @import("doe_external_texture_native.zig").DoeExternalTexture;

const RESOURCE_KIND_NONE: u32 = 0;
const RESOURCE_KIND_BUFFER: u32 = 1;
const RESOURCE_KIND_SAMPLER: u32 = 2;
const RESOURCE_KIND_TEXTURE: u32 = 3;
const RESOURCE_KIND_STORAGE_TEXTURE: u32 = 4;
const RESOURCE_KIND_EXTERNAL_TEXTURE: u32 = 5;
const FLAT_BUFFER_BIND_GROUP_ENTRY_LIMIT: u32 = 4;

fn chained_struct(raw: ?*anyopaque) ?*const abi_callback.WGPUChainedStruct {
    const ptr = raw orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn has_chain_type(raw: ?*anyopaque, s_type: abi_core.WGPUSType) bool {
    const chain = chained_struct(raw) orelse return false;
    return chain.sType == s_type;
}

fn external_texture_layout_chain(raw: ?*anyopaque) ?*const abi_pipeline.WGPUExternalTextureBindingLayout {
    if (!has_chain_type(raw, abi_core.WGPUSType_ExternalTextureBindingLayout)) return null;
    const ptr = raw orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn external_texture_entry_chain(raw: ?*anyopaque) ?*const abi_pipeline.WGPUExternalTextureBindingEntry {
    if (!has_chain_type(raw, abi_core.WGPUSType_ExternalTextureBindingEntry)) return null;
    const ptr = raw orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn buffer_binding_type_active(value: u32) bool {
    return value != abi_binding.WGPUBufferBindingType_BindingNotUsed and
        value != abi_binding.WGPUBufferBindingType_Undefined;
}

fn texture_sample_type_active(value: u32) bool {
    return value != abi_binding.WGPUTextureSampleType_BindingNotUsed and
        value != abi_binding.WGPUTextureSampleType_Undefined;
}

fn storage_texture_access_active(value: u32) bool {
    return value != abi_binding.WGPUStorageTextureAccess_BindingNotUsed and
        value != abi_binding.WGPUStorageTextureAccess_Undefined;
}

fn sampler_binding_type_active(value: u32) bool {
    return value != abi_binding.WGPUSamplerBindingType_BindingNotUsed and
        value != abi_binding.WGPUSamplerBindingType_Undefined;
}

fn classify_layout_entry(entry: abi_pipeline.WGPUBindGroupLayoutEntry) DoeBindGroupLayoutEntry {
    var out = DoeBindGroupLayoutEntry{
        .binding = entry.binding,
        .resource_kind = RESOURCE_KIND_NONE,
        .binding_array_size = entry.bindingArraySize,
    };
    if (buffer_binding_type_active(entry.buffer.type)) {
        out.resource_kind = RESOURCE_KIND_BUFFER;
        return out;
    }
    if (texture_sample_type_active(entry.texture.sampleType)) {
        out.resource_kind = RESOURCE_KIND_TEXTURE;
        out.texture_sample_type = entry.texture.sampleType;
        out.texture_view_dimension = entry.texture.viewDimension;
        out.texture_multisampled = entry.texture.multisampled != 0;
        return out;
    }
    if (storage_texture_access_active(entry.storageTexture.access)) {
        out.resource_kind = RESOURCE_KIND_STORAGE_TEXTURE;
        out.texture_sample_type = entry.storageTexture.access;
        out.texture_view_dimension = entry.storageTexture.viewDimension;
        return out;
    }
    if (sampler_binding_type_active(entry.sampler.type)) {
        out.resource_kind = RESOURCE_KIND_SAMPLER;
        return out;
    }
    if (external_texture_layout_chain(entry.nextInChain) != null) {
        out.resource_kind = RESOURCE_KIND_EXTERNAL_TEXTURE;
    }
    return out;
}

fn infer_texture_sample_type(tex: *DoeTexture) u32 {
    return switch (tex.format) {
        abi_texture.WGPUTextureFormat_Depth16Unorm,
        abi_texture.WGPUTextureFormat_Depth24Plus,
        abi_texture.WGPUTextureFormat_Depth24PlusStencil8,
        abi_texture.WGPUTextureFormat_Depth32Float,
        abi_texture.WGPUTextureFormat_Depth32FloatStencil8,
        => abi_binding.WGPUTextureSampleType_Depth,
        abi_texture.WGPUTextureFormat_R8Uint,
        abi_texture.WGPUTextureFormat_R16Uint,
        abi_texture.WGPUTextureFormat_RG8Uint,
        abi_texture.WGPUTextureFormat_R32Uint,
        abi_texture.WGPUTextureFormat_RG16Uint,
        abi_texture.WGPUTextureFormat_RGBA8Uint,
        abi_texture.WGPUTextureFormat_RGB10A2Uint,
        abi_texture.WGPUTextureFormat_RG32Uint,
        abi_texture.WGPUTextureFormat_RGBA16Uint,
        abi_texture.WGPUTextureFormat_RGBA32Uint,
        => abi_binding.WGPUTextureSampleType_Uint,
        abi_texture.WGPUTextureFormat_R8Sint,
        abi_texture.WGPUTextureFormat_R16Sint,
        abi_texture.WGPUTextureFormat_RG8Sint,
        abi_texture.WGPUTextureFormat_R32Sint,
        abi_texture.WGPUTextureFormat_RG16Sint,
        abi_texture.WGPUTextureFormat_RGBA8Sint,
        abi_texture.WGPUTextureFormat_RG32Sint,
        abi_texture.WGPUTextureFormat_RGBA16Sint,
        abi_texture.WGPUTextureFormat_RGBA32Sint,
        => abi_binding.WGPUTextureSampleType_Sint,
        else => abi_binding.WGPUTextureSampleType_Float,
    };
}

fn resolve_view_dimension(view: *DoeTextureView) u32 {
    if (view.dimension != 0) return view.dimension;
    if (view.tex.texture_binding_view_dimension != 0) return view.tex.texture_binding_view_dimension;
    return switch (view.tex.dimension) {
        abi_texture.WGPUTextureDimension_1D => abi_texture.WGPUTextureViewDimension_1D,
        abi_texture.WGPUTextureDimension_3D => abi_texture.WGPUTextureViewDimension_3D,
        else => abi_texture.WGPUTextureViewDimension_2D,
    };
}

fn texture_aspect_matches(tex: *DoeTexture, view: *DoeTextureView) bool {
    const aspect = if (view.aspect != 0) view.aspect else abi_texture.WGPUTextureAspect_All;
    return switch (aspect) {
        abi_texture.WGPUTextureAspect_All => true,
        abi_texture.WGPUTextureAspect_DepthOnly => switch (tex.format) {
            abi_texture.WGPUTextureFormat_Stencil8 => false,
            abi_texture.WGPUTextureFormat_Depth16Unorm, abi_texture.WGPUTextureFormat_Depth24Plus, abi_texture.WGPUTextureFormat_Depth24PlusStencil8, abi_texture.WGPUTextureFormat_Depth32Float, abi_texture.WGPUTextureFormat_Depth32FloatStencil8 => true,
            else => false,
        },
        abi_texture.WGPUTextureAspect_StencilOnly => switch (tex.format) {
            abi_texture.WGPUTextureFormat_Stencil8, abi_texture.WGPUTextureFormat_Depth24PlusStencil8, abi_texture.WGPUTextureFormat_Depth32FloatStencil8 => true,
            else => false,
        },
        else => false,
    };
}

fn storage_texture_access_supported(access: u32) bool {
    return switch (access) {
        abi_binding.WGPUStorageTextureAccess_Undefined, abi_binding.WGPUStorageTextureAccess_WriteOnly, abi_binding.WGPUStorageTextureAccess_ReadOnly, abi_binding.WGPUStorageTextureAccess_ReadWrite => true,
        else => false,
    };
}

fn texture_view_matches_layout(layout_entry: DoeBindGroupLayoutEntry, view: *DoeTextureView) bool {
    const tex = view.tex;
    if (layout_entry.texture_multisampled != (tex.sample_count > 1)) return false;
    if (layout_entry.texture_view_dimension != 0 and
        layout_entry.texture_view_dimension != abi_texture.WGPUTextureViewDimension_Undefined and
        layout_entry.texture_view_dimension != resolve_view_dimension(view)) return false;
    if (layout_entry.texture_sample_type != 0 and
        layout_entry.texture_sample_type != abi_binding.WGPUTextureSampleType_Undefined and
        layout_entry.texture_sample_type != infer_texture_sample_type(tex)) return false;
    if (!texture_aspect_matches(tex, view)) return false;
    return true;
}

fn storage_texture_matches_layout(layout_entry: DoeBindGroupLayoutEntry, view: *DoeTextureView) bool {
    switch (view.tex.format) {
        abi_texture.WGPUTextureFormat_Stencil8, abi_texture.WGPUTextureFormat_Depth16Unorm, abi_texture.WGPUTextureFormat_Depth24Plus, abi_texture.WGPUTextureFormat_Depth24PlusStencil8, abi_texture.WGPUTextureFormat_Depth32Float, abi_texture.WGPUTextureFormat_Depth32FloatStencil8 => return false,
        else => {},
    }
    const usage = view.usage | view.tex.usage;
    if ((usage & abi_texture.WGPUTextureUsage_StorageBinding) == 0) return false;
    if (layout_entry.texture_view_dimension != 0 and
        layout_entry.texture_view_dimension != abi_texture.WGPUTextureViewDimension_Undefined and
        layout_entry.texture_view_dimension != resolve_view_dimension(view)) return false;
    if (!texture_aspect_matches(view.tex, view)) return false;
    return storage_texture_access_supported(layout_entry.texture_sample_type);
}

fn find_layout_entry(layout: *DoeBindGroupLayout, binding: u32) ?DoeBindGroupLayoutEntry {
    const entries = layout.entries orelse return null;
    for (entries) |entry| {
        if (entry.binding == binding) return entry;
    }
    return null;
}

fn retain_buffer(bg: *DoeBindGroup, binding: usize, buffer: *DoeBuffer) void {
    native_helpers.object_add_ref(DoeBuffer, toOpaque(buffer));
    bg.retained_buffers[binding] = buffer;
}

fn remember_vulkan_buffer_binding(bg: *DoeBindGroup, binding: usize, buffer: *const DoeBuffer) void {
    if (buffer.vk_id == 0) return;
    bg.vk_buffer_handles[binding] = buffer.vk_id;
    bg.vk_buffer_binding_mask |= @as(u64, 1) << @intCast(binding);
}

fn resolve_buffer_binding_size(buffer: *const DoeBuffer, offset: u64, requested_size: u64) ?u64 {
    if (offset > buffer.size) return null;
    if (requested_size == abi_core.WGPU_WHOLE_SIZE) return buffer.size - offset;
    const end = std.math.add(u64, offset, requested_size) catch return null;
    if (end > buffer.size) return null;
    return requested_size;
}

fn retain_texture_view(bg: *DoeBindGroup, binding: usize, view: *DoeTextureView) void {
    native_helpers.object_add_ref(DoeTextureView, toOpaque(view));
    bg.retained_texture_views[binding] = view;
}

fn retain_sampler(bg: *DoeBindGroup, binding: usize, sampler: *DoeSampler) void {
    native_helpers.object_add_ref(DoeSampler, toOpaque(sampler));
    bg.retained_samplers[binding] = sampler;
}

fn retain_external_texture(bg: *DoeBindGroup, binding: usize, external_texture: abi_core.WGPUExternalTexture) void {
    native_helpers.object_add_ref(DoeExternalTexture, external_texture);
    bg.retained_external_textures[binding] = external_texture;
}

fn resolve_external_texture(entry: abi_pipeline.WGPUBindGroupEntry) ?abi_core.WGPUExternalTexture {
    if (external_texture_entry_chain(entry.nextInChain)) |chain| {
        return chain.externalTexture;
    }
    return null;
}

// ============================================================
// Bind Group Layout / Bind Group / Pipeline Layout
// ============================================================

pub export fn doeNativeDeviceCreateBindGroupLayout(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUBindGroupLayoutDescriptor) callconv(.c) ?*anyopaque {
    _ = dev_raw;
    const d = desc orelse return null;
    if (d.entryCount > 0 and d.entries == null) {
        return null;
    }
    const bgl = make(DoeBindGroupLayout) orelse return null;
    var stored_entries: ?[]DoeBindGroupLayoutEntry = null;
    if (d.entryCount > 0) {
        stored_entries = alloc.alloc(DoeBindGroupLayoutEntry, d.entryCount) catch {
            alloc.destroy(bgl);
            return null;
        };
        for (d.entries.?[0..d.entryCount], 0..) |entry, i| {
            stored_entries.?[i] = classify_layout_entry(entry);
        }
    }
    bgl.* = .{
        .entry_count = @intCast(d.entryCount),
        .entries = stored_entries,
    };
    const result = toOpaque(bgl);
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeDeviceCreateBufferBindGroupLayoutFlat4(dev_raw: ?*anyopaque, entry_count: u32, b0: u32, b1: u32, b2: u32, b3: u32) callconv(.c) ?*anyopaque {
    _ = dev_raw;
    if (entry_count > FLAT_BUFFER_BIND_GROUP_ENTRY_LIMIT) return null;
    const bgl = make(DoeBindGroupLayout) orelse return null;
    bgl.* = .{
        .entry_count = entry_count,
        .entries_inline = true,
    };
    if (entry_count > 0) {
        const count: usize = @intCast(entry_count);
        const bindings = [_]u32{ b0, b1, b2, b3 };
        for (0..count) |i| {
            bgl.inline_entries[i] = .{
                .binding = bindings[i],
                .resource_kind = RESOURCE_KIND_BUFFER,
            };
        }
        bgl.entries = bgl.inline_entries[0..count];
    }
    return toOpaque(bgl);
}

pub export fn doeNativeBindGroupLayoutRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeBindGroupLayout, raw)) |l| {
        if (!native_helpers.object_should_destroy(l)) return;
        label_store.remove(raw);
        if (!l.entries_inline) {
            if (l.entries) |entries| alloc.free(entries);
        }
        alloc.destroy(l);
    }
}

pub export fn doeNativeDeviceCreateBindGroup(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUBindGroupDescriptor) callconv(.c) ?*anyopaque {
    const d = desc orelse return null;
    const bg = make(DoeBindGroup) orelse return null;
    bg.* = .{};
    const layout = cast(DoeBindGroupLayout, d.layout);

    // For Vulkan devices, store the DoeBuffer* opaque pointer in buffers[] instead
    // of the MTL handle, so the compute dispatch can look up the vk_id at submit time.
    const is_vulkan = if (cast(DoeDevice, dev_raw)) |dev| dev.backend == .vulkan else false;

    for (d.entries[0..d.entryCount]) |e| {
        if (layout) |bgl| {
            if (find_layout_entry(bgl, e.binding)) |layout_entry| {
                if (layout_entry.resource_kind == RESOURCE_KIND_TEXTURE) {
                    const view = cast(DoeTextureView, e.textureView) orelse {
                        alloc.destroy(bg);
                        return null;
                    };
                    if (view.tex.error_object) {
                        alloc.destroy(bg);
                        return null;
                    }
                    if (!texture_view_matches_layout(layout_entry, view)) {
                        alloc.destroy(bg);
                        return null;
                    }
                } else if (layout_entry.resource_kind == RESOURCE_KIND_STORAGE_TEXTURE) {
                    const view = cast(DoeTextureView, e.textureView) orelse {
                        alloc.destroy(bg);
                        return null;
                    };
                    if (view.tex.error_object) {
                        alloc.destroy(bg);
                        return null;
                    }
                    if (!storage_texture_matches_layout(layout_entry, view)) {
                        alloc.destroy(bg);
                        return null;
                    }
                } else if (layout_entry.resource_kind == RESOURCE_KIND_EXTERNAL_TEXTURE) {
                    const external_texture = resolve_external_texture(e) orelse {
                        alloc.destroy(bg);
                        return null;
                    };
                    const ext = native_helpers.cast(DoeExternalTexture, external_texture) orelse {
                        alloc.destroy(bg);
                        return null;
                    };
                    if (ext.expired or ext.plane0 == null) {
                        alloc.destroy(bg);
                        return null;
                    }
                }
            }
        }
        if (e.binding < MAX_BIND) {
            if (cast(DoeBuffer, e.buffer)) |doe_buf| {
                if (doe_buf.error_object) {
                    alloc.destroy(bg);
                    return null;
                }
                if (is_vulkan) {
                    // Store the DoeBuffer handle — dispatch reads vk_id from it.
                    bg.buffers[e.binding] = toOpaque(doe_buf);
                    remember_vulkan_buffer_binding(bg, @intCast(e.binding), doe_buf);
                } else {
                    bg.buffers[e.binding] = doe_buf.mtl;
                }
                const binding_size = resolve_buffer_binding_size(doe_buf, e.offset, e.size) orelse {
                    alloc.destroy(bg);
                    return null;
                };
                bg.offsets[e.binding] = e.offset;
                bg.buffer_sizes[e.binding] = binding_size;
                retain_buffer(bg, e.binding, doe_buf);
            } else if (cast(DoeTextureView, e.textureView)) |view| {
                if (view.tex.error_object) {
                    alloc.destroy(bg);
                    return null;
                }
                bg.textures[e.binding] = if (view.handle) |handle| handle else view.tex.mtl;
                bg.texture_views[e.binding] = toOpaque(view);
                retain_texture_view(bg, e.binding, view);
            } else if (cast(DoeSampler, e.sampler)) |sampler| {
                bg.samplers[e.binding] = if (is_vulkan) toOpaque(sampler) else sampler.mtl;
                retain_sampler(bg, e.binding, sampler);
            } else if (resolve_external_texture(e)) |external_texture| {
                const ext_mod = @import("doe_external_texture_native.zig");
                const ext = native_helpers.cast(DoeExternalTexture, external_texture) orelse continue;
                if (is_vulkan) {
                    const plane0_view = texture_sampler.registeredTextureView(ext.plane0) orelse {
                        alloc.destroy(bg);
                        return null;
                    };
                    if (plane0_view.tex.error_object or plane0_view.tex.vk_id == 0) {
                        alloc.destroy(bg);
                        return null;
                    }
                    bg.textures[e.binding] = toOpaque(plane0_view.tex);
                    bg.texture_views[e.binding] = toOpaque(plane0_view);
                } else {
                    bg.textures[e.binding] = ext_mod.resolvePlane0MtlHandle(ext);
                    bg.texture_views[e.binding] = ext.plane0;
                }
                retain_external_texture(bg, e.binding, external_texture);
                if (ext_mod.isMultiPlane(ext)) {
                    const next_slot = e.binding + 1;
                    if (next_slot < MAX_BIND) {
                        if (is_vulkan) {
                            const plane1_view = texture_sampler.registeredTextureView(ext.plane1) orelse {
                                alloc.destroy(bg);
                                return null;
                            };
                            if (plane1_view.tex.error_object or plane1_view.tex.vk_id == 0) {
                                alloc.destroy(bg);
                                return null;
                            }
                            bg.textures[next_slot] = toOpaque(plane1_view.tex);
                            bg.texture_views[next_slot] = toOpaque(plane1_view);
                        } else {
                            bg.textures[next_slot] = ext_mod.resolvePlane1MtlHandle(ext);
                            bg.texture_views[next_slot] = ext.plane1;
                        }
                        if (next_slot + 1 > bg.count) bg.count = next_slot + 1;
                    }
                }
            } else continue;
            if (e.binding + 1 > bg.count) bg.count = e.binding + 1;
        }
    }
    if (is_vulkan) bg.vk_buffer_binding_cache_complete = true;
    const bg_result = toOpaque(bg);
    label_store.set(bg_result, d.label.data, d.label.length);
    return bg_result;
}

pub export fn doeNativeDeviceCreateBufferBindGroupFlat4(
    dev_raw: ?*anyopaque,
    layout_raw: ?*anyopaque,
    entry_count: u32,
    b0: u32,
    buffer0_raw: ?*anyopaque,
    offset0: u64,
    b1: u32,
    buffer1_raw: ?*anyopaque,
    offset1: u64,
    b2: u32,
    buffer2_raw: ?*anyopaque,
    offset2: u64,
    b3: u32,
    buffer3_raw: ?*anyopaque,
    offset3: u64,
) callconv(.c) ?*anyopaque {
    if (entry_count > FLAT_BUFFER_BIND_GROUP_ENTRY_LIMIT) return null;
    const bg = make(DoeBindGroup) orelse return null;
    bg.* = .{};
    _ = layout_raw;
    const is_vulkan = if (cast(DoeDevice, dev_raw)) |dev| dev.backend == .vulkan else false;
    const bindings = [_]u32{ b0, b1, b2, b3 };
    const buffers = [_]?*anyopaque{ buffer0_raw, buffer1_raw, buffer2_raw, buffer3_raw };
    const offsets = [_]u64{ offset0, offset1, offset2, offset3 };
    const count: usize = @intCast(entry_count);
    for (0..count) |i| {
        const binding = bindings[i];
        if (binding >= MAX_BIND) continue;
        const doe_buf = cast(DoeBuffer, buffers[i]) orelse {
            doeNativeBindGroupRelease(toOpaque(bg));
            return null;
        };
        if (doe_buf.error_object) {
            doeNativeBindGroupRelease(toOpaque(bg));
            return null;
        }
        bg.buffers[binding] = if (is_vulkan) toOpaque(doe_buf) else doe_buf.mtl;
        if (is_vulkan) remember_vulkan_buffer_binding(bg, @intCast(binding), doe_buf);
        bg.offsets[binding] = offsets[i];
        bg.buffer_sizes[binding] = doe_buf.size;
        retain_buffer(bg, binding, doe_buf);
        if (binding + 1 > bg.count) bg.count = binding + 1;
    }
    if (is_vulkan) bg.vk_buffer_binding_cache_complete = true;
    return toOpaque(bg);
}

pub export fn doeNativeBindGroupRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeBindGroup, raw)) |g| {
        if (!native_helpers.object_should_destroy(g)) return;
        label_store.remove(raw);
        for (g.retained_buffers) |maybe_buffer| {
            if (maybe_buffer) |buffer| native_exports.doeNativeBufferRelease(toOpaque(buffer));
        }
        for (g.retained_texture_views) |maybe_view| {
            if (maybe_view) |view| native_exports.doeNativeTextureViewRelease(toOpaque(view));
        }
        for (g.retained_samplers) |maybe_sampler| {
            if (maybe_sampler) |sampler| native_exports.doeNativeSamplerRelease(toOpaque(sampler));
        }
        for (g.retained_external_textures) |external_texture| {
            if (external_texture != null) native_exports.doeNativeExternalTextureRelease(external_texture);
        }
        alloc.destroy(g);
    }
}

pub export fn doeNativeDeviceCreatePipelineLayout(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUPipelineLayoutDescriptor) callconv(.c) ?*anyopaque {
    _ = dev_raw;
    const pl = make(DoePipelineLayout) orelse return null;
    pl.* = .{};
    const pl_result = toOpaque(pl);
    if (desc) |pd| {
        if (pd.bindGroupLayoutCount > MAX_COMPUTE_BIND_GROUPS) {
            doeNativePipelineLayoutRelease(pl_result);
            return null;
        }
        pl.immediate_size = pd.immediateSize;
        pl.bind_group_layout_count = @intCast(pd.bindGroupLayoutCount);
        for (0..pd.bindGroupLayoutCount) |index| {
            const layout = cast(DoeBindGroupLayout, pd.bindGroupLayouts[index]) orelse {
                doeNativePipelineLayoutRelease(pl_result);
                return null;
            };
            native_helpers.object_add_ref(DoeBindGroupLayout, toOpaque(layout));
            pl.bind_group_layouts[index] = layout;
        }
        label_store.set(pl_result, pd.label.data, pd.label.length);
    }
    return pl_result;
}

pub export fn doeNativeDeviceCreatePipelineLayoutOne(dev_raw: ?*anyopaque, layout_raw: ?*anyopaque, immediate_size: u32) callconv(.c) ?*anyopaque {
    _ = dev_raw;
    const layout = cast(DoeBindGroupLayout, layout_raw) orelse return null;
    const pl = make(DoePipelineLayout) orelse return null;
    pl.* = .{
        .immediate_size = immediate_size,
        .bind_group_layout_count = 1,
    };
    native_helpers.object_add_ref(DoeBindGroupLayout, toOpaque(layout));
    pl.bind_group_layouts[0] = layout;
    return toOpaque(pl);
}

pub export fn doeNativePipelineLayoutRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoePipelineLayout, raw)) |l| {
        if (!native_helpers.object_should_destroy(l)) return;
        label_store.remove(raw);
        for (l.bind_group_layouts[0..l.bind_group_layout_count]) |layout| {
            if (layout) |bgl| doeNativeBindGroupLayoutRelease(toOpaque(bgl));
        }
        alloc.destroy(l);
    }
}

fn layout_entry_for_kind_test() abi_pipeline.WGPUBindGroupLayoutEntry {
    return .{
        .nextInChain = null,
        .binding = 0,
        .visibility = 0,
        .bindingArraySize = 0,
        .buffer = .{
            .nextInChain = null,
            .type = abi_binding.WGPUBufferBindingType_BindingNotUsed,
            .hasDynamicOffset = 0,
            .minBindingSize = 0,
        },
        .sampler = .{
            .nextInChain = null,
            .type = abi_binding.WGPUSamplerBindingType_BindingNotUsed,
        },
        .texture = .{
            .nextInChain = null,
            .sampleType = abi_binding.WGPUTextureSampleType_BindingNotUsed,
            .viewDimension = abi_texture.WGPUTextureViewDimension_Undefined,
            .multisampled = 0,
        },
        .storageTexture = .{
            .nextInChain = null,
            .access = abi_binding.WGPUStorageTextureAccess_BindingNotUsed,
            .format = abi_texture.WGPUTextureFormat_Undefined,
            .viewDimension = abi_texture.WGPUTextureViewDimension_Undefined,
        },
    };
}

test "bind group layout classification follows active binding sentinel" {
    var buffer_entry = layout_entry_for_kind_test();
    buffer_entry.buffer.type = abi_binding.WGPUBufferBindingType_Storage;
    buffer_entry.texture.viewDimension = abi_texture.WGPUTextureViewDimension_2D;
    buffer_entry.storageTexture.format = abi_texture.WGPUTextureFormat_RGBA8Unorm;
    try std.testing.expectEqual(RESOURCE_KIND_BUFFER, classify_layout_entry(buffer_entry).resource_kind);

    var texture_entry = layout_entry_for_kind_test();
    texture_entry.texture.sampleType = abi_binding.WGPUTextureSampleType_Float;
    texture_entry.storageTexture.format = abi_texture.WGPUTextureFormat_RGBA8Unorm;
    texture_entry.storageTexture.viewDimension = abi_texture.WGPUTextureViewDimension_2D;
    const classified_texture = classify_layout_entry(texture_entry);
    try std.testing.expectEqual(RESOURCE_KIND_TEXTURE, classified_texture.resource_kind);
    try std.testing.expectEqual(abi_binding.WGPUTextureSampleType_Float, classified_texture.texture_sample_type);

    var storage_entry = layout_entry_for_kind_test();
    storage_entry.storageTexture.access = abi_binding.WGPUStorageTextureAccess_WriteOnly;
    storage_entry.storageTexture.format = abi_texture.WGPUTextureFormat_RGBA8Unorm;
    storage_entry.storageTexture.viewDimension = abi_texture.WGPUTextureViewDimension_2D;
    try std.testing.expectEqual(RESOURCE_KIND_STORAGE_TEXTURE, classify_layout_entry(storage_entry).resource_kind);
}

test "inactive nested binding defaults do not classify a resource kind" {
    var view_only_entry = layout_entry_for_kind_test();
    view_only_entry.texture.viewDimension = abi_texture.WGPUTextureViewDimension_2D;
    try std.testing.expectEqual(RESOURCE_KIND_NONE, classify_layout_entry(view_only_entry).resource_kind);

    var storage_shape_only_entry = layout_entry_for_kind_test();
    storage_shape_only_entry.storageTexture.format = abi_texture.WGPUTextureFormat_RGBA8Unorm;
    storage_shape_only_entry.storageTexture.viewDimension = abi_texture.WGPUTextureViewDimension_2D;
    try std.testing.expectEqual(RESOURCE_KIND_NONE, classify_layout_entry(storage_shape_only_entry).resource_kind);
}

test "external texture layout ignores Dawn undefined nested defaults" {
    var external_layout = abi_pipeline.WGPUExternalTextureBindingLayout{
        .chain = .{
            .next = null,
            .sType = abi_core.WGPUSType_ExternalTextureBindingLayout,
        },
    };
    var entry = layout_entry_for_kind_test();
    entry.nextInChain = @ptrCast(&external_layout.chain);
    entry.buffer.type = abi_binding.WGPUBufferBindingType_Undefined;
    entry.sampler.type = abi_binding.WGPUSamplerBindingType_Undefined;
    entry.texture.sampleType = abi_binding.WGPUTextureSampleType_Undefined;
    entry.storageTexture.access = abi_binding.WGPUStorageTextureAccess_Undefined;

    try std.testing.expectEqual(RESOURCE_KIND_EXTERNAL_TEXTURE, classify_layout_entry(entry).resource_kind);
}
