const std = @import("std");
const c = @import("vk_constants.zig");
const compute = @import("../../contracts/model/model_compute_types.zig");
const binding_types = @import("../../contracts/model/model_binding_value_types.zig");

// These are the variable fields of the layouts built by vk_pipeline. All
// descriptors have count one, compute visibility, and no immutable samplers;
// layout flags and push constant ranges are empty.
const LayoutBinding = struct {
    group: u32,
    binding: u32,
    descriptor_type: u32,

    fn from(binding: compute.KernelBinding) !LayoutBinding {
        return .{ .group = binding.group, .binding = binding.binding, .descriptor_type = try descriptorType(binding) };
    }
};

pub fn descriptorType(binding: compute.KernelBinding) !u32 {
    return switch (binding.resource_kind) {
        .buffer => switch (binding.buffer_type) {
            binding_types.WGPUBufferBindingType_Uniform => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            binding_types.WGPUBufferBindingType_Storage,
            binding_types.WGPUBufferBindingType_ReadOnlyStorage,
            => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            else => error.UnsupportedFeature,
        },
        .texture => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .storage_texture => c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
    };
}

pub const Request = struct {
    words: []const u32,
    entry_point: []const u8,
    bindings: []const compute.KernelBinding,
    required_subgroup_size: ?u32,
};

pub const Pipeline = struct {
    handle: c.VkPipeline,
    creation_layout: c.VkPipelineLayout,
    words: []u32,
    entry_point: [:0]u8,
    layout: []LayoutBinding,
    required_subgroup_size: ?u32,
    references: usize = 1,

    pub fn matches(self: *const Pipeline, request: Request) !bool {
        if (self.required_subgroup_size != request.required_subgroup_size or
            self.layout.len != request.bindings.len or
            !std.mem.eql(u32, self.words, request.words) or
            !std.mem.eql(u8, self.entry_point, request.entry_point)) return false;
        for (self.layout, request.bindings) |layout, binding| {
            if (!std.meta.eql(layout, try LayoutBinding.from(binding))) return false;
        }
        return true;
    }
};

/// Device-owned registry; callers serialize it with the owning runtime queue.
/// Entries exist only while an active, cached, retired, or prepared state owns
/// a reference. Descriptor sets and their layouts remain private to that state.
pub const Registry = struct {
    entries: std.ArrayListUnmanaged(*Pipeline) = .{},

    pub fn acquire(
        self: *Registry,
        allocator: std.mem.Allocator,
        device: c.VkDevice,
        driver_cache: c.VkPipelineCache,
        set_layouts: []const c.VkDescriptorSetLayout,
        request: Request,
        share: bool,
    ) !*Pipeline {
        if (share) for (self.entries.items) |entry| {
            if (try entry.matches(request)) {
                entry.references = try std.math.add(usize, entry.references, 1);
                return entry;
            }
        };
        try self.entries.ensureUnusedCapacity(allocator, 1);
        const entry = try allocator.create(Pipeline);
        errdefer allocator.destroy(entry);
        const words = try allocator.dupe(u32, request.words);
        errdefer allocator.free(words);
        const entry_point = try allocator.dupeZ(u8, request.entry_point);
        errdefer allocator.free(entry_point);
        const bindings = try allocator.alloc(LayoutBinding, request.bindings.len);
        errdefer allocator.free(bindings);
        for (bindings, request.bindings) |*target, binding| target.* = try LayoutBinding.from(binding);

        // Vulkan 1.2 implementations may retain the creation layout. Owning a
        // compatible layout here keeps sharing independent of maintenance4.
        var layout: c.VkPipelineLayout = c.VK_NULL_U64;
        const layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = @intCast(set_layouts.len),
            .pSetLayouts = if (set_layouts.len != 0) set_layouts.ptr else null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        try c.check_vk(c.vkCreatePipelineLayout(device, &layout_info, null, &layout));
        errdefer c.vkDestroyPipelineLayout(device, layout, null);

        var shader: c.VkShaderModule = c.VK_NULL_U64;
        const shader_info = c.VkShaderModuleCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .pNext = null, .flags = 0, .codeSize = words.len * @sizeOf(u32), .pCode = words.ptr };
        try c.check_vk(c.vkCreateShaderModule(device, &shader_info, null, &shader));
        defer c.vkDestroyShaderModule(device, shader, null);
        var subgroup = c.VkPipelineShaderStageRequiredSubgroupSizeCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO,
            .pNext = null,
            .requiredSubgroupSize = request.required_subgroup_size orelse 0,
        };
        const stage = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = if (request.required_subgroup_size != null) @ptrCast(&subgroup) else null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader,
            .pName = entry_point.ptr,
            .pSpecializationInfo = null,
        };
        const info = c.VkComputePipelineCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .pNext = null, .flags = 0, .stage = stage, .layout = layout, .basePipelineHandle = c.VK_NULL_U64, .basePipelineIndex = -1 };
        var handle: c.VkPipeline = c.VK_NULL_U64;
        errdefer if (handle != c.VK_NULL_U64) c.vkDestroyPipeline(device, handle, null);
        try c.check_vk(c.vkCreateComputePipelines(device, driver_cache, 1, @ptrCast(&info), null, @ptrCast(&handle)));
        entry.* = .{ .handle = handle, .creation_layout = layout, .words = words, .entry_point = entry_point, .layout = bindings, .required_subgroup_size = request.required_subgroup_size };
        self.entries.appendAssumeCapacity(entry);
        return entry;
    }

    pub fn release(self: *Registry, allocator: std.mem.Allocator, device: c.VkDevice, entry: *Pipeline) void {
        std.debug.assert(entry.references > 0);
        entry.references -= 1;
        if (entry.references != 0) return;
        for (self.entries.items, 0..) |candidate, index| {
            if (candidate != entry) continue;
            _ = self.entries.swapRemove(index);
            c.vkDestroyPipeline(device, entry.handle, null);
            c.vkDestroyPipelineLayout(device, entry.creation_layout, null);
            allocator.free(entry.words);
            allocator.free(entry.entry_point);
            allocator.free(entry.layout);
            allocator.destroy(entry);
            return;
        }
        unreachable;
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        std.debug.assert(self.entries.items.len == 0);
        self.entries.deinit(allocator);
        self.* = .{};
    }
};
