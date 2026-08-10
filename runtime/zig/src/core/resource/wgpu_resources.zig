const std = @import("std");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const proc_types = @import("../abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_records = @import("../abi/wgpu_runtime_records.zig");
const normalizers = @import("wgpu_resource_normalizers.zig");
const loader = @import("../abi/wgpu_loader.zig");
const p0_procs_mod = @import("../abi/procs/wgpu_p0_procs.zig");
const texture_procs_mod = @import("../abi/procs/wgpu_texture_procs.zig");
const BUFFER_ZERO_INIT_CHUNK_BYTES: usize = 64 * 1024;
const BUFFER_MIN_ALIGNMENT: u64 = 4;

pub fn normalizeTextureFormat(value: u32) abi_base.WGPUTextureFormat {
    return normalizers.normalizeTextureFormat(value);
}

pub fn getOrCreateBuffer(
    self: anytype,
    handle: u64,
    requested_size: u64,
    required_usage: abi_base.WGPUBufferUsage,
) !abi_base.WGPUBuffer {
    return getOrCreateBufferWithOptions(self, handle, requested_size, required_usage, false);
}

pub fn getOrCreateBufferInitialized(
    self: anytype,
    handle: u64,
    requested_size: u64,
    required_usage: abi_base.WGPUBufferUsage,
) !abi_base.WGPUBuffer {
    return getOrCreateBufferWithOptions(self, handle, requested_size, required_usage, true);
}

fn getOrCreateBufferWithOptions(
    self: anytype,
    handle: u64,
    requested_size: u64,
    required_usage: abi_base.WGPUBufferUsage,
    initialize_on_create: bool,
) !abi_base.WGPUBuffer {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const p0_procs = p0_procs_mod.loadP0Procs(self.core.dyn_lib);

    if (self.core.buffers.get(handle)) |existing| {
        const can_reuse = existing.size >= requested_size and (existing.usage & required_usage) == required_usage;
        if (can_reuse) return existing.buffer;
        p0_procs_mod.destroyBuffer(p0_procs, existing.buffer);
        procs.wgpuBufferRelease(existing.buffer);
        _ = self.core.buffers.remove(handle);
    }

    const size = loader.alignTo(requested_size, BUFFER_MIN_ALIGNMENT);

    const desc = abi_descriptor.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .usage = required_usage,
        .size = size,
        .mappedAtCreation = abi_base.WGPU_FALSE,
    };
    const buffer = procs.wgpuDeviceCreateBuffer(self.core.device.?, &desc);
    if (buffer == null) {
        return error.BufferAllocationFailed;
    }
    errdefer procs.wgpuBufferRelease(buffer);
    if (initialize_on_create) {
        try zeroInitializeBuffer(self, buffer, size);
    }
    try self.core.buffers.put(handle, .{
        .buffer = buffer,
        .size = size,
        .usage = required_usage,
    });
    return buffer;
}

fn zeroInitializeBuffer(self: anytype, buffer: abi_base.WGPUBuffer, size: u64) !void {
    if (size == 0) return;
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const queue = self.core.queue orelse return error.ProceduralNotReady;
    const zero_chunk = try ensureZeroScratchBytes(self, BUFFER_ZERO_INIT_CHUNK_BYTES);

    var offset: u64 = 0;
    while (offset < size) {
        const remaining = size - offset;
        const write_len_u64 = @min(remaining, @as(u64, zero_chunk.len));
        const write_len = @as(usize, @intCast(write_len_u64));
        procs.wgpuQueueWriteBuffer(
            queue,
            buffer,
            offset,
            @ptrCast(zero_chunk.ptr),
            write_len,
        );
        offset += write_len_u64;
    }
}

fn ensureZeroScratchBytes(self: anytype, required_len: usize) ![]u8 {
    if (self.core.upload_scratch.len < required_len) {
        if (self.core.upload_scratch.len > 0) {
            self.core.allocator.free(self.core.upload_scratch);
        }
        self.core.upload_scratch = try self.core.allocator.alloc(u8, required_len);
    }
    const chunk = self.core.upload_scratch[0..required_len];
    @memset(chunk, 0);
    return chunk;
}

pub fn requiredBytes(bytes: u64, offset: u64) !u64 {
    const checked = try std.math.add(u64, bytes, offset);
    return loader.alignTo(checked, 4);
}

pub fn getOrCreateTexture(self: anytype, resource: model_resource_types.CopyTextureResource, required_usage: abi_base.WGPUTextureUsage) !abi_base.WGPUTexture {
    return getOrCreateTextureWithOptions(self, resource, required_usage, false);
}

pub fn getOrCreateTextureInitialized(self: anytype, resource: model_resource_types.CopyTextureResource, required_usage: abi_base.WGPUTextureUsage) !abi_base.WGPUTexture {
    return getOrCreateTextureWithOptions(self, resource, required_usage, true);
}

fn getOrCreateTextureWithOptions(
    self: anytype,
    resource: model_resource_types.CopyTextureResource,
    required_usage: abi_base.WGPUTextureUsage,
    initialize_on_create: bool,
) !abi_base.WGPUTexture {
    if (resource.kind != .texture) return error.InvalidTextureResourceKind;
    const procs = self.core.procs orelse return error.ProceduralNotReady;

    const handle = resource.handle;
    const width = if (resource.width == 0) 1 else resource.width;
    const height = if (resource.height == 0) 1 else resource.height;
    const depth = if (resource.depth_or_array_layers == 0) 1 else resource.depth_or_array_layers;
    const sample_count = if (resource.sample_count == 0) 1 else resource.sample_count;
    const dimension = if (resource.dimension == model_gpu_types.WGPUTextureDimension_Undefined or resource.dimension == 0)
        abi_base.WGPUTextureDimension_2D
    else
        resource.dimension;
    const raw_format = normalizers.normalizeTextureFormat(resource.format);
    const format = if (raw_format == abi_base.WGPUTextureFormat_Undefined) abi_base.WGPUTextureFormat_R8Unorm else raw_format;
    const usage = required_usage | resource.usage;

    if (self.core.textures.get(handle)) |existing| {
        if (existing.width == width and
            existing.height == height and
            existing.depth_or_array_layers == depth and
            existing.format == format and
            existing.dimension == dimension and
            existing.sample_count == sample_count and
            (existing.usage & required_usage) == required_usage)
        {
            return existing.texture;
        }
        const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
        texture_procs.texture_destroy(existing.texture);
        procs.wgpuTextureRelease(existing.texture);
        _ = self.core.textures.remove(handle);
    }

    const descriptor = abi_descriptor.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .usage = usage,
        .dimension = dimension,
        .size = .{
            .width = width,
            .height = height,
            .depthOrArrayLayers = depth,
        },
        .format = format,
        .mipLevelCount = 1,
        .sampleCount = if (sample_count == 0) 1 else sample_count,
        .viewFormatCount = 0,
        .viewFormats = null,
    };
    const texture = procs.wgpuDeviceCreateTexture(self.core.device.?, &descriptor);
    if (texture == null) return error.TextureAllocationFailed;
    errdefer procs.wgpuTextureRelease(texture);

    if (initialize_on_create) {
        try zeroInitializeTexture(self, texture, .{
            .handle = resource.handle,
            .kind = .texture,
            .width = width,
            .height = height,
            .depth_or_array_layers = depth,
            .format = format,
            .usage = usage,
            .dimension = dimension,
            .view_dimension = resource.view_dimension,
            .mip_level = resource.mip_level,
            .sample_count = sample_count,
            .aspect = resource.aspect,
            .bytes_per_row = resource.bytes_per_row,
            .rows_per_image = resource.rows_per_image,
            .offset = resource.offset,
        });
    }

    try self.core.textures.put(handle, .{
        .texture = texture,
        .width = width,
        .height = height,
        .depth_or_array_layers = depth,
        .format = format,
        .usage = usage,
        .dimension = dimension,
        .sample_count = if (sample_count == 0) 1 else sample_count,
    });

    return texture;
}

fn zeroInitializeTexture(
    self: anytype,
    texture: abi_base.WGPUTexture,
    resource: model_resource_types.CopyTextureResource,
) !void {
    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
    const queue = self.core.queue orelse return error.ProceduralNotReady;

    const width = if (resource.width == 0) 1 else resource.width;
    const height = if (resource.height == 0) 1 else resource.height;
    const depth = if (resource.depth_or_array_layers == 0) 1 else resource.depth_or_array_layers;
    const format = normalizers.normalizeTextureFormat(resource.format);
    const bytes_per_pixel = normalizers.textureFormatBytesPerPixel(format) orelse return;
    const bytes_per_row = if (resource.bytes_per_row != 0)
        resource.bytes_per_row
    else
        width * bytes_per_pixel;
    const rows_per_image = if (resource.rows_per_image != 0) resource.rows_per_image else height;
    const data_size_u64 = @as(u64, bytes_per_row) * rows_per_image * depth;
    const data_size = std.math.cast(usize, data_size_u64) orelse return error.TextureAllocationFailed;
    const zero_bytes = try ensureZeroScratchBytes(self, data_size);

    texture_procs.queue_write_texture(
        queue,
        &abi_descriptor.WGPUTexelCopyTextureInfo{
            .texture = texture,
            .mipLevel = resource.mip_level,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = loader.normalizeTextureAspect(resource.aspect),
        },
        @ptrCast(zero_bytes.ptr),
        zero_bytes.len,
        &abi_descriptor.WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = bytes_per_row,
            .rowsPerImage = rows_per_image,
        },
        &abi_descriptor.WGPUExtent3D{
            .width = width,
            .height = height,
            .depthOrArrayLayers = depth,
        },
    );
}

pub fn getOrCreateTextureFromBinding(self: anytype, binding: model_compute_types.KernelBinding, required_usage: abi_base.WGPUTextureUsage) !abi_base.WGPUTexture {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const handle = binding.resource_handle;
    const requested_format = normalizers.normalizeTextureFormat(binding.texture_format);
    const requested_dimension = normalizers.inferTextureDimensionFromViewDimension(binding.texture_view_dimension);
    var fallback_format = requested_format;
    var fallback_dimension = requested_dimension;
    var fallback_width: u32 = 1;
    var fallback_height: u32 = 1;
    var fallback_depth: u32 = 1;
    var fallback_sample_count: u32 = 1;
    var fallback_usage: abi_base.WGPUTextureUsage = abi_base.WGPUTextureUsage_None;

    if (self.core.textures.get(handle)) |existing| {
        fallback_format = if (requested_format == abi_base.WGPUTextureFormat_Undefined) existing.format else requested_format;
        fallback_dimension = existing.dimension;
        fallback_width = existing.width;
        fallback_height = existing.height;
        fallback_depth = existing.depth_or_array_layers;
        fallback_sample_count = existing.sample_count;
        fallback_usage = existing.usage;

        if ((existing.usage & required_usage) == required_usage) {
            if ((requested_format == abi_base.WGPUTextureFormat_Undefined or requested_format == existing.format) and
                (requested_dimension == abi_base.WGPUTextureDimension_Undefined or requested_dimension == existing.dimension))
            {
                return existing.texture;
            }
        }
        const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
        texture_procs.texture_destroy(existing.texture);
        procs.wgpuTextureRelease(existing.texture);
        _ = self.core.textures.remove(handle);
    }

    const dimension = if (requested_dimension == abi_base.WGPUTextureDimension_Undefined) fallback_dimension else requested_dimension;
    const format = if (fallback_format == abi_base.WGPUTextureFormat_Undefined) abi_base.WGPUTextureFormat_R8Unorm else fallback_format;
    const usage = fallback_usage | required_usage;
    const resource = model_resource_types.CopyTextureResource{
        .handle = handle,
        .kind = .texture,
        .width = fallback_width,
        .height = fallback_height,
        .depth_or_array_layers = fallback_depth,
        .format = format,
        .usage = fallback_usage,
        .dimension = dimension,
        .view_dimension = binding.texture_view_dimension,
        .mip_level = 0,
        .sample_count = fallback_sample_count,
        .aspect = normalizers.normalizeTextureViewAspect(binding.texture_aspect),
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .offset = 0,
    };
    return try getOrCreateTexture(self, resource, usage);
}

pub fn createTextureViewForBinding(self: anytype, texture: abi_base.WGPUTexture, binding: model_compute_types.KernelBinding) !abi_base.WGPUTextureView {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const format = blk: {
        if (self.core.textures.get(binding.resource_handle)) |record| {
            const normalized = normalizers.normalizeTextureFormat(binding.texture_format);
            break :blk if (normalized == abi_base.WGPUTextureFormat_Undefined) record.format else normalized;
        }
        const normalized = normalizers.normalizeTextureFormat(binding.texture_format);
        break :blk if (normalized == abi_base.WGPUTextureFormat_Undefined) abi_base.WGPUTextureFormat_R8Unorm else normalized;
    };
    const dimension = normalizers.normalizeTextureViewDimension(binding.texture_view_dimension);
    const descriptor = abi_descriptor.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .format = format,
        .dimension = if (dimension == abi_base.WGPUTextureViewDimension_Undefined) abi_base.WGPUTextureViewDimension_2D else dimension,
        .baseMipLevel = 0,
        .mipLevelCount = abi_base.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
        .baseArrayLayer = 0,
        .arrayLayerCount = abi_base.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
        .aspect = loader.normalizeTextureAspect(binding.texture_aspect),
        .usage = 0,
    };

    const view = procs.wgpuTextureCreateView(texture, &descriptor);
    if (view == null) return error.TextureViewCreationFailed;
    return view;
}

pub fn buildDispatchPassGroups(
    self: anytype,
    bindings: []const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
) !abi_records.DispatchPassArtifacts {
    return buildDispatchPassGroupsInternal(
        self,
        bindings,
        initialize_buffers_on_create,
        null,
    );
}

pub fn buildDispatchPassGroupsForPipeline(
    self: anytype,
    bindings: []const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
    pipeline: abi_base.WGPUComputePipeline,
) !abi_records.DispatchPassArtifacts {
    return buildDispatchPassGroupsInternal(
        self,
        bindings,
        initialize_buffers_on_create,
        pipeline,
    );
}

fn buildDispatchPassGroupsInternal(
    self: anytype,
    bindings: []const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
    compatible_pipeline: abi_base.WGPUComputePipeline,
) !abi_records.DispatchPassArtifacts {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    var max_group: u32 = 0;
    for (bindings) |binding| {
        if (binding.group > max_group) max_group = binding.group;
    }

    const group_count_u32 = max_group + 1;
    const group_count = @as(usize, group_count_u32);

    var groups = try self.core.allocator.alloc(abi_records.DispatchPassGroup, group_count);
    for (groups) |*group| {
        group.layout_entries = std.ArrayList(abi_descriptor.WGPUBindGroupLayoutEntry).empty;
        group.bind_entries = std.ArrayList(abi_descriptor.WGPUBindGroupEntry).empty;
    }

    var pending_group_layouts = try self.core.allocator.alloc(?abi_base.WGPUBindGroupLayout, group_count);
    var pass_bind_groups = try self.core.allocator.alloc(?abi_base.WGPUBindGroup, group_count);
    for (pending_group_layouts) |*pending| pending.* = null;
    for (pass_bind_groups) |*pending| pending.* = null;

    var texture_views = std.ArrayList(abi_base.WGPUTextureView).empty;
    var clean_after = true;
    defer {
        if (clean_after) {
            for (pass_bind_groups) |bind_group| {
                if (bind_group) |actual_bind_group| {
                    procs.wgpuBindGroupRelease(actual_bind_group);
                }
            }
            self.core.allocator.free(pass_bind_groups);

            for (pending_group_layouts) |maybe_layout| {
                if (maybe_layout) |layout| {
                    procs.wgpuBindGroupLayoutRelease(layout);
                }
            }
            self.core.allocator.free(pending_group_layouts);

            for (texture_views.items) |texture_view| {
                procs.wgpuTextureViewRelease(texture_view);
            }
            texture_views.deinit(self.core.allocator);

            for (groups) |*group| {
                group.layout_entries.deinit(self.core.allocator);
                group.bind_entries.deinit(self.core.allocator);
            }
            self.core.allocator.free(groups);
        }
    }

    for (bindings) |binding| {
        if (binding.group >= group_count_u32) return error.InvalidKernelDispatchBinding;
        var group = &groups[@as(usize, binding.group)];
        try group.layout_entries.append(self.core.allocator, dispatchPassLayoutEntry(binding));
        try group.bind_entries.append(self.core.allocator, try dispatchPassBindEntry(self, binding, &texture_views, initialize_buffers_on_create));
    }

    for (groups, 0..) |*group, index| {
        const layout = if (compatible_pipeline) |pipeline|
            procs.wgpuComputePipelineGetBindGroupLayout(pipeline, @intCast(index))
        else
            try createBindGroupLayout(self, group.layout_entries.items);
        if (layout == null) return error.BindGroupLayoutCreationFailed;
        pending_group_layouts[index] = layout;
        if (group.bind_entries.items.len > 0) {
            const bind_group = try createBindGroup(self, layout, group.bind_entries.items);
            pass_bind_groups[index] = bind_group;
        }
    }

    var group_layouts = try self.core.allocator.alloc(abi_base.WGPUBindGroupLayout, group_count);
    for (pending_group_layouts, 0..) |maybe_layout, index| {
        group_layouts[index] = maybe_layout orelse return error.InvalidKernelDispatchBinding;
    }

    const views = try texture_views.toOwnedSlice(self.core.allocator);
    for (groups) |*group| {
        group.layout_entries.deinit(self.core.allocator);
        group.bind_entries.deinit(self.core.allocator);
    }
    self.core.allocator.free(groups);
    self.core.allocator.free(pending_group_layouts);
    clean_after = false;

    return .{
        .pass_bind_groups = pass_bind_groups,
        .group_layouts = group_layouts,
        .texture_views = views,
    };
}

fn dispatchPassLayoutEntry(binding: model_compute_types.KernelBinding) abi_descriptor.WGPUBindGroupLayoutEntry {
    const visibility = if (binding.visibility != 0) binding.visibility else abi_base.WGPUShaderStage_Compute;
    var layout_entry = abi_descriptor.WGPUBindGroupLayoutEntry{
        .nextInChain = null,
        .binding = binding.binding,
        .visibility = visibility,
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
    };

    switch (binding.resource_kind) {
        .buffer => {
            layout_entry.buffer.type = normalizers.normalizeBufferBindingType(binding.buffer_type);
            layout_entry.buffer.minBindingSize = if (binding.buffer_size == abi_base.WGPU_WHOLE_SIZE or binding.buffer_size == 0)
                0
            else
                binding.buffer_size;
        },
        .texture => {
            layout_entry.texture.sampleType = normalizers.normalizeTextureSampleType(binding.texture_sample_type);
            layout_entry.texture.viewDimension = normalizers.normalizeTextureViewDimension(binding.texture_view_dimension);
            layout_entry.texture.multisampled = if (binding.texture_multisampled) abi_base.WGPU_TRUE else abi_base.WGPU_FALSE;
        },
        .storage_texture => {
            layout_entry.storageTexture.access = normalizers.normalizeStorageTextureAccess(binding.storage_texture_access);
            layout_entry.storageTexture.format = normalizers.normalizeTextureFormat(binding.texture_format);
            if (layout_entry.storageTexture.format == abi_base.WGPUTextureFormat_Undefined) {
                layout_entry.storageTexture.format = abi_base.WGPUTextureFormat_R8Unorm;
            }
            layout_entry.storageTexture.viewDimension = normalizers.normalizeTextureViewDimension(binding.texture_view_dimension);
        },
        .sampler => {
            layout_entry.sampler.type = abi_base.WGPUSamplerBindingType_Filtering;
        },
    }

    return layout_entry;
}

fn dispatchPassBindEntry(
    self: anytype,
    binding: model_compute_types.KernelBinding,
    texture_views: *std.ArrayList(abi_base.WGPUTextureView),
    initialize_buffers_on_create: bool,
) !abi_descriptor.WGPUBindGroupEntry {
    var bind_entry = abi_descriptor.WGPUBindGroupEntry{
        .nextInChain = null,
        .binding = binding.binding,
        .buffer = null,
        .offset = binding.buffer_offset,
        .size = if (binding.buffer_size == 0) abi_base.WGPU_WHOLE_SIZE else binding.buffer_size,
        .sampler = null,
        .textureView = null,
    };

    switch (binding.resource_kind) {
        .buffer => {
            const usage = bindingUsageForBufferKind(binding);
            const requested_size = if (binding.buffer_size == abi_base.WGPU_WHOLE_SIZE)
                try requiredBytes(4, binding.buffer_offset)
            else
                try requiredBytes(binding.buffer_size, binding.buffer_offset);
            const buffer = if (initialize_buffers_on_create)
                try getOrCreateBufferInitialized(self, binding.resource_handle, requested_size, usage)
            else
                try getOrCreateBuffer(self, binding.resource_handle, requested_size, usage);
            bind_entry.buffer = buffer;
            bind_entry.size = binding.buffer_size;
        },
        .texture, .storage_texture => {
            const required_usage = if (binding.resource_kind == .storage_texture)
                (abi_base.WGPUTextureUsage_StorageBinding | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst)
            else
                (abi_base.WGPUTextureUsage_TextureBinding | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst);
            const texture = try getOrCreateTextureFromBinding(self, binding, required_usage);
            const view = try createTextureViewForBinding(self, texture, binding);
            try texture_views.append(self.core.allocator, view);
            bind_entry.textureView = view;
        },
        .sampler => {
            // Sampler binding via Dawn delegate: sampler object must be
            // created externally and passed as resource_handle. The Dawn
            // delegate backend manages VkSampler/MTLSamplerState lifetime.
            bind_entry.sampler = @ptrFromInt(binding.resource_handle);
        },
    }
    return bind_entry;
}

pub fn createBindGroupLayout(self: anytype, entries: []const abi_descriptor.WGPUBindGroupLayoutEntry) !abi_base.WGPUBindGroupLayout {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const descriptor = abi_descriptor.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .entryCount = entries.len,
        .entries = if (entries.len == 0) null else entries.ptr,
    };
    const layout = procs.wgpuDeviceCreateBindGroupLayout(self.core.device.?, &descriptor);
    if (layout == null) return error.BindGroupLayoutCreationFailed;
    return layout;
}

pub fn createBindGroup(self: anytype, layout: abi_base.WGPUBindGroupLayout, entries: []const abi_descriptor.WGPUBindGroupEntry) !abi_base.WGPUBindGroup {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const descriptor = abi_descriptor.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .layout = layout,
        .entryCount = entries.len,
        .entries = entries.ptr,
    };
    const bind_group = procs.wgpuDeviceCreateBindGroup(self.core.device.?, &descriptor);
    if (bind_group == null) return error.BindGroupCreationFailed;
    return bind_group;
}

pub fn createShaderModule(self: anytype, source: []const u8) !abi_base.WGPUShaderModule {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    var chained_source = abi_descriptor.WGPUShaderSourceWGSL{
        .chain = .{
            .next = null,
            .sType = abi_base.WGPUSType_ShaderSourceWGSL,
        },
        .code = loader.stringView(source),
    };
    const descriptor = abi_descriptor.WGPUShaderModuleDescriptor{
        .nextInChain = &chained_source.chain,
        .label = loader.emptyStringView(),
    };
    const shader_module = procs.wgpuDeviceCreateShaderModule(self.core.device.?, &descriptor);
    if (shader_module == null) return error.KernelModuleCreationFailed;
    return shader_module;
}

pub fn createComputePipeline(
    self: anytype,
    kernel_name: []const u8,
    module: abi_base.WGPUShaderModule,
    entry_point: []const u8,
    pipeline_layout: abi_base.WGPUPipelineLayout,
) !abi_base.WGPUComputePipeline {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const p0_procs = p0_procs_mod.loadP0Procs(self.core.dyn_lib);
    const compute_state = abi_descriptor.WGPUComputeState{
        .nextInChain = null,
        .module = module,
        .entryPoint = loader.stringView(entry_point),
        .constantCount = 0,
        .constants = null,
    };
    const descriptor = abi_descriptor.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = loader.stringView(kernel_name),
        .layout = pipeline_layout,
        .compute = compute_state,
    };
    if (p0_procs) |loaded| {
        if (loaded.device_create_compute_pipeline_async != null) {
            return p0_procs_mod.createComputePipelineAsyncAndWait(
                loaded,
                self.core.instance.?,
                procs,
                self.core.device.?,
                &descriptor,
            ) catch error.ComputePipelineCreationFailed;
        }
    }
    const pipeline = procs.wgpuDeviceCreateComputePipeline(self.core.device.?, &descriptor);
    if (pipeline == null) return error.ComputePipelineCreationFailed;
    return pipeline;
}

pub fn createPipelineLayout(self: anytype, bind_group_layouts: []const abi_base.WGPUBindGroupLayout) !abi_base.WGPUPipelineLayout {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const descriptor = abi_descriptor.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .bindGroupLayoutCount = bind_group_layouts.len,
        .bindGroupLayouts = bind_group_layouts.ptr,
        .immediateSize = 0,
    };
    const layout = procs.wgpuDeviceCreatePipelineLayout(self.core.device.?, &descriptor);
    if (layout == null) return error.PipelineLayoutCreationFailed;
    return layout;
}

pub fn bindingUsageForBufferKind(binding: model_compute_types.KernelBinding) abi_base.WGPUBufferUsage {
    return switch (binding.buffer_type) {
        model_binding_types.WGPUBufferBindingType_Uniform => abi_base.WGPUBufferUsage_Uniform | abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
        model_binding_types.WGPUBufferBindingType_ReadOnlyStorage => abi_base.WGPUBufferUsage_Storage | abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
        model_binding_types.WGPUBufferBindingType_Storage => abi_base.WGPUBufferUsage_Storage | abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
        else => abi_base.WGPUBufferUsage_Storage | abi_base.WGPUBufferUsage_Uniform | abi_base.WGPUBufferUsage_CopySrc | abi_base.WGPUBufferUsage_CopyDst,
    };
}
