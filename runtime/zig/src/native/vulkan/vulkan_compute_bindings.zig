//! Collect WebGPU bind-group resources into Vulkan compute descriptor bindings.

const std = @import("std");
const doe_wgsl = @import("../../compiler/wgsl/mod.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const binding_contract = @import("../../contracts/binding.zig");
const shader_binding_reflection = @import("../shader/shader_binding_reflection.zig");
const pipeline_hash = @import("vulkan_pipeline_hash.zig");

const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const MAX_BIND = native_shared.MAX_BIND;
const MAX_COMPUTE_BIND_GROUPS = native_shared.MAX_COMPUTE_BIND_GROUPS;
const MAX_KERNEL_BINDINGS = MAX_COMPUTE_BIND_GROUPS * MAX_BIND;

const DoeShaderModule = native_types.DoeShaderModule;
const DoeComputePipeline = native_types.DoeComputePipeline;
const DoeBuffer = native_types.DoeBuffer;
const DoeBindGroup = native_types.DoeBindGroup;
const DoeBindGroupLayout = native_types.DoeBindGroupLayout;
const DoePipelineLayout = native_types.DoePipelineLayout;
const DoeTexture = native_types.DoeTexture;
const DoeTextureView = native_types.DoeTextureView;
const DoeSampler = native_types.DoeSampler;
const DoeBindGroupLayoutEntry = native_shared.DoeBindGroupLayoutEntry;

const BINDING_KIND_BUFFER: u32 = @intFromEnum(doe_wgsl.BindingKind.buffer);
const ADDRESS_SPACE_STORAGE: u32 = @intFromEnum(doe_wgsl.ir.AddressSpace.storage);
const ADDRESS_SPACE_UNIFORM: u32 = @intFromEnum(doe_wgsl.ir.AddressSpace.uniform);
const ACCESS_READ: u32 = @intFromEnum(doe_wgsl.ir.AccessMode.read);
const ACCESS_READ_WRITE: u32 = @intFromEnum(doe_wgsl.ir.AccessMode.read_write);
const RESOURCE_KIND_SAMPLER = binding_contract.layoutResourceKindCode(.sampler);
const RESOURCE_KIND_TEXTURE = binding_contract.layoutResourceKindCode(.texture);
const RESOURCE_KIND_STORAGE_TEXTURE = binding_contract.layoutResourceKindCode(.storage_texture);

pub const BindingCollection = struct {
    count: usize,
    flat_mask: u64,
    descriptor_hash: u64,
};

fn shaderBufferBindingType(
    shader_module: ?*DoeShaderModule,
    group: u32,
    binding: u32,
) u32 {
    const sm = shader_module orelse
        return model_binding_types.WGPUBufferBindingType_Storage;
    shader_binding_reflection.ensureShaderBindings(sm);
    const count: usize = @min(
        @as(usize, @intCast(sm.binding_count)),
        native_shared.MAX_SHADER_BINDINGS,
    );
    for (sm.bindings[0..count]) |meta| {
        if (meta.group != group or
            meta.binding != binding or
            meta.kind != BINDING_KIND_BUFFER) continue;
        if (meta.addr_space == ADDRESS_SPACE_UNIFORM) {
            return model_binding_types.WGPUBufferBindingType_Uniform;
        }
        if (meta.addr_space == ADDRESS_SPACE_STORAGE and
            meta.access == ACCESS_READ)
        {
            return model_binding_types.WGPUBufferBindingType_ReadOnlyStorage;
        }
        if (meta.addr_space == ADDRESS_SPACE_STORAGE and
            meta.access == ACCESS_READ_WRITE)
        {
            return model_binding_types.WGPUBufferBindingType_Storage;
        }
    }
    return model_binding_types.WGPUBufferBindingType_Storage;
}

fn appendRecordedBindingAtSlot(
    pip: *const DoeComputePipeline,
    bufs: []const ?*anyopaque,
    buf_offsets: []const u64,
    buf_sizes: []const u64,
    slot: usize,
    out_bindings: []model_compute_types.KernelBinding,
    count: *usize,
    flat_mask: *u64,
    descriptor_hasher: *pipeline_hash.DescriptorBindingsHasher,
) void {
    if (slot >= bufs.len) return;
    const raw_ptr = bufs[slot] orelse return;
    const buf = cast(DoeBuffer, raw_ptr) orelse return;
    if (buf.error_object or buf.vk_id == 0 or count.* >= out_bindings.len) return;
    const group: u32 = @intCast(slot / MAX_BIND);
    const binding_index: u32 = @intCast(slot % MAX_BIND);
    const binding = model_compute_types.KernelBinding{
        .group = group,
        .binding = binding_index,
        .resource_kind = .buffer,
        .resource_handle = buf.vk_id,
        .buffer_offset = buf_offsets[slot],
        .buffer_size = buf_sizes[slot],
        .buffer_type = if (pip.vk_flat_buffer_binding_types_ready)
            pip.vk_flat_buffer_binding_types[slot]
        else
            shaderBufferBindingType(pip.shader_module, group, binding_index),
    };
    out_bindings[count.*] = binding;
    descriptor_hasher.update(binding);
    flat_mask.* |= @as(u64, 1) << @intCast(slot);
    count.* += 1;
}

pub fn collectRecordedBindings(
    pip: *const DoeComputePipeline,
    bufs: []const ?*anyopaque,
    buf_offsets: []const u64,
    buf_sizes: []const u64,
    out_bindings: []model_compute_types.KernelBinding,
) BindingCollection {
    var count: usize = 0;
    var flat_mask: u64 = 0;
    var descriptor_hasher = pipeline_hash.DescriptorBindingsHasher{};
    if (pip.vk_static_pipeline_hash_ready and
        pip.vk_static_buffer_binding_mask != 0)
    {
        var mask = pip.vk_static_buffer_binding_mask;
        while (mask != 0 and count < out_bindings.len) {
            const slot: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            appendRecordedBindingAtSlot(
                pip,
                bufs,
                buf_offsets,
                buf_sizes,
                slot,
                out_bindings,
                &count,
                &flat_mask,
                &descriptor_hasher,
            );
        }
    } else {
        for (bufs, 0..) |maybe_raw, slot| {
            if (maybe_raw == null) continue;
            appendRecordedBindingAtSlot(
                pip,
                bufs,
                buf_offsets,
                buf_sizes,
                slot,
                out_bindings,
                &count,
                &flat_mask,
                &descriptor_hasher,
            );
        }
    }
    return .{
        .count = count,
        .flat_mask = flat_mask,
        .descriptor_hash = descriptor_hasher.final(),
    };
}

fn pipelineLayoutEntry(
    pip: *const DoeComputePipeline,
    group_index: usize,
    binding: u32,
) ?DoeBindGroupLayoutEntry {
    const layout = pip.layout orelse return null;
    if (group_index >= layout.bind_group_layout_count) return null;
    const group_layout = layout.bind_group_layouts[group_index] orelse return null;
    const entries = group_layout.entries orelse return null;
    for (entries) |entry| {
        if (entry.binding == binding) return entry;
    }
    return null;
}

fn bindingAtSlot(
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
    slot: usize,
) ?model_compute_types.KernelBinding {
    const group_index = slot / MAX_BIND;
    const binding_index = slot % MAX_BIND;
    if (group_index >= bind_groups.len) return null;
    const group = bind_groups[group_index] orelse return null;
    if (binding_index >= group.count) return null;
    const group_u32: u32 = @intCast(group_index);
    const binding_u32: u32 = @intCast(binding_index);
    const layout_entry = pipelineLayoutEntry(pip, group_index, binding_u32);
    const binding_bit = @as(u64, 1) << @intCast(binding_index);

    if ((group.vk_buffer_binding_mask & binding_bit) != 0 or
        group.buffers[binding_index] != null)
    {
        const handle = if ((group.vk_buffer_binding_mask & binding_bit) != 0)
            group.vk_buffer_handles[binding_index]
        else buffer_handle: {
            const raw_ptr = group.buffers[binding_index] orelse return null;
            const buffer = cast(DoeBuffer, raw_ptr) orelse return null;
            if (buffer.error_object) return null;
            break :buffer_handle buffer.vk_id;
        };
        if (handle == 0) return null;
        return .{
            .group = group_u32,
            .binding = binding_u32,
            .resource_kind = .buffer,
            .resource_handle = handle,
            .buffer_offset = group.offsets[binding_index],
            .buffer_size = group.buffer_sizes[binding_index],
            .buffer_type = if (pip.vk_flat_buffer_binding_types_ready)
                pip.vk_flat_buffer_binding_types[slot]
            else
                shaderBufferBindingType(pip.shader_module, group_u32, binding_u32),
        };
    }

    if (group.texture_views[binding_index]) |raw_view| {
        const view = cast(DoeTextureView, raw_view) orelse return null;
        if (view.tex.error_object or view.tex.vk_id == 0) return null;
        const entry = layout_entry orelse return null;
        const resource_kind: model_compute_types.KernelBindingResourceKind =
            switch (entry.resource_kind) {
                RESOURCE_KIND_TEXTURE => .texture,
                RESOURCE_KIND_STORAGE_TEXTURE => .storage_texture,
                else => return null,
            };
        return .{
            .group = group_u32,
            .binding = binding_u32,
            .resource_kind = resource_kind,
            .resource_handle = view.tex.vk_id,
            .texture_sample_type = if (resource_kind == .texture)
                entry.texture_sample_type
            else
                model_binding_types.WGPUTextureSampleType_Undefined,
            .texture_view_dimension = if (view.dimension != 0)
                view.dimension
            else
                entry.texture_view_dimension,
            .storage_texture_access = if (resource_kind == .storage_texture)
                entry.texture_sample_type
            else
                model_binding_types.WGPUStorageTextureAccess_Undefined,
            .texture_aspect = view.aspect,
            .texture_format = if (view.format != 0) view.format else view.tex.format,
            .texture_multisampled = view.tex.sample_count > 1,
        };
    }

    if (group.samplers[binding_index]) |raw_sampler| {
        const sampler = cast(DoeSampler, raw_sampler) orelse return null;
        if (layout_entry) |entry| {
            if (entry.resource_kind != RESOURCE_KIND_SAMPLER) return null;
        }
        return .{
            .group = group_u32,
            .binding = binding_u32,
            .resource_kind = .sampler,
            .resource_handle = @intFromPtr(sampler),
        };
    }
    return null;
}

fn bindGroupsHaveNonBufferResources(
    bind_groups: []const ?*DoeBindGroup,
) bool {
    for (bind_groups) |maybe_group| {
        const group = maybe_group orelse continue;
        for (group.texture_views) |view| {
            if (view != null) return true;
        }
        for (group.samplers) |sampler| {
            if (sampler != null) return true;
        }
    }
    return false;
}

fn appendBindGroupBinding(
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
    slot: usize,
    out_bindings: []model_compute_types.KernelBinding,
    count: *usize,
    flat_mask: *u64,
    descriptor_hasher: *pipeline_hash.DescriptorBindingsHasher,
) void {
    if (count.* >= out_bindings.len) return;
    const binding = bindingAtSlot(pip, bind_groups, slot) orelse return;
    out_bindings[count.*] = binding;
    descriptor_hasher.update(binding);
    flat_mask.* |= @as(u64, 1) << @intCast(slot);
    count.* += 1;
}

pub fn collectBindGroupBindings(
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
    out_bindings: []model_compute_types.KernelBinding,
) BindingCollection {
    var count: usize = 0;
    var flat_mask: u64 = 0;
    var descriptor_hasher = pipeline_hash.DescriptorBindingsHasher{};
    if (pip.vk_static_pipeline_hash_ready and
        pip.vk_static_buffer_binding_mask != 0 and
        !bindGroupsHaveNonBufferResources(bind_groups))
    {
        var mask = pip.vk_static_buffer_binding_mask;
        while (mask != 0 and count < out_bindings.len) {
            const slot: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            appendBindGroupBinding(
                pip,
                bind_groups,
                slot,
                out_bindings,
                &count,
                &flat_mask,
                &descriptor_hasher,
            );
        }
    } else {
        for (bind_groups, 0..) |maybe_group, group_index| {
            const group = maybe_group orelse continue;
            const binding_count: usize = @min(
                @as(usize, @intCast(group.count)),
                MAX_BIND,
            );
            for (0..binding_count) |binding_index| {
                appendBindGroupBinding(
                    pip,
                    bind_groups,
                    (group_index * MAX_BIND) + binding_index,
                    out_bindings,
                    &count,
                    &flat_mask,
                    &descriptor_hasher,
                );
            }
        }
    }
    return .{
        .count = count,
        .flat_mask = flat_mask,
        .descriptor_hash = descriptor_hasher.final(),
    };
}

test "collectBindGroupBindings includes readonly storage textures" {
    var entries = [_]DoeBindGroupLayoutEntry{.{
        .binding = 1,
        .resource_kind = RESOURCE_KIND_STORAGE_TEXTURE,
        .texture_sample_type = model_binding_types.WGPUStorageTextureAccess_ReadOnly,
        .texture_view_dimension = 2,
    }};
    var group_layout = DoeBindGroupLayout{
        .entry_count = 1,
        .entries = entries[0..],
    };
    var pipeline_layout = DoePipelineLayout{ .bind_group_layout_count = 1 };
    pipeline_layout.bind_group_layouts[0] = &group_layout;
    var pipeline = DoeComputePipeline{ .layout = &pipeline_layout };
    var texture = DoeTexture{
        .backend = .vulkan,
        .format = 18,
        .width = 8,
        .height = 8,
        .usage = 8,
        .vk_id = 77,
    };
    var view = DoeTextureView{
        .backend = .vulkan,
        .tex = &texture,
        .format = 18,
        .dimension = 2,
    };
    var group = DoeBindGroup{ .count = 2 };
    group.texture_views[1] = toOpaque(&view);
    var groups = [_]?*DoeBindGroup{&group};
    var storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;

    const result = collectBindGroupBindings(&pipeline, groups[0..], &storage);

    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(
        model_compute_types.KernelBindingResourceKind.storage_texture,
        storage[0].resource_kind,
    );
    try std.testing.expectEqual(@as(u64, 77), storage[0].resource_handle);
    try std.testing.expectEqual(
        model_binding_types.WGPUStorageTextureAccess_ReadOnly,
        storage[0].storage_texture_access,
    );
}
