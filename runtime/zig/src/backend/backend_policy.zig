const std = @import("std");
const backend_ids = @import("../contracts/backend.zig");
const backend_contract = @import("../contracts/backend.zig");
const runtime_types = @import("../contracts/runtime_types.zig");

pub const BackendLane = backend_contract.BackendLane;
pub const UploadPathPolicy = backend_contract.UploadPathPolicy;
pub const VulkanSubgroupSizePolicy = backend_contract.VulkanSubgroupSizePolicy;
pub const SelectionPolicy = backend_contract.SelectionPolicy;
pub const lane_name = backend_contract.laneName;
pub const parse_lane = backend_contract.parseLane;

pub const LoadedSelectionPolicy = struct {
    policy: SelectionPolicy,
    owned_policy_hash: []u8,
};

pub const DEFAULT_RUNTIME_POLICY_PATH = "config/backend-runtime-policy.json";
const MAX_RUNTIME_POLICY_BYTES: usize = 64 * 1024;
const MAX_RUNTIME_POLICY_SEARCH_DEPTH: usize = 4;
const EXPECTED_SCHEMA_VERSION: i64 = 6;
const DEFAULT_POLICY_HASH = "backend-runtime-policy-v7";

pub const PolicyLoadError = error{
    InvalidRuntimePolicy,
};

pub fn load_policy_for_lane(
    allocator: std.mem.Allocator,
    policy_path: []const u8,
    lane: BackendLane,
) !LoadedSelectionPolicy {
    const bytes = try read_policy_file_alloc(allocator, policy_path);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), bytes, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };

    const schema_value = root_obj.get("schemaVersion") orelse return PolicyLoadError.InvalidRuntimePolicy;
    const schema_version = switch (schema_value) {
        .integer => |value| value,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };
    if (schema_version != EXPECTED_SCHEMA_VERSION) {
        return PolicyLoadError.InvalidRuntimePolicy;
    }

    const policy_hash_value = root_obj.get("selectionPolicyHashSeed") orelse return PolicyLoadError.InvalidRuntimePolicy;
    const policy_hash = switch (policy_hash_value) {
        .string => |value| value,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };
    const owned_policy_hash = try allocator.dupe(u8, policy_hash);
    errdefer allocator.free(owned_policy_hash);

    const lanes_value = root_obj.get("lanes") orelse return PolicyLoadError.InvalidRuntimePolicy;
    const lanes_obj = switch (lanes_value) {
        .object => |obj| obj,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };

    const lane_value = lanes_obj.get(lane_name(lane)) orelse return PolicyLoadError.InvalidRuntimePolicy;
    const lane_obj = switch (lane_value) {
        .object => |obj| obj,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };

    const backend_value = lane_obj.get("defaultBackend") orelse return PolicyLoadError.InvalidRuntimePolicy;
    const backend_name = switch (backend_value) {
        .string => |value| value,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };
    const backend_id = backend_ids.parse_backend_id(backend_name) orelse return PolicyLoadError.InvalidRuntimePolicy;

    const allow_fallback_value = lane_obj.get("allowFallback") orelse return PolicyLoadError.InvalidRuntimePolicy;
    const allow_fallback = switch (allow_fallback_value) {
        .bool => |value| value,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };

    const strict_no_fallback_value = lane_obj.get("strictNoFallback") orelse return PolicyLoadError.InvalidRuntimePolicy;
    const strict_no_fallback = switch (strict_no_fallback_value) {
        .bool => |value| value,
        else => return PolicyLoadError.InvalidRuntimePolicy,
    };
    if (allow_fallback or !strict_no_fallback) {
        return PolicyLoadError.InvalidRuntimePolicy;
    }

    const upload_path_policy = blk: {
        const upload_path_policy_value = lane_obj.get("uploadPathPolicy") orelse break :blk UploadPathPolicy.allow_mapped_shortcuts;
        const upload_path_policy_name = switch (upload_path_policy_value) {
            .string => |value| value,
            else => return PolicyLoadError.InvalidRuntimePolicy,
        };
        break :blk parse_upload_path_policy(upload_path_policy_name) orelse return PolicyLoadError.InvalidRuntimePolicy;
    };
    if (strict_staged_upload_policy_required(lane) and upload_path_policy != .staged_copy_only) {
        return PolicyLoadError.InvalidRuntimePolicy;
    }

    const queue_family_policy = blk: {
        const queue_family_policy_value = lane_obj.get("queueFamilyPolicy") orelse return PolicyLoadError.InvalidRuntimePolicy;
        const queue_family_policy_name = switch (queue_family_policy_value) {
            .string => |value| value,
            else => return PolicyLoadError.InvalidRuntimePolicy,
        };
        break :blk parse_queue_family_policy(queue_family_policy_name) orelse return PolicyLoadError.InvalidRuntimePolicy;
    };

    const deferred_submission_sync_policy = blk: {
        const policy_value = lane_obj.get("deferredSubmissionSyncPolicy") orelse return PolicyLoadError.InvalidRuntimePolicy;
        const policy_name = switch (policy_value) {
            .string => |value| value,
            else => return PolicyLoadError.InvalidRuntimePolicy,
        };
        break :blk parse_deferred_submission_sync_policy(policy_name) orelse return PolicyLoadError.InvalidRuntimePolicy;
    };

    const vulkan_subgroup_size_policy = blk: {
        const policy_value = lane_obj.get("vulkanSubgroupSizePolicy") orelse break :blk default_vulkan_subgroup_size_policy(lane);
        const policy_name = switch (policy_value) {
            .string => |value| value,
            else => return PolicyLoadError.InvalidRuntimePolicy,
        };
        break :blk parse_vulkan_subgroup_size_policy(policy_name) orelse return PolicyLoadError.InvalidRuntimePolicy;
    };

    return .{
        .policy = .{
            .lane = lane,
            .default_backend = backend_id,
            .allow_fallback = allow_fallback,
            .strict_no_fallback = strict_no_fallback,
            .policy_hash = owned_policy_hash,
            .upload_path_policy = upload_path_policy,
            .queue_family_policy = queue_family_policy,
            .deferred_submission_sync_policy = deferred_submission_sync_policy,
            .vulkan_subgroup_size_policy = vulkan_subgroup_size_policy,
        },
        .owned_policy_hash = owned_policy_hash,
    };
}

fn read_policy_file_alloc(allocator: std.mem.Allocator, policy_path: []const u8) ![]u8 {
    var candidate_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var depth: usize = 0;
    while (depth <= MAX_RUNTIME_POLICY_SEARCH_DEPTH) : (depth += 1) {
        const candidate = if (depth == 0) policy_path else blk: {
            const prefix_len = depth * "../".len;
            if (prefix_len + policy_path.len > candidate_buffer.len) return error.NameTooLong;
            var index: usize = 0;
            while (index < depth) : (index += 1) {
                const start = index * "../".len;
                @memcpy(candidate_buffer[start .. start + "../".len], "../");
            }
            @memcpy(candidate_buffer[prefix_len .. prefix_len + policy_path.len], policy_path);
            break :blk candidate_buffer[0 .. prefix_len + policy_path.len];
        };
        return std.fs.cwd().readFileAlloc(allocator, candidate, MAX_RUNTIME_POLICY_BYTES) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.FileNotFound;
}

pub fn default_policy_for_lane(lane: BackendLane) SelectionPolicy {
    return switch (lane) {
        .metal_doe_app => .{
            .lane = lane,
            .default_backend = .doe_metal,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .metal_doe_comparable, .metal_doe_release => .{
            .lane = lane,
            .default_backend = .doe_metal,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .staged_copy_only,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .metal_doe_directional => .{
            .lane = lane,
            .default_backend = .doe_metal,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .metal_dawn_release => .{
            .lane = lane,
            .default_backend = .dawn_delegate,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .metal_webkit_release => .{
            .lane = lane,
            .default_backend = .webkit_delegate,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .metal_webkit_comparable => .{
            .lane = lane,
            .default_backend = .webkit_delegate,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .staged_copy_only,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .vulkan_doe_app => .{
            .lane = lane,
            .default_backend = .doe_vulkan,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .vulkan_doe_comparable, .vulkan_doe_release => .{
            .lane = lane,
            .default_backend = .doe_vulkan,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .staged_copy_only,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .vulkan_doe_compute_only_diagnostic => .{
            .lane = lane,
            .default_backend = .doe_vulkan,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .staged_copy_only,
            .queue_family_policy = .require_compute_only,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .vulkan_doe_compute_only_fence_diagnostic => .{
            .lane = lane,
            .default_backend = .doe_vulkan,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .staged_copy_only,
            .queue_family_policy = .require_compute_only,
            .deferred_submission_sync_policy = .require_fence_pool,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .vulkan_dawn_release => .{
            .lane = lane,
            .default_backend = .dawn_delegate,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .d3d12_doe_app => .{
            .lane = lane,
            .default_backend = .doe_d3d12,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .d3d12_doe_comparable, .d3d12_doe_release => .{
            .lane = lane,
            .default_backend = .doe_d3d12,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .staged_copy_only,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .d3d12_doe_directional => .{
            .lane = lane,
            .default_backend = .doe_d3d12,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
        .d3d12_dawn_release => .{
            .lane = lane,
            .default_backend = .dawn_delegate,
            .allow_fallback = false,
            .strict_no_fallback = true,
            .policy_hash = DEFAULT_POLICY_HASH,
            .upload_path_policy = .allow_mapped_shortcuts,
            .queue_family_policy = .prefer_graphics_compute,
            .deferred_submission_sync_policy = .prefer_timeline_semaphore,
            .vulkan_subgroup_size_policy = default_vulkan_subgroup_size_policy(lane),
        },
    };
}

fn parse_upload_path_policy(raw: []const u8) ?UploadPathPolicy {
    if (std.mem.eql(u8, raw, "allow_mapped_shortcuts")) return .allow_mapped_shortcuts;
    if (std.mem.eql(u8, raw, "staged_copy_only")) return .staged_copy_only;
    return null;
}

fn parse_queue_family_policy(raw: []const u8) ?runtime_types.QueueFamilyPolicy {
    if (std.mem.eql(u8, raw, "prefer_graphics_compute")) return .prefer_graphics_compute;
    if (std.mem.eql(u8, raw, "prefer_compute_only")) return .prefer_compute_only;
    if (std.mem.eql(u8, raw, "require_compute_only")) return .require_compute_only;
    return null;
}

fn parse_deferred_submission_sync_policy(raw: []const u8) ?runtime_types.DeferredSubmissionSyncPolicy {
    if (std.mem.eql(u8, raw, "prefer_timeline_semaphore")) return .prefer_timeline_semaphore;
    if (std.mem.eql(u8, raw, "require_fence_pool")) return .require_fence_pool;
    return null;
}

fn parse_vulkan_subgroup_size_policy(raw: []const u8) ?VulkanSubgroupSizePolicy {
    if (std.mem.eql(u8, raw, "fixed_32_when_supported")) return .fixed_32_when_supported;
    if (std.mem.eql(u8, raw, "suppress_for_workgroup_memory_256")) return .suppress_for_workgroup_memory_256;
    if (std.mem.eql(u8, raw, "suppress_for_workgroup_memory_256_or_single_invocation")) return .suppress_for_workgroup_memory_256_or_single_invocation;
    return null;
}

fn default_vulkan_subgroup_size_policy(lane: BackendLane) VulkanSubgroupSizePolicy {
    return switch (lane) {
        .vulkan_doe_app,
        .vulkan_doe_comparable,
        .vulkan_doe_compute_only_diagnostic,
        .vulkan_doe_compute_only_fence_diagnostic,
        .vulkan_doe_release,
        => .suppress_for_workgroup_memory_256_or_single_invocation,
        else => .fixed_32_when_supported,
    };
}

fn strict_staged_upload_policy_required(lane: BackendLane) bool {
    return switch (lane) {
        .metal_doe_comparable,
        .metal_doe_release,
        .metal_webkit_comparable,
        .vulkan_doe_comparable,
        .vulkan_doe_compute_only_diagnostic,
        .vulkan_doe_compute_only_fence_diagnostic,
        .vulkan_doe_release,
        .d3d12_doe_comparable,
        .d3d12_doe_release,
        => true,
        else => false,
    };
}

const testing = std.testing;

test "lane table round-trips canonical and alias names" {
    try testing.expectEqualStrings("metal_webkit_comparable", lane_name(.metal_webkit_comparable));
    try testing.expectEqual(@as(?BackendLane, .metal_webkit_comparable), parse_lane("metal_webkit_comparable"));
    try testing.expectEqual(@as(?BackendLane, .metal_webkit_comparable), parse_lane("metal-webkit-comparable"));
    try testing.expectEqual(@as(?BackendLane, .vulkan_dawn_release), parse_lane("vulkan_dawn_directional"));
    try testing.expectEqual(@as(?BackendLane, .vulkan_doe_compute_only_fence_diagnostic), parse_lane("vulkan-doe-compute-only-fence-diagnostic"));
}

test "default Vulkan comparable policy declares graphics compute queue preference" {
    const policy = default_policy_for_lane(.vulkan_doe_comparable);
    try testing.expectEqual(runtime_types.QueueFamilyPolicy.prefer_graphics_compute, policy.queue_family_policy);
    try testing.expectEqual(UploadPathPolicy.staged_copy_only, policy.upload_path_policy);
    try testing.expectEqual(runtime_types.DeferredSubmissionSyncPolicy.prefer_timeline_semaphore, policy.deferred_submission_sync_policy);
}

test "default Vulkan compute-only diagnostic policy requires compute queue and staged uploads" {
    const policy = default_policy_for_lane(.vulkan_doe_compute_only_diagnostic);
    try testing.expectEqual(runtime_types.QueueFamilyPolicy.require_compute_only, policy.queue_family_policy);
    try testing.expectEqual(UploadPathPolicy.staged_copy_only, policy.upload_path_policy);
    try testing.expectEqual(runtime_types.DeferredSubmissionSyncPolicy.prefer_timeline_semaphore, policy.deferred_submission_sync_policy);
}

test "default Vulkan compute-only fence diagnostic policy requires fence pool" {
    const policy = default_policy_for_lane(.vulkan_doe_compute_only_fence_diagnostic);
    try testing.expectEqual(runtime_types.QueueFamilyPolicy.require_compute_only, policy.queue_family_policy);
    try testing.expectEqual(UploadPathPolicy.staged_copy_only, policy.upload_path_policy);
    try testing.expectEqual(runtime_types.DeferredSubmissionSyncPolicy.require_fence_pool, policy.deferred_submission_sync_policy);
}
