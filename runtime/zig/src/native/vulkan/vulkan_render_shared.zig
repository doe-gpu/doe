const std = @import("std");
const builtin = @import("builtin");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_rt_helpers = @import("../support/doe_native_runtime_helpers.zig");
const error_scope = @import("../../runtime/diagnostics/error_scope.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");

pub const has_vulkan = (builtin.os.tag == .linux);
pub const c = if (has_vulkan) resource_ops.vk_constants else struct {};
pub const vk_resources = if (has_vulkan) resource_ops.vk_resources else struct {};
pub const NativeVulkanRuntime = native_shared.NativeVulkanRuntime;

pub const DoeBuffer = native_types.DoeBuffer;
pub const DoeDevice = native_types.DoeDevice;
pub const DoeRenderPass = native_types.DoeRenderPass;
pub const DoeRenderPipeline = native_types.DoeRenderPipeline;
pub const DoeSampler = native_types.DoeSampler;
pub const DoeShaderModule = native_types.DoeShaderModule;
pub const DoeTexture = native_types.DoeTexture;
pub const DoeTextureView = native_types.DoeTextureView;

pub const WGPU_FILTER_NEAREST: u32 = 1;
pub const WGPU_FILTER_LINEAR: u32 = 2;
pub const WGPU_ADDRESS_MODE_CLAMP_TO_EDGE: u32 = 1;
pub const WGPU_ADDRESS_MODE_REPEAT: u32 = 2;
pub const WGPU_ADDRESS_MODE_MIRROR_REPEAT: u32 = 3;
pub const WGPU_COMPARE_UNDEFINED: u32 = 0;
pub const VK_SAMPLER_ADDRESS_MODE_REPEAT: u32 = 0;
pub const VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT: u32 = 1;
pub const VK_FILTER_LINEAR: u32 = 1;
pub const VK_SAMPLER_MIPMAP_MODE_LINEAR: u32 = 1;
pub const VK_COMPARE_OP_LESS: u32 = 1;
pub const VK_COMPARE_OP_EQUAL: u32 = 2;
pub const VK_COMPARE_OP_LESS_OR_EQUAL: u32 = 3;
pub const VK_COMPARE_OP_GREATER: u32 = 4;
pub const VK_COMPARE_OP_NOT_EQUAL: u32 = 5;
pub const VK_COMPARE_OP_GREATER_OR_EQUAL: u32 = 6;
pub const VK_COMPARE_OP_ALWAYS: u32 = 7;

pub fn deliverInternalError(dev: *DoeDevice, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "doe_vulkan_render_internal_error";
    dev.error_scopes.deliver(error_scope.ERROR_TYPE_INTERNAL, msg);
}

pub fn get_runtime(dev: *DoeDevice) ?*NativeVulkanRuntime {
    if (comptime !has_vulkan) return null;
    return native_rt_helpers.device_vk_runtime(dev);
}

pub fn wgpu_filter_to_vk(filter: u32) u32 {
    return if (filter == WGPU_FILTER_LINEAR) VK_FILTER_LINEAR else c.VK_FILTER_NEAREST;
}

pub fn wgpu_mipmap_to_vk(filter: u32) u32 {
    return if (filter == WGPU_FILTER_LINEAR) VK_SAMPLER_MIPMAP_MODE_LINEAR else c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
}

pub fn wgpu_address_to_vk(mode: u32) u32 {
    return switch (mode) {
        WGPU_ADDRESS_MODE_REPEAT => VK_SAMPLER_ADDRESS_MODE_REPEAT,
        WGPU_ADDRESS_MODE_MIRROR_REPEAT => VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        else => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
}

pub fn wgpu_compare_to_vk(compare: u32) u32 {
    return switch (compare) {
        0x00000002 => VK_COMPARE_OP_LESS,
        0x00000003 => VK_COMPARE_OP_EQUAL,
        0x00000004 => VK_COMPARE_OP_LESS_OR_EQUAL,
        0x00000005 => VK_COMPARE_OP_GREATER,
        0x00000006 => VK_COMPARE_OP_NOT_EQUAL,
        0x00000007 => VK_COMPARE_OP_GREATER_OR_EQUAL,
        0x00000008 => VK_COMPARE_OP_ALWAYS,
        else => c.VK_COMPARE_OP_NEVER,
    };
}
