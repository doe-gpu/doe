// doe_vulkan_compute_native.zig — Vulkan-specific compute operations for the Doe native C ABI.
// Routes shader module creation through NativeVulkanRuntime when the device backend is
// .vulkan. Queue submit replays recorded compute dispatches with Vulkan-native deferred
// submission semantics.

const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const std = @import("std");
const doe_wgsl = @import("doe_wgsl/mod.zig");
const runtime_compile = @import("doe_wgsl/runtime_compile.zig");
const shader_translation_cache = @import("doe_shader_translation_cache.zig");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_cmds = @import("doe_native_command_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const bind_group_native = @import("doe_bind_group_native.zig");
const model_compute_types = @import("model_compute_types.zig");
const model_binding_types = @import("model_binding_value_types.zig");
const shader_native = @import("doe_shader_native.zig");
const resource_ops = @import("backend/dropin_resource_ops.zig");
const pipeline_hash = @import("doe_vulkan_pipeline_hash.zig");

const c = if (has_vulkan) resource_ops.vk_constants else struct {};
const vk_dispatch_indirect = if (has_vulkan) resource_ops.vk_dispatch_indirect else struct {};
const alloc = native_helpers.alloc;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const MAX_COMPUTE_BIND_GROUPS = native_shared.MAX_COMPUTE_BIND_GROUPS;
const MAX_BIND = native_shared.MAX_BIND;
const PREPARED_BINDING_CACHE_CAPACITY = native_shared.VULKAN_PREPARED_BINDING_CACHE_CAPACITY;

const NativeVulkanRuntime = native_shared.NativeVulkanRuntime;
const DoeShaderModule = native_types.DoeShaderModule;
const DoeComputePipeline = native_types.DoeComputePipeline;
const DoeBuffer = native_types.DoeBuffer;
const DoeBindGroup = native_types.DoeBindGroup;
// Maximum KernelBinding slots: groups × bindings per group.
const MAX_KERNEL_BINDINGS: usize = MAX_COMPUTE_BIND_GROUPS * MAX_BIND;
const MAX_FLAT_BIND: usize = native_shared.MAX_FLAT_BIND;

const BINDING_KIND_BUFFER: u32 = @intFromEnum(doe_wgsl.BindingKind.buffer);
const ADDRESS_SPACE_STORAGE: u32 = @intFromEnum(doe_wgsl.ir.AddressSpace.storage);
const ADDRESS_SPACE_UNIFORM: u32 = @intFromEnum(doe_wgsl.ir.AddressSpace.uniform);
const ACCESS_READ: u32 = @intFromEnum(doe_wgsl.ir.AccessMode.read);
const ACCESS_READ_WRITE: u32 = @intFromEnum(doe_wgsl.ir.AccessMode.read_write);
const BIND_GROUP_LAYOUT_RESOURCE_KIND_BUFFER: u32 = 1;
const SPIRV_MAGIC: u32 = 0x07230203;
const DISPATCH_INDIRECT_ARGS_BYTES: u64 = @sizeOf([3]u32);
const DISPATCH_INDIRECT_ARGS_ALIGNMENT: u64 = @alignOf(u32);

const BindingCollection = struct {
    count: usize,
    flat_mask: u64,
    descriptor_hash: u64,
};

pub const VulkanDispatchBindingState = struct {
    count: usize = 0,
    flat_mask: u64 = 0,
    descriptor_hash: u64 = 0,
    bindings: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined,
};

fn bindGroupIdentityKey(bind_groups: []const ?*DoeBindGroup) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const group_count: u32 = @intCast(@min(bind_groups.len, MAX_COMPUTE_BIND_GROUPS));
    hasher.update(std.mem.asBytes(&group_count));
    for (0..MAX_COMPUTE_BIND_GROUPS) |index| {
        const ptr_value: usize = if (index < group_count)
            if (bind_groups[index]) |bg| @intFromPtr(bg) else 0
        else
            0;
        hasher.update(std.mem.asBytes(&ptr_value));
    }
    const key = hasher.final();
    return if (key == 0) 1 else key;
}

fn bindGroupIdentityMatches(
    cached: *const [MAX_COMPUTE_BIND_GROUPS]?*DoeBindGroup,
    bind_groups: []const ?*DoeBindGroup,
) bool {
    const group_count = @min(bind_groups.len, MAX_COMPUTE_BIND_GROUPS);
    for (0..MAX_COMPUTE_BIND_GROUPS) |index| {
        const current = if (index < group_count) bind_groups[index] else null;
        if (cached[index] != current) return false;
    }
    return true;
}

fn clearPreparedBindingCacheSlot(pip: *DoeComputePipeline, slot: usize) void {
    if (pip.vk_prepared_binding_cache_keys[slot] == 0) return;
    for (&pip.vk_prepared_binding_cache_bind_groups[slot]) |*maybe_bg| {
        if (maybe_bg.*) |bg| bind_group_native.doeNativeBindGroupRelease(toOpaque(bg));
        maybe_bg.* = null;
    }
    pip.vk_prepared_binding_cache_keys[slot] = 0;
    pip.vk_prepared_binding_cache_counts[slot] = 0;
    pip.vk_prepared_binding_cache_flat_masks[slot] = 0;
    pip.vk_prepared_binding_cache_descriptor_hashes[slot] = 0;
}

fn clearPipelinePreparedBindingCache(pip: *DoeComputePipeline) void {
    for (0..PREPARED_BINDING_CACHE_CAPACITY) |slot| {
        clearPreparedBindingCacheSlot(pip, slot);
    }
    pip.vk_prepared_binding_cache_next = 0;
}

fn findPreparedBindingCacheSlot(
    pip: *const DoeComputePipeline,
    key: u64,
    bind_groups: []const ?*DoeBindGroup,
) ?usize {
    for (pip.vk_prepared_binding_cache_keys, 0..) |entry_key, slot| {
        if (entry_key != key) continue;
        if (bindGroupIdentityMatches(&pip.vk_prepared_binding_cache_bind_groups[slot], bind_groups)) return slot;
    }
    return null;
}

fn loadPreparedBindingCache(
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
) ?VulkanDispatchBindingState {
    const key = bindGroupIdentityKey(bind_groups);
    const slot = findPreparedBindingCacheSlot(pip, key, bind_groups) orelse return null;
    var state = VulkanDispatchBindingState{
        .count = pip.vk_prepared_binding_cache_counts[slot],
        .flat_mask = pip.vk_prepared_binding_cache_flat_masks[slot],
        .descriptor_hash = pip.vk_prepared_binding_cache_descriptor_hashes[slot],
    };
    const count: usize = @intCast(pip.vk_prepared_binding_cache_counts[slot]);
    @memcpy(state.bindings[0..count], pip.vk_prepared_binding_cache_bindings[slot][0..count]);
    return state;
}

fn nextPreparedBindingCacheSlot(pip: *DoeComputePipeline) usize {
    for (pip.vk_prepared_binding_cache_keys, 0..) |key, slot| {
        if (key == 0) return slot;
    }
    const slot: usize = @intCast(pip.vk_prepared_binding_cache_next % PREPARED_BINDING_CACHE_CAPACITY);
    const capacity_u32: u32 = @intCast(PREPARED_BINDING_CACHE_CAPACITY);
    pip.vk_prepared_binding_cache_next = (pip.vk_prepared_binding_cache_next + 1) % capacity_u32;
    return slot;
}

fn storePreparedBindingCache(
    pip: *DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
    state: *const VulkanDispatchBindingState,
) void {
    if (state.count > MAX_KERNEL_BINDINGS) return;
    const key = bindGroupIdentityKey(bind_groups);
    const slot = findPreparedBindingCacheSlot(pip, key, bind_groups) orelse nextPreparedBindingCacheSlot(pip);
    clearPreparedBindingCacheSlot(pip, slot);

    const group_count = @min(bind_groups.len, MAX_COMPUTE_BIND_GROUPS);
    for (0..MAX_COMPUTE_BIND_GROUPS) |index| {
        const bg = if (index < group_count) bind_groups[index] else null;
        pip.vk_prepared_binding_cache_bind_groups[slot][index] = bg;
        if (bg) |ptr| native_helpers.object_add_ref(DoeBindGroup, toOpaque(ptr));
    }
    pip.vk_prepared_binding_cache_keys[slot] = key;
    pip.vk_prepared_binding_cache_counts[slot] = @intCast(state.count);
    pip.vk_prepared_binding_cache_flat_masks[slot] = state.flat_mask;
    pip.vk_prepared_binding_cache_descriptor_hashes[slot] = state.descriptor_hash;
    @memcpy(pip.vk_prepared_binding_cache_bindings[slot][0..state.count], state.bindings[0..state.count]);
}

test "prepared binding cache retains identity and reloads state" {
    const TEST_DESCRIPTOR_HASH: u64 = 101;
    const TEST_RESOURCE_HANDLE: u64 = 77;
    const TEST_BUFFER_SIZE: u64 = 256;

    const bg = native_helpers.make(DoeBindGroup) orelse return error.SkipZigTest;
    bg.* = .{};
    var pip = DoeComputePipeline{};
    defer {
        clearPipelinePreparedBindingCache(&pip);
        bind_group_native.doeNativeBindGroupRelease(toOpaque(bg));
    }

    var bind_groups = [_]?*DoeBindGroup{ bg, null, null, null };
    var state = VulkanDispatchBindingState{
        .count = 1,
        .flat_mask = 1,
        .descriptor_hash = TEST_DESCRIPTOR_HASH,
    };
    state.bindings[0] = .{
        .group = 0,
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = TEST_RESOURCE_HANDLE,
        .buffer_size = TEST_BUFFER_SIZE,
    };

    storePreparedBindingCache(&pip, bind_groups[0..], &state);
    try std.testing.expectEqual(@as(u32, 2), bg.ref_count);

    const cached = loadPreparedBindingCache(&pip, bind_groups[0..]) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(state.count, cached.count);
    try std.testing.expectEqual(state.flat_mask, cached.flat_mask);
    try std.testing.expectEqual(state.descriptor_hash, cached.descriptor_hash);
    try std.testing.expectEqual(state.bindings[0], cached.bindings[0]);

    clearPipelinePreparedBindingCache(&pip);
    try std.testing.expectEqual(@as(u32, 1), bg.ref_count);
}

fn shader_buffer_binding_type(
    shader_module: ?*DoeShaderModule,
    group: u32,
    binding: u32,
) u32 {
    const sm = shader_module orelse return model_binding_types.WGPUBufferBindingType_Storage;
    shader_native.ensureShaderBindings(sm);
    const binding_count: usize = @min(
        @as(usize, @intCast(sm.binding_count)),
        native_shared.MAX_SHADER_BINDINGS,
    );
    for (sm.bindings[0..binding_count]) |meta| {
        if (meta.group != group or meta.binding != binding) continue;
        if (meta.kind != BINDING_KIND_BUFFER) break;
        if (meta.addr_space == ADDRESS_SPACE_UNIFORM) return model_binding_types.WGPUBufferBindingType_Uniform;
        if (meta.addr_space == ADDRESS_SPACE_STORAGE and
            meta.access == ACCESS_READ) return model_binding_types.WGPUBufferBindingType_ReadOnlyStorage;
        if (meta.addr_space == ADDRESS_SPACE_STORAGE and
            meta.access == ACCESS_READ_WRITE) return model_binding_types.WGPUBufferBindingType_Storage;
        return model_binding_types.WGPUBufferBindingType_Storage;
    }
    return model_binding_types.WGPUBufferBindingType_Storage;
}

fn populate_pipeline_buffer_binding_types(pip: *DoeComputePipeline, shader_module: ?*DoeShaderModule) void {
    for (0..MAX_FLAT_BIND) |slot| {
        const group_u32: u32 = @intCast(slot / MAX_BIND);
        const binding_u32: u32 = @intCast(slot % MAX_BIND);
        pip.vk_flat_buffer_binding_types[slot] = shader_buffer_binding_type(shader_module, group_u32, binding_u32);
    }
    pip.vk_flat_buffer_binding_types_ready = true;
}

fn reset_pipeline_static_hashes(pip: *DoeComputePipeline) void {
    clearPipelinePreparedBindingCache(pip);
    pip.vk_static_layout_hash = 0;
    pip.vk_static_pipeline_hash = 0;
    pip.vk_static_buffer_binding_mask = 0;
    pip.vk_static_buffer_binding_count = 0;
    pip.vk_static_pipeline_hash_ready = false;
}

fn pipeline_entry_point(pip: *const DoeComputePipeline) ?[]const u8 {
    return if (pip.vk_entry_point_owned) |ep| ep[0..] else null;
}

fn precompute_pipeline_static_hashes(pip: *DoeComputePipeline) void {
    reset_pipeline_static_hashes(pip);
    if (!pip.vk_spirv_hash_ready or !pip.vk_flat_buffer_binding_types_ready) return;
    const layout = pip.layout orelse return;

    var binding_mask: u64 = 0;
    var binding_count: u32 = 0;
    for (layout.bind_group_layouts[0..layout.bind_group_layout_count], 0..) |maybe_bgl, group_index| {
        const bgl = maybe_bgl orelse return;
        const entries = bgl.entries orelse {
            if (bgl.entry_count == 0) continue;
            return;
        };
        for (entries[0..bgl.entry_count]) |entry| {
            if (entry.resource_kind != BIND_GROUP_LAYOUT_RESOURCE_KIND_BUFFER) return;
            if (entry.binding >= MAX_BIND) return;
            const slot = (group_index * MAX_BIND) + entry.binding;
            const slot_bit = @as(u64, 1) << @intCast(slot);
            if ((binding_mask & slot_bit) == 0) {
                binding_mask |= slot_bit;
                binding_count += 1;
            }
        }
    }

    var binding_storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;
    var count: usize = 0;
    for (0..MAX_FLAT_BIND) |slot| {
        const slot_bit = @as(u64, 1) << @intCast(slot);
        if ((binding_mask & slot_bit) == 0) continue;
        binding_storage[count] = .{
            .group = @intCast(slot / MAX_BIND),
            .binding = @intCast(slot % MAX_BIND),
            .resource_kind = .buffer,
            .resource_handle = 0,
            .buffer_type = pip.vk_flat_buffer_binding_types[slot],
        };
        count += 1;
    }

    const bindings = binding_storage[0..count];
    const layout_hash = pipeline_hash.compute_layout_hash(bindings);
    pip.vk_static_layout_hash = layout_hash;
    pip.vk_static_pipeline_hash = pipeline_hash.compute_pipeline_hash_from_layout_hash(
        pip.vk_spirv_hash,
        pipeline_entry_point(pip),
        layout_hash,
    );
    pip.vk_static_buffer_binding_mask = binding_mask;
    pip.vk_static_buffer_binding_count = binding_count;
    pip.vk_static_pipeline_hash_ready = true;
}

// ============================================================
// Shader module — WGSL → SPIR-V
// ============================================================

/// Translate WGSL source to SPIR-V words and store them in shader.spirv_data.
/// Called from doe_shader_native.zig when dev.backend == .vulkan.
/// Returns error on OOM or compilation failure.
pub fn vulkan_create_shader_module(
    shader: *DoeShaderModule,
    wgsl: []const u8,
) error{ OutOfMemory, ShaderCompileFailed }!void {
    var cached_translation = shader_translation_cache.lookupComputeSpirvTranslation(alloc, wgsl);
    defer if (cached_translation) |*cached| cached.deinit(alloc);

    if (cached_translation) |*cached| {
        moveTranslationInfoToShader(shader, &cached.info);
        try assignSpirvWords(shader, cached.spirv);
        return;
    }

    var spirv_buf = alloc.alloc(u8, doe_wgsl.MAX_SPIRV_OUTPUT) catch return error.OutOfMemory;
    defer alloc.free(spirv_buf);

    var translation = runtime_compile.translateToSpirvForVulkanComputeRuntime(alloc, wgsl, spirv_buf) catch {
        const head_len: usize = @min(wgsl.len, 120);
        std.log.err(
            "doe_vulkan_compute: WGSL→SPIR-V translation failed: {s} | wgsl[0..{d}]: {s}",
            .{ doe_wgsl.lastErrorMessage(), head_len, wgsl[0..head_len] },
        );
        return error.ShaderCompileFailed;
    };
    errdefer translation.info.deinit(alloc);

    if (translation.len == 0 or (translation.len % 4) != 0) {
        std.log.err("doe_vulkan_compute: SPIR-V output length invalid: {}", .{translation.len});
        return error.ShaderCompileFailed;
    }

    shader_translation_cache.storeComputeSpirvTranslation(
        alloc,
        wgsl,
        spirv_buf[0..translation.len],
        &translation.info,
    );
    moveTranslationInfoToShader(shader, &translation.info);
    try assignSpirvWords(shader, spirv_buf[0..translation.len]);
}

// ============================================================
// Compute pipeline — copy SPIR-V from shader to pipeline
// ============================================================

/// Duplicate SPIR-V words from shader into pip.spirv_data.
/// Called from doe_shader_native.zig for the Vulkan compute pipeline creation path.
/// Returns error on OOM.
pub fn vulkan_copy_pipeline_spirv(
    pip: *DoeComputePipeline,
    shader: *DoeShaderModule,
) error{OutOfMemory}!void {
    const src = shader.spirv_data orelse return;
    pip.spirv_data = alloc.dupe(u32, src) catch return error.OutOfMemory;
    pip.vk_spirv_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(src));
    pip.vk_spirv_hash_ready = true;
    populate_pipeline_buffer_binding_types(pip, shader);
    precompute_pipeline_static_hashes(pip);
}

/// Free pip.spirv_data if heap-allocated. The runtime manages VkPipeline lifecycle.
pub fn vulkan_release_compute_pipeline(pip: *DoeComputePipeline) void {
    if (pip.spirv_data) |s| {
        alloc.free(s);
        pip.spirv_data = null;
    }
    pip.vk_spirv_hash = 0;
    pip.vk_spirv_hash_ready = false;
    reset_pipeline_static_hashes(pip);
    pip.vk_flat_buffer_binding_types_ready = false;
    if (pip.vk_entry_point_owned) |ep| {
        alloc.free(ep);
        pip.vk_entry_point_owned = null;
    }
}

// ============================================================
// Compute dispatch — queue submit replay through NativeVulkanRuntime
// ============================================================

fn append_recorded_binding_at_slot(
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
    if (buf.error_object) return;
    if (buf.vk_id == 0) return;
    if (count.* >= out_bindings.len) return;
    const shader_module = pip.shader_module;
    const group_u32: u32 = @intCast(slot / MAX_BIND);
    const binding_u32: u32 = @intCast(slot % MAX_BIND);
    const binding = model_compute_types.KernelBinding{
        .group = group_u32,
        .binding = binding_u32,
        .resource_kind = .buffer,
        .resource_handle = buf.vk_id,
        .buffer_offset = buf_offsets[slot],
        .buffer_size = buf_sizes[slot],
        .buffer_type = if (pip.vk_flat_buffer_binding_types_ready)
            pip.vk_flat_buffer_binding_types[slot]
        else
            shader_buffer_binding_type(shader_module, group_u32, binding_u32),
    };
    out_bindings[count.*] = binding;
    descriptor_hasher.update(binding);
    flat_mask.* |= @as(u64, 1) << @intCast(slot);
    count.* += 1;
}

/// Build a KernelBinding slice from recorded flat buffer bindings for the given pipeline.
/// Returns the number of bindings populated in out_bindings.
fn collect_recorded_bindings(
    pip: *const DoeComputePipeline,
    bufs: []const ?*anyopaque,
    buf_offsets: []const u64,
    buf_sizes: []const u64,
    out_bindings: []model_compute_types.KernelBinding,
) BindingCollection {
    var count: usize = 0;
    var flat_mask: u64 = 0;
    var descriptor_hasher = pipeline_hash.DescriptorBindingsHasher{};
    if (pip.vk_static_pipeline_hash_ready and pip.vk_static_buffer_binding_mask != 0) {
        var mask = pip.vk_static_buffer_binding_mask;
        while (mask != 0 and count < out_bindings.len) {
            const slot: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            append_recorded_binding_at_slot(
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
        return .{ .count = count, .flat_mask = flat_mask, .descriptor_hash = descriptor_hasher.final() };
    }
    for (bufs, 0..) |maybe_raw, slot| {
        if (maybe_raw == null) continue;
        append_recorded_binding_at_slot(
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
    return .{ .count = count, .flat_mask = flat_mask, .descriptor_hash = descriptor_hasher.final() };
}

pub fn vulkan_collect_recorded_binding_state(
    pip: *const DoeComputePipeline,
    bufs: []const ?*anyopaque,
    buf_offsets: []const u64,
    buf_sizes: []const u64,
) native_cmds.RecordedVulkanBindingState {
    var state = native_cmds.RecordedVulkanBindingState{};
    const binding_result = collect_recorded_bindings(pip, bufs, buf_offsets, buf_sizes, &state.bindings);
    state.valid = true;
    state.count = binding_result.count;
    state.flat_mask = binding_result.flat_mask;
    state.descriptor_hash = binding_result.descriptor_hash;
    return state;
}

fn append_bind_group_binding_at_slot(
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
    slot: usize,
    out_bindings: []model_compute_types.KernelBinding,
    count: *usize,
    flat_mask: *u64,
    descriptor_hasher: *pipeline_hash.DescriptorBindingsHasher,
) void {
    const group_index = slot / MAX_BIND;
    const binding_index = slot % MAX_BIND;
    if (group_index >= bind_groups.len) return;
    const bg = bind_groups[group_index] orelse return;
    if (binding_index >= bg.count) return;
    const binding_bit = @as(u64, 1) << @intCast(binding_index);
    const resource_handle = if ((bg.vk_buffer_binding_mask & binding_bit) != 0)
        bg.vk_buffer_handles[binding_index]
    else blk: {
        const raw_ptr = bg.buffers[binding_index] orelse return;
        const buf = cast(DoeBuffer, raw_ptr) orelse return;
        if (buf.error_object) return;
        break :blk buf.vk_id;
    };
    if (resource_handle == 0) return;
    if (count.* >= out_bindings.len) return;
    const group_u32: u32 = @intCast(group_index);
    const binding_u32: u32 = @intCast(binding_index);
    const binding = model_compute_types.KernelBinding{
        .group = group_u32,
        .binding = binding_u32,
        .resource_kind = .buffer,
        .resource_handle = resource_handle,
        .buffer_offset = bg.offsets[binding_index],
        .buffer_size = bg.buffer_sizes[binding_index],
        .buffer_type = if (pip.vk_flat_buffer_binding_types_ready)
            pip.vk_flat_buffer_binding_types[slot]
        else
            shader_buffer_binding_type(pip.shader_module, group_u32, binding_u32),
    };
    out_bindings[count.*] = binding;
    descriptor_hasher.update(binding);
    flat_mask.* |= @as(u64, 1) << @intCast(slot);
    count.* += 1;
}

fn collect_bind_group_bindings(
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
    out_bindings: []model_compute_types.KernelBinding,
) BindingCollection {
    var count: usize = 0;
    var flat_mask: u64 = 0;
    var descriptor_hasher = pipeline_hash.DescriptorBindingsHasher{};
    if (pip.vk_static_pipeline_hash_ready and pip.vk_static_buffer_binding_mask != 0) {
        var mask = pip.vk_static_buffer_binding_mask;
        while (mask != 0 and count < out_bindings.len) {
            const slot: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            append_bind_group_binding_at_slot(
                pip,
                bind_groups,
                slot,
                out_bindings,
                &count,
                &flat_mask,
                &descriptor_hasher,
            );
        }
        return .{ .count = count, .flat_mask = flat_mask, .descriptor_hash = descriptor_hasher.final() };
    }
    for (bind_groups, 0..) |maybe_bg, group_index| {
        const bg = maybe_bg orelse continue;
        if (bg.vk_buffer_binding_cache_complete and bg.vk_buffer_binding_mask != 0) {
            var mask = bg.vk_buffer_binding_mask;
            while (mask != 0 and count < out_bindings.len) {
                const binding_index: usize = @intCast(@ctz(mask));
                mask &= mask - 1;
                append_bind_group_binding_at_slot(
                    pip,
                    bind_groups,
                    (group_index * MAX_BIND) + binding_index,
                    out_bindings,
                    &count,
                    &flat_mask,
                    &descriptor_hasher,
                );
            }
            continue;
        }
        const binding_count: usize = @min(@as(usize, @intCast(bg.count)), MAX_BIND);
        for (0..binding_count) |binding_index| {
            append_bind_group_binding_at_slot(
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
    return .{ .count = count, .flat_mask = flat_mask, .descriptor_hash = descriptor_hasher.final() };
}

test "collect_bind_group_bindings cached handles match fallback slots" {
    var pip = DoeComputePipeline{ .vk_flat_buffer_binding_types_ready = true };
    pip.vk_flat_buffer_binding_types[1] = model_binding_types.WGPUBufferBindingType_Uniform;
    pip.vk_flat_buffer_binding_types[MAX_BIND + 2] = model_binding_types.WGPUBufferBindingType_Storage;

    var buffer_a = DoeBuffer{ .vk_id = 11, .size = 128 };
    var buffer_b = DoeBuffer{ .vk_id = 22, .size = 256 };

    var fallback_group0 = DoeBindGroup{ .count = 2 };
    fallback_group0.buffers[1] = native_helpers.toOpaque(&buffer_a);
    fallback_group0.offsets[1] = 4;
    fallback_group0.buffer_sizes[1] = 64;
    var fallback_group1 = DoeBindGroup{ .count = 3 };
    fallback_group1.buffers[2] = native_helpers.toOpaque(&buffer_b);
    fallback_group1.offsets[2] = 8;
    fallback_group1.buffer_sizes[2] = 128;

    var cached_group0 = fallback_group0;
    cached_group0.vk_buffer_handles[1] = buffer_a.vk_id;
    cached_group0.vk_buffer_binding_mask = @as(u64, 1) << 1;
    cached_group0.vk_buffer_binding_cache_complete = true;
    var cached_group1 = fallback_group1;
    cached_group1.vk_buffer_handles[2] = buffer_b.vk_id;
    cached_group1.vk_buffer_binding_mask = @as(u64, 1) << 2;
    cached_group1.vk_buffer_binding_cache_complete = true;

    var fallback_groups = [_]?*DoeBindGroup{ &fallback_group0, &fallback_group1 };
    var cached_groups = [_]?*DoeBindGroup{ &cached_group0, &cached_group1 };
    var fallback_storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;
    var cached_storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;

    const fallback_result = collect_bind_group_bindings(&pip, fallback_groups[0..], &fallback_storage);
    const cached_result = collect_bind_group_bindings(&pip, cached_groups[0..], &cached_storage);

    try std.testing.expectEqual(fallback_result.count, cached_result.count);
    try std.testing.expectEqual(fallback_result.flat_mask, cached_result.flat_mask);
    try std.testing.expectEqual(fallback_result.descriptor_hash, cached_result.descriptor_hash);
    try std.testing.expectEqualSlices(
        model_compute_types.KernelBinding,
        fallback_storage[0..fallback_result.count],
        cached_storage[0..cached_result.count],
    );
    try std.testing.expectEqual((@as(u64, 1) << 1) | (@as(u64, 1) << (MAX_BIND + 2)), cached_result.flat_mask);
}

test "collect_bind_group_bindings partial cache scans uncached buffers" {
    var pip = DoeComputePipeline{ .vk_flat_buffer_binding_types_ready = true };
    pip.vk_flat_buffer_binding_types[1] = model_binding_types.WGPUBufferBindingType_Uniform;
    pip.vk_flat_buffer_binding_types[2] = model_binding_types.WGPUBufferBindingType_Storage;

    var buffer_a = DoeBuffer{ .vk_id = 31, .size = 128 };
    var buffer_b = DoeBuffer{ .vk_id = 32, .size = 256 };

    var group = DoeBindGroup{ .count = 3 };
    group.buffers[1] = native_helpers.toOpaque(&buffer_a);
    group.offsets[1] = 4;
    group.buffer_sizes[1] = 64;
    group.vk_buffer_handles[1] = buffer_a.vk_id;
    group.vk_buffer_binding_mask = @as(u64, 1) << 1;
    group.buffers[2] = native_helpers.toOpaque(&buffer_b);
    group.offsets[2] = 8;
    group.buffer_sizes[2] = 128;

    var groups = [_]?*DoeBindGroup{&group};
    var storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;
    const result = collect_bind_group_bindings(&pip, groups[0..], &storage);

    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual((@as(u64, 1) << 1) | (@as(u64, 1) << 2), result.flat_mask);
    try std.testing.expectEqual(@as(u64, 31), storage[0].resource_handle);
    try std.testing.expectEqual(@as(u64, 32), storage[1].resource_handle);
}

fn use_static_pipeline_hash(
    rt: *NativeVulkanRuntime,
    pip: *const DoeComputePipeline,
    spirv: []const u32,
    entry_slice: ?[]const u8,
    bindings: []const model_compute_types.KernelBinding,
    flat_mask: u64,
    descriptor_hash: u64,
) !bool {
    if (!pip.vk_static_pipeline_hash_ready) return false;
    if (pip.vk_static_buffer_binding_count != bindings.len) return false;
    if (pip.vk_static_buffer_binding_mask != flat_mask) return false;
    if (spirv.len == 0 or spirv[0] != SPIRV_MAGIC) return error.ShaderCompileFailed;
    try rt.set_compute_shader_spirv_with_hashes(
        spirv,
        pip.vk_static_pipeline_hash,
        pip.vk_static_layout_hash,
        descriptor_hash,
        entry_slice,
        bindings,
        false,
    );
    return true;
}

fn prepare_pipeline_bindings(
    rt: *NativeVulkanRuntime,
    pip: *const DoeComputePipeline,
    spirv: []const u32,
    binding_result: BindingCollection,
    binding_storage: []const model_compute_types.KernelBinding,
) bool {
    const bindings_slice = binding_storage[0..binding_result.count];
    const bindings: ?[]const model_compute_types.KernelBinding = if (binding_result.count > 0)
        bindings_slice
    else
        null;

    // Pass the pipeline's captured entry-point name so the Vulkan
    // runtime matches the SPIR-V's actual OpEntryPoint. Null entry
    // point → runtime defaults to "main", which is correct for
    // kernels whose entry is "main" and wrong for kernels with
    // custom entries like "main_vec4" or "main_multicol".
    const entry_slice = pipeline_entry_point(pip);
    if (binding_result.count > 0) {
        if (use_static_pipeline_hash(rt, pip, spirv, entry_slice, bindings_slice, binding_result.flat_mask, binding_result.descriptor_hash) catch |err| {
            std.log.err("doe_vulkan_compute: set_compute_shader_spirv failed: {s}", .{@errorName(err)});
            return false;
        }) {
            return true;
        }
    }
    if (pip.vk_spirv_hash_ready) {
        if (binding_result.count > 0) {
            const layout_hash = pipeline_hash.compute_layout_hash(bindings_slice);
            const dynamic_pipeline_hash = pipeline_hash.compute_pipeline_hash_from_layout_hash(
                pip.vk_spirv_hash,
                entry_slice,
                layout_hash,
            );
            rt.set_compute_shader_spirv_with_hashes(
                spirv,
                dynamic_pipeline_hash,
                layout_hash,
                binding_result.descriptor_hash,
                entry_slice,
                bindings_slice,
                false,
            ) catch |err| {
                std.log.err("doe_vulkan_compute: set_compute_shader_spirv failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }
        rt.set_compute_shader_spirv_prehashed(spirv, pip.vk_spirv_hash, entry_slice, bindings, false) catch |err| {
            std.log.err("doe_vulkan_compute: set_compute_shader_spirv failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }
    rt.set_compute_shader_spirv(spirv, entry_slice, bindings, false) catch |err| {
        std.log.err("doe_vulkan_compute: set_compute_shader_spirv failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn pipeline_spirv_or_log(pip: *const DoeComputePipeline) ?[]const u32 {
    return pip.spirv_data orelse {
        std.log.err("doe_vulkan_compute: recorded dispatch missing SPIR-V data", .{});
        return null;
    };
}

pub fn vulkan_prepare_dispatch_bind_groups(
    rt: *NativeVulkanRuntime,
    pip: *const DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
) bool {
    if (comptime !has_vulkan) return false;
    const spirv = pipeline_spirv_or_log(pip) orelse return false;
    var binding_storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;
    const binding_result = collect_bind_group_bindings(pip, bind_groups, &binding_storage);
    return prepare_pipeline_bindings(rt, pip, spirv, binding_result, &binding_storage);
}

pub fn vulkan_collect_dispatch_binding_state(
    pip: *DoeComputePipeline,
    bind_groups: []const ?*DoeBindGroup,
) VulkanDispatchBindingState {
    if (loadPreparedBindingCache(pip, bind_groups)) |cached| return cached;
    var state = VulkanDispatchBindingState{};
    const binding_result = collect_bind_group_bindings(pip, bind_groups, &state.bindings);
    state.count = binding_result.count;
    state.flat_mask = binding_result.flat_mask;
    state.descriptor_hash = binding_result.descriptor_hash;
    storePreparedBindingCache(pip, bind_groups, &state);
    return state;
}

pub fn vulkan_prepare_dispatch_binding_state(
    rt: *NativeVulkanRuntime,
    pip: *const DoeComputePipeline,
    state: *const VulkanDispatchBindingState,
) bool {
    if (comptime !has_vulkan) return false;
    const spirv = pipeline_spirv_or_log(pip) orelse return false;
    const binding_result = BindingCollection{
        .count = state.count,
        .flat_mask = state.flat_mask,
        .descriptor_hash = state.descriptor_hash,
    };
    return prepare_pipeline_bindings(rt, pip, spirv, binding_result, state.bindings[0..state.count]);
}

/// Replay a recorded compute dispatch through NativeVulkanRuntime at queue-submit time.
pub fn vulkan_prepare_recorded_dispatch(rt: *NativeVulkanRuntime, dispatch: anytype) bool {
    if (comptime !has_vulkan) return false;
    const pip = cast(DoeComputePipeline, dispatch.compute_pipeline) orelse {
        std.log.err("doe_vulkan_compute: recorded dispatch missing compute pipeline", .{});
        return false;
    };
    const spirv = pipeline_spirv_or_log(pip) orelse return false;
    if (dispatch.vulkan_binding_state.valid) {
        const state = dispatch.vulkan_binding_state;
        const binding_result = BindingCollection{
            .count = state.count,
            .flat_mask = state.flat_mask,
            .descriptor_hash = state.descriptor_hash,
        };
        return prepare_pipeline_bindings(rt, pip, spirv, binding_result, state.bindings[0..state.count]);
    }
    var binding_storage: [MAX_KERNEL_BINDINGS]model_compute_types.KernelBinding = undefined;
    const binding_result = collect_recorded_bindings(
        pip,
        dispatch.bufs[0..dispatch.buf_count],
        dispatch.buf_offsets[0..dispatch.buf_count],
        dispatch.buf_sizes[0..dispatch.buf_count],
        &binding_storage,
    );
    return prepare_pipeline_bindings(rt, pip, spirv, binding_result, &binding_storage);
}

pub fn vulkan_run_prepared_dispatch(rt: *NativeVulkanRuntime, dispatch: anytype) void {
    if (comptime !has_vulkan) return;
    const repeat_count = if (dispatch.repeat_count == 0) 1 else dispatch.repeat_count;
    var repeat_index: u32 = 0;
    while (repeat_index < repeat_count) : (repeat_index += 1) {
        rt.record_prepared_dispatch_replay(dispatch.x, dispatch.y, dispatch.z) catch |err| {
            std.log.err("doe_vulkan_compute: recorded run_dispatch({},{},{}) failed: {s}", .{
                dispatch.x,
                dispatch.y,
                dispatch.z,
                @errorName(err),
            });
            return;
        };
    }
}

pub fn vulkan_submit_recorded_dispatch(rt: *NativeVulkanRuntime, dispatch: anytype) void {
    if (!vulkan_prepare_recorded_dispatch(rt, dispatch)) return;
    vulkan_run_prepared_dispatch(rt, dispatch);
}

/// Replay a recorded indirect compute dispatch through NativeVulkanRuntime at queue-submit time.
pub fn vulkan_run_prepared_dispatch_indirect(rt: *NativeVulkanRuntime, dispatch: anytype) void {
    if (comptime !has_vulkan) return;
    const indirect_buffer = resolve_indirect_buffer(rt, dispatch.indirect_buf, dispatch.offset) orelse return;
    _ = vk_dispatch_indirect.record_prepared_replay(
        rt,
        indirect_buffer.buffer,
        dispatch.offset,
        indirect_buffer.resource_handle,
    ) catch |err| {
        std.log.err("doe_vulkan_compute: recorded dispatch_indirect failed: {s}", .{@errorName(err)});
    };
}

pub fn vulkan_submit_recorded_dispatch_indirect(rt: *NativeVulkanRuntime, dispatch: anytype) void {
    if (!vulkan_prepare_recorded_dispatch(rt, dispatch)) return;
    vulkan_run_prepared_dispatch_indirect(rt, dispatch);
}

// ============================================================
// Indirect buffer helpers
// ============================================================

const ResolvedIndirectBuffer = struct {
    buffer: c.VkBuffer,
    resource_handle: u64,
};

fn resolve_indirect_buffer(
    rt: *NativeVulkanRuntime,
    buf_raw: ?*anyopaque,
    offset: u64,
) ?ResolvedIndirectBuffer {
    if (comptime !has_vulkan) return null;
    const buf = cast(DoeBuffer, buf_raw) orelse return null;
    if (buf.error_object or buf.vk_id == 0) return null;
    if ((offset % DISPATCH_INDIRECT_ARGS_ALIGNMENT) != 0) return null;
    const cb = rt.compute_buffers.get(buf.vk_id) orelse return null;
    const end = std.math.add(u64, offset, DISPATCH_INDIRECT_ARGS_BYTES) catch return null;
    if (end > cb.size) return null;
    return .{
        .buffer = cb.buffer,
        .resource_handle = buf.vk_id,
    };
}

fn moveTranslationInfoToShader(
    shader: *DoeShaderModule,
    info: *runtime_compile.TranslationInfo,
) void {
    shader.needs_sizes_buf = info.needs_sizes_buf;
    shader.dispatch_preconditions = info.dispatch_preconditions;
    shader.texture_dispatch_preconditions = info.texture_dispatch_preconditions;
    shader.wg_x = info.workgroup_size[0];
    shader.wg_y = info.workgroup_size[1];
    shader.wg_z = info.workgroup_size[2];
    info.dispatch_preconditions = &.{};
    info.texture_dispatch_preconditions = &.{};
}

fn assignSpirvWords(
    shader: *DoeShaderModule,
    spirv_bytes: []const u8,
) error{ OutOfMemory, ShaderCompileFailed }!void {
    if (spirv_bytes.len == 0 or (spirv_bytes.len % 4) != 0) {
        return error.ShaderCompileFailed;
    }
    const word_count = spirv_bytes.len / 4;
    const words = alloc.alloc(u32, word_count) catch return error.OutOfMemory;
    errdefer alloc.free(words);
    for (words, 0..) |*word, index| {
        const offset = index * 4;
        const chunk: *const [4]u8 = @ptrCast(spirv_bytes[offset .. offset + 4].ptr);
        word.* = std.mem.readInt(u32, chunk, .little);
    }
    shader.spirv_data = words;
}
