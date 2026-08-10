//! Stable backend, lane, queue-policy, and selection identities.

const std = @import("std");
const profile_contract = @import("model/model_profile.zig");

pub const BackendId = enum {
    dawn_delegate,
    webkit_delegate,
    doe_metal,
    doe_vulkan,
    doe_d3d12,
};

pub const NativeBackendKind = enum(u8) {
    metal = 0,
    vulkan = 1,
    d3d12 = 2,
};

pub const ADAPTER_DEVICE_NAME_BYTES: usize = 256;

pub fn backendIdName(id: BackendId) []const u8 {
    return @tagName(id);
}

pub fn parseBackendId(raw: []const u8) ?BackendId {
    inline for (@typeInfo(BackendId).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub const BackendLane = enum {
    metal_doe_app,
    metal_doe_directional,
    metal_doe_comparable,
    metal_doe_release,
    metal_dawn_release,
    metal_webkit_release,
    metal_webkit_comparable,
    vulkan_doe_app,
    vulkan_doe_comparable,
    vulkan_doe_compute_only_diagnostic,
    vulkan_doe_compute_only_fence_diagnostic,
    vulkan_doe_release,
    vulkan_dawn_release,
    d3d12_doe_app,
    d3d12_doe_directional,
    d3d12_doe_comparable,
    d3d12_doe_release,
    d3d12_dawn_release,
};

const LaneSpec = struct {
    lane: BackendLane,
    name: []const u8,
    aliases: []const []const u8 = &.{},
};

const LANE_SPECS = [_]LaneSpec{
    .{ .lane = .metal_doe_app, .name = "metal_doe_app" },
    .{ .lane = .metal_doe_directional, .name = "metal_doe_directional" },
    .{ .lane = .metal_doe_comparable, .name = "metal_doe_comparable" },
    .{ .lane = .metal_doe_release, .name = "metal_doe_release" },
    .{ .lane = .metal_dawn_release, .name = "metal_dawn_release" },
    .{ .lane = .metal_webkit_release, .name = "metal_webkit_release" },
    .{ .lane = .metal_webkit_comparable, .name = "metal_webkit_comparable" },
    .{ .lane = .vulkan_doe_app, .name = "vulkan_doe_app" },
    .{ .lane = .vulkan_doe_comparable, .name = "vulkan_doe_comparable" },
    .{ .lane = .vulkan_doe_compute_only_diagnostic, .name = "vulkan_doe_compute_only_diagnostic" },
    .{ .lane = .vulkan_doe_compute_only_fence_diagnostic, .name = "vulkan_doe_compute_only_fence_diagnostic" },
    .{ .lane = .vulkan_doe_release, .name = "vulkan_doe_release" },
    .{ .lane = .vulkan_dawn_release, .name = "vulkan_dawn_release", .aliases = &.{"vulkan_dawn_directional"} },
    .{ .lane = .d3d12_doe_app, .name = "d3d12_doe_app" },
    .{ .lane = .d3d12_doe_directional, .name = "d3d12_doe_directional" },
    .{ .lane = .d3d12_doe_comparable, .name = "d3d12_doe_comparable" },
    .{ .lane = .d3d12_doe_release, .name = "d3d12_doe_release" },
    .{ .lane = .d3d12_dawn_release, .name = "d3d12_dawn_release" },
};

const MAX_LANE_NAME_BYTES = blk: {
    var max_len: usize = 0;
    for (LANE_SPECS) |spec| {
        max_len = @max(max_len, spec.name.len);
        for (spec.aliases) |alias| max_len = @max(max_len, alias.len);
    }
    break :blk max_len;
};

pub fn laneName(lane: BackendLane) []const u8 {
    inline for (LANE_SPECS) |spec| if (spec.lane == lane) return spec.name;
    unreachable;
}

pub fn parseLane(raw: []const u8) ?BackendLane {
    if (raw.len == 0 or raw.len > MAX_LANE_NAME_BYTES) return null;
    var buffer: [MAX_LANE_NAME_BYTES]u8 = undefined;
    for (raw, 0..) |char, index| buffer[index] = if (char == '-') '_' else std.ascii.toLower(char);
    const normalized = buffer[0..raw.len];
    inline for (LANE_SPECS) |spec| {
        if (std.mem.eql(u8, normalized, spec.name)) return spec.lane;
        inline for (spec.aliases) |alias| if (std.mem.eql(u8, normalized, alias)) return spec.lane;
    }
    return null;
}

pub const UploadPathPolicy = enum { allow_mapped_shortcuts, staged_copy_only };
pub const VulkanSubgroupSizePolicy = enum {
    fixed_32_when_supported,
    suppress_for_workgroup_memory_256,
    suppress_for_workgroup_memory_256_or_single_invocation,
};
pub const QueueFamilyPolicy = enum {
    prefer_graphics_compute,
    prefer_compute_only,
    require_compute_only,

    pub fn name(self: QueueFamilyPolicy) []const u8 {
        return @tagName(self);
    }
};
pub const QueueFamilyKind = enum {
    graphics_compute,
    compute_only,

    pub fn name(self: QueueFamilyKind) []const u8 {
        return @tagName(self);
    }
};
pub const DeferredSubmissionSyncPolicy = enum {
    prefer_timeline_semaphore,
    require_fence_pool,

    pub fn name(self: DeferredSubmissionSyncPolicy) []const u8 {
        return @tagName(self);
    }
};

pub const SelectionPolicy = struct {
    lane: BackendLane,
    default_backend: BackendId,
    allow_fallback: bool,
    strict_no_fallback: bool,
    policy_hash: []const u8,
    upload_path_policy: UploadPathPolicy,
    queue_family_policy: QueueFamilyPolicy,
    deferred_submission_sync_policy: DeferredSubmissionSyncPolicy,
    vulkan_subgroup_size_policy: VulkanSubgroupSizePolicy,
};

pub const Selection = struct {
    backend_id: BackendId,
    reason: []const u8,
    fallback_used: bool,
};

pub fn select(profile: profile_contract.DeviceProfile, policy: SelectionPolicy) Selection {
    const reason: []const u8 = switch (policy.default_backend) {
        .dawn_delegate => "policy_lane_prefers_dawn_delegate",
        .webkit_delegate => "policy_lane_prefers_webkit_delegate",
        .doe_metal => if (profile.api == .metal and std.ascii.eqlIgnoreCase(profile.vendor, "apple"))
            "apple_chip_prefers_doe_metal"
        else if (profile.api == .metal)
            "policy_lane_prefers_doe_metal"
        else if (policy.strict_no_fallback)
            "strict_lane_no_fallback"
        else
            "policy_lane_default",
        .doe_vulkan => "policy_lane_prefers_doe_vulkan",
        .doe_d3d12 => "policy_lane_prefers_doe_d3d12",
    };
    return .{
        .backend_id = policy.default_backend,
        .reason = reason,
        .fallback_used = false,
    };
}

pub const backend_id_name = backendIdName;
pub const parse_backend_id = parseBackendId;
pub const lane_name = laneName;
pub const parse_lane = parseLane;
pub const select_backend = select;

test "backend identities and strict selection are stable" {
    try std.testing.expectEqual(BackendId.doe_vulkan, parseBackendId("DOE_VULKAN").?);
    try std.testing.expectEqual(BackendLane.metal_doe_app, parseLane("metal-doe-app").?);
    try std.testing.expectEqual(BackendLane.vulkan_dawn_release, parseLane("vulkan_dawn_directional").?);
}
