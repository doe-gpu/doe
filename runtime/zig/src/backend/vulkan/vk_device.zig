// Vulkan instance, physical device, and device lifecycle.
//
// Handles bootstrap (instance creation, adapter selection, device+queue
// creation, command pool, fence) and memory type queries.

const std = @import("std");
const webgpu = @import("../runtime_types.zig");
const c = @import("vk_constants.zig");
const vk_feature_caps = @import("vk_feature_caps.zig");
const vk_pipeline_cache_persistent = @import("vk_pipeline_cache_persistent.zig");
const vk_sync = @import("vk_sync.zig");
const vulkan_surface = @import("vulkan_surface.zig");

const VkPhysicalDevice = c.VkPhysicalDevice;
const VK_NULL_U64 = c.VK_NULL_U64;

const APP_NAME: [*:0]const u8 = "doe-zig-runtime";
const ENGINE_NAME: [*:0]const u8 = "doe-vulkan-runtime";

pub const QueueFamilySelection = struct {
    index: u32,
    supports_graphics: bool,
    timestamp_valid_bits: u32,
    queue_count: u32,
};

pub const PhysicalDeviceSelection = struct {
    index: u32,
    queue: QueueFamilySelection,
    score: u64,
};

pub fn bootstrap(self: anytype) !void {
    try create_instance(self);
    try select_physical_device(self);
    try create_device_and_queue(self);
    // Device-request latency matters for package cold-start benchmarks.
    // Defer submission scaffolding until the first path that actually records
    // or submits GPU work.
}

pub fn create_instance(self: anytype) !void {
    const surface_exts = vulkan_surface.required_instance_extensions();
    var enabled_exts: [4][*:0]const u8 = undefined;
    var enabled_ext_count: usize = 0;
    const surface_extension_available = detect_instance_extension(vulkan_surface.INSTANCE_SURFACE_EXTENSION);
    if (surface_extension_available) {
        enabled_exts[enabled_ext_count] = vulkan_surface.INSTANCE_SURFACE_EXTENSION;
        enabled_ext_count += 1;
        for (surface_exts) |ext| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.span(vulkan_surface.INSTANCE_SURFACE_EXTENSION))) continue;
            if (!detect_instance_extension(ext)) continue;
            enabled_exts[enabled_ext_count] = ext;
            enabled_ext_count += 1;
        }
    }
    var app_info = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = APP_NAME,
        .applicationVersion = 0,
        .pEngineName = ENGINE_NAME,
        .engineVersion = 0,
        .apiVersion = c.VK_API_VERSION_1_2,
    };
    var create_info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @intCast(enabled_ext_count),
        .ppEnabledExtensionNames = if (enabled_ext_count > 0) enabled_exts[0..enabled_ext_count].ptr else null,
    };
    try c.check_vk(c.vkCreateInstance(&create_info, null, &self.instance));
    self.has_instance = true;
}

pub fn destroy_instance_only(self: anytype) void {
    if (!self.has_instance) return;
    c.vkDestroyInstance(self.instance, null);
    self.instance = null;
    self.has_instance = false;
    self.physical_device = null;
}

pub fn select_physical_device(self: anytype) !void {
    var count: u32 = 0;
    try c.check_vk(c.vkEnumeratePhysicalDevices(self.instance, &count, null));
    if (count == 0) return error.UnsupportedFeature;
    const devices = try self.allocator.alloc(VkPhysicalDevice, count);
    defer self.allocator.free(devices);
    try c.check_vk(c.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));
    const selection = try select_preferred_physical_device(self, devices[0..count]);
    self.physical_device = devices[selection.index];
    self.adapter_ordinal_value = selection.index;
    self.queue_family_index = selection.queue.index;
    self.queue_family_index_value_cache = selection.queue.index;
    self.queue_family_kind_value_cache = queue_family_kind(selection.queue);
    self.queue_family_queue_count_value_cache = selection.queue.queue_count;
    self.queue_family_timestamp_valid_bits_value_cache = selection.queue.timestamp_valid_bits;
    self.queue_family_supports_graphics_value_cache = selection.queue.supports_graphics;
    self.present_capable_value = selection.queue.supports_graphics;
    self.timestamp_query_supported_value = selection.queue.timestamp_valid_bits > 0;
}

pub fn create_device_and_queue(self: anytype) !void {
    const requested_device_exts = vulkan_surface.required_device_extensions();
    const depth_clip_available = detect_device_extension(
        self.physical_device,
        c.VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME,
    );
    const subgroup_size_control_available = detect_device_extension(
        self.physical_device,
        c.VK_EXT_SUBGROUP_SIZE_CONTROL_EXTENSION_NAME,
    );
    var feature_query = vk_feature_caps.query(self.physical_device);
    const enable_subgroup_size_control = subgroup_size_control_available and feature_query.caps.subgroup_size_control;
    if (enable_subgroup_size_control) {
        feature_query.enabled_subgroup_size_control_features.pNext = @ptrCast(&feature_query.enabled_storage16_features);
        feature_query.enabled_vulkan12_features.pNext = @ptrCast(&feature_query.enabled_subgroup_size_control_features);
    } else {
        feature_query.enabled_vulkan12_features.pNext = @ptrCast(&feature_query.enabled_storage16_features);
    }

    var all_exts: [8][*:0]const u8 = undefined;
    var total_ext_count: usize = 0;
    for (requested_device_exts) |ext| {
        if (!detect_device_extension(self.physical_device, ext)) continue;
        all_exts[total_ext_count] = ext;
        total_ext_count += 1;
    }
    if (depth_clip_available) {
        all_exts[total_ext_count] = c.VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME;
        total_ext_count += 1;
    }
    if (enable_subgroup_size_control) {
        all_exts[total_ext_count] = c.VK_EXT_SUBGROUP_SIZE_CONTROL_EXTENSION_NAME;
        total_ext_count += 1;
    }

    var priority: f32 = 1.0;
    var queue_info = c.VkDeviceQueueCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = self.queue_family_index,
        .queueCount = 1,
        .pQueuePriorities = @ptrCast(&priority),
    };
    var device_info = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = @ptrCast(&feature_query.enabled_vulkan12_features),
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = @ptrCast(&queue_info),
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @intCast(total_ext_count),
        .ppEnabledExtensionNames = if (total_ext_count > 0) &all_exts else null,
        .pEnabledFeatures = @ptrCast(&feature_query.enabled_features),
    };
    try c.check_vk(c.vkCreateDevice(self.physical_device, &device_info, null, &self.device));
    self.has_device = true;
    self.has_depth_clip_enable_ext = depth_clip_available;
    self.has_subgroup_size_control_ext = enable_subgroup_size_control;
    self.required_compute_subgroup_size = if (enable_subgroup_size_control and
        feature_query.caps.subgroup_min_size <= 32 and
        feature_query.caps.subgroup_max_size >= 32 and
        (feature_query.caps.required_subgroup_size_stages & c.VK_SHADER_STAGE_COMPUTE_BIT) != 0)
        32
    else
        0;
    c.vkGetDeviceQueue(self.device, self.queue_family_index, 0, &self.queue);
    if (self.queue == null) return error.InvalidState;
    // Create the process-level VkPipelineCache so subsequent pipeline
    // creation calls can share compile state. Failures here are non-fatal;
    // the cache falls back to disabled and pipeline creation continues with
    // VK_NULL_U64 as before.
    vk_pipeline_cache_persistent.create_process_pipeline_cache(self.device) catch {};
}

pub fn create_command_pool_and_primary_buffer(self: anytype) !void {
    var pool_info = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT | c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = self.queue_family_index,
    };
    try c.check_vk(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
    self.has_command_pool = true;

    var alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = self.command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    try c.check_vk(c.vkAllocateCommandBuffers(self.device, &alloc_info, @ptrCast(&self.primary_command_buffer)));
    self.has_primary_command_buffer = true;
}

pub fn create_fence(self: anytype) !void {
    var fence_info = c.VkFenceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    try c.check_vk(c.vkCreateFence(self.device, &fence_info, null, &self.fence));
    self.has_fence = true;
}

pub fn find_memory_type_index(self: anytype, type_bits: u32, required_flags: u32) !u32 {
    var memory_props = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memory_props);
    var i: u32 = 0;
    while (i < memory_props.memoryTypeCount) : (i += 1) {
        const supports_type = (type_bits & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0;
        if (!supports_type) continue;
        if ((memory_props.memoryTypes[i].propertyFlags & required_flags) == required_flags) return i;
    }
    return error.UnsupportedFeature;
}

fn select_preferred_physical_device(self: anytype, devices: []const VkPhysicalDevice) !PhysicalDeviceSelection {
    var best: ?PhysicalDeviceSelection = null;
    for (devices, 0..) |device, index| {
        const queue = select_queue_family_for_device(self, device) catch continue;
        const score = score_physical_device(device, queue, self.queue_family_policy);
        const candidate = PhysicalDeviceSelection{
            .index = @as(u32, @intCast(index)),
            .queue = queue,
            .score = score,
        };
        if (best == null or candidate.score > best.?.score) {
            best = candidate;
        }
    }
    return best orelse error.UnsupportedFeature;
}

fn select_queue_family_for_device(self: anytype, device: VkPhysicalDevice) !QueueFamilySelection {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    if (count == 0) return error.UnsupportedFeature;
    const props = try self.allocator.alloc(c.VkQueueFamilyProperties, count);
    defer self.allocator.free(props);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, props.ptr);

    var best: ?QueueFamilySelection = null;
    for (props, 0..) |family, idx| {
        if ((family.queueFlags & c.VK_QUEUE_COMPUTE_BIT) == 0 or family.queueCount == 0) continue;
        const candidate = QueueFamilySelection{
            .index = @as(u32, @intCast(idx)),
            .supports_graphics = (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0,
            .timestamp_valid_bits = family.timestampValidBits,
            .queue_count = family.queueCount,
        };
        if (self.queue_family_policy == .require_compute_only and candidate.supports_graphics) {
            continue;
        }
        if (best == null or queue_selection_score_for_policy(candidate, self.queue_family_policy) > queue_selection_score_for_policy(best.?, self.queue_family_policy)) {
            best = candidate;
        }
    }
    return best orelse error.UnsupportedFeature;
}

fn score_physical_device(device: VkPhysicalDevice, queue: QueueFamilySelection, policy: webgpu.QueueFamilyPolicy) u64 {
    var memory_props = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    c.vkGetPhysicalDeviceMemoryProperties(device, &memory_props);

    var device_local_heap_bytes: u64 = 0;
    var type_index: u32 = 0;
    while (type_index < memory_props.memoryTypeCount) : (type_index += 1) {
        const memory_type = memory_props.memoryTypes[type_index];
        if ((memory_type.propertyFlags & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) == 0) continue;
        if (memory_type.heapIndex >= memory_props.memoryHeapCount) continue;
        device_local_heap_bytes +|= memory_props.memoryHeaps[memory_type.heapIndex].size;
    }

    return queue_selection_score_for_policy(queue, policy) + (device_local_heap_bytes / (1024 * 1024));
}

pub fn queue_selection_score(selection: QueueFamilySelection) u64 {
    return queue_selection_score_for_policy(selection, .prefer_graphics_compute);
}

pub fn queue_selection_score_for_policy(selection: QueueFamilySelection, policy: webgpu.QueueFamilyPolicy) u64 {
    var score: u64 = 0;
    score +|= @as(u64, selection.queue_count) * 100;
    switch (policy) {
        .prefer_graphics_compute => {
            if (selection.supports_graphics) score +|= 10_000;
        },
        .prefer_compute_only,
        .require_compute_only,
        => {
            if (!selection.supports_graphics) score +|= 10_000;
        },
    }
    if (selection.timestamp_valid_bits > 0) score +|= 1_000;
    return score;
}

pub fn queue_family_kind(selection: QueueFamilySelection) webgpu.QueueFamilyKind {
    return if (selection.supports_graphics) .graphics_compute else .compute_only;
}

pub fn create_fence_pool(self: anytype) !void {
    self.fence_pool_state = try vk_sync.FencePool.init(self.device);
    self.has_fence_pool = true;
}

pub fn create_timeline_semaphore(self: anytype) void {
    self.timeline_semaphore_probe_done = true;
    const supported = vk_sync.detect_timeline_semaphore_support(self.physical_device);
    self.timeline_semaphore = vk_sync.TimelineSemaphore.init(self.device, supported);
    self.has_timeline_semaphore = self.timeline_semaphore.available;
}

pub fn create_timestamp_query_pool(self: anytype) !void {
    if (!self.timestamp_query_supported_value) return;
    // Query timestampPeriod from physical device properties.
    var properties2 = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
    properties2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    c.vkGetPhysicalDeviceProperties2(self.physical_device, &properties2);
    self.timestamp_period = properties2.properties.limits.timestampPeriod;
    // Create a persistent 2-slot timestamp query pool.
    var create_info = c.VkQueryPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queryType = c.VK_QUERY_TYPE_TIMESTAMP,
        .queryCount = 2,
        .pipelineStatistics = 0,
    };
    try c.check_vk(c.vkCreateQueryPool(self.device, &create_info, null, &self.timestamp_query_pool));
}

pub fn ensure_submission_state(self: anytype) !void {
    if (!self.has_command_pool) {
        try create_command_pool_and_primary_buffer(self);
    }
    if (!self.has_fence) {
        try create_fence(self);
    }
}

pub fn ensure_deferred_submission_state(self: anytype) !void {
    if (self.deferred_submission_sync_policy == .require_fence_pool) {
        self.timeline_semaphore_probe_done = true;
        self.has_timeline_semaphore = false;
        if (!self.has_fence_pool) {
            try create_fence_pool(self);
        }
        return;
    }
    if (!self.timeline_semaphore_probe_done) {
        create_timeline_semaphore(self);
    }
    if (!self.has_timeline_semaphore and !self.has_fence_pool) {
        try create_fence_pool(self);
    }
}

pub fn ensure_timestamp_query_pool(self: anytype) !void {
    if (!self.timestamp_query_supported_value or self.timestamp_query_pool != VK_NULL_U64) {
        return;
    }
    try create_timestamp_query_pool(self);
}

const MAX_DEVICE_EXTENSIONS: u32 = 512;
const MAX_INSTANCE_EXTENSIONS: u32 = 512;

fn detect_instance_extension(target_name: [*:0]const u8) bool {
    var count: u32 = 0;
    const count_result = c.vkEnumerateInstanceExtensionProperties(null, &count, null);
    if (count_result != c.VK_SUCCESS or count == 0) return false;
    if (count > MAX_INSTANCE_EXTENSIONS) count = MAX_INSTANCE_EXTENSIONS;

    var props: [MAX_INSTANCE_EXTENSIONS]c.VkExtensionProperties = undefined;
    const enum_result = c.vkEnumerateInstanceExtensionProperties(null, &count, &props);
    if (enum_result != c.VK_SUCCESS) return false;

    const target_len = std.mem.len(target_name);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_bytes = &props[i].extensionName;
        const ext_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
        if (ext_len == target_len and std.mem.eql(u8, name_bytes[0..ext_len], target_name[0..target_len])) {
            return true;
        }
    }
    return false;
}

/// Check whether a physical device advertises a given extension by name.
fn detect_device_extension(physical_device: VkPhysicalDevice, target_name: [*:0]const u8) bool {
    var count: u32 = 0;
    const count_result = c.vkEnumerateDeviceExtensionProperties(physical_device, null, &count, null);
    if (count_result != c.VK_SUCCESS or count == 0) return false;
    if (count > MAX_DEVICE_EXTENSIONS) count = MAX_DEVICE_EXTENSIONS;

    var props: [MAX_DEVICE_EXTENSIONS]c.VkExtensionProperties = undefined;
    const enum_result = c.vkEnumerateDeviceExtensionProperties(physical_device, null, &count, &props);
    if (enum_result != c.VK_SUCCESS) return false;

    const target_len = std.mem.len(target_name);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_bytes = &props[i].extensionName;
        const ext_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
        if (ext_len == target_len and std.mem.eql(u8, name_bytes[0..ext_len], target_name[0..target_len])) {
            return true;
        }
    }
    return false;
}
