const std = @import("std");
const dawn_plan_types = @import("dawn_plan_types.zig");
const plan_config = @import("webgpu_plan_executor_config.zig");
const plan_core = @import("webgpu_plan_executor_core.zig");
const plan_emit = @import("webgpu_plan_executor_emit.zig");
const support = @import("webgpu_plan_executor_support.zig");

const Allocator = std.mem.Allocator;

const DEFAULT_BACKEND_SELECTION_REASON = "queueWaitMode=process-events";
const DEFAULT_TIMING_SOURCE = "doe-execution-total-ns";
const DEFAULT_TIMING_CLASS = "operation";
const DEFAULT_SEMANTIC_STAGE = "webgpu_plan";
const DEFAULT_QUEUE_SYNC_MODE = "per-command";
const DEFAULT_SCHEMA = "webgpu_plan_executor";

const TRACE_EMIT_DEFAULTS = plan_emit.TraceEmitDefaults{
    .backend_selection_reason = DEFAULT_BACKEND_SELECTION_REASON,
    .timing_source = DEFAULT_TIMING_SOURCE,
    .timing_class = DEFAULT_TIMING_CLASS,
    .queue_sync_mode = DEFAULT_QUEUE_SYNC_MODE,
    .schema = DEFAULT_SCHEMA,
};

pub const Config = plan_config.RunOptions;
pub const executePlan = runPlan;

pub fn runPlan(allocator: Allocator, options: plan_config.RunOptions) !void {
    const start_ns = support.nowNs();
    const plan_read_start_ns = support.nowNs();
    const plan_bytes = try dawn_plan_types.readPlanBytes(allocator, options.plan_path);
    const host_input_read_total_ns = support.elapsedSince(plan_read_start_ns);
    defer allocator.free(plan_bytes);

    const plan_parse_start_ns = support.nowNs();
    var loaded = try dawn_plan_types.parsePlanBytes(allocator, plan_bytes);
    const host_input_parse_total_ns = support.elapsedSince(plan_parse_start_ns);
    defer loaded.deinit();

    if (!std.mem.eql(u8, loaded.plan.workload_id, options.workload_id)) return error.WorkloadMismatch;
    const workload_prepare_start_ns = support.nowNs();
    try validatePlanCounts(loaded.plan);
    var buffer_specs = try support.collectBufferSpecs(allocator, loaded.plan);
    defer buffer_specs.deinit();
    const kernel_root = try support.loadKernelRoot(allocator, loaded.plan.ir_path);
    const host_workload_prepare_total_ns = support.elapsedSince(workload_prepare_start_ns);
    defer allocator.free(kernel_root);

    var host_executor_init_total_ns: u64 = 0;
    var execute_wall_ns: u64 = 0;
    var resolved_identity: support.BackendIdentity = support.DAWN_IDENTITY;
    const results = if (options.dry_run) blk: {
        // For dry-run, resolve identity from override only (no library to probe)
        if (options.backend_id_override) |override| {
            if (std.mem.eql(u8, override, support.WEBKIT_BACKEND_ID)) {
                resolved_identity = support.WEBKIT_IDENTITY;
            }
        }
        break :blk try makeDryRunResults(allocator, loaded.plan, resolved_identity);
    } else blk: {
        const executed = try plan_core.executeLivePlan(
            allocator,
            &buffer_specs,
            options.backend_id_override,
            loaded.plan,
            kernel_root,
        );
        host_executor_init_total_ns = executed.host_executor_init_total_ns;
        execute_wall_ns = executed.execute_wall_ns;
        resolved_identity = executed.identity;
        break :blk executed.results;
    };
    defer allocator.free(results);

    var summary = summarize(results);
    summary.host_input_read_total_ns = host_input_read_total_ns;
    summary.host_input_parse_total_ns = host_input_parse_total_ns;
    summary.host_workload_prepare_total_ns = host_workload_prepare_total_ns;
    summary.host_executor_init_total_ns = host_executor_init_total_ns;
    if (execute_wall_ns > summary.total_ns) {
        summary.host_command_orchestration_total_ns = execute_wall_ns - summary.total_ns;
    }

    const artifact_finalize_start_ns = support.nowNs();
    try support.ensureParentDir(options.trace_meta_path);
    try support.ensureParentDir(options.trace_jsonl_path);
    try plan_emit.writeTraceJsonl(options.trace_jsonl_path, results);
    summary.host_artifact_finalize_total_ns = support.elapsedSince(artifact_finalize_start_ns);
    summary.process_wall_ns = support.elapsedSince(start_ns);
    try plan_emit.writeTraceMeta(
        options.trace_meta_path,
        loaded.plan,
        summary,
        options.plan_path,
        resolved_identity,
        TRACE_EMIT_DEFAULTS,
    );
}

fn validatePlanCounts(plan: dawn_plan_types.Plan) !void {
    var buffer_write_count: u32 = 0;
    var buffer_load_count: u32 = 0;
    var dispatch_count: u32 = 0;
    for (plan.commands) |command| {
        switch (command) {
            .buffer_write => buffer_write_count += 1,
            .buffer_load => buffer_load_count += 1,
            .kernel_dispatch => dispatch_count += 1,
        }
    }
    if (buffer_write_count != plan.buffer_write_count or
        buffer_load_count != plan.buffer_load_count or
        dispatch_count != plan.dispatch_count or
        plan.command_count != plan.commands.len)
    {
        return error.InvalidPlan;
    }
}

fn makeDryRunResults(allocator: Allocator, plan: dawn_plan_types.Plan, identity: support.BackendIdentity) ![]support.StepResult {
    const results = try allocator.alloc(support.StepResult, plan.commands.len);
    for (plan.commands, 0..) |command, idx| {
        const seq = @as(u64, idx);
        results[idx] = switch (command) {
            .buffer_write => support.StepResult{
                .seq = seq,
                .command_kind = "buffer_write",
                .kernel = null,
                .semantic_stage = DEFAULT_SEMANTIC_STAGE,
                .semantic_phase = "buffer_write",
                .status = "ok",
                .status_code = "dry_run",
                .status_message = "validation only",
                .timestamp_mono_ns = seq,
                .duration_ns = 0,
                .setup_ns = 0,
                .encode_ns = 0,
                .submit_wait_ns = 0,
                .dispatch_count = 0,
                .submit_count = 0,
                .execution_backend = identity.execution_backend,
                .backend_id = identity.backend_id,
                .backend_lane = identity.backend_lane,
                .plan_hash = plan.plan_sha256,
            },
            .buffer_load => support.StepResult{
                .seq = seq,
                .command_kind = "buffer_load",
                .kernel = null,
                .semantic_stage = DEFAULT_SEMANTIC_STAGE,
                .semantic_phase = "buffer_load",
                .status = "ok",
                .status_code = "dry_run",
                .status_message = "validation only",
                .timestamp_mono_ns = seq,
                .duration_ns = 0,
                .setup_ns = 0,
                .encode_ns = 0,
                .submit_wait_ns = 0,
                .dispatch_count = 0,
                .submit_count = 0,
                .execution_backend = identity.execution_backend,
                .backend_id = identity.backend_id,
                .backend_lane = identity.backend_lane,
                .plan_hash = plan.plan_sha256,
            },
            .kernel_dispatch => |kd| support.StepResult{
                .seq = seq,
                .command_kind = "kernel_dispatch",
                .kernel = kd.kernel,
                .semantic_stage = DEFAULT_SEMANTIC_STAGE,
                .semantic_phase = "kernel_dispatch",
                .status = "ok",
                .status_code = "dry_run",
                .status_message = "validation only",
                .timestamp_mono_ns = seq,
                .duration_ns = 0,
                .setup_ns = 0,
                .encode_ns = 0,
                .submit_wait_ns = 0,
                .dispatch_count = 1,
                .submit_count = 0,
                .execution_backend = identity.execution_backend,
                .backend_id = identity.backend_id,
                .backend_lane = identity.backend_lane,
                .plan_hash = plan.plan_sha256,
            },
        };
    }
    return results;
}

fn summarize(results: []const support.StepResult) support.RunSummary {
    var summary = support.RunSummary{};
    summary.row_count = results.len;
    summary.seq_max = if (results.len > 0) @as(u64, results.len - 1) else 0;
    summary.previous_hash = support.HASH_SEED;
    summary.final_hash = support.HASH_SEED;
    for (results) |result| {
        summary.total_ns += result.duration_ns;
        summary.setup_total_ns += result.setup_ns;
        summary.encode_total_ns += result.encode_ns;
        summary.submit_wait_total_ns += result.submit_wait_ns;
        summary.dispatch_count += result.dispatch_count;
        summary.submit_count += result.submit_count;
        if (std.mem.eql(u8, result.status_code, "dry_run") or std.mem.eql(u8, result.status_code, "ok")) {
            summary.success_count += 1;
        } else if (std.mem.eql(u8, result.status_code, "unsupported")) {
            summary.unsupported_count += 1;
        } else if (std.mem.eql(u8, result.status_code, "skipped")) {
            summary.skipped_count += 1;
        } else {
            summary.error_count += 1;
        }
    }
    return summary;
}
