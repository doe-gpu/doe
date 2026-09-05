const std = @import("std");
const c = @import("vk_constants.zig");
const options = @import("build_options");

pub const readback_required_properties = options.vulkan_readback_required_properties;
pub const readback_preferred_properties = options.vulkan_readback_preferred_properties;

pub fn select_memory_type_index(properties: c.VkPhysicalDeviceMemoryProperties, type_bits: u32, required: u32, preferred: u32) !u32 {
    var required_match: ?u32 = null;
    for (properties.memoryTypes[0..properties.memoryTypeCount], 0..) |memory_type, index| {
        if ((type_bits & (@as(u32, 1) << @as(u5, @intCast(index)))) == 0) continue;
        if ((memory_type.propertyFlags & required) != required) continue;
        if ((memory_type.propertyFlags & preferred) == preferred) return @intCast(index);
        if (required_match == null) required_match = @intCast(index);
    }
    return required_match orelse error.UnsupportedFeature;
}

test "readback preference preserves coherence and supported memory type constraints" {
    var properties = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    properties.memoryTypeCount = 3;
    const coherent = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const cached = c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    properties.memoryTypes[0].propertyFlags = coherent;
    properties.memoryTypes[1].propertyFlags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | cached;
    properties.memoryTypes[2].propertyFlags = coherent | cached;
    try std.testing.expectEqual(@as(u32, 2), try select_memory_type_index(properties, 0b111, coherent, cached));
    try std.testing.expectEqual(@as(u32, 0), try select_memory_type_index(properties, 0b011, coherent, cached));
    try std.testing.expectError(error.UnsupportedFeature, select_memory_type_index(properties, 0b010, coherent, cached));
    try std.testing.expectError(error.UnsupportedFeature, select_memory_type_index(properties, 0, coherent, cached));
    try std.testing.expectEqual(@as(u32, 0), try select_memory_type_index(properties, 0b111, coherent, 0));
}
