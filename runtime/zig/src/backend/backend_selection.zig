const std = @import("std");
const model = @import("../contracts/model/model_profile.zig");
const backend_ids = @import("backend_ids.zig");
const backend_policy = @import("backend_policy.zig");

pub const Selection = struct {
    backend_id: backend_ids.BackendId,
    reason: []const u8,
    fallback_used: bool,
};

fn is_apple_vendor(vendor: []const u8) bool {
    return std.ascii.eqlIgnoreCase(vendor, "apple");
}

pub fn select_backend(profile: model.DeviceProfile, policy: backend_policy.SelectionPolicy) Selection {
    if (policy.default_backend == .dawn_delegate) {
        return .{
            .backend_id = .dawn_delegate,
            .reason = "policy_lane_prefers_dawn_delegate",
            .fallback_used = false,
        };
    }

    if (policy.default_backend == .webkit_delegate) {
        return .{
            .backend_id = .webkit_delegate,
            .reason = "policy_lane_prefers_webkit_delegate",
            .fallback_used = false,
        };
    }

    if (policy.default_backend == .doe_metal and profile.api == .metal and is_apple_vendor(profile.vendor)) {
        return .{
            .backend_id = .doe_metal,
            .reason = "apple_chip_prefers_doe_metal",
            .fallback_used = false,
        };
    }

    if (policy.default_backend == .doe_vulkan) {
        return .{
            .backend_id = .doe_vulkan,
            .reason = "policy_lane_prefers_doe_vulkan",
            .fallback_used = false,
        };
    }

    if (policy.default_backend == .doe_d3d12) {
        return .{
            .backend_id = .doe_d3d12,
            .reason = "policy_lane_prefers_doe_d3d12",
            .fallback_used = false,
        };
    }

    if (profile.api == .metal and policy.default_backend == .doe_metal) {
        return .{
            .backend_id = .doe_metal,
            .reason = "policy_lane_prefers_doe_metal",
            .fallback_used = false,
        };
    }

    return .{
        .backend_id = policy.default_backend,
        .reason = if (policy.strict_no_fallback) "strict_lane_no_fallback" else "policy_lane_default",
        .fallback_used = false,
    };
}
