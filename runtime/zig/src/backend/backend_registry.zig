const std = @import("std");
const builtin = @import("builtin");
const model = @import("../contracts/model/model_profile.zig");
const backend_ids = @import("../contracts/backend.zig");
const backend_iface = @import("backend_iface.zig");
const backend_policy = @import("backend_policy.zig");
const dawn_delegate_backend = @import("dawn_delegate_backend.zig");
const metal_backend = if (builtin.os.tag == .macos) @import("metal/mod.zig") else struct {};
const vulkan_backend = if (builtin.os.tag == .linux) @import("vulkan/mod.zig") else struct {};
const d3d12_backend = if (builtin.os.tag == .windows) @import("d3d12/mod.zig") else struct {};

pub fn init_backend(
    allocator: std.mem.Allocator,
    policy: backend_policy.SelectionPolicy,
    backend_id: backend_ids.BackendId,
    profile: model.DeviceProfile,
    kernel_root: ?[]const u8,
    reason: []const u8,
) !backend_iface.BackendIface {
    return switch (backend_id) {
        .dawn_delegate, .webkit_delegate => blk: {
            const backend = try dawn_delegate_backend.DawnDelegateBackend.init_with_id(allocator, profile, kernel_root, backend_id);
            break :blk try backend.as_iface(allocator, reason, policy.policy_hash);
        },
        .doe_metal => if (comptime builtin.os.tag == .macos) blk: {
            const backend = try metal_backend.ZigMetalBackend.init_with_selection_policy(
                allocator,
                profile,
                kernel_root,
                policy,
            );
            break :blk try backend.as_iface(allocator, reason, policy.policy_hash);
        } else error.UnsupportedBackend,
        .doe_vulkan => if (comptime builtin.os.tag == .linux) blk: {
            const backend = try vulkan_backend.ZigVulkanBackend.init_with_selection_policy(allocator, profile, kernel_root, policy);
            break :blk try backend.as_iface(allocator, reason, policy.policy_hash);
        } else error.UnsupportedBackend,
        .doe_d3d12 => if (comptime builtin.os.tag == .windows) blk: {
            const backend = try d3d12_backend.ZigD3D12Backend.init(allocator, profile, kernel_root);
            break :blk try backend.as_iface(allocator, reason, policy.policy_hash);
        } else error.UnsupportedBackend,
    };
}
