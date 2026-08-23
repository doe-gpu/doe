//! Backend-neutral runtime identity and observation snapshot.

const backend_contract = @import("backend.zig");

pub const RuntimeTelemetry = struct {
    backend_id: backend_contract.BackendId,
    backend_selection_reason: []const u8,
    fallback_used: bool,
    selection_policy_hash: []const u8,
    shader_artifact_manifest_path: ?[]const u8,
    shader_artifact_manifest_hash: ?[]const u8,
    host_plan_artifact_path: ?[]const u8,
    host_plan_artifact_hash: ?[]const u8,
    adapter_ordinal: ?u32,
    queue_family_index: ?u32,
    present_capable: ?bool,
    queue_family_policy: ?[]const u8 = null,
    queue_family_kind: ?[]const u8 = null,
    queue_family_queue_count: ?u32 = null,
    queue_family_timestamp_valid_bits: ?u32 = null,
    queue_family_supports_graphics: ?bool = null,
    last_submit_count: ?u32 = null,
    pipeline_cache_active: bool = false,
    pipeline_cache_warmup_count: u64 = 0,
    pipeline_cache_warmup_ns: u64 = 0,
};

pub fn defaultTelemetry() RuntimeTelemetry {
    return .{
        .backend_id = .dawn_delegate,
        .backend_selection_reason = "legacy_native_default",
        .fallback_used = false,
        .selection_policy_hash = "backend-runtime-policy-v7",
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
    };
}
