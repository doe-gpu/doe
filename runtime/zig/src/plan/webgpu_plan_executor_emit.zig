const std = @import("std");
const dawn_plan_types = @import("dawn_plan_types.zig");
const support = @import("webgpu_plan_executor_support.zig");

pub const TraceEmitDefaults = struct {
    backend_selection_reason: []const u8,
    timing_source: []const u8,
    timing_class: []const u8,
    queue_sync_mode: []const u8,
    schema: []const u8,
};

pub fn writeTraceMeta(
    path: []const u8,
    plan: dawn_plan_types.Plan,
    summary: support.RunSummary,
    plan_path: []const u8,
    identity: support.BackendIdentity,
    defaults: TraceEmitDefaults,
) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var writer = file.deprecatedWriter();
    const timing_ms = @as(f64, @floatFromInt(summary.total_ns)) / 1_000_000.0;
    const elapsed_ms = @as(f64, @floatFromInt(summary.process_wall_ns)) / 1_000_000.0;
    try writer.writeAll("{\"traceVersion\":1,\"module\":");
    try support.writeJsonString(&writer, support.DEFAULT_MODULE_NAME);
    try writer.print(",\"seqMax\":{},\"rowCount\":{},\"commandCount\":{},\"matchedCount\":0,\"blockingCount\":0,\"requiresLeanCount\":0,\"leanRequiredCount\":0,\"executionRowCount\":{},\"executionSuccessCount\":{},\"executionErrorCount\":{},\"executionSkippedCount\":{},\"executionUnsupportedCount\":{},\"executionTotalNs\":{},\"executionSetupTotalNs\":{},\"executionEncodeTotalNs\":{},\"executionSubmitWaitTotalNs\":{},\"executionDispatchCount\":{},\"executionSubmitCount\":{},\"hostInputReadTotalNs\":{},\"hostInputParseTotalNs\":{},\"hostWorkloadPrepareTotalNs\":{},\"hostExecutorInitTotalNs\":{},\"hostUploadPrewarmTotalNs\":{},\"hostKernelPrewarmTotalNs\":{},\"hostCommandOrchestrationTotalNs\":{},\"hostArtifactFinalizeTotalNs\":{},\"executionGpuTimestampTotalNs\":0,\"executionGpuTimestampAttemptedCount\":0,\"executionGpuTimestampValidCount\":0,\"semanticTracingEnabled\":false,\"semanticOpRowCount\":0,\"semanticCaptureCount\":0,\"semanticReproCount\":0,\"hash\":\"0x{x}\",\"previousHash\":\"0x{x}\",", .{
        summary.seq_max,
        summary.row_count,
        plan.command_count,
        summary.row_count,
        summary.success_count,
        summary.error_count,
        summary.skipped_count,
        summary.unsupported_count,
        summary.total_ns,
        summary.setup_total_ns,
        summary.encode_total_ns,
        summary.submit_wait_total_ns,
        summary.dispatch_count,
        summary.submit_count,
        summary.host_input_read_total_ns,
        summary.host_input_parse_total_ns,
        summary.host_workload_prepare_total_ns,
        summary.host_executor_init_total_ns,
        summary.host_upload_prewarm_total_ns,
        summary.host_kernel_prewarm_total_ns,
        summary.host_command_orchestration_total_ns,
        summary.host_artifact_finalize_total_ns,
        summary.final_hash,
        summary.previous_hash,
    });
    try writer.writeAll("\"executionBackend\":");
    try support.writeJsonString(&writer, identity.execution_backend);
    try writer.writeAll(",\"backendId\":");
    try support.writeJsonString(&writer, identity.backend_id);
    try writer.writeAll(",\"backendLane\":");
    try support.writeJsonString(&writer, identity.backend_lane);
    try writer.writeAll(",\"backendSelectionReason\":");
    try support.writeJsonString(&writer, defaults.backend_selection_reason);
    try writer.writeAll(",\"queueSyncMode\":");
    try support.writeJsonString(&writer, defaults.queue_sync_mode);
    try writer.writeAll(",\"hostPlanArtifactPath\":");
    try support.writeJsonString(&writer, plan_path);
    try writer.writeAll(",\"hostPlanArtifactHash\":");
    try support.writeJsonString(&writer, plan.plan_sha256);
    try writer.writeAll(",\"timingSource\":");
    try support.writeJsonString(&writer, defaults.timing_source);
    try writer.writeAll(",\"timingClass\":");
    try support.writeJsonString(&writer, defaults.timing_class);
    try writer.print(",\"timingMs\":{d},\"elapsedMs\":{d},\"processWallMs\":{d},\"schema\":", .{ timing_ms, elapsed_ms, elapsed_ms });
    try support.writeJsonString(&writer, defaults.schema);
    try writer.writeAll(",\"workload\":");
    try support.writeJsonString(&writer, plan.workload_id);
    try writer.writeAll(",\"profile\":{\"vendor\":");
    try support.writeJsonString(&writer, support.DEFAULT_PROFILE_VENDOR);
    try writer.writeAll(",\"api\":");
    try support.writeJsonString(&writer, support.DEFAULT_PROFILE_API);
    try writer.writeAll(",\"deviceFamily\":null,\"driver\":");
    try support.writeJsonString(&writer, identity.profile_driver);
    try writer.writeAll("}}\n");
}

pub fn writeTraceJsonl(path: []const u8, results: []const support.StepResult) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var writer = file.deprecatedWriter();
    var previous_hash = support.HASH_SEED;
    for (results) |result| {
        const hash = support.rowHash(previous_hash, result);
        var semantic_buf: [32]u8 = undefined;
        const semantic_op_id = support.semanticOpId(result.seq, &semantic_buf);
        try writer.writeAll("{\"traceVersion\":1,\"module\":");
        try support.writeJsonString(&writer, support.DEFAULT_MODULE_NAME);
        try writer.writeAll(",\"opCode\":");
        try support.writeJsonString(&writer, result.command_kind);
        try writer.print(",\"seq\":{},\"timestampMonoNs\":{},\"hash\":\"0x{x}\",\"previousHash\":\"0x{x}\",\"command\":", .{ result.seq, result.timestamp_mono_ns, hash, previous_hash });
        try support.writeJsonString(&writer, result.command_kind);
        try writer.writeAll(",\"semanticOpId\":");
        try support.writeJsonString(&writer, semantic_op_id);
        try writer.writeAll(",\"semanticStage\":");
        try support.writeJsonString(&writer, result.semantic_stage);
        try writer.writeAll(",\"semanticPhase\":");
        try support.writeJsonString(&writer, result.semantic_phase);
        try writer.writeAll(",\"semanticExecutionPlanHash\":");
        try support.writeJsonString(&writer, result.plan_hash);
        if (result.kernel) |kernel| {
            try writer.writeAll(",\"kernel\":");
            try support.writeJsonString(&writer, kernel);
        }
        try writer.writeAll(",\"executionBackend\":");
        try support.writeJsonString(&writer, result.execution_backend);
        try writer.writeAll(",\"backendId\":");
        try support.writeJsonString(&writer, result.backend_id);
        try writer.writeAll(",\"executionStatus\":");
        try support.writeJsonString(&writer, result.status);
        try writer.writeAll(",\"executionStatusCode\":");
        try support.writeJsonString(&writer, result.status_code);
        try writer.writeAll(",\"executionStatusMessage\":");
        try support.writeJsonString(&writer, result.status_message);
        try writer.writeAll(",\"executionBackendLane\":");
        try support.writeJsonString(&writer, result.backend_lane);
        try writer.print(",\"executionDurationNs\":{},\"executionSetupNs\":{},\"executionEncodeNs\":{},\"executionSubmitWaitNs\":{},\"executionDispatchCount\":{},\"executionSubmitCount\":{},\"executionGpuTimestampNs\":0,\"executionGpuTimestampAttempted\":false,\"executionGpuTimestampValid\":false}}\n", .{
            result.duration_ns,
            result.setup_ns,
            result.encode_ns,
            result.submit_wait_ns,
            result.dispatch_count,
            result.submit_count,
        });
        previous_hash = hash;
    }
}
