// Compute pipeline/layout ownership and command binding.

const std = @import("std");
const c = @import("vk_constants.zig");
const shared = @import("vk_shared_pipeline.zig");
const descriptors = @import("vk_descriptors.zig");
const build_options = @import("build_options");
const vk_device = @import("vk_device.zig");
const vk_pipeline_cache = @import("vk_pipeline_cache.zig");
const vk_compute_sync = @import("vk_compute_sync.zig");
const vk_upload = @import("vk_upload.zig");
const vk_resources = @import("vk_resources.zig");
const vk_spirv_inspect = @import("vk_spirv_inspect.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const hash_contract = @import("../../native/vulkan/vulkan_pipeline_hash.zig");
const common_errors = @import("../../contracts/execution.zig");

const VkBuffer = c.VkBuffer;
const VkDeviceMemory = c.VkDeviceMemory;
const VK_NULL_U64 = c.VK_NULL_U64;

const SPIRV_MAGIC: u32 = 0x07230203;

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

pub const RetiredPipelineState = struct {
    shared_pipeline: ?*shared.Pipeline = null,
    pipeline: c.VkPipeline = VK_NULL_U64,
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
const has_active_compute_state = vk_pipeline_cache.has_active_compute_state;
pub const release_cached_compute_states = vk_pipeline_cache.release_cached_compute_states;
pub const release_descriptor_state_cache = vk_pipeline_cache.release_descriptor_state_cache;
const stash_active_compute_state = vk_pipeline_cache.stash_active_compute_state;

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
    if (!self.has_pipeline) {
        self.current_pipeline_hash = 0;
        return;
    }
    self.retired_pipeline_states.append(self.allocator, .{
        .pipeline = self.pipeline,
        .shared_pipeline = self.shared_pipeline,
    }) catch std.debug.panic("vk_pipeline: OOM retiring pipeline state", .{});
    self.has_pipeline = false;
    self.pipeline = VK_NULL_U64;
    self.shared_pipeline = null;
    self.current_pipeline_hash = 0;
}

fn retire_descriptor_state(self: anytype) void {
    self.allocator.free(self.current_descriptor_identity);
    self.current_descriptor_identity = &.{};
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

pub fn release_retired_states(self: anytype) void {
    for (self.retired_pipeline_states.items) |retired| {
        if (retired.shared_pipeline) |entry| {
            self.shared_pipelines.release(self.allocator, self.device, entry);
        } else if (retired.pipeline != VK_NULL_U64) c.vkDestroyPipeline(self.device, retired.pipeline, null);
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
    const request = shared.Request{
        .words = words,
        .entry_point = entry_point orelse "main",
        .bindings = bindings orelse &.{},
        .required_subgroup_size = required_subgroup_size_for_pipeline(self, words),
    };
    const cache_hash = try vk_pipeline_cache.resolve_compute_state_hash(self, pipeline_hash, request);
    if (!self.has_pipeline or cache_hash != self.current_pipeline_hash) {
        const previous_pipeline_hash = self.current_pipeline_hash;
        const had_active_state = has_active_compute_state(self);
        if (had_active_state) {
            try stash_active_compute_state(self);
        }
        errdefer if (had_active_state and self.current_pipeline_hash == 0) {
            _ = activate_cached_compute_state(self, previous_pipeline_hash);
        };
        if (!activate_cached_compute_state(self, cache_hash)) {
            try build_pipeline_for_request(self, request, cache_hash, layout_hash);
        }
    }
    try descriptors.prepare(self, bindings, initialize_buffers_on_create, descriptor_bindings_hash);
    vk_compute_sync.capture_current_compute_bindings(self, bindings);
    stage_spirv_for_artifact(self, words);
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
    return build_pipeline_for_request(self, .{
        .words = words,
        .entry_point = entry_point orelse "main",
        .bindings = bindings orelse &.{},
        .required_subgroup_size = required_subgroup_size_for_pipeline(self, words),
    }, pipeline_hash, layout_hash);
}

fn build_pipeline_for_request(self: anytype, request: shared.Request, pipeline_hash: u64, layout_hash: u64) !void {
    const words = request.words;
    const bindings = request.bindings;
    const entry_name = request.entry_point;
    if (!self.recorded_submit_replay_active and (self.has_deferred_submissions or self.pending_uploads.items.len > 0)) {
        _ = try vk_upload.flush_queue(self);
    }
    // Guard: if no bindings were provided but SPIR-V declares descriptor bindings,
    // refuse to create the pipeline rather than letting the driver crash (RADV segfaults
    // when pipeline layout is empty but shader references descriptors).
    if (bindings.len == 0 and spirv_has_descriptor_bindings(words)) {
        return error.InvalidArgument;
    }
    // Defensive: RADV (and likely other drivers) segfault inside vkCreateComputePipelines
    // when the pName references an OpEntryPoint that doesn't exist in the module.
    // Doe must reject this at the boundary rather than crashing inside the driver.
    if (!spirv_has_entry_point(words, entry_name)) {
        return error.InvalidArgument;
    }
    try ensure_pipeline_layout_with_hash(self, bindings, layout_hash);
    release_or_retire_pipeline_objects(self);
    errdefer {
        destroy_pipeline_objects(self);
        destroy_descriptor_state(self);
    }
    const entry = try self.shared_pipelines.acquire(
        self.allocator,
        self.device,
        self.pipeline_cache.handleForPipelineCreation(),
        self.descriptor_set_layouts[0..self.descriptor_set_count],
        request,
        build_options.vulkan_share_live_compute_pipelines,
    );
    self.shared_pipeline = entry;
    self.pipeline = entry.handle;
    self.has_pipeline = true;
    self.current_pipeline_hash = pipeline_hash;
}

fn stage_spirv_for_artifact(self: anytype, words: []const u32) void {
    if (self.pending_spirv_bytes_owned) |stale| self.allocator.free(stale);
    self.pending_spirv_bytes_owned = self.allocator.dupe(
        u8,
        std.mem.sliceAsBytes(words),
    ) catch null;
}

test "staged SPIR-V receipt replaces prewarm bytes" {
    const Fixture = struct {
        allocator: std.mem.Allocator,
        pending_spirv_bytes_owned: ?[]u8 = null,
    };
    var fixture = Fixture{ .allocator = std.testing.allocator };
    defer if (fixture.pending_spirv_bytes_owned) |bytes| fixture.allocator.free(bytes);
    const prewarm_words = [_]u32{ SPIRV_MAGIC, 1, 2 };
    const executed_words = [_]u32{ SPIRV_MAGIC, 3, 4 };

    stage_spirv_for_artifact(&fixture, &prewarm_words);
    stage_spirv_for_artifact(&fixture, &executed_words);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(&executed_words),
        fixture.pending_spirv_bytes_owned.?,
    );
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
        if (self.shared_pipeline) |entry| {
            self.shared_pipelines.release(self.allocator, self.device, entry);
            self.shared_pipeline = null;
        } else c.vkDestroyPipeline(self.device, self.pipeline, null);
        self.has_pipeline = false;
        self.pipeline = VK_NULL_U64;
    }
    self.current_pipeline_hash = 0;
}

pub fn destroy_descriptor_state(self: anytype) void {
    self.allocator.free(self.current_descriptor_identity);
    self.current_descriptor_identity = &.{};
    self.current_descriptor_bindings_hash = 0;
    self.has_current_descriptor_bindings_hash = false;
    self.has_bound_descriptor_bindings_hash = false;
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
    if (self.has_pipeline_layout and layout_hash == self.current_layout_hash) {
        if (self.shared_pipeline) |entry| {
            if (try entry.matchesLayout(bindings orelse &.{})) return;
        }
    }

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

pub const descriptor_type_for_binding = descriptors.descriptor_type_for_binding;
pub const validate_texture_binding = descriptors.validate_texture_binding;
pub const descriptor_range = descriptors.descriptor_range;
