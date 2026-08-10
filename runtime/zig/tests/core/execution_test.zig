const std = @import("std");
const testing = std.testing;

const execution = @import("../../src/runtime/execution.zig");
const command = @import("../../src/contracts/command.zig");
const profile_contract = @import("../../src/contracts/model/model_profile.zig");
const resource_types = @import("../../src/contracts/model/model_resource_types.zig");
const compute = @import("../../src/contracts/model/model_compute_types.zig");
const gpu = @import("../../src/contracts/model/model_gpu_types.zig");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const backend_ids = @import("../../src/contracts/backend.zig");
const compute_commands = @import("../../src/core/compute/wgpu_commands_compute.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");

// ============================================================
// ExecutionStatus enum — string mapping

test "executionStatusName maps all status variants to correct strings" {
    try testing.expectEqualStrings("skipped", execution.executionStatusName(.skipped));
    try testing.expectEqualStrings("ok", execution.executionStatusName(.ok));
    try testing.expectEqualStrings("unsupported", execution.executionStatusName(.unsupported));
    try testing.expectEqualStrings("error", execution.executionStatusName(.@"error"));
}

test "ExecutionStatus enum has exactly four variants" {
    const fields = @typeInfo(execution.ExecutionStatus).@"enum".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

// ============================================================
// BackendMode enum — string mapping and parsing

test "executionModeName maps trace to trace string" {
    try testing.expectEqualStrings("trace", execution.executionModeName(.trace));
}

test "executionModeName maps native to webgpu-ffi string" {
    try testing.expectEqualStrings("webgpu-ffi", execution.executionModeName(.native));
}

test "parseBackend parses trace mode" {
    try testing.expectEqual(execution.BackendMode.trace, execution.parseBackend("trace").?);
}

test "parseBackend parses native mode" {
    try testing.expectEqual(execution.BackendMode.native, execution.parseBackend("native").?);
}

test "parseBackend parses webgpu as native mode" {
    try testing.expectEqual(execution.BackendMode.native, execution.parseBackend("webgpu").?);
}

test "parseBackend is case-insensitive" {
    try testing.expectEqual(execution.BackendMode.trace, execution.parseBackend("TRACE").?);
    try testing.expectEqual(execution.BackendMode.trace, execution.parseBackend("Trace").?);
    try testing.expectEqual(execution.BackendMode.native, execution.parseBackend("NATIVE").?);
    try testing.expectEqual(execution.BackendMode.native, execution.parseBackend("WebGPU").?);
    try testing.expectEqual(execution.BackendMode.native, execution.parseBackend("WEBGPU").?);
}

test "parseBackend returns null for unknown inputs" {
    try testing.expect(execution.parseBackend("opengl") == null);
    try testing.expect(execution.parseBackend("vulkan") == null);
    try testing.expect(execution.parseBackend("") == null);
    try testing.expect(execution.parseBackend("trace_mode") == null);
}

// ============================================================
// Upload buffer usage parsing

test "parseUploadBufferUsage parses valid modes" {
    try testing.expectEqual(execution.UploadBufferUsageMode.copy_dst_copy_src, execution.parseUploadBufferUsage("copy-dst-copy-src").?);
    try testing.expectEqual(execution.UploadBufferUsageMode.copy_dst, execution.parseUploadBufferUsage("copy-dst").?);
}

test "parseUploadBufferUsage is case-insensitive" {
    try testing.expectEqual(execution.UploadBufferUsageMode.copy_dst, execution.parseUploadBufferUsage("COPY-DST").?);
    try testing.expectEqual(execution.UploadBufferUsageMode.copy_dst_copy_src, execution.parseUploadBufferUsage("Copy-Dst-Copy-Src").?);
}

test "parseUploadBufferUsage returns null for unknown modes" {
    try testing.expect(execution.parseUploadBufferUsage("map-write") == null);
    try testing.expect(execution.parseUploadBufferUsage("storage") == null);
    try testing.expect(execution.parseUploadBufferUsage("") == null);
}

// ============================================================
// Queue wait mode parsing

test "parseQueueWaitMode parses valid modes" {
    try testing.expectEqual(execution.QueueWaitMode.process_events, execution.parseQueueWaitMode("process-events").?);
    try testing.expectEqual(execution.QueueWaitMode.wait_any, execution.parseQueueWaitMode("wait-any").?);
}

test "parseQueueWaitMode is case-insensitive" {
    try testing.expectEqual(execution.QueueWaitMode.wait_any, execution.parseQueueWaitMode("Wait-Any").?);
    try testing.expectEqual(execution.QueueWaitMode.process_events, execution.parseQueueWaitMode("PROCESS-EVENTS").?);
}

test "parseQueueWaitMode returns null for unknown modes" {
    try testing.expect(execution.parseQueueWaitMode("spin") == null);
    try testing.expect(execution.parseQueueWaitMode("poll") == null);
    try testing.expect(execution.parseQueueWaitMode("") == null);
}

// ============================================================
// Queue sync mode parsing

test "parseQueueSyncMode parses valid modes" {
    try testing.expectEqual(execution.QueueSyncMode.per_command, execution.parseQueueSyncMode("per-command").?);
    try testing.expectEqual(execution.QueueSyncMode.deferred, execution.parseQueueSyncMode("deferred").?);
}

test "parseQueueSyncMode is case-insensitive" {
    try testing.expectEqual(execution.QueueSyncMode.deferred, execution.parseQueueSyncMode("DEFERRED").?);
    try testing.expectEqual(execution.QueueSyncMode.per_command, execution.parseQueueSyncMode("Per-Command").?);
}

test "parseQueueSyncMode returns null for unknown modes" {
    try testing.expect(execution.parseQueueSyncMode("batch") == null);
    try testing.expect(execution.parseQueueSyncMode("immediate") == null);
    try testing.expect(execution.parseQueueSyncMode("") == null);
}

// ============================================================
// GPU timestamp mode parsing

test "parseGpuTimestampMode parses valid modes" {
    try testing.expectEqual(execution.GpuTimestampMode.auto, execution.parseGpuTimestampMode("auto").?);
    try testing.expectEqual(execution.GpuTimestampMode.off, execution.parseGpuTimestampMode("off").?);
    try testing.expectEqual(execution.GpuTimestampMode.require, execution.parseGpuTimestampMode("require").?);
}

test "parseGpuTimestampMode is case-insensitive" {
    try testing.expectEqual(execution.GpuTimestampMode.require, execution.parseGpuTimestampMode("REQUIRE").?);
    try testing.expectEqual(execution.GpuTimestampMode.auto, execution.parseGpuTimestampMode("Auto").?);
    try testing.expectEqual(execution.GpuTimestampMode.off, execution.parseGpuTimestampMode("OFF").?);
}

test "parseGpuTimestampMode returns null for unknown modes" {
    try testing.expect(execution.parseGpuTimestampMode("maybe") == null);
    try testing.expect(execution.parseGpuTimestampMode("on") == null);
    try testing.expect(execution.parseGpuTimestampMode("") == null);
}

// ============================================================
// Backend lane parsing — snake_case and kebab-case

test "parseBackendLane parses metal lanes in snake_case" {
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_app, execution.parseBackendLane("metal_doe_app").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_directional, execution.parseBackendLane("metal_doe_directional").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_comparable, execution.parseBackendLane("metal_doe_comparable").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_release, execution.parseBackendLane("metal_doe_release").?);
}

test "parseBackendLane parses metal lanes in kebab-case" {
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_app, execution.parseBackendLane("metal-doe-app").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_dawn_release, execution.parseBackendLane("metal-dawn-release").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_webkit_comparable, execution.parseBackendLane("metal-webkit-comparable").?);
}

test "parseBackendLane parses vulkan lanes" {
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, execution.parseBackendLane("vulkan_doe_app").?);
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, execution.parseBackendLane("vulkan-doe-app").?);
    try testing.expectEqual(backend_policy.BackendLane.vulkan_dawn_release, execution.parseBackendLane("vulkan-dawn-release").?);
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_comparable, execution.parseBackendLane("vulkan_doe_comparable").?);
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_release, execution.parseBackendLane("vulkan_doe_release").?);
}

test "parseBackendLane parses d3d12 lanes" {
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_app, execution.parseBackendLane("d3d12_doe_app").?);
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_app, execution.parseBackendLane("d3d12-doe-app").?);
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_directional, execution.parseBackendLane("d3d12_doe_directional").?);
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_comparable, execution.parseBackendLane("d3d12_doe_comparable").?);
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_release, execution.parseBackendLane("d3d12_doe_release").?);
    try testing.expectEqual(backend_policy.BackendLane.d3d12_dawn_release, execution.parseBackendLane("d3d12-dawn-release").?);
}

test "parseBackendLane returns null for unknown lanes" {
    try testing.expect(execution.parseBackendLane("opengl_doe_app") == null);
    try testing.expect(execution.parseBackendLane("metal") == null);
    try testing.expect(execution.parseBackendLane("") == null);
    try testing.expect(execution.parseBackendLane("metal_doe") == null);
}

// ============================================================
// Backend lane name — round-trip fidelity

test "backendLaneName returns correct string for all lanes" {
    try testing.expectEqualStrings("metal_doe_app", execution.backendLaneName(.metal_doe_app));
    try testing.expectEqualStrings("metal_doe_directional", execution.backendLaneName(.metal_doe_directional));
    try testing.expectEqualStrings("metal_doe_comparable", execution.backendLaneName(.metal_doe_comparable));
    try testing.expectEqualStrings("metal_doe_release", execution.backendLaneName(.metal_doe_release));
    try testing.expectEqualStrings("metal_dawn_release", execution.backendLaneName(.metal_dawn_release));
    try testing.expectEqualStrings("metal_webkit_release", execution.backendLaneName(.metal_webkit_release));
    try testing.expectEqualStrings("metal_webkit_comparable", execution.backendLaneName(.metal_webkit_comparable));
    try testing.expectEqualStrings("vulkan_doe_app", execution.backendLaneName(.vulkan_doe_app));
    try testing.expectEqualStrings("vulkan_doe_comparable", execution.backendLaneName(.vulkan_doe_comparable));
    try testing.expectEqualStrings("vulkan_doe_release", execution.backendLaneName(.vulkan_doe_release));
    try testing.expectEqualStrings("vulkan_dawn_release", execution.backendLaneName(.vulkan_dawn_release));
    try testing.expectEqualStrings("d3d12_doe_app", execution.backendLaneName(.d3d12_doe_app));
    try testing.expectEqualStrings("d3d12_doe_directional", execution.backendLaneName(.d3d12_doe_directional));
    try testing.expectEqualStrings("d3d12_doe_comparable", execution.backendLaneName(.d3d12_doe_comparable));
    try testing.expectEqualStrings("d3d12_doe_release", execution.backendLaneName(.d3d12_doe_release));
    try testing.expectEqualStrings("d3d12_dawn_release", execution.backendLaneName(.d3d12_dawn_release));
}

test "backendLaneName round-trips through parseBackendLane for every lane" {
    const lanes = [_]backend_policy.BackendLane{
        .metal_doe_app,
        .metal_doe_directional,
        .metal_doe_comparable,
        .metal_doe_release,
        .metal_dawn_release,
        .metal_webkit_release,
        .metal_webkit_comparable,
        .vulkan_doe_app,
        .vulkan_doe_comparable,
        .vulkan_doe_release,
        .vulkan_dawn_release,
        .d3d12_doe_app,
        .d3d12_doe_directional,
        .d3d12_doe_comparable,
        .d3d12_doe_release,
        .d3d12_dawn_release,
    };
    for (lanes) |lane| {
        const name = execution.backendLaneName(lane);
        const parsed = execution.parseBackendLane(name);
        try testing.expect(parsed != null);
        try testing.expectEqual(lane, parsed.?);
    }
}

// ============================================================
// Default backend lane — per API selection

test "defaultBackendLane selects metal_doe_app for metal API" {
    const profile = profile_contract.DeviceProfile{
        .vendor = "apple",
        .api = .metal,
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_app, execution.defaultBackendLane(profile));
}

test "defaultBackendLane selects d3d12_doe_app for d3d12 API" {
    const profile = profile_contract.DeviceProfile{
        .vendor = "amd",
        .api = .d3d12,
        .driver_version = .{ .major = 23, .minor = 1, .patch = 0 },
    };
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_app, execution.defaultBackendLane(profile));
}

test "defaultBackendLane selects vulkan_doe_app for vulkan API" {
    const profile = profile_contract.DeviceProfile{
        .vendor = "nvidia",
        .api = .vulkan,
        .driver_version = .{ .major = 535, .minor = 0, .patch = 0 },
    };
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, execution.defaultBackendLane(profile));
}

test "defaultBackendLane falls back to vulkan_doe_app for webgpu API" {
    const profile = profile_contract.DeviceProfile{
        .vendor = "generic",
        .api = .webgpu,
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, execution.defaultBackendLane(profile));
}

// ============================================================
// Backend ID name mapping

test "backend_id_name returns correct string for all backend IDs" {
    try testing.expectEqualStrings("dawn_delegate", execution.backend_id_name(.dawn_delegate));
    try testing.expectEqualStrings("doe_metal", execution.backend_id_name(.doe_metal));
    try testing.expectEqualStrings("doe_vulkan", execution.backend_id_name(.doe_vulkan));
    try testing.expectEqualStrings("doe_d3d12", execution.backend_id_name(.doe_d3d12));
}

// ============================================================
// ExecutionResult — default field initialization

test "ExecutionResult default construction has correct zero values" {
    const result = execution.ExecutionResult{
        .backend = "test",
        .status = .skipped,
        .status_code = "disabled",
        .duration_ns = 0,
        .setup_ns = 0,
        .encode_ns = 0,
        .submit_wait_ns = 0,
        .dispatch_count = 0,
        .submit_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .backend_lane = null,
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
    };
    try testing.expectEqualStrings("test", result.backend);
    try testing.expectEqual(execution.ExecutionStatus.skipped, result.status);
    try testing.expectEqual(@as(u64, 0), result.duration_ns);
    try testing.expectEqual(@as(u64, 0), result.setup_ns);
    try testing.expectEqual(@as(u64, 0), result.encode_ns);
    try testing.expectEqual(@as(u64, 0), result.submit_wait_ns);
    try testing.expectEqual(@as(u32, 0), result.dispatch_count);
    try testing.expectEqual(@as(u64, 0), result.gpu_timestamp_ns);
    try testing.expect(!result.gpu_timestamp_attempted);
    try testing.expect(!result.gpu_timestamp_valid);
    try testing.expect(result.backend_selection_reason == null);
    try testing.expect(result.fallback_used == null);
    try testing.expect(result.selection_policy_hash == null);
    try testing.expect(result.shader_artifact_manifest_path == null);
    try testing.expect(result.shader_artifact_manifest_hash == null);
    try testing.expect(result.backend_lane == null);
    try testing.expect(result.adapter_ordinal == null);
    try testing.expect(result.queue_family_index == null);
    try testing.expect(result.present_capable == null);
}

// ============================================================
// pipelineCacheKey — determinism and sensitivity

test "pipelineCacheKey is deterministic for identical inputs" {
    const key_a = compute_commands.pipelineCacheKey("@compute fn main() {}", "main", null);
    const key_b = compute_commands.pipelineCacheKey("@compute fn main() {}", "main", null);
    try testing.expectEqual(key_a, key_b);
}

test "pipelineCacheKey differs for different source" {
    const key_a = compute_commands.pipelineCacheKey("@compute fn main() {}", "main", null);
    const key_b = compute_commands.pipelineCacheKey("@compute fn other() {}", "main", null);
    try testing.expect(key_a != key_b);
}

test "pipelineCacheKey differs for different entry point" {
    const key_a = compute_commands.pipelineCacheKey("@compute fn main() {}", "main", null);
    const key_b = compute_commands.pipelineCacheKey("@compute fn main() {}", "dispatch", null);
    try testing.expect(key_a != key_b);
}

test "pipelineCacheKey handles empty source" {
    const key_a = compute_commands.pipelineCacheKey("", "main", null);
    const key_b = compute_commands.pipelineCacheKey("x", "main", null);
    try testing.expect(key_a != key_b);
}

test "pipelineCacheKey handles empty entry point" {
    const key_a = compute_commands.pipelineCacheKey("@compute fn main() {}", "", null);
    const key_b = compute_commands.pipelineCacheKey("@compute fn main() {}", "main", null);
    try testing.expect(key_a != key_b);
}

test "pipelineCacheKey is order-sensitive between source and entry point" {
    // Ensure the separator (h ^= 0xff) prevents source/entry collisions
    const key_a = compute_commands.pipelineCacheKey("abc", "def", null);
    const key_b = compute_commands.pipelineCacheKey("abcdef", "", null);
    try testing.expect(key_a != key_b);
}

test "pipelineCacheKey produces non-zero values" {
    const key = compute_commands.pipelineCacheKey("@compute fn main() {}", "main", null);
    try testing.expect(key != 0);
}

// ============================================================
// sourceContainsComputeStage — detection of @compute annotation

test "sourceContainsComputeStage detects @compute in simple kernel" {
    try testing.expect(compute_commands.sourceContainsComputeStage("@compute fn main() {}"));
}

test "sourceContainsComputeStage detects @compute with workgroup_size" {
    try testing.expect(compute_commands.sourceContainsComputeStage(
        \\@group(0) @binding(0) var<storage,read_write> data : array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
    ));
}

test "sourceContainsComputeStage rejects source without @compute" {
    try testing.expect(!compute_commands.sourceContainsComputeStage("fn main() {}"));
}

test "sourceContainsComputeStage rejects empty source" {
    try testing.expect(!compute_commands.sourceContainsComputeStage(""));
}

test "sourceContainsComputeStage rejects vertex-only shader" {
    try testing.expect(!compute_commands.sourceContainsComputeStage(
        \\@vertex fn vs_main() -> @builtin(position) vec4<f32> {
        \\    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
        \\}
    ));
}

test "sourceContainsComputeStage detects @compute anywhere in source" {
    try testing.expect(compute_commands.sourceContainsComputeStage("// some comment\n// more\n@compute\nfn dispatch() {}"));
}

// ============================================================
// hasValidTextureExtent — texture dimension validation

test "hasValidTextureExtent accepts valid 1x1x1 texture" {
    const resource = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 1,
        .height = 1,
        .depth_or_array_layers = 1,
    };
    try testing.expect(compute_commands.hasValidTextureExtent(resource));
}

test "hasValidTextureExtent accepts large texture" {
    const resource = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 4096,
        .height = 2048,
        .depth_or_array_layers = 6,
    };
    try testing.expect(compute_commands.hasValidTextureExtent(resource));
}

test "hasValidTextureExtent rejects zero width" {
    const resource = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 0,
        .height = 1,
        .depth_or_array_layers = 1,
    };
    try testing.expect(!compute_commands.hasValidTextureExtent(resource));
}

test "hasValidTextureExtent rejects zero height" {
    const resource = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 1,
        .height = 0,
        .depth_or_array_layers = 1,
    };
    try testing.expect(!compute_commands.hasValidTextureExtent(resource));
}

test "hasValidTextureExtent rejects zero depth" {
    const resource = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 1,
        .height = 1,
        .depth_or_array_layers = 0,
    };
    try testing.expect(!compute_commands.hasValidTextureExtent(resource));
}

test "hasValidTextureExtent rejects all-zero dimensions" {
    const resource = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 0,
        .height = 0,
        .depth_or_array_layers = 0,
    };
    try testing.expect(!compute_commands.hasValidTextureExtent(resource));
}

// ============================================================
// hasMatchingTextureExtent — texture extent comparison

test "hasMatchingTextureExtent matches identical extents" {
    const a = resource_types.CopyTextureResource{
        .handle = 1,
        .width = 256,
        .height = 256,
        .depth_or_array_layers = 1,
    };
    const b = resource_types.CopyTextureResource{
        .handle = 2,
        .width = 256,
        .height = 256,
        .depth_or_array_layers = 1,
    };
    try testing.expect(compute_commands.hasMatchingTextureExtent(a, b));
}

test "hasMatchingTextureExtent rejects different width" {
    const a = resource_types.CopyTextureResource{ .handle = 1, .width = 256, .height = 256, .depth_or_array_layers = 1 };
    const b = resource_types.CopyTextureResource{ .handle = 2, .width = 512, .height = 256, .depth_or_array_layers = 1 };
    try testing.expect(!compute_commands.hasMatchingTextureExtent(a, b));
}

test "hasMatchingTextureExtent rejects different height" {
    const a = resource_types.CopyTextureResource{ .handle = 1, .width = 256, .height = 256, .depth_or_array_layers = 1 };
    const b = resource_types.CopyTextureResource{ .handle = 2, .width = 256, .height = 128, .depth_or_array_layers = 1 };
    try testing.expect(!compute_commands.hasMatchingTextureExtent(a, b));
}

test "hasMatchingTextureExtent rejects different depth" {
    const a = resource_types.CopyTextureResource{ .handle = 1, .width = 256, .height = 256, .depth_or_array_layers = 1 };
    const b = resource_types.CopyTextureResource{ .handle = 2, .width = 256, .height = 256, .depth_or_array_layers = 6 };
    try testing.expect(!compute_commands.hasMatchingTextureExtent(a, b));
}

test "hasMatchingTextureExtent ignores non-extent fields" {
    const a = resource_types.CopyTextureResource{
        .handle = 100,
        .width = 64,
        .height = 64,
        .depth_or_array_layers = 2,
        .format = gpu.WGPUTextureFormat_RGBA8Unorm,
        .mip_level = 0,
    };
    const b = resource_types.CopyTextureResource{
        .handle = 200,
        .width = 64,
        .height = 64,
        .depth_or_array_layers = 2,
        .format = gpu.WGPUTextureFormat_BGRA8Unorm,
        .mip_level = 3,
    };
    try testing.expect(compute_commands.hasMatchingTextureExtent(a, b));
}

// ============================================================
// minPositiveLimit — helper for binding limit selection

test "minPositiveLimit returns minimum when both positive" {
    try testing.expectEqual(@as(u64, 100), compute_commands.minPositiveLimit(100, 200));
    try testing.expectEqual(@as(u64, 100), compute_commands.minPositiveLimit(200, 100));
}

test "minPositiveLimit returns non-zero when one is zero" {
    try testing.expectEqual(@as(u64, 100), compute_commands.minPositiveLimit(0, 100));
    try testing.expectEqual(@as(u64, 100), compute_commands.minPositiveLimit(100, 0));
}

test "minPositiveLimit returns zero when both are zero" {
    try testing.expectEqual(@as(u64, 0), compute_commands.minPositiveLimit(0, 0));
}

test "minPositiveLimit handles equal values" {
    try testing.expectEqual(@as(u64, 42), compute_commands.minPositiveLimit(42, 42));
}

test "minPositiveLimit handles large values" {
    const large: u64 = 0xFFFF_FFFF_FFFF_FFFE;
    try testing.expectEqual(@as(u64, 1), compute_commands.minPositiveLimit(large, 1));
    try testing.expectEqual(@as(u64, 1), compute_commands.minPositiveLimit(1, large));
}

// ============================================================
// bindingBufferLimit — per-binding-type limit selection

test "bindingBufferLimit returns maxUniformBufferBindingSize for uniform bindings" {
    var limits = std.mem.zeroes(types.WGPULimits);
    limits.maxUniformBufferBindingSize = 65536;
    limits.maxStorageBufferBindingSize = 128_000_000;

    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = gpu.WGPUBufferBindingType_Uniform,
    };
    try testing.expectEqual(@as(u64, 65536), compute_commands.bindingBufferLimit(binding, limits));
}

test "bindingBufferLimit returns maxStorageBufferBindingSize for storage bindings" {
    var limits = std.mem.zeroes(types.WGPULimits);
    limits.maxUniformBufferBindingSize = 65536;
    limits.maxStorageBufferBindingSize = 128_000_000;

    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = gpu.WGPUBufferBindingType_Storage,
    };
    try testing.expectEqual(@as(u64, 128_000_000), compute_commands.bindingBufferLimit(binding, limits));
}

test "bindingBufferLimit returns maxStorageBufferBindingSize for read-only storage bindings" {
    var limits = std.mem.zeroes(types.WGPULimits);
    limits.maxUniformBufferBindingSize = 65536;
    limits.maxStorageBufferBindingSize = 128_000_000;

    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = gpu.WGPUBufferBindingType_ReadOnlyStorage,
    };
    try testing.expectEqual(@as(u64, 128_000_000), compute_commands.bindingBufferLimit(binding, limits));
}

test "bindingBufferLimit returns min positive limit for undefined binding type" {
    var limits = std.mem.zeroes(types.WGPULimits);
    limits.maxUniformBufferBindingSize = 65536;
    limits.maxStorageBufferBindingSize = 128_000_000;

    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = gpu.WGPUBufferBindingType_Undefined,
    };
    try testing.expectEqual(@as(u64, 65536), compute_commands.bindingBufferLimit(binding, limits));
}

test "bindingBufferLimit with zero uniform limit falls back to storage limit for undefined type" {
    var limits = std.mem.zeroes(types.WGPULimits);
    limits.maxUniformBufferBindingSize = 0;
    limits.maxStorageBufferBindingSize = 256_000_000;

    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = gpu.WGPUBufferBindingType_Undefined,
    };
    try testing.expectEqual(@as(u64, 256_000_000), compute_commands.bindingBufferLimit(binding, limits));
}

// ============================================================
// timestampReadbackStatus — error-to-message mapping

test "timestampReadbackStatus maps known errors to descriptive messages" {
    try testing.expectEqualStrings("gpu timestamp map timeout", compute_commands.timestampReadbackStatus(error.BufferMapTimeout));
    try testing.expectEqualStrings("gpu timestamp map failed", compute_commands.timestampReadbackStatus(error.BufferMapFailed));
    try testing.expectEqualStrings("gpu timestamp range invalid", compute_commands.timestampReadbackStatus(error.TimestampRangeInvalid));
    try testing.expectEqualStrings("gpu timestamp wait timed out", compute_commands.timestampReadbackStatus(error.WaitTimedOut));
}

test "timestampReadbackStatus falls back for unknown errors" {
    try testing.expectEqualStrings("gpu timestamp readback failed", compute_commands.timestampReadbackStatus(error.OutOfMemory));
}

// ============================================================
// NativeExecutionResult — default field values

test "NativeExecutionResult defaults timing fields to zero" {
    const result = types.NativeExecutionResult{
        .status = .ok,
        .status_message = "test",
    };
    try testing.expectEqual(@as(u64, 0), result.setup_ns);
    try testing.expectEqual(@as(u64, 0), result.encode_ns);
    try testing.expectEqual(@as(u64, 0), result.submit_wait_ns);
    try testing.expectEqual(@as(u32, 0), result.dispatch_count);
    try testing.expectEqual(@as(u64, 0), result.gpu_timestamp_ns);
    try testing.expect(!result.gpu_timestamp_attempted);
    try testing.expect(!result.gpu_timestamp_valid);
}

test "NativeExecutionResult preserves explicit timing values" {
    const result = types.NativeExecutionResult{
        .status = .ok,
        .status_message = "completed",
        .setup_ns = 1000,
        .encode_ns = 2000,
        .submit_wait_ns = 3000,
        .dispatch_count = 10,
        .gpu_timestamp_ns = 5000,
        .gpu_timestamp_attempted = true,
        .gpu_timestamp_valid = true,
    };
    try testing.expectEqual(@as(u64, 1000), result.setup_ns);
    try testing.expectEqual(@as(u64, 2000), result.encode_ns);
    try testing.expectEqual(@as(u64, 3000), result.submit_wait_ns);
    try testing.expectEqual(@as(u32, 10), result.dispatch_count);
    try testing.expectEqual(@as(u64, 5000), result.gpu_timestamp_ns);
    try testing.expect(result.gpu_timestamp_attempted);
    try testing.expect(result.gpu_timestamp_valid);
}

// ============================================================
// NativeExecutionStatus — variant coverage

test "NativeExecutionStatus has three variants" {
    const fields = @typeInfo(types.NativeExecutionStatus).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

// ============================================================
// KernelSource — struct initialization

test "KernelSource modes cover all lookup results" {
    const builtin_src = types.KernelSource{ .source = "fn main() {}", .owned = false, .mode = .builtin };
    const file_src = types.KernelSource{ .source = "fn main() {}", .owned = true, .mode = .file };
    const fallback_src = types.KernelSource{ .source = "fn main() {}", .owned = false, .mode = .fallback };

    try testing.expect(!builtin_src.owned);
    try testing.expect(file_src.owned);
    try testing.expect(!fallback_src.owned);
}

// ============================================================
// Command — union tag verification

test "Command union tag matches expected kind for upload" {
    const cmd = command.Command{ .upload = .{ .bytes = 1024, .align_bytes = 256 } };
    try testing.expectEqual(command.CommandKind.upload, std.meta.activeTag(cmd));
}

test "Command union tag matches expected kind for dispatch" {
    const cmd = command.Command{ .dispatch = .{ .x = 4, .y = 4, .z = 1 } };
    try testing.expectEqual(command.CommandKind.dispatch, std.meta.activeTag(cmd));
}

test "Command union tag matches expected kind for barrier" {
    const cmd = command.Command{ .barrier = .{ .dependency_count = 3 } };
    try testing.expectEqual(command.CommandKind.barrier, std.meta.activeTag(cmd));
}

test "Command union tag matches expected kind for kernel_dispatch" {
    const cmd = command.Command{ .kernel_dispatch = .{
        .kernel = "test.wgsl",
        .x = 16,
        .y = 1,
        .z = 1,
    } };
    try testing.expectEqual(command.CommandKind.kernel_dispatch, std.meta.activeTag(cmd));
}

test "Command union tag matches expected kind for copy_buffer_to_texture" {
    const cmd = command.Command{ .copy_buffer_to_texture = .{
        .direction = .buffer_to_buffer,
        .src = .{ .handle = 1 },
        .dst = .{ .handle = 2 },
        .bytes = 256,
    } };
    try testing.expectEqual(command.CommandKind.copy_buffer_to_texture, std.meta.activeTag(cmd));
}

test "Command union tag matches expected kind for map_async" {
    const cmd = command.Command{ .map_async = .{ .bytes = 4096 } };
    try testing.expectEqual(command.CommandKind.map_async, std.meta.activeTag(cmd));
}

// ============================================================
// CopyDirection — all directions are distinct

test "CopyDirection enum variants are distinct" {
    try testing.expect(resource_types.CopyDirection.buffer_to_buffer != resource_types.CopyDirection.buffer_to_texture);
    try testing.expect(resource_types.CopyDirection.buffer_to_texture != resource_types.CopyDirection.texture_to_buffer);
    try testing.expect(resource_types.CopyDirection.texture_to_buffer != resource_types.CopyDirection.texture_to_texture);
}

// ============================================================
// CopyCommand — default field values

test "CopyCommand defaults uses_temporary_buffer to false" {
    const cmd = resource_types.CopyCommand{
        .direction = .buffer_to_buffer,
        .src = .{ .handle = 1 },
        .dst = .{ .handle = 2 },
        .bytes = 1024,
    };
    try testing.expect(!cmd.uses_temporary_buffer);
    try testing.expectEqual(@as(u32, 0), cmd.temporary_buffer_alignment);
}

test "CopyCommand explicit temporary buffer fields" {
    const cmd = resource_types.CopyCommand{
        .direction = .buffer_to_texture,
        .src = .{ .handle = 1 },
        .dst = .{ .handle = 2, .width = 64, .height = 64, .depth_or_array_layers = 1 },
        .bytes = 16384,
        .uses_temporary_buffer = true,
        .temporary_buffer_alignment = 256,
    };
    try testing.expect(cmd.uses_temporary_buffer);
    try testing.expectEqual(@as(u32, 256), cmd.temporary_buffer_alignment);
}

// ============================================================
// KernelDispatchCommand — default values

test "KernelDispatchCommand defaults repeat to 1 and warmup to 0" {
    const cmd = compute.KernelDispatchCommand{
        .kernel = "test.wgsl",
        .x = 1,
        .y = 1,
        .z = 1,
    };
    try testing.expectEqual(@as(u32, 1), cmd.repeat);
    try testing.expectEqual(compute.KernelDispatchRepeatSynchronization.dependent, cmd.repeat_synchronization);
    try testing.expectEqual(@as(u32, 0), cmd.warmup_dispatch_count);
    try testing.expect(!cmd.initialize_buffers_on_create);
    try testing.expect(cmd.bindings == null);
    try testing.expect(cmd.entry_point == null);
}

// ============================================================
// KernelBinding — default values

test "KernelBinding defaults to compute visibility and whole-size" {
    const binding = compute.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 42,
    };
    try testing.expectEqual(@as(u32, 0), binding.group);
    try testing.expectEqual(gpu.WGPUShaderStage_Compute, binding.visibility);
    try testing.expectEqual(@as(u64, 0), binding.buffer_offset);
    try testing.expectEqual(gpu.WGPUWholeSize, binding.buffer_size);
    try testing.expectEqual(gpu.WGPUBufferBindingType_Undefined, binding.buffer_type);
}

// ============================================================
// CopyTextureResource — default values

test "CopyTextureResource defaults to 1x1x1 buffer resource" {
    const resource = resource_types.CopyTextureResource{ .handle = 1 };
    try testing.expectEqual(resource_types.CopyResourceKind.buffer, resource.kind);
    try testing.expectEqual(@as(u32, 1), resource.width);
    try testing.expectEqual(@as(u32, 1), resource.height);
    try testing.expectEqual(@as(u32, 1), resource.depth_or_array_layers);
    try testing.expectEqual(gpu.WGPUTextureFormat_Undefined, resource.format);
    try testing.expectEqual(@as(u64, 0), resource.offset);
    try testing.expectEqual(@as(u32, 0), resource.mip_level);
    try testing.expectEqual(@as(u32, 1), resource.sample_count);
}
