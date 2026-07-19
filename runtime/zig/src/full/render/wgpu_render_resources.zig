const std = @import("std");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const proc_types = @import("../../core/abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_records = @import("../../core/abi/wgpu_runtime_records.zig");
const loader = @import("../../core/abi/wgpu_loader.zig");
const resources = @import("../../core/resource/wgpu_resources.zig");
const render_assets = @import("wgpu_render_assets.zig");
const texture_procs_mod = @import("../../core/abi/procs/wgpu_texture_procs.zig");

pub const RENDER_UNIFORM_BINDING_INDEX: u32 = 0;
pub const RENDER_TEXTURE_BINDING_INDEX: u32 = 1;
pub const RENDER_SAMPLER_BINDING_INDEX: u32 = 2;

const RENDER_UNIFORM_BUFFER_HANDLE: u64 = 0x8C9F_2600_0000_0000;
pub const RENDER_UNIFORM_MIN_BINDING_SIZE_BYTES: u64 = 3 * @sizeOf(f32);
pub const RENDER_UNIFORM_DYNAMIC_STRIDE_BYTES: u64 = 256;
pub const RENDER_UNIFORM_DYNAMIC_SLOT_COUNT: u64 = 64;
pub const RENDER_UNIFORM_TOTAL_BYTES: u64 = RENDER_UNIFORM_DYNAMIC_STRIDE_BYTES * RENDER_UNIFORM_DYNAMIC_SLOT_COUNT;
const RENDER_SAMPLED_TEXTURE_HANDLE: u64 = 0x8C9F_2800_0000_0000;

pub const RenderUniformBindingResources = struct {
    bind_group_layout: abi_base.WGPUBindGroupLayout,
    bind_group: abi_base.WGPUBindGroup,
};

pub fn getOrCreateRenderUniformBindingResources(self: anytype) !RenderUniformBindingResources {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;

    if (self.full.render_uniform_bind_group_layout != null and self.full.render_uniform_bind_group != null) {
        return .{
            .bind_group_layout = self.full.render_uniform_bind_group_layout,
            .bind_group = self.full.render_uniform_bind_group,
        };
    }

    if (self.full.render_uniform_bind_group) |stale_group| {
        procs.wgpuBindGroupRelease(stale_group);
        self.full.render_uniform_bind_group = null;
    }
    if (self.full.render_uniform_bind_group_layout) |stale_layout| {
        procs.wgpuBindGroupLayoutRelease(stale_layout);
        self.full.render_uniform_bind_group_layout = null;
    }

    const uniform_bytes = std.mem.sliceAsBytes(render_assets.RENDER_DRAW_UNIFORM_COLOR[0..]);
    const uniform_usage = abi_base.WGPUBufferUsage_Uniform | abi_base.WGPUBufferUsage_CopyDst;
    const should_upload_uniform_data = blk: {
        if (self.core.buffers.get(RENDER_UNIFORM_BUFFER_HANDLE)) |existing| {
            if (existing.size >= RENDER_UNIFORM_TOTAL_BYTES and
                (existing.usage & uniform_usage) == uniform_usage)
            {
                break :blk false;
            }
        }
        break :blk true;
    };
    const uniform_buffer = try resources.getOrCreateBuffer(
        self,
        RENDER_UNIFORM_BUFFER_HANDLE,
        RENDER_UNIFORM_TOTAL_BYTES,
        uniform_usage,
    );
    if (should_upload_uniform_data) {
        var payload: [@intCast(RENDER_UNIFORM_TOTAL_BYTES)]u8 = undefined;
        @memset(payload[0..], 0);
        var offset: usize = 0;
        while (offset + uniform_bytes.len <= payload.len) : (offset += @as(usize, @intCast(RENDER_UNIFORM_DYNAMIC_STRIDE_BYTES))) {
            @memcpy(payload[offset .. offset + uniform_bytes.len], uniform_bytes);
        }
        procs.wgpuQueueWriteBuffer(
            self.core.queue.?,
            uniform_buffer,
            0,
            payload[0..].ptr,
            payload.len,
        );
    }

    const sampled_usage = abi_base.WGPUTextureUsage_TextureBinding | abi_base.WGPUTextureUsage_CopyDst;
    const sampled_resource = model_resource_types.CopyTextureResource{
        .handle = RENDER_SAMPLED_TEXTURE_HANDLE,
        .kind = .texture,
        .width = render_assets.RENDER_DRAW_TEXTURE_WIDTH,
        .height = render_assets.RENDER_DRAW_TEXTURE_HEIGHT,
        .depth_or_array_layers = 1,
        .format = model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
        .usage = sampled_usage,
        .dimension = model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
        .mip_level = 0,
        .sample_count = 1,
        .aspect = model_gpu_types.WGPUTextureAspect_All,
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .offset = 0,
    };
    const should_upload_texture_data = blk: {
        if (self.core.textures.get(RENDER_SAMPLED_TEXTURE_HANDLE)) |existing| {
            if (existing.width == render_assets.RENDER_DRAW_TEXTURE_WIDTH and
                existing.height == render_assets.RENDER_DRAW_TEXTURE_HEIGHT and
                existing.depth_or_array_layers == 1 and
                existing.format == model_gpu_types.WGPUTextureFormat_RGBA8Unorm and
                existing.dimension == model_gpu_types.WGPUTextureDimension_2D and
                existing.sample_count == 1 and
                (existing.usage & sampled_usage) == sampled_usage)
            {
                break :blk false;
            }
        }
        break :blk true;
    };
    const sampled_texture = try resources.getOrCreateTexture(self, sampled_resource, sampled_usage);
    if (should_upload_texture_data) {
        texture_procs.queue_write_texture(
            self.core.queue.?,
            &abi_descriptor.WGPUTexelCopyTextureInfo{
                .texture = sampled_texture,
                .mipLevel = 0,
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .aspect = abi_base.WGPUTextureAspect_All,
            },
            render_assets.RENDER_DRAW_TEXTURE_DATA[0..].ptr,
            render_assets.RENDER_DRAW_TEXTURE_DATA.len,
            &abi_descriptor.WGPUTexelCopyBufferLayout{
                .offset = 0,
                .bytesPerRow = render_assets.RENDER_DRAW_TEXTURE_BYTES_PER_ROW,
                .rowsPerImage = render_assets.RENDER_DRAW_TEXTURE_HEIGHT,
            },
            &abi_descriptor.WGPUExtent3D{
                .width = render_assets.RENDER_DRAW_TEXTURE_WIDTH,
                .height = render_assets.RENDER_DRAW_TEXTURE_HEIGHT,
                .depthOrArrayLayers = 1,
            },
        );
    }

    const sampled_texture_view = try getOrCreateCachedRenderTextureView(
        self,
        &self.full.render_target_view_cache,
        RENDER_SAMPLED_TEXTURE_HANDLE,
        sampled_texture,
        render_assets.RENDER_DRAW_TEXTURE_WIDTH,
        render_assets.RENDER_DRAW_TEXTURE_HEIGHT,
        model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
        abi_base.WGPUTextureUsage_TextureBinding,
    );

    if (self.full.render_sampler == null) {
        const sampler = texture_procs.device_create_sampler(self.core.device.?, null);
        if (sampler == null) return error.SamplerCreationFailed;
        self.full.render_sampler = sampler;
    }

    const layout_entries = [_]abi_descriptor.WGPUBindGroupLayoutEntry{
        .{
            .nextInChain = null,
            .binding = RENDER_UNIFORM_BINDING_INDEX,
            .visibility = abi_base.WGPUShaderStage_Fragment,
            .bindingArraySize = 0,
            .buffer = .{
                .nextInChain = null,
                .type = abi_base.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = abi_base.WGPU_TRUE,
                .minBindingSize = RENDER_UNIFORM_MIN_BINDING_SIZE_BYTES,
            },
            .sampler = .{
                .nextInChain = null,
                .type = abi_base.WGPUSamplerBindingType_BindingNotUsed,
            },
            .texture = .{
                .nextInChain = null,
                .sampleType = abi_base.WGPUTextureSampleType_BindingNotUsed,
                .viewDimension = abi_base.WGPUTextureViewDimension_Undefined,
                .multisampled = abi_base.WGPU_FALSE,
            },
            .storageTexture = .{
                .nextInChain = null,
                .access = abi_base.WGPUStorageTextureAccess_BindingNotUsed,
                .format = abi_base.WGPUTextureFormat_Undefined,
                .viewDimension = abi_base.WGPUTextureViewDimension_Undefined,
            },
        },
        .{
            .nextInChain = null,
            .binding = RENDER_TEXTURE_BINDING_INDEX,
            .visibility = abi_base.WGPUShaderStage_Fragment,
            .bindingArraySize = 0,
            .buffer = .{
                .nextInChain = null,
                .type = abi_base.WGPUBufferBindingType_BindingNotUsed,
                .hasDynamicOffset = abi_base.WGPU_FALSE,
                .minBindingSize = 0,
            },
            .sampler = .{
                .nextInChain = null,
                .type = abi_base.WGPUSamplerBindingType_BindingNotUsed,
            },
            .texture = .{
                .nextInChain = null,
                .sampleType = abi_base.WGPUTextureSampleType_Float,
                .viewDimension = abi_base.WGPUTextureViewDimension_2D,
                .multisampled = abi_base.WGPU_FALSE,
            },
            .storageTexture = .{
                .nextInChain = null,
                .access = abi_base.WGPUStorageTextureAccess_BindingNotUsed,
                .format = abi_base.WGPUTextureFormat_Undefined,
                .viewDimension = abi_base.WGPUTextureViewDimension_Undefined,
            },
        },
        .{
            .nextInChain = null,
            .binding = RENDER_SAMPLER_BINDING_INDEX,
            .visibility = abi_base.WGPUShaderStage_Fragment,
            .bindingArraySize = 0,
            .buffer = .{
                .nextInChain = null,
                .type = abi_base.WGPUBufferBindingType_BindingNotUsed,
                .hasDynamicOffset = abi_base.WGPU_FALSE,
                .minBindingSize = 0,
            },
            .sampler = .{
                .nextInChain = null,
                .type = abi_base.WGPUSamplerBindingType_Filtering,
            },
            .texture = .{
                .nextInChain = null,
                .sampleType = abi_base.WGPUTextureSampleType_BindingNotUsed,
                .viewDimension = abi_base.WGPUTextureViewDimension_Undefined,
                .multisampled = abi_base.WGPU_FALSE,
            },
            .storageTexture = .{
                .nextInChain = null,
                .access = abi_base.WGPUStorageTextureAccess_BindingNotUsed,
                .format = abi_base.WGPUTextureFormat_Undefined,
                .viewDimension = abi_base.WGPUTextureViewDimension_Undefined,
            },
        },
    };

    const bind_group_layout = try resources.createBindGroupLayout(self, layout_entries[0..]);
    errdefer procs.wgpuBindGroupLayoutRelease(bind_group_layout);

    const bind_entries = [_]abi_descriptor.WGPUBindGroupEntry{
        .{
            .nextInChain = null,
            .binding = RENDER_UNIFORM_BINDING_INDEX,
            .buffer = uniform_buffer,
            .offset = 0,
            .size = RENDER_UNIFORM_MIN_BINDING_SIZE_BYTES,
            .sampler = null,
            .textureView = null,
        },
        .{
            .nextInChain = null,
            .binding = RENDER_TEXTURE_BINDING_INDEX,
            .buffer = null,
            .offset = 0,
            .size = 0,
            .sampler = null,
            .textureView = sampled_texture_view,
        },
        .{
            .nextInChain = null,
            .binding = RENDER_SAMPLER_BINDING_INDEX,
            .buffer = null,
            .offset = 0,
            .size = 0,
            .sampler = self.full.render_sampler,
            .textureView = null,
        },
    };
    const bind_group = try resources.createBindGroup(self, bind_group_layout, bind_entries[0..]);

    self.full.render_uniform_bind_group_layout = bind_group_layout;
    self.full.render_uniform_bind_group = bind_group;
    return .{
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
    };
}

pub fn getOrCreateCachedRenderTextureView(
    self: anytype,
    cache: *std.AutoHashMap(u64, abi_records.RenderTextureViewCacheEntry),
    key: u64,
    texture: abi_base.WGPUTexture,
    width: u32,
    height: u32,
    format: abi_base.WGPUTextureFormat,
    usage: abi_base.WGPUTextureUsage,
) !abi_base.WGPUTextureView {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    if (cache.get(key)) |existing| {
        if (existing.texture == texture and
            existing.width == width and
            existing.height == height and
            existing.format == format)
        {
            return existing.view;
        }
        procs.wgpuTextureViewRelease(existing.view);
        _ = cache.remove(key);
    }

    const view = procs.wgpuTextureCreateView(texture, &abi_descriptor.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .format = format,
        .dimension = abi_base.WGPUTextureViewDimension_2D,
        .baseMipLevel = 0,
        .mipLevelCount = 1,
        .baseArrayLayer = 0,
        .arrayLayerCount = 1,
        .aspect = abi_base.WGPUTextureAspect_All,
        .usage = usage,
        .swizzleR = abi_base.WGPUTextureComponentSwizzle_Red,
        .swizzleG = abi_base.WGPUTextureComponentSwizzle_Green,
        .swizzleB = abi_base.WGPUTextureComponentSwizzle_Blue,
        .swizzleA = abi_base.WGPUTextureComponentSwizzle_Alpha,
    });
    if (view == null) return error.TextureViewCreationFailed;
    cache.put(key, .{
        .texture = texture,
        .view = view,
        .width = width,
        .height = height,
        .format = format,
    }) catch {
        procs.wgpuTextureViewRelease(view);
        return error.TextureViewCacheInsertFailed;
    };
    return view;
}
