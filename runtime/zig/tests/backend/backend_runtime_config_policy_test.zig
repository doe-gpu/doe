const std = @import("std");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const runtime_types = @import("../../src/backend/runtime_types.zig");

test "backend runtime policy loads local metal lane from config" {
    const loaded = try backend_policy.load_policy_for_lane(
        std.testing.allocator,
        "config/backend-runtime-policy.json",
        .metal_doe_comparable,
    );
    defer std.testing.allocator.free(loaded.owned_policy_hash);

    try std.testing.expect(loaded.policy.default_backend == .doe_metal);
    try std.testing.expect(!loaded.policy.allow_fallback);
    try std.testing.expect(loaded.policy.strict_no_fallback);
    try std.testing.expect(loaded.policy.upload_path_policy == .staged_copy_only);
    try std.testing.expectEqual(runtime_types.QueueFamilyPolicy.prefer_graphics_compute, loaded.policy.queue_family_policy);
    try std.testing.expectEqual(runtime_types.DeferredSubmissionSyncPolicy.prefer_timeline_semaphore, loaded.policy.deferred_submission_sync_policy);
    try std.testing.expectEqualStrings("backend-runtime-policy-v7", loaded.policy.policy_hash);
}

test "backend runtime policy forces staged uploads on strict Vulkan lanes" {
    const loaded = try backend_policy.load_policy_for_lane(
        std.testing.allocator,
        "config/backend-runtime-policy.json",
        .vulkan_doe_release,
    );
    defer std.testing.allocator.free(loaded.owned_policy_hash);

    try std.testing.expect(loaded.policy.default_backend == .doe_vulkan);
    try std.testing.expect(!loaded.policy.allow_fallback);
    try std.testing.expect(loaded.policy.strict_no_fallback);
    try std.testing.expect(loaded.policy.upload_path_policy == .staged_copy_only);
    try std.testing.expectEqual(runtime_types.QueueFamilyPolicy.prefer_graphics_compute, loaded.policy.queue_family_policy);
    try std.testing.expectEqual(runtime_types.DeferredSubmissionSyncPolicy.prefer_timeline_semaphore, loaded.policy.deferred_submission_sync_policy);
    try std.testing.expectEqualStrings("backend-runtime-policy-v7", loaded.policy.policy_hash);
}

test "backend runtime policy loads Vulkan compute-only fence diagnostic lane" {
    const loaded = try backend_policy.load_policy_for_lane(
        std.testing.allocator,
        "config/backend-runtime-policy.json",
        .vulkan_doe_compute_only_fence_diagnostic,
    );
    defer std.testing.allocator.free(loaded.owned_policy_hash);

    try std.testing.expect(loaded.policy.default_backend == .doe_vulkan);
    try std.testing.expect(!loaded.policy.allow_fallback);
    try std.testing.expect(loaded.policy.strict_no_fallback);
    try std.testing.expect(loaded.policy.upload_path_policy == .staged_copy_only);
    try std.testing.expectEqual(runtime_types.QueueFamilyPolicy.require_compute_only, loaded.policy.queue_family_policy);
    try std.testing.expectEqual(runtime_types.DeferredSubmissionSyncPolicy.require_fence_pool, loaded.policy.deferred_submission_sync_policy);
    try std.testing.expectEqualStrings("backend-runtime-policy-v7", loaded.policy.policy_hash);
}

test "backend lane parser handles metal_doe_app and local metal lanes" {
    try std.testing.expect(
        backend_policy.parse_lane("metal_doe_app") == .metal_doe_app,
    );
    try std.testing.expect(
        backend_policy.parse_lane("metal_doe_directional") == .metal_doe_directional,
    );
    try std.testing.expect(
        backend_policy.parse_lane("metal_dawn_release") == .metal_dawn_release,
    );
    try std.testing.expect(
        backend_policy.parse_lane("metal_webkit_comparable") == .metal_webkit_comparable,
    );
    try std.testing.expect(
        backend_policy.parse_lane("metal-webkit-comparable") == .metal_webkit_comparable,
    );
    try std.testing.expect(
        backend_policy.parse_lane("d3d12_doe_release") == .d3d12_doe_release,
    );
    try std.testing.expect(
        backend_policy.parse_lane("d3d12_doe_app") == .d3d12_doe_app,
    );
    try std.testing.expect(
        backend_policy.parse_lane("vulkan_dawn_directional") == .vulkan_dawn_release,
    );
    try std.testing.expect(
        backend_policy.parse_lane("vulkan-doe-compute-only-fence-diagnostic") == .vulkan_doe_compute_only_fence_diagnostic,
    );
}

test "backend runtime policy rejects fallback-enabled lane config" {
    const path = ".tmp_backend_runtime_policy_invalid.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
        \\{
        \\  "schemaVersion": 6,
        \\  "selectionPolicyHashSeed": "backend-runtime-policy-v7",
        \\  "lanes": {
        \\    "metal_doe_comparable": {
        \\      "defaultBackend": "doe_metal",
        \\      "allowFallback": true,
        \\      "strictNoFallback": false,
        \\      "queueFamilyPolicy": "prefer_graphics_compute",
        \\      "deferredSubmissionSyncPolicy": "prefer_timeline_semaphore"
        \\    }
        \\  }
        \\}
        ,
    });

    try std.testing.expectError(
        backend_policy.PolicyLoadError.InvalidRuntimePolicy,
        backend_policy.load_policy_for_lane(
            std.testing.allocator,
            path,
            .metal_doe_comparable,
        ),
    );
}

test "backend runtime policy rejects mapped shortcuts for strict staged-upload lanes" {
    const path = ".tmp_backend_runtime_policy_invalid_upload.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
        \\{
        \\  "schemaVersion": 6,
        \\  "selectionPolicyHashSeed": "backend-runtime-policy-v7",
        \\  "lanes": {
        \\    "metal_doe_release": {
        \\      "defaultBackend": "doe_metal",
        \\      "allowFallback": false,
        \\      "strictNoFallback": true,
        \\      "uploadPathPolicy": "allow_mapped_shortcuts",
        \\      "queueFamilyPolicy": "prefer_graphics_compute",
        \\      "deferredSubmissionSyncPolicy": "prefer_timeline_semaphore"
        \\    }
        \\  }
        \\}
        ,
    });

    try std.testing.expectError(
        backend_policy.PolicyLoadError.InvalidRuntimePolicy,
        backend_policy.load_policy_for_lane(
            std.testing.allocator,
            path,
            .metal_doe_release,
        ),
    );
}

test "backend runtime policy rejects missing deferred sync policy" {
    const path = ".tmp_backend_runtime_policy_missing_sync.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
        \\{
        \\  "schemaVersion": 6,
        \\  "selectionPolicyHashSeed": "backend-runtime-policy-v7",
        \\  "lanes": {
        \\    "vulkan_doe_comparable": {
        \\      "defaultBackend": "doe_vulkan",
        \\      "allowFallback": false,
        \\      "strictNoFallback": true,
        \\      "uploadPathPolicy": "staged_copy_only",
        \\      "queueFamilyPolicy": "prefer_graphics_compute"
        \\    }
        \\  }
        \\}
        ,
    });

    try std.testing.expectError(
        backend_policy.PolicyLoadError.InvalidRuntimePolicy,
        backend_policy.load_policy_for_lane(
            std.testing.allocator,
            path,
            .vulkan_doe_comparable,
        ),
    );
}
