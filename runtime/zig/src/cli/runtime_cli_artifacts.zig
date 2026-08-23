const std = @import("std");
const backend_ids = @import("../contracts/backend.zig");
const execution = @import("../runtime/execution.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const numeric_stability = @import("../runtime/numeric_stability/mod.zig");
const operator_artifacts = @import("../runtime/trace/operator_artifacts.zig");
const quirk = @import("../quirk/mod.zig");
const trace = @import("../runtime/trace/trace.zig");
const trace_jsonl_emit = @import("../runtime/trace/trace_jsonl_emit.zig");

pub const BufferedTraceRow = trace_jsonl_emit.BufferedTraceRow;

pub const HostTimingTotals = struct {
    host_input_read_total_ns: u64 = 0,
    host_input_parse_total_ns: u64 = 0,
    host_workload_prepare_total_ns: u64 = 0,
    host_executor_init_total_ns: u64 = 0,
    host_upload_prewarm_total_ns: u64 = 0,
    host_kernel_prewarm_total_ns: u64 = 0,
};

pub const ArtifactFinalizeTotals = struct {
    host_artifact_finalize_total_ns: u64 = 0,
    host_artifact_trace_jsonl_serialize_total_ns: u64 = 0,
    host_artifact_trace_jsonl_write_total_ns: u64 = 0,
    host_artifact_operator_manifest_finalize_total_ns: u64 = 0,
};

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

pub fn initTraceSummary(
    command_count: u64,
    host_timing: HostTimingTotals,
    profile: model_profile.DeviceProfile,
    profile_vendor: []const u8,
    profile_family: ?[]const u8,
    profile_driver: []const u8,
    backend_lane: backend_ids.BackendLane,
    queue_wait_mode: execution.QueueWaitMode,
    webgpu_ffi_queue_wait_timeout_ns: u64,
    queue_sync_mode: execution.QueueSyncMode,
    quirk_mode: quirk.QuirkMode,
    execution_context: ?*execution.ExecutionContext,
) trace.TraceRunSummary {
    var summary = trace.TraceRunSummary{
        .trace_version = 1,
        .module_name = "doe-zig-runtime",
        .seq_max = 0,
        .row_count = 0,
        .command_count = command_count,
        .matched_count = 0,
        .blocking_count = 0,
        .requires_lean_count = 0,
        .lean_required_count = 0,
        .execution_row_count = 0,
        .execution_success_count = 0,
        .execution_error_count = 0,
        .execution_skipped_count = 0,
        .execution_unsupported_count = 0,
        .execution_total_ns = 0,
        .execution_setup_total_ns = 0,
        .execution_encode_total_ns = 0,
        .execution_submit_wait_total_ns = 0,
        .execution_dispatch_count = 0,
        .execution_submit_count = 0,
        .host_input_read_total_ns = host_timing.host_input_read_total_ns,
        .host_input_parse_total_ns = host_timing.host_input_parse_total_ns,
        .host_workload_prepare_total_ns = host_timing.host_workload_prepare_total_ns,
        .host_executor_init_total_ns = host_timing.host_executor_init_total_ns,
        .host_upload_prewarm_total_ns = host_timing.host_upload_prewarm_total_ns,
        .host_kernel_prewarm_total_ns = host_timing.host_kernel_prewarm_total_ns,
        .execution_gpu_timestamp_total_ns = 0,
        .execution_gpu_timestamp_attempted_count = 0,
        .execution_gpu_timestamp_valid_count = 0,
        .execution_backend = null,
        .final_hash = (trace.TraceState{}).previous_hash,
        .final_previous_hash = (trace.TraceState{}).previous_hash,
        .profile_vendor = profile_vendor,
        .profile_api = trace.apiName(profile.api),
        .profile_family = profile_family,
        .profile_driver = profile_driver,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .semantic_tracing_enabled = false,
        .semantic_op_row_count = 0,
        .semantic_capture_count = 0,
        .semantic_repro_count = 0,
        .operator_record_manifest_path = null,
        .operator_record_manifest_hash = null,
        .backend_lane = execution.backendLaneName(backend_lane),
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
        .queue_sync_mode = if (execution_context != null)
            execution.queueSyncModeName(queue_sync_mode)
        else
            null,
        .queue_wait_mode = if (execution_context != null)
            execution.queueWaitModeName(queue_wait_mode)
        else
            null,
        .quirk_mode = quirk_mode.name(),
    };

    if (execution_context) |ctx| {
        if (ctx.telemetry()) |selection| {
            summary.execution_backend = execution.backend_id_name(selection.backend_id);
            summary.backend_selection_reason = selection.backend_selection_reason;
            summary.fallback_used = selection.fallback_used;
            summary.selection_policy_hash = selection.selection_policy_hash;
            if (selection.backend_id == backend_ids.BackendId.dawn_delegate or
                selection.backend_id == backend_ids.BackendId.webkit_delegate)
            {
                summary.webgpu_ffi_queue_wait_timeout_ns = webgpu_ffi_queue_wait_timeout_ns;
            }
            summary.shader_artifact_manifest_path = selection.shader_artifact_manifest_path;
            summary.shader_artifact_manifest_hash = selection.shader_artifact_manifest_hash;
            summary.host_plan_artifact_path = selection.host_plan_artifact_path;
            summary.host_plan_artifact_hash = selection.host_plan_artifact_hash;
            if (selection.queue_family_policy) |policy| summary.queue_family_policy = policy;
            if (selection.queue_family_kind) |kind| summary.queue_family_kind = kind;
            if (selection.queue_family_queue_count) |queue_count| summary.queue_family_queue_count = queue_count;
            if (selection.queue_family_timestamp_valid_bits) |valid_bits| summary.queue_family_timestamp_valid_bits = valid_bits;
            if (selection.queue_family_supports_graphics) |supports_graphics| summary.queue_family_supports_graphics = supports_graphics;
        }
    }

    return summary;
}

pub fn finalizeArtifacts(
    allocator: std.mem.Allocator,
    emit_trace_jsonl: ?[]const u8,
    compact_upload_trace_row_totals: ?*std.ArrayList(u64),
    buffered_trace_rows: ?*std.ArrayList(BufferedTraceRow),
    artifact_recorder: *operator_artifacts.Recorder,
    numeric_stability_recorder: *numeric_stability.runtime.Recorder,
    trace_summary: *trace.TraceRunSummary,
) !ArtifactFinalizeTotals {
    const artifact_finalize_start_ns = nowNs();
    var totals = ArtifactFinalizeTotals{};

    if (emit_trace_jsonl) |path| {
        if (compact_upload_trace_row_totals) |rows| {
            if (rows.items.len > 0) {
                trace_summary.seq_max = 0;
                trace_summary.row_count = 1;
            }
            const previous_hash = (trace.TraceState{}).previous_hash;
            const compact_hash = trace_jsonl_emit.compactUploadTraceHash(rows.items, previous_hash);
            trace_summary.final_previous_hash = previous_hash;
            trace_summary.final_hash = compact_hash;
            const trace_jsonl_timing = try trace_jsonl_emit.writeCompactUploadTraceRows(
                allocator,
                path,
                "doe-zig-runtime",
                rows.items,
                compact_hash,
                previous_hash,
            );
            totals.host_artifact_trace_jsonl_serialize_total_ns = trace_jsonl_timing.serialize_ns;
            totals.host_artifact_trace_jsonl_write_total_ns = trace_jsonl_timing.write_ns;
        } else if (buffered_trace_rows) |rows| {
            const trace_jsonl_timing = try trace_jsonl_emit.writeBufferedTraceRows(allocator, path, rows.items);
            totals.host_artifact_trace_jsonl_serialize_total_ns = trace_jsonl_timing.serialize_ns;
            totals.host_artifact_trace_jsonl_write_total_ns = trace_jsonl_timing.write_ns;
        }
    }

    const operator_manifest_finalize_start_ns = nowNs();
    const artifact_summary = try artifact_recorder.finalize();
    totals.host_artifact_operator_manifest_finalize_total_ns = elapsedSince(operator_manifest_finalize_start_ns);
    totals.host_artifact_finalize_total_ns = elapsedSince(artifact_finalize_start_ns);

    trace_summary.semantic_op_row_count = artifact_summary.row_count;
    trace_summary.semantic_capture_count = artifact_summary.capture_count;
    trace_summary.semantic_repro_count = artifact_summary.repro_count;
    trace_summary.operator_record_manifest_path = artifact_summary.manifest_path;
    trace_summary.operator_record_manifest_hash = artifact_summary.manifest_hash;
    trace_summary.numeric_stability = numeric_stability_recorder.summary();

    return totals;
}
