// Vulkan VkResult error mapping and diagnostic name lookup.
//
// Single source of truth for all VkResult-to-Zig-error mapping in the
// Vulkan backend. Other modules should import check_vk / map_vk_result
// from here (or via vk_constants re-exports) instead of defining their own.

const std = @import("std");
const common_errors = @import("../../contracts/execution.zig");
const vk = @import("vulkan_types.zig");

pub const VkResult = vk.VkResult;
pub const VulkanError = common_errors.BackendNativeError;

// --- VkResult error codes (named for fail-fast error mapping) ---
pub const VK_ERROR_EXTENSION_NOT_PRESENT: VkResult = -7;
pub const VK_ERROR_FEATURE_NOT_PRESENT: VkResult = -8;
pub const VK_ERROR_INCOMPATIBLE_DRIVER: VkResult = -9;
pub const VK_ERROR_TOO_MANY_OBJECTS: VkResult = -10;
pub const VK_ERROR_FORMAT_NOT_SUPPORTED: VkResult = -11;
pub const VK_ERROR_FRAGMENTED_POOL: VkResult = -12;
pub const VK_ERROR_UNKNOWN: VkResult = -13;
pub const VK_ERROR_OUT_OF_DATE_KHR: VkResult = -1000001004;

/// Check a VkResult and return a Zig error on failure, or void on VK_SUCCESS.
pub fn check_vk(result: VkResult) common_errors.BackendNativeError!void {
    if (result == vk.VK_SUCCESS) return;
    return map_vk_result(result);
}

/// Map a raw VkResult (i32) to a BackendNativeError. Called for non-success codes.
pub fn map_vk_result(result: VkResult) common_errors.BackendNativeError {
    return switch (result) {
        VK_ERROR_EXTENSION_NOT_PRESENT,
        VK_ERROR_FEATURE_NOT_PRESENT,
        VK_ERROR_INCOMPATIBLE_DRIVER,
        VK_ERROR_TOO_MANY_OBJECTS,
        VK_ERROR_FORMAT_NOT_SUPPORTED,
        VK_ERROR_FRAGMENTED_POOL,
        VK_ERROR_UNKNOWN,
        => error.UnsupportedFeature,
        VK_ERROR_OUT_OF_DATE_KHR => error.SurfaceUnavailable,
        else => error.InvalidState,
    };
}

/// Return a human-readable name for common VkResult codes. Useful for
/// structured log output without pulling in the full Vulkan header names.
pub fn vulkanResultName(result: VkResult) []const u8 {
    return switch (result) {
        0 => "VK_SUCCESS",
        1 => "VK_NOT_READY",
        2 => "VK_TIMEOUT",
        3 => "VK_EVENT_SET",
        4 => "VK_EVENT_RESET",
        5 => "VK_INCOMPLETE",
        -1 => "VK_ERROR_OUT_OF_HOST_MEMORY",
        -2 => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        -3 => "VK_ERROR_INITIALIZATION_FAILED",
        -4 => "VK_ERROR_DEVICE_LOST",
        -5 => "VK_ERROR_MEMORY_MAP_FAILED",
        -6 => "VK_ERROR_LAYER_NOT_PRESENT",
        VK_ERROR_EXTENSION_NOT_PRESENT => "VK_ERROR_EXTENSION_NOT_PRESENT",
        VK_ERROR_FEATURE_NOT_PRESENT => "VK_ERROR_FEATURE_NOT_PRESENT",
        VK_ERROR_INCOMPATIBLE_DRIVER => "VK_ERROR_INCOMPATIBLE_DRIVER",
        VK_ERROR_TOO_MANY_OBJECTS => "VK_ERROR_TOO_MANY_OBJECTS",
        VK_ERROR_FORMAT_NOT_SUPPORTED => "VK_ERROR_FORMAT_NOT_SUPPORTED",
        VK_ERROR_FRAGMENTED_POOL => "VK_ERROR_FRAGMENTED_POOL",
        VK_ERROR_UNKNOWN => "VK_ERROR_UNKNOWN",
        -1000000000 => "VK_ERROR_SURFACE_LOST_KHR",
        VK_ERROR_OUT_OF_DATE_KHR => "VK_ERROR_OUT_OF_DATE_KHR",
        else => "VK_UNKNOWN",
    };
}

test "check_vk succeeds on VK_SUCCESS" {
    try check_vk(vk.VK_SUCCESS);
}

test "check_vk returns error on failure code" {
    const result = check_vk(VK_ERROR_EXTENSION_NOT_PRESENT);
    try std.testing.expectEqual(error.UnsupportedFeature, result);
}

test "map_vk_result maps EXTENSION_NOT_PRESENT to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_EXTENSION_NOT_PRESENT));
}

test "map_vk_result maps FEATURE_NOT_PRESENT to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_FEATURE_NOT_PRESENT));
}

test "map_vk_result maps INCOMPATIBLE_DRIVER to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_INCOMPATIBLE_DRIVER));
}

test "map_vk_result maps TOO_MANY_OBJECTS to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_TOO_MANY_OBJECTS));
}

test "map_vk_result maps FORMAT_NOT_SUPPORTED to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_FORMAT_NOT_SUPPORTED));
}

test "map_vk_result maps FRAGMENTED_POOL to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_FRAGMENTED_POOL));
}

test "map_vk_result maps UNKNOWN to UnsupportedFeature" {
    try std.testing.expectEqual(error.UnsupportedFeature, map_vk_result(VK_ERROR_UNKNOWN));
}

test "map_vk_result maps OUT_OF_DATE_KHR to SurfaceUnavailable" {
    try std.testing.expectEqual(error.SurfaceUnavailable, map_vk_result(VK_ERROR_OUT_OF_DATE_KHR));
}

test "map_vk_result maps other errors to InvalidState" {
    // VK_ERROR_OUT_OF_HOST_MEMORY = -1
    try std.testing.expectEqual(error.InvalidState, map_vk_result(-1));
    // VK_ERROR_OUT_OF_DEVICE_MEMORY = -2
    try std.testing.expectEqual(error.InvalidState, map_vk_result(-2));
}

test "vulkanResultName returns known names" {
    try std.testing.expectEqualStrings("VK_SUCCESS", vulkanResultName(0));
    try std.testing.expectEqualStrings("VK_ERROR_DEVICE_LOST", vulkanResultName(-4));
    try std.testing.expectEqualStrings("VK_ERROR_OUT_OF_DATE_KHR", vulkanResultName(VK_ERROR_OUT_OF_DATE_KHR));
    try std.testing.expectEqualStrings("VK_UNKNOWN", vulkanResultName(9999));
}
