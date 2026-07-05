const backend_ids = @import("backend_ids.zig");

pub const BackendTelemetry = struct {
    backend_id: backend_ids.BackendId,
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
    // Apple Metal pipeline cache state and warmup telemetry. Populated by
    // backend_runtime_telemetry.refresh from the active Metal backend's
    // MTLBinaryArchive cache. `pipeline_cache_active` is true only when Doe's
    // Metal native runtime opened an MTLBinaryArchive; it is false on non-Mac
    // builds, when --no-pipeline-cache disabled init, AND when the active
    // backend is not Doe's Metal (e.g. dawn_delegate Metal goes through Dawn's
    // own backend and never opens Doe's archive). Surfaced into trace_meta and
    // the run-receipt's runtimeIdentity.pipelineCache for fair-cold lane
    // verification and cache-derived cost-savings quantification.
    pipeline_cache_active: bool = false,
    pipeline_cache_warmup_count: u64 = 0,
    pipeline_cache_warmup_ns: u64 = 0,
};

pub fn default_telemetry() BackendTelemetry {
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
        .queue_family_policy = null,
        .queue_family_kind = null,
        .queue_family_queue_count = null,
        .queue_family_timestamp_valid_bits = null,
        .queue_family_supports_graphics = null,
        .last_submit_count = null,
        .pipeline_cache_active = false,
        .pipeline_cache_warmup_count = 0,
        .pipeline_cache_warmup_ns = 0,
    };
}
