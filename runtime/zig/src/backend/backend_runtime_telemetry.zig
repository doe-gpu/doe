const std = @import("std");
const builtin = @import("builtin");
const backend_iface = @import("backend_iface.zig");
const dawn_delegate_backend = @import("dawn_delegate_backend.zig");
const vulkan_backend = if (builtin.os.tag == .linux) @import("vulkan/mod.zig") else struct {};
const metal_backend = if (builtin.os.tag == .macos) @import("metal/mod.zig") else struct {};
const d3d12_backend = if (builtin.os.tag == .windows) @import("d3d12/mod.zig") else struct {};

/// Apple Metal pipeline cache opt-out, cross-platform-safe wrapper. No-op on
/// non-Mac builds. Called by cli/runtime_cli.zig when --no-pipeline-cache is
/// present; must be invoked *before* backend init so the cache init skip
/// check sees the flag set.
pub fn set_metal_pipeline_cache_disabled(disabled: bool) void {
    if (comptime builtin.os.tag == .macos) {
        metal_backend.set_pipeline_cache_disabled(disabled);
    } else {
        // Silence unused-parameter diagnostic on non-Mac builds; the flag
        // has no effect off Apple platforms.
        std.mem.doNotOptimizeAway(disabled);
    }
}

/// Doe Vulkan pipeline cache opt-out, cross-platform-safe wrapper. No-op on
/// non-Linux builds. Called by cli/runtime_cli.zig when --no-pipeline-cache is
/// present; must be invoked *before* backend init so the cache init skip
/// check in vk_pipeline_cache_persistent.create_process_pipeline_cache sees
/// the flag set.
pub fn set_vulkan_pipeline_cache_disabled(disabled: bool) void {
    if (comptime builtin.os.tag == .linux) {
        vulkan_backend.set_pipeline_cache_disabled(disabled);
    } else {
        std.mem.doNotOptimizeAway(disabled);
    }
}

/// Configure the Vulkan pipeline-cache disk directory. Empty slice disables
/// disk persistence; the cache then stays in-memory for the process lifetime.
/// Must be invoked *before* backend init (parallel to the disabled flag).
pub fn set_vulkan_pipeline_cache_dir(dir: []const u8) void {
    if (comptime builtin.os.tag == .linux) {
        vulkan_backend.set_pipeline_cache_dir(dir);
    } else {
        std.mem.doNotOptimizeAway(dir);
    }
}

pub fn refresh(backend: *backend_iface.BackendIface) void {
    switch (backend.id) {
        .doe_vulkan => {
            if (comptime builtin.os.tag == .linux) {
                backend.telemetry.shader_artifact_manifest_path = vulkan_backend.manifest_path_from_context(backend.context);
                backend.telemetry.shader_artifact_manifest_hash = vulkan_backend.manifest_hash_from_context(backend.context);
                backend.telemetry.adapter_ordinal = vulkan_backend.adapter_ordinal_from_context(backend.context);
                backend.telemetry.queue_family_index = vulkan_backend.queue_family_index_from_context(backend.context);
                backend.telemetry.present_capable = vulkan_backend.present_capable_from_context(backend.context);
                backend.telemetry.queue_family_policy = vulkan_backend.queue_family_policy_from_context(backend.context);
                backend.telemetry.queue_family_kind = vulkan_backend.queue_family_kind_from_context(backend.context);
                backend.telemetry.queue_family_queue_count = vulkan_backend.queue_family_queue_count_from_context(backend.context);
                backend.telemetry.queue_family_timestamp_valid_bits = vulkan_backend.queue_family_timestamp_valid_bits_from_context(backend.context);
                backend.telemetry.queue_family_supports_graphics = vulkan_backend.queue_family_supports_graphics_from_context(backend.context);
                const vulkan_cache_telemetry = vulkan_backend.pipeline_cache_warmup_telemetry_from_context(backend.context);
                backend.telemetry.pipeline_cache_warmup_count = vulkan_cache_telemetry.count;
                backend.telemetry.pipeline_cache_warmup_ns = vulkan_cache_telemetry.ns;
                backend.telemetry.pipeline_cache_active = vulkan_backend.pipeline_cache_active_from_context(backend.context);
                backend.telemetry.last_submit_count = vulkan_backend.last_submit_count_from_context(backend.context);
            }
        },
        .dawn_delegate, .webkit_delegate => {
            backend.telemetry.last_submit_count = dawn_delegate_backend.last_submit_count_from_context(backend.context);
        },
        .doe_metal => {
            if (comptime builtin.os.tag == .macos) {
                backend.telemetry.shader_artifact_manifest_path = metal_backend.manifest_path_from_context(backend.context);
                backend.telemetry.shader_artifact_manifest_hash = metal_backend.manifest_hash_from_context(backend.context);
                backend.telemetry.host_plan_artifact_path = metal_backend.host_plan_path_from_context(backend.context);
                backend.telemetry.host_plan_artifact_hash = metal_backend.host_plan_hash_from_context(backend.context);
                const cache_telemetry = metal_backend.pipeline_cache_warmup_telemetry_from_context(backend.context);
                backend.telemetry.pipeline_cache_warmup_count = cache_telemetry.count;
                backend.telemetry.pipeline_cache_warmup_ns = cache_telemetry.ns;
                backend.telemetry.pipeline_cache_active = metal_backend.pipeline_cache_active_from_context(backend.context);
                backend.telemetry.last_submit_count = metal_backend.last_submit_count_from_context(backend.context);
            }
        },
        .doe_d3d12 => {
            if (comptime builtin.os.tag == .windows) {
                backend.telemetry.shader_artifact_manifest_path = d3d12_backend.manifest_path_from_context(backend.context);
                backend.telemetry.shader_artifact_manifest_hash = d3d12_backend.manifest_hash_from_context(backend.context);
            }
        },
    }
}
