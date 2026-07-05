// Compute pipeline, shader module, and descriptor set management.
//
// Handles SPIR-V loading, WGSL-to-SPIR-V compilation, pipeline/layout
// creation, descriptor set allocation, and binding.

const std = @import("std");
const c = @import("vk_constants.zig");
const vk_device = @import("vk_device.zig");
const vk_formats = @import("vk_formats.zig");
const vk_pipeline_cache = @import("vk_pipeline_cache.zig");
const vk_pipeline_cache_persistent = @import("vk_pipeline_cache_persistent.zig");
const vk_compute_sync = @import("vk_compute_sync.zig");
const vk_upload = @import("vk_upload.zig");
const vk_resources = @import("vk_resources.zig");
const vk_spirv_inspect = @import("vk_spirv_inspect.zig");
const model_compute_types = @import("../../model_compute_types.zig");
const model_texture_types = @import("../../model_texture_value_types.zig");
const model_binding_types = @import("../../model_binding_value_types.zig");
const hash_contract = @import("../../doe_vulkan_pipeline_hash.zig");
const doe_wgsl = @import("../../doe_wgsl/mod.zig");
const common_errors = @import("../common/errors.zig");
const path_utils = @import("../common/path_utils.zig");

const VkBuffer = c.VkBuffer;
const VkDeviceMemory = c.VkDeviceMemory;
const VK_NULL_U64 = c.VK_NULL_U64;

const MAX_KERNEL_SOURCE_BYTES: usize = 2 * 1024 * 1024;
const SPIRV_MAGIC: u32 = 0x07230203;
const DEFAULT_KERNEL_ROOT = "bench/kernels";

// SPIR-V opcode/decoration constants for binding detection.
const SPIRV_OP_DECORATE: u16 = 71;
const SPIRV_DECORATION_BINDING: u32 = 33;
const SPIRV_OP_ENTRY_POINT: u16 = 15;
const WORKGROUP_MEMORY_SUBGROUP_HINT_LOCAL_SIZE_X_MIN: u32 = 256;

pub const compute_layout_hash = hash_contract.compute_layout_hash;
pub const compute_descriptor_bindings_hash = hash_contract.compute_descriptor_bindings_hash;
pub const compute_pipeline_hash = hash_contract.compute_pipeline_hash;
pub const compute_spirv_words_hash = hash_contract.compute_spirv_words_hash;
pub const compute_pipeline_hash_from_spirv_hash = hash_contract.compute_pipeline_hash_from_spirv_hash;
pub const compute_pipeline_hash_from_layout_hash = hash_contract.compute_pipeline_hash_from_layout_hash;

/// Scan SPIR-V words for any OpDecorate ... Binding instructions.
/// Returns true if the shader declares at least one descriptor binding.
fn spirv_has_descriptor_bindings(words: []const u32) bool {
    if (words.len < 5) return false;
    var i: usize = 5; // skip SPIR-V header (5 words)
    while (i < words.len) {
        const word = words[i];
        const opcode: u16 = @truncate(word & 0xFFFF);
        const word_count: u16 = @truncate((word >> 16) & 0xFFFF);
        if (word_count == 0) break;
        if (opcode == SPIRV_OP_DECORATE and word_count >= 4 and i + 2 < words.len) {
            if (words[i + 2] == SPIRV_DECORATION_BINDING) return true;
        }
        i += word_count;
    }
    return false;
}

/// Scan SPIR-V for an OpEntryPoint instruction whose name matches `name`.
/// OpEntryPoint layout: opcode|wordcount, ExecutionModel, EntryPoint <id>, Name (literal string), Interfaces...
/// The Name is a null-terminated, packed-word string.
fn spirv_has_entry_point(words: []const u32, name: []const u8) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const opcode: u16 = @truncate(word & 0xFFFF);
        const word_count: u16 = @truncate((word >> 16) & 0xFFFF);
        if (word_count == 0) break;
        if (opcode == SPIRV_OP_ENTRY_POINT and word_count >= 4 and i + word_count <= words.len) {
            // Name starts at offset 3 within the instruction (after opcode word, ExecutionModel, EntryPoint id).
            const name_words = words[i + 3 .. i + word_count];
            if (entry_name_matches(name_words, name)) return true;
        }
        i += word_count;
    }
    return false;
}

/// Compare a packed-word SPIR-V literal string against a Zig string slice.
/// Stops at the first NUL byte in the packed words.
fn entry_name_matches(name_words: []const u32, target: []const u8) bool {
    var byte_index: usize = 0;
    for (name_words) |w| {
        var shift: u5 = 0;
        while (shift <= 24) {
            const byte: u8 = @truncate((w >> shift) & 0xFF);
            if (byte == 0) {
                return byte_index == target.len;
            }
            if (byte_index >= target.len) return false;
            if (target[byte_index] != byte) return false;
            byte_index += 1;
            if (shift == 24) break;
            shift += 8;
        }
    }
    return false;
}
const MAIN_ENTRY: [*:0]const u8 = "main";

pub const DescriptorInfoKind = enum {
    buffer,
    image,
};

pub const PendingDescriptorWrite = struct {
    set_index: u32,
    binding: u32,
    descriptor_type: u32,
    kind: DescriptorInfoKind,
    info_index: usize,
};

pub const RetiredPipelineState = struct {
    pipeline: c.VkPipeline = VK_NULL_U64,
    shader_module: c.VkShaderModule = VK_NULL_U64,
    entry_point_owned: ?[:0]u8 = null,
};

pub const RetiredDescriptorState = struct {
    descriptor_pool: c.VkDescriptorPool = VK_NULL_U64,
    descriptor_set_layouts: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSetLayout = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
    pipeline_layout: c.VkPipelineLayout = VK_NULL_U64,
};

pub const CachedDescriptorState = vk_pipeline_cache.CachedDescriptorState;
pub const CachedComputeState = vk_pipeline_cache.CachedComputeState;
pub const HOT_COMPUTE_STATE_CACHE_CAPACITY = vk_pipeline_cache.HOT_COMPUTE_STATE_CACHE_CAPACITY;
pub const HOT_DESCRIPTOR_STATE_CACHE_CAPACITY = vk_pipeline_cache.HOT_DESCRIPTOR_STATE_CACHE_CAPACITY;

const activate_cached_compute_state = vk_pipeline_cache.activate_cached_compute_state;
const activate_cached_descriptor_state = vk_pipeline_cache.activate_cached_descriptor_state;
const has_active_compute_state = vk_pipeline_cache.has_active_compute_state;
pub const release_cached_compute_states = vk_pipeline_cache.release_cached_compute_states;
pub const release_descriptor_state_cache = vk_pipeline_cache.release_descriptor_state_cache;
const stash_active_compute_state = vk_pipeline_cache.stash_active_compute_state;
const stash_active_descriptor_state = vk_pipeline_cache.stash_active_descriptor_state;

fn submitted_work_may_reference_compute_state(self: anytype) bool {
    return self.recorded_submit_replay_active or
        self.replay_recording_active or
        self.has_deferred_submissions;
}

fn release_or_retire_pipeline_objects(self: anytype) void {
    if (submitted_work_may_reference_compute_state(self)) {
        retire_pipeline_objects(self);
        return;
    }
    destroy_pipeline_objects(self);
}

fn release_or_retire_descriptor_state(self: anytype) void {
    if (submitted_work_may_reference_compute_state(self)) {
        retire_descriptor_state(self);
        return;
    }
    destroy_descriptor_state(self);
}

fn retire_pipeline_objects(self: anytype) void {
    if (!self.has_pipeline and !self.has_shader_module and self.current_entry_point_owned == null) {
        self.current_pipeline_hash = 0;
        return;
    }
    self.retired_pipeline_states.append(self.allocator, .{
        .pipeline = self.pipeline,
        .shader_module = self.shader_module,
        .entry_point_owned = self.current_entry_point_owned,
    }) catch std.debug.panic("vk_pipeline: OOM retiring pipeline state", .{});
    self.has_pipeline = false;
    self.pipeline = VK_NULL_U64;
    self.has_shader_module = false;
    self.shader_module = VK_NULL_U64;
    self.current_entry_point_owned = null;
    self.current_pipeline_hash = 0;
}

fn retire_descriptor_state(self: anytype) void {
    if (!self.has_descriptor_pool and !self.has_pipeline_layout) {
        release_descriptor_state_cache(self);
        self.current_layout_hash = 0;
        self.descriptor_set_count = 0;
        self.current_descriptor_bindings_hash = 0;
        self.has_current_descriptor_bindings_hash = false;
        return;
    }
    release_descriptor_state_cache(self);
    self.retired_descriptor_states.append(self.allocator, .{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_layouts = self.descriptor_set_layouts,
        .pipeline_layout = self.pipeline_layout,
    }) catch std.debug.panic("vk_pipeline: OOM retiring descriptor state", .{});
    self.has_descriptor_pool = false;
    self.descriptor_pool = VK_NULL_U64;
    self.descriptor_sets = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
    self.descriptor_set_layouts = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
    self.descriptor_set_count = 0;
    self.has_pipeline_layout = false;
    self.pipeline_layout = VK_NULL_U64;
    self.current_layout_hash = 0;
    self.current_descriptor_bindings_hash = 0;
    self.has_current_descriptor_bindings_hash = false;
}

fn retire_descriptor_pool_only(self: anytype) void {
    if (!self.has_descriptor_pool) {
        release_descriptor_state_cache(self);
        self.descriptor_sets = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
        self.current_descriptor_bindings_hash = 0;
        self.has_current_descriptor_bindings_hash = false;
        return;
    }
    release_descriptor_state_cache(self);
    self.retired_descriptor_states.append(self.allocator, .{
        .descriptor_pool = self.descriptor_pool,
        .descriptor_set_layouts = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
        .pipeline_layout = VK_NULL_U64,
    }) catch std.debug.panic("vk_pipeline: OOM retiring descriptor pool", .{});
    self.has_descriptor_pool = false;
    self.descriptor_pool = VK_NULL_U64;
    self.descriptor_sets = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS;
    self.current_descriptor_bindings_hash = 0;
    self.has_current_descriptor_bindings_hash = false;
}

pub fn release_retired_states(self: anytype) void {
    for (self.retired_pipeline_states.items) |retired| {
        if (retired.pipeline != VK_NULL_U64) c.vkDestroyPipeline(self.device, retired.pipeline, null);
        if (retired.shader_module != VK_NULL_U64) c.vkDestroyShaderModule(self.device, retired.shader_module, null);
        if (retired.entry_point_owned) |entry_name| self.allocator.free(entry_name);
    }
    self.retired_pipeline_states.clearRetainingCapacity();
    for (self.retired_descriptor_states.items) |retired| {
        if (retired.descriptor_pool != VK_NULL_U64) c.vkDestroyDescriptorPool(self.device, retired.descriptor_pool, null);
        for (retired.descriptor_set_layouts) |layout| {
            if (layout != VK_NULL_U64) c.vkDestroyDescriptorSetLayout(self.device, layout, null);
        }
        if (retired.pipeline_layout != VK_NULL_U64) c.vkDestroyPipelineLayout(self.device, retired.pipeline_layout, null);
    }
    self.retired_descriptor_states.clearRetainingCapacity();
}

pub fn load_kernel_source(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    const path = try resolve_kernel_path(self, allocator, kernel_name);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, MAX_KERNEL_SOURCE_BYTES) catch error.ShaderCompileFailed;
}

pub fn load_kernel_spirv(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
    return try load_kernel_spirv_uncached(self, allocator, kernel_name);
}

pub fn ensure_kernel_spirv_cached(self: anytype, kernel_name: []const u8) ![]const u32 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    if (self.kernel_spirv_cache.get(kernel_name)) |cached| return cached;
    const words = try load_kernel_spirv_uncached(self, self.allocator, kernel_name);
    const owned_kernel_name = try self.allocator.dupe(u8, kernel_name);
    errdefer self.allocator.free(owned_kernel_name);
    try self.kernel_spirv_cache.put(self.allocator, owned_kernel_name, words);
    return words;
}

pub fn release_kernel_spirv_cache(self: anytype) void {
    var it = self.kernel_spirv_cache.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.kernel_spirv_cache.deinit(self.allocator);
}

fn load_kernel_spirv_uncached(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
    if (kernel_name.len == 0) return error.InvalidArgument;
    const path = resolve_kernel_spirv_path(self, allocator, kernel_name) catch |err| switch (err) {
        error.UnsupportedFeature => return try compile_kernel_wgsl_to_spirv(self, allocator, kernel_name),
        else => return err,
    };
    defer allocator.free(path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    defer allocator.free(bytes);
    return try words_from_spirv_bytes(allocator, bytes);
}

pub fn load_kernel_spirv_cached(self: anytype, kernel_name: []const u8) ![]const u32 {
    return ensure_kernel_spirv_cached(self, kernel_name);
}

fn compile_kernel_wgsl_to_spirv(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
    const source_path = try resolve_kernel_path(self, allocator, kernel_name);
    defer allocator.free(source_path);
    if (!std.mem.endsWith(u8, source_path, ".wgsl")) return error.UnsupportedFeature;

    const wgsl = std.fs.cwd().readFileAlloc(allocator, source_path, MAX_KERNEL_SOURCE_BYTES) catch return error.ShaderCompileFailed;
    defer allocator.free(wgsl);

    var spirv_buf = try allocator.alloc(u8, doe_wgsl.MAX_SPIRV_OUTPUT);
    defer allocator.free(spirv_buf);
    const spirv_len = doe_wgsl.translateToSpirv(allocator, wgsl, spirv_buf) catch return error.ShaderCompileFailed;
    return try words_from_spirv_bytes(allocator, spirv_buf[0..spirv_len]);
}
pub fn set_compute_shader_spirv(
    self: anytype,
    words: []const u32,
    entry_point: ?[]const u8,
    bindings: ?[]const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
) !void {
    if (words.len == 0 or words[0] != SPIRV_MAGIC) return error.ShaderCompileFailed;
    const layout_hash = compute_layout_hash(bindings);
    const pipeline_hash = compute_pipeline_hash_from_layout_hash(compute_spirv_words_hash(words), entry_point, layout_hash);
    try set_compute_shader_spirv_with_hashes(self, words, pipeline_hash, layout_hash, null, entry_point, bindings, initialize_buffers_on_create);
}
pub fn set_compute_shader_spirv_prehashed(
    self: anytype,
    words: []const u32,
    spirv_hash: u64,
    entry_point: ?[]const u8,
    bindings: ?[]const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
) !void {
    if (words.len == 0 or words[0] != SPIRV_MAGIC) return error.ShaderCompileFailed;
    const layout_hash = compute_layout_hash(bindings);
    const pipeline_hash = compute_pipeline_hash_from_layout_hash(spirv_hash, entry_point, layout_hash);
    try set_compute_shader_spirv_with_hashes(self, words, pipeline_hash, layout_hash, null, entry_point, bindings, initialize_buffers_on_create);
}
pub fn set_compute_shader_spirv_with_hashes(
    self: anytype,
    words: []const u32,
    pipeline_hash: u64,
    layout_hash: u64,
    descriptor_bindings_hash: ?u64,
    entry_point: ?[]const u8,
    bindings: ?[]const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
) !void {
    if (!self.has_pipeline or pipeline_hash != self.current_pipeline_hash) {
        const previous_pipeline_hash = self.current_pipeline_hash;
        const had_active_state = has_active_compute_state(self);
        if (had_active_state) {
            try stash_active_compute_state(self);
        }
        errdefer if (had_active_state and self.current_pipeline_hash == 0) {
            _ = activate_cached_compute_state(self, previous_pipeline_hash);
        };
        if (!activate_cached_compute_state(self, pipeline_hash)) {
            try build_pipeline_for_words(self, words, pipeline_hash, layout_hash, entry_point, bindings);
        }
    }
    try prepare_descriptor_sets(self, bindings, initialize_buffers_on_create, descriptor_bindings_hash);
    vk_compute_sync.capture_current_compute_bindings(self, bindings);
}
pub fn rebuild_compute_shader_spirv(self: anytype, words: []const u32) !void {
    if (words.len == 0 or words[0] != SPIRV_MAGIC) return error.ShaderCompileFailed;
    const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words));
    try build_pipeline_for_words(self, words, hash +% 1, compute_layout_hash(null), null, null);
}

pub fn build_pipeline_for_words(
    self: anytype,
    words: []const u32,
    pipeline_hash: u64,
    layout_hash: u64,
    entry_point: ?[]const u8,
    bindings: ?[]const model_compute_types.KernelBinding,
) !void {
    if (!self.recorded_submit_replay_active and (self.has_deferred_submissions or self.pending_uploads.items.len > 0)) {
        _ = try vk_upload.flush_queue(self);
    }
    // Guard: if no bindings were provided but SPIR-V declares descriptor bindings,
    // refuse to create the pipeline rather than letting the driver crash (RADV segfaults
    // when pipeline layout is empty but shader references descriptors).
    if (bindings == null and spirv_has_descriptor_bindings(words)) {
        return error.InvalidArgument;
    }
    try ensure_pipeline_layout_with_hash(self, bindings, layout_hash);
    release_or_retire_pipeline_objects(self);
    errdefer destroy_pipeline_objects(self);

    const entry_name = entry_point orelse "main";
    // Defensive: RADV (and likely other drivers) segfault inside vkCreateComputePipelines
    // when the pName references an OpEntryPoint that doesn't exist in the module.
    // Doe must reject this at the boundary rather than crashing inside the driver.
    if (!spirv_has_entry_point(words, entry_name)) {
        return error.InvalidArgument;
    }
    const owned_entry = try self.allocator.dupeZ(u8, entry_name);
    errdefer self.allocator.free(owned_entry);

    var shader_info = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0, .codeSize = words.len * @sizeOf(u32), .pCode = words.ptr };
    try c.check_vk(c.vkCreateShaderModule(self.device, &shader_info, null, &self.shader_module));
    self.has_shader_module = true;

    // Persist SPIR-V bytes for the next shader artifact manifest emission so
    // `shader_artifact_gate.py --require-spirv-validation` can run spirv-val
    // against the real binary. The backend pulls these bytes at manifest
    // emit time, writes a sibling .spv file, records its path in the
    // ir_to_spirv stage record, then frees the allocation.
    if (self.pending_spirv_bytes_owned) |stale| self.allocator.free(stale);
    self.pending_spirv_bytes_owned = self.allocator.dupe(u8, std.mem.sliceAsBytes(words)) catch null;

    var required_subgroup_size_info = c.VkPipelineShaderStageRequiredSubgroupSizeCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO,
        .pNext = null,
        .requiredSubgroupSize = 0,
    };
    const stage_pnext: ?*const anyopaque = if (required_subgroup_size_for_pipeline(self, words)) |required_size| blk: {
        required_subgroup_size_info.requiredSubgroupSize = required_size;
        break :blk @ptrCast(&required_subgroup_size_info);
    } else null;
    const stage_info = c.VkPipelineShaderStageCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = stage_pnext, .flags = 0, .stage = c.VK_SHADER_STAGE_COMPUTE_BIT, .module = self.shader_module, .pName = owned_entry.ptr, .pSpecializationInfo = null };
    var pipeline_info = c.VkComputePipelineCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .pNext = null, .flags = 0, .stage = stage_info, .layout = self.pipeline_layout, .basePipelineHandle = VK_NULL_U64, .basePipelineIndex = -1 };
    const compute_cache_handle = vk_pipeline_cache_persistent.handle_for_pipeline_creation();
    try c.check_vk(c.vkCreateComputePipelines(self.device, compute_cache_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&self.pipeline)));
    self.has_pipeline = true;
    self.current_entry_point_owned = owned_entry;
    self.current_pipeline_hash = pipeline_hash;
}

fn required_subgroup_size_for_pipeline(self: anytype, words: []const u32) ?u32 {
    if (!self.has_subgroup_size_control_ext) return null;
    if (std.posix.getenv("DOE_VULKAN_REQUIRED_SUBGROUP_SIZE")) |value| {
        if (value.len == 0) return null;
        const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return null;
        if (parsed == 0) return null;
        return parsed;
    }
    if (self.required_compute_subgroup_size == 0) return null;
    switch (self.vulkan_subgroup_size_policy) {
        .fixed_32_when_supported => {},
        .suppress_for_workgroup_memory_256 => {
            if ((vk_spirv_inspect.compute_local_size_x(words) orelse 0) >= WORKGROUP_MEMORY_SUBGROUP_HINT_LOCAL_SIZE_X_MIN and
                vk_spirv_inspect.has_workgroup_storage(words))
            {
                return null;
            }
        },
        .suppress_for_workgroup_memory_256_or_single_invocation => {
            const local_size = vk_spirv_inspect.compute_local_size(words);
            if (is_single_invocation_workgroup(local_size)) return null;
            if ((if (local_size) |size| size.x else 0) >= WORKGROUP_MEMORY_SUBGROUP_HINT_LOCAL_SIZE_X_MIN and
                vk_spirv_inspect.has_workgroup_storage(words))
            {
                return null;
            }
        },
    }
    return self.required_compute_subgroup_size;
}

fn is_single_invocation_workgroup(local_size: ?vk_spirv_inspect.LocalSize) bool {
    const size = local_size orelse return false;
    return size.x == 1 and size.y == 1 and size.z == 1;
}

pub fn destroy_pipeline_objects(self: anytype) void {
    if (self.has_pipeline) {
        c.vkDestroyPipeline(self.device, self.pipeline, null);
        self.has_pipeline = false;
        self.pipeline = VK_NULL_U64;
    }
    if (self.has_shader_module) {
        c.vkDestroyShaderModule(self.device, self.shader_module, null);
        self.has_shader_module = false;
        self.shader_module = VK_NULL_U64;
    }
    if (self.current_entry_point_owned) |entry_name| {
        self.allocator.free(entry_name);
        self.current_entry_point_owned = null;
    }
    self.current_pipeline_hash = 0;
}

pub fn destroy_descriptor_state(self: anytype) void {
    release_descriptor_state_cache(self);
    if (self.has_descriptor_pool) {
        c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.has_descriptor_pool = false;
        self.descriptor_pool = VK_NULL_U64;
    }
    var set_index: usize = 0;
    while (set_index < c.MAX_DESCRIPTOR_SETS) : (set_index += 1) {
        if (self.descriptor_set_layouts[set_index] != VK_NULL_U64) {
            c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layouts[set_index], null);
            self.descriptor_set_layouts[set_index] = VK_NULL_U64;
        }
        self.descriptor_sets[set_index] = VK_NULL_U64;
    }
    self.descriptor_set_count = 0;
    if (self.has_pipeline_layout) {
        c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.has_pipeline_layout = false;
        self.pipeline_layout = VK_NULL_U64;
    }
    self.current_layout_hash = 0;
}

pub fn bind_descriptor_sets(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (!self.has_descriptor_pool or self.descriptor_set_count == 0) return;
    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        self.pipeline_layout,
        0,
        self.descriptor_set_count,
        self.descriptor_sets[0..@intCast(self.descriptor_set_count)].ptr,
        0,
        null,
    );
}

pub fn reset_bound_compute_state(self: anytype) void {
    self.bound_compute_pipeline = VK_NULL_U64;
    self.bound_compute_pipeline_layout = VK_NULL_U64;
    self.bound_descriptor_bindings_hash = 0;
    self.has_bound_descriptor_bindings_hash = false;
}

pub fn bind_compute_pipeline_if_needed(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (self.bound_compute_pipeline == self.pipeline) return;
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    self.bound_compute_pipeline = self.pipeline;
}

pub fn bind_descriptor_sets_if_needed(self: anytype, command_buffer: c.VkCommandBuffer) void {
    if (!self.has_descriptor_pool or self.descriptor_set_count == 0) return;
    if (self.has_bound_descriptor_bindings_hash and
        self.bound_compute_pipeline_layout == self.pipeline_layout and
        self.bound_descriptor_bindings_hash == self.current_descriptor_bindings_hash)
    {
        return;
    }
    bind_descriptor_sets(self, command_buffer);
    self.bound_compute_pipeline_layout = self.pipeline_layout;
    self.bound_descriptor_bindings_hash = self.current_descriptor_bindings_hash;
    self.has_bound_descriptor_bindings_hash = self.has_current_descriptor_bindings_hash;
}

fn ensure_pipeline_layout_with_hash(
    self: anytype,
    bindings: ?[]const model_compute_types.KernelBinding,
    layout_hash: u64,
) !void {
    if (self.has_pipeline_layout and layout_hash == self.current_layout_hash) return;

    release_or_retire_descriptor_state(self);
    errdefer destroy_descriptor_state(self);

    var set_count: u32 = 0;
    if (bindings) |bs| {
        for (bs) |binding| {
            if (binding.group >= c.MAX_DESCRIPTOR_SETS_U32) return error.UnsupportedFeature;
            set_count = @max(set_count, binding.group + 1);
        }
    }

    const set_count_usize: usize = @intCast(set_count);
    var per_set_bindings = try self.allocator.alloc(std.ArrayListUnmanaged(c.VkDescriptorSetLayoutBinding), set_count_usize);
    defer {
        for (per_set_bindings) |*list| list.deinit(self.allocator);
        self.allocator.free(per_set_bindings);
    }
    for (per_set_bindings) |*list| list.* = .{};

    if (bindings) |bs| {
        for (bs) |binding| {
            try per_set_bindings[@intCast(binding.group)].append(self.allocator, .{
                .binding = binding.binding,
                .descriptorType = try descriptor_type_for_binding(binding),
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            });
        }
    }

    self.descriptor_set_count = set_count;
    var set_index: usize = 0;
    while (set_index < set_count_usize) : (set_index += 1) {
        const set_bindings = per_set_bindings[set_index].items;
        var layout_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = @intCast(set_bindings.len),
            .pBindings = if (set_bindings.len > 0) set_bindings.ptr else null,
        };
        try c.check_vk(c.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_set_layouts[set_index]));
    }

    var layout_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = self.descriptor_set_count,
        .pSetLayouts = if (self.descriptor_set_count > 0) @ptrCast(self.descriptor_set_layouts[0..@intCast(self.descriptor_set_count)].ptr) else null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    try c.check_vk(c.vkCreatePipelineLayout(self.device, &layout_info, null, &self.pipeline_layout));
    self.has_pipeline_layout = true;
    self.current_layout_hash = layout_hash;
}

fn prepare_descriptor_sets(
    self: anytype,
    bindings: ?[]const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
    precomputed_descriptor_bindings_hash: ?u64,
) !void {
    if (self.descriptor_set_count == 0) return;
    const bs = bindings orelse return error.InvalidArgument;
    const descriptor_bindings_hash = precomputed_descriptor_bindings_hash orelse compute_descriptor_bindings_hash(bs);
    if (self.has_descriptor_pool and self.has_current_descriptor_bindings_hash and descriptor_bindings_hash == self.current_descriptor_bindings_hash) {
        return;
    }
    if (self.has_descriptor_pool and self.has_current_descriptor_bindings_hash) {
        try stash_active_descriptor_state(self);
        if (activate_cached_descriptor_state(self, descriptor_bindings_hash)) {
            return;
        }
    }
    if (!self.recorded_submit_replay_active and (self.has_deferred_submissions or self.pending_uploads.items.len > 0)) {
        _ = try vk_upload.flush_queue(self);
    }
    try ensure_descriptor_pool(self, bindings);
    var buffer_infos = std.ArrayListUnmanaged(c.VkDescriptorBufferInfo){};
    defer buffer_infos.deinit(self.allocator);
    var image_infos = std.ArrayListUnmanaged(c.VkDescriptorImageInfo){};
    defer image_infos.deinit(self.allocator);
    var retired_promoted_buffers = std.ArrayListUnmanaged(vk_resources.ComputeBuffer){};
    defer {
        for (retired_promoted_buffers.items) |buffer| {
            vk_resources.release_compute_buffer(self, buffer);
        }
        retired_promoted_buffers.deinit(self.allocator);
    }
    var pending_writes = std.ArrayListUnmanaged(PendingDescriptorWrite){};
    defer pending_writes.deinit(self.allocator);
    var writes = std.ArrayListUnmanaged(c.VkWriteDescriptorSet){};
    defer writes.deinit(self.allocator);

    for (bs) |binding| {
        const descriptor_type = try descriptor_type_for_binding(binding);
        switch (binding.resource_kind) {
            .buffer => {
                const promotion = try vk_resources.ensure_compute_buffer_for_binding(
                    self,
                    binding,
                    initialize_buffers_on_create,
                );
                if (promotion.retired_source) |retired_source| {
                    try retired_promoted_buffers.append(self.allocator, retired_source);
                }
                const compute_buffer = promotion.buffer;
                try buffer_infos.append(self.allocator, .{
                    .buffer = compute_buffer.buffer,
                    .offset = binding.buffer_offset,
                    .range = try descriptor_range(binding, compute_buffer.size),
                });
                try pending_writes.append(self.allocator, .{
                    .set_index = binding.group,
                    .binding = binding.binding,
                    .descriptor_type = descriptor_type,
                    .kind = .buffer,
                    .info_index = buffer_infos.items.len - 1,
                });
            },
            .texture, .storage_texture => {
                const texture = self.textures.getPtr(binding.resource_handle) orelse return error.InvalidState;
                try validate_texture_binding(binding, texture.*);
                try vk_resources.ensure_texture_shader_layout(self, texture);
                try image_infos.append(self.allocator, .{
                    .sampler = 0,
                    .imageView = texture.view,
                    .imageLayout = texture.layout,
                });
                try pending_writes.append(self.allocator, .{
                    .set_index = binding.group,
                    .binding = binding.binding,
                    .descriptor_type = descriptor_type,
                    .kind = .image,
                    .info_index = image_infos.items.len - 1,
                });
            },
            .sampler => {
                const vk_sampler = self.samplers.get(binding.resource_handle) orelse return error.InvalidState;
                try image_infos.append(self.allocator, .{
                    .sampler = vk_sampler,
                    .imageView = VK_NULL_U64,
                    .imageLayout = 0,
                });
                try pending_writes.append(self.allocator, .{
                    .set_index = binding.group,
                    .binding = binding.binding,
                    .descriptor_type = descriptor_type,
                    .kind = .image,
                    .info_index = image_infos.items.len - 1,
                });
            },
        }
    }

    for (pending_writes.items) |pending| {
        try writes.append(self.allocator, .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_sets[@intCast(pending.set_index)],
            .dstBinding = pending.binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = pending.descriptor_type,
            .pImageInfo = if (pending.kind == .image) @ptrCast(&image_infos.items[pending.info_index]) else null,
            .pBufferInfo = if (pending.kind == .buffer) @ptrCast(&buffer_infos.items[pending.info_index]) else null,
            .pTexelBufferView = null,
        });
    }

    if (writes.items.len > 0) {
        c.vkUpdateDescriptorSets(self.device, @intCast(writes.items.len), writes.items.ptr, 0, null);
    }
    self.current_descriptor_bindings_hash = descriptor_bindings_hash;
    self.has_current_descriptor_bindings_hash = true;
}

fn ensure_descriptor_pool(self: anytype, bindings: ?[]const model_compute_types.KernelBinding) !void {
    if (self.has_descriptor_pool) return;
    if (self.descriptor_set_count == 0) return;

    var uniform_count: u32 = 0;
    var storage_count: u32 = 0;
    var sampled_image_count: u32 = 0;
    var storage_image_count: u32 = 0;
    var sampler_count: u32 = 0;
    if (bindings) |bs| {
        for (bs) |binding| {
            switch (try descriptor_type_for_binding(binding)) {
                c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER => uniform_count += 1,
                c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER => storage_count += 1,
                c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE => sampled_image_count += 1,
                c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE => storage_image_count += 1,
                c.VK_DESCRIPTOR_TYPE_SAMPLER => sampler_count += 1,
                else => return error.UnsupportedFeature,
            }
        }
    }

    var pool_sizes: [5]c.VkDescriptorPoolSize = undefined;
    var pool_size_count: usize = 0;
    if (uniform_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = uniform_count };
        pool_size_count += 1;
    }
    if (storage_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = storage_count };
        pool_size_count += 1;
    }
    if (sampled_image_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = sampled_image_count };
        pool_size_count += 1;
    }
    if (storage_image_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = storage_image_count };
        pool_size_count += 1;
    }
    if (sampler_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = sampler_count };
        pool_size_count += 1;
    }

    var pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = self.descriptor_set_count,
        .poolSizeCount = @intCast(pool_size_count),
        .pPoolSizes = if (pool_size_count > 0) pool_sizes[0..pool_size_count].ptr else null,
    };
    try c.check_vk(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool));
    errdefer {
        c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.descriptor_pool = VK_NULL_U64;
    }

    var alloc_info = c.VkDescriptorSetAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = self.descriptor_set_count,
        .pSetLayouts = self.descriptor_set_layouts[0..@intCast(self.descriptor_set_count)].ptr,
    };
    try c.check_vk(c.vkAllocateDescriptorSets(self.device, &alloc_info, self.descriptor_sets[0..@intCast(self.descriptor_set_count)].ptr));
    self.has_descriptor_pool = true;
}

// --- Pure helpers ---

pub fn descriptor_type_for_binding(binding: model_compute_types.KernelBinding) !u32 {
    return switch (binding.resource_kind) {
        .buffer => switch (binding.buffer_type) {
            model_binding_types.WGPUBufferBindingType_Uniform => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            model_binding_types.WGPUBufferBindingType_Storage,
            model_binding_types.WGPUBufferBindingType_ReadOnlyStorage,
            => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            else => error.UnsupportedFeature,
        },
        .texture => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .storage_texture => c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
    };
}

pub fn validate_texture_binding(binding: model_compute_types.KernelBinding, texture: vk_resources.TextureResource) !void {
    if (binding.texture_view_dimension != model_texture_types.WGPUTextureViewDimension_Undefined and
        binding.texture_view_dimension != texture.view_dimension) return error.InvalidState;
    if (binding.texture_multisampled != (texture.sample_count > 1)) return error.InvalidState;
    try validate_texture_binding_aspect(binding.texture_aspect, texture);
    if (binding.texture_format != model_texture_types.WGPUTextureFormat_Undefined and
        binding.texture_format != texture.format) return error.InvalidState;

    switch (binding.resource_kind) {
        .buffer, .sampler => return error.InvalidArgument,
        .texture => {
            if ((texture.usage & model_texture_types.WGPUTextureUsage_TextureBinding) == 0) return error.InvalidState;
            switch (binding.texture_sample_type) {
                model_binding_types.WGPUTextureSampleType_Undefined,
                model_binding_types.WGPUTextureSampleType_Float,
                model_binding_types.WGPUTextureSampleType_UnfilterableFloat,
                model_binding_types.WGPUTextureSampleType_Depth,
                model_binding_types.WGPUTextureSampleType_Sint,
                model_binding_types.WGPUTextureSampleType_Uint,
                => {},
                else => return error.UnsupportedFeature,
            }
        },
        .storage_texture => {
            if ((texture.usage & model_texture_types.WGPUTextureUsage_StorageBinding) == 0) return error.InvalidState;
            switch (binding.storage_texture_access) {
                model_binding_types.WGPUStorageTextureAccess_Undefined,
                model_binding_types.WGPUStorageTextureAccess_WriteOnly,
                model_binding_types.WGPUStorageTextureAccess_ReadOnly,
                model_binding_types.WGPUStorageTextureAccess_ReadWrite,
                => {},
                else => return error.UnsupportedFeature,
            }
        },
    }
}

fn validate_texture_binding_aspect(binding_aspect: u32, texture: vk_resources.TextureResource) !void {
    if (binding_aspect == model_texture_types.WGPUTextureAspect_Undefined or
        binding_aspect == model_texture_types.WGPUTextureAspect_All) return;

    const full_mask = vk_formats.aspect_mask_for_format(texture.format);
    const requested_mask = switch (binding_aspect) {
        model_texture_types.WGPUTextureAspect_DepthOnly => vk_formats.VK_IMAGE_ASPECT_DEPTH_BIT,
        model_texture_types.WGPUTextureAspect_StencilOnly => vk_formats.VK_IMAGE_ASPECT_STENCIL_BIT,
        else => return error.UnsupportedFeature,
    };
    if (requested_mask != full_mask) return error.UnsupportedFeature;
}

pub fn descriptor_range(binding: model_compute_types.KernelBinding, buffer_size: u64) !u64 {
    if (binding.resource_kind != .buffer) return error.UnsupportedFeature;
    if (binding.buffer_size == model_texture_types.WGPUWholeSize) {
        if (binding.buffer_offset > buffer_size) return error.InvalidArgument;
        return c.VK_WHOLE_SIZE;
    }
    if (binding.buffer_size == 0) return error.InvalidArgument;
    const end = std.math.add(u64, binding.buffer_offset, binding.buffer_size) catch return error.InvalidArgument;
    if (end > buffer_size) return error.InvalidArgument;
    return binding.buffer_size;
}

test "validate_texture_binding accepts matching array texture metadata" {
    const binding = model_compute_types.KernelBinding{
        .binding = 0,
        .resource_kind = .texture,
        .resource_handle = 1,
        .texture_view_dimension = model_texture_types.WGPUTextureViewDimension_2DArray,
        .texture_sample_type = model_binding_types.WGPUTextureSampleType_Float,
    };
    const texture = vk_resources.TextureResource{
        .image = VK_NULL_U64,
        .memory = VK_NULL_U64,
        .view = VK_NULL_U64,
        .width = 32,
        .height = 32,
        .depth_or_array_layers = 4,
        .mip_levels = 1,
        .sample_count = 1,
        .dimension = model_texture_types.WGPUTextureDimension_2D,
        .view_dimension = model_texture_types.WGPUTextureViewDimension_2DArray,
        .aspect = model_texture_types.WGPUTextureAspect_All,
        .format = model_texture_types.WGPUTextureFormat_RGBA8Unorm,
        .usage = model_texture_types.WGPUTextureUsage_TextureBinding,
        .layout = 0,
    };
    try validate_texture_binding(binding, texture);
}

test "validate_texture_binding rejects multisample mismatch" {
    const binding = model_compute_types.KernelBinding{
        .binding = 0,
        .resource_kind = .texture,
        .resource_handle = 1,
        .texture_multisampled = true,
        .texture_sample_type = model_binding_types.WGPUTextureSampleType_Float,
    };
    const texture = vk_resources.TextureResource{
        .image = VK_NULL_U64,
        .memory = VK_NULL_U64,
        .view = VK_NULL_U64,
        .width = 16,
        .height = 16,
        .depth_or_array_layers = 1,
        .mip_levels = 1,
        .sample_count = 1,
        .dimension = model_texture_types.WGPUTextureDimension_2D,
        .view_dimension = model_texture_types.WGPUTextureViewDimension_2D,
        .aspect = model_texture_types.WGPUTextureAspect_All,
        .format = model_texture_types.WGPUTextureFormat_RGBA8Unorm,
        .usage = model_texture_types.WGPUTextureUsage_TextureBinding,
        .layout = 0,
    };
    try std.testing.expectError(error.InvalidState, validate_texture_binding(binding, texture));
}

pub fn words_from_spirv_bytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u32 {
    if (bytes.len == 0 or (bytes.len % 4) != 0) return error.ShaderCompileFailed;

    const words = try allocator.alloc(u32, bytes.len / 4);
    errdefer allocator.free(words);
    for (words, 0..) |*word, i| {
        const start = i * 4;
        const chunk: *const [4]u8 = @ptrCast(bytes[start .. start + 4].ptr);
        word.* = std.mem.readInt(u32, chunk, .little);
    }
    if (words[0] != SPIRV_MAGIC) return error.ShaderCompileFailed;
    return words;
}

fn resolve_kernel_path(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    const direct = try allocator.dupe(u8, kernel_name);
    if (path_utils.file_exists(direct)) return direct;
    allocator.free(direct);

    const root = self.kernel_root orelse DEFAULT_KERNEL_ROOT;
    const rooted = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, kernel_name });
    if (path_utils.file_exists(rooted)) return rooted;
    allocator.free(rooted);

    if (!std.mem.endsWith(u8, kernel_name, ".wgsl")) {
        const with_suffix = try std.fmt.allocPrint(allocator, "{s}/{s}.wgsl", .{ root, kernel_name });
        if (path_utils.file_exists(with_suffix)) return with_suffix;
        allocator.free(with_suffix);
    }
    return error.ShaderToolchainUnavailable;
}

fn resolve_kernel_spirv_path(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
    const source_path = try resolve_kernel_path(self, allocator, kernel_name);
    defer allocator.free(source_path);

    if (std.mem.endsWith(u8, source_path, ".spv") or std.mem.endsWith(u8, source_path, ".spirv")) {
        return try allocator.dupe(u8, source_path);
    }

    const sibling_spv = try std.fmt.allocPrint(allocator, "{s}.spv", .{source_path});
    if (path_utils.file_exists(sibling_spv)) return sibling_spv;
    allocator.free(sibling_spv);

    if (std.mem.lastIndexOfScalar(u8, source_path, '.')) |idx| {
        const replaced = try std.fmt.allocPrint(allocator, "{s}.spv", .{source_path[0..idx]});
        if (path_utils.file_exists(replaced)) return replaced;
        allocator.free(replaced);
    }

    return error.UnsupportedFeature;
}
