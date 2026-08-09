const std = @import("std");
const synthetic_assets = @import("synthetic_assets.zig");
const model_commands = @import("../contracts/command.zig");
const model_policy = @import("../contracts/model/model_policy.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const model_compute_types = @import("../contracts/model/model_compute_types.zig");
const model_gpu_types = @import("../contracts/model/model_binding_value_types.zig");
const execution = @import("../runtime/execution.zig");
const backend_policy = @import("../backend/backend_policy.zig");
const main_print = @import("../runtime/trace/command_output.zig");
const quirk = @import("../quirk/mod.zig");
const semantic_trace = @import("../contracts/semantic.zig");
const trace = @import("../runtime/trace/trace.zig");
const trace_jsonl_emit = @import("../runtime/trace/trace_jsonl_emit.zig");
const dawn_plan_types = @import("dawn_plan_types.zig");
const plan_validation = @import("plan_validation.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const SemVer = model_profile.SemVer;
    pub const WGPUBufferBindingType_Uniform = model_gpu_types.WGPUBufferBindingType_Uniform;
    pub const WGPUBufferBindingType_Storage = model_gpu_types.WGPUBufferBindingType_Storage;
    pub const WGPUBufferBindingType_ReadOnlyStorage = model_gpu_types.WGPUBufferBindingType_ReadOnlyStorage;
    pub const parse_api = model_policy.parse_api;
};

const Allocator = std.mem.Allocator;

const DEFAULT_MODULE_NAME = "doe-plan-executor";
const DEFAULT_EXECUTION_BACKEND = "doe_direct_plan";
const DEFAULT_SEMANTIC_STAGE = "runtime_plan";

pub const RunOptions = struct {
    plan_path: []const u8,
    trace_meta_path: []const u8,
    trace_jsonl_path: []const u8,
    workload_id: []const u8,
    vendor: []const u8 = "apple",
    api: []const u8 = "metal",
    family: ?[]const u8 = "m3",
    driver: []const u8 = "1.0.0",
    kernel_root: ?[]const u8 = null,
    backend_lane: ?[]const u8 = null,
    gpu_timestamp_mode: execution.GpuTimestampMode = .auto,
    queue_wait_mode: execution.QueueWaitMode = .process_events,
    queue_sync_mode: execution.QueueSyncMode = .per_command,
    upload_buffer_usage_mode: execution.UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = 1,
    dry_run: bool = false,
};

const ExecutablePayload = union(enum) {
    runtime: model.Command,
    buffer_load: dawn_plan_types.BufferLoadCommand,
};

const ExecutableCommand = struct {
    payload: ExecutablePayload,
    semantic_phase: []const u8,
};

const BufferedTraceRow = trace_jsonl_emit.BufferedTraceRow;

const TraceDecisionWrapper = struct {
    decision: quirk.runtime.DispatchDecision,
};

const EMPTY_DECISION = quirk.runtime.DispatchDecision{
    .matched_quirk_id = null,
    .action = null,
    .score = 0,
    .matched_count = 0,
    .requires_lean = false,
    .is_blocking = false,
    .proof_level = null,
    .verification_mode = null,
    .applied_toggle = null,
    .matched_scope = null,
    .matched_safety_class = null,
};

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try std.fs.cwd().makePath(dir);
}

fn semanticOpId(seq: usize, buffer: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "step-{d:0>6}", .{seq}) catch "step";
}

fn semanticContext(seq: usize, phase: []const u8, plan_hash: []const u8, op_id_buffer: *[32]u8) semantic_trace.SemanticContext {
    return .{
        .op_id = semanticOpId(seq, op_id_buffer),
        .stage = DEFAULT_SEMANTIC_STAGE,
        .phase = phase,
        .execution_plan_hash = plan_hash,
    };
}

fn parseBufferType(buffer_type: dawn_plan_types.BufferBindingType) u32 {
    return switch (buffer_type) {
        .uniform => model.WGPUBufferBindingType_Uniform,
        .storage => model.WGPUBufferBindingType_Storage,
        .read_only_storage => model.WGPUBufferBindingType_ReadOnlyStorage,
    };
}

fn lowerPlanCommands(allocator: Allocator, plan: dawn_plan_types.Plan) ![]ExecutableCommand {
    const commands = try allocator.alloc(ExecutableCommand, plan.commands.len);
    for (plan.commands, 0..) |plan_command, idx| {
        commands[idx] = switch (plan_command) {
            .buffer_write => |bw| .{
                .payload = .{
                    .runtime = .{
                        .buffer_write = .{
                            .handle = bw.handle,
                            .offset = bw.offset,
                            .buffer_size = bw.buffer_size,
                            .data = bw.data,
                        },
                    },
                },
                .semantic_phase = "buffer_write",
            },
            .buffer_load => |bl| .{
                .payload = .{ .buffer_load = bl },
                .semantic_phase = "buffer_load",
            },
            .kernel_dispatch => |kd| blk: {
                const bindings = try allocator.alloc(model.KernelBinding, kd.bindings.len);
                for (kd.bindings, 0..) |binding, binding_idx| {
                    bindings[binding_idx] = .{
                        .binding = binding.binding,
                        .group = binding.group,
                        .resource_kind = .buffer,
                        .resource_handle = binding.resource_handle,
                        .buffer_size = binding.buffer_size,
                        .buffer_type = parseBufferType(binding.buffer_type),
                    };
                }
                break :blk .{
                    .payload = .{
                        .runtime = .{
                            .kernel_dispatch = .{
                                .kernel = kd.kernel,
                                .entry_point = kd.entry_point,
                                .x = kd.x,
                                .y = kd.y,
                                .z = kd.z,
                                .initialize_buffers_on_create = kd.initialize_buffers_on_create,
                                .bindings = bindings,
                            },
                        },
                    },
                    .semantic_phase = "kernel_dispatch",
                };
            },
        };
    }
    return commands;
}

fn loadKernelRoot(allocator: Allocator, ir_path: []const u8, override_root: ?[]const u8) ![]const u8 {
    if (override_root) |value| return allocator.dupe(u8, value);
    const ir_bytes = std.fs.cwd().readFileAlloc(allocator, ir_path, 8 * 1024 * 1024) catch {
        return allocator.dupe(u8, "bench/inference-pipeline/kernels");
    };
    defer allocator.free(ir_bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), ir_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |object| {
            if (object.get("shared")) |shared| switch (shared) {
                .object => |shared_object| {
                    if (shared_object.get("kernelRoot")) |value| {
                        if (value == .string) return allocator.dupe(u8, value.string);
                    }
                },
                else => {},
            };
        },
        else => {},
    }
    return allocator.dupe(u8, "bench/inference-pipeline/kernels");
}

fn makeDryRunExecutionResult(dispatch_count: u32, backend_lane: backend_policy.BackendLane, plan_path: []const u8, plan_hash: []const u8) execution.ExecutionResult {
    return .{
        .backend = DEFAULT_EXECUTION_BACKEND,
        .status = .ok,
        .status_code = "dry_run",
        .duration_ns = 0,
        .setup_ns = 0,
        .encode_ns = 0,
        .submit_wait_ns = 0,
        .dispatch_count = dispatch_count,
        .submit_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = plan_path,
        .host_plan_artifact_hash = plan_hash,
        .backend_lane = execution.backendLaneName(backend_lane),
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
    };
}

fn executeBufferLoadWithSemantic(
    allocator: Allocator,
    ctx: *execution.ExecutionContext,
    command: dawn_plan_types.BufferLoadCommand,
    semantic: semantic_trace.SemanticContext,
) !execution.ExecutionResult {
    const load_start_ns = nowNs();
    const bytes = try synthetic_assets.readAssetBytes(
        allocator,
        command.cache_namespace,
        command.cache_key,
        command.byte_length,
    );
    defer allocator.free(bytes);
    const load_setup_ns = elapsedSince(load_start_ns);
    var result = try ctx.execute_buffer_write_bytes_with_semantic(
        command.handle,
        command.offset,
        command.buffer_size,
        bytes,
        semantic,
    );
    result.setup_ns += load_setup_ns;
    result.duration_ns += load_setup_ns;
    return result;
}

fn prewarmNativeExecutionBootstrap(ctx: *execution.ExecutionContext) !u64 {
    const prewarm_start_ns = nowNs();
    // Force backend/runtime submission bootstrap before the timed loop
    // without hoisting plan transfer work out of the measured row stream.
    try ctx.prewarmUploadPath(0);
    return elapsedSince(prewarm_start_ns);
}

pub fn runPlan(allocator: Allocator, options: RunOptions) !void {
    const plan_read_start_ns = nowNs();
    const plan_bytes = try dawn_plan_types.readPlanBytes(allocator, options.plan_path);
    const host_input_read_total_ns = elapsedSince(plan_read_start_ns);
    defer allocator.free(plan_bytes);

    const plan_parse_start_ns = nowNs();
    var loaded = try dawn_plan_types.parsePlanBytes(allocator, plan_bytes);
    const host_input_parse_total_ns = elapsedSince(plan_parse_start_ns);
    defer loaded.deinit();

    if (!std.mem.eql(u8, loaded.plan.workload_id, options.workload_id)) return error.WorkloadMismatch;

    const workload_prepare_start_ns = nowNs();
    try plan_validation.validateCounts(loaded.plan);
    const kernel_root = try loadKernelRoot(allocator, loaded.plan.ir_path, options.kernel_root);
    defer allocator.free(kernel_root);
    const executable_commands = try lowerPlanCommands(allocator, loaded.plan);
    const host_workload_prepare_total_ns = elapsedSince(workload_prepare_start_ns);

    const profile = model.DeviceProfile{
        .vendor = options.vendor,
        .api = try model.parse_api(options.api),
        .device_family = options.family,
        .driver_version = try model.SemVer.parse(options.driver),
    };
    const backend_lane = if (options.backend_lane) |raw_lane|
        (execution.parseBackendLane(raw_lane) orelse return error.InvalidCommandLine)
    else
        execution.defaultBackendLane(profile);

    var trace_state = trace.TraceState{};
    var trace_rows = try std.ArrayList(BufferedTraceRow).initCapacity(allocator, executable_commands.len);
    defer trace_rows.deinit(allocator);

    var trace_summary = trace.TraceRunSummary{
        .trace_version = 1,
        .module_name = DEFAULT_MODULE_NAME,
        .seq_max = 0,
        .row_count = 0,
        .command_count = @intCast(executable_commands.len),
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
        .host_input_read_total_ns = host_input_read_total_ns,
        .host_input_parse_total_ns = host_input_parse_total_ns,
        .host_workload_prepare_total_ns = host_workload_prepare_total_ns,
        .host_executor_init_total_ns = 0,
        .host_upload_prewarm_total_ns = 0,
        .host_kernel_prewarm_total_ns = 0,
        .host_command_orchestration_total_ns = 0,
        .host_artifact_finalize_total_ns = 0,
        .host_artifact_trace_jsonl_serialize_total_ns = 0,
        .host_artifact_trace_jsonl_write_total_ns = 0,
        .host_artifact_operator_manifest_finalize_total_ns = 0,
        .execution_gpu_timestamp_total_ns = 0,
        .execution_gpu_timestamp_attempted_count = 0,
        .execution_gpu_timestamp_valid_count = 0,
        .execution_backend = DEFAULT_EXECUTION_BACKEND,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = options.plan_path,
        .host_plan_artifact_hash = loaded.plan.plan_sha256,
        .semantic_tracing_enabled = true,
        .semantic_op_row_count = 0,
        .semantic_capture_count = 0,
        .semantic_repro_count = 0,
        .operator_record_manifest_path = null,
        .operator_record_manifest_hash = null,
        .backend_lane = execution.backendLaneName(backend_lane),
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
        .final_hash = trace_state.previous_hash,
        .final_previous_hash = trace_state.previous_hash,
        .profile_vendor = options.vendor,
        .profile_api = trace.apiName(profile.api),
        .profile_family = options.family,
        .profile_driver = options.driver,
        .queue_sync_mode = switch (options.queue_sync_mode) {
            .per_command => "per-command",
            .deferred => "deferred",
        },
        .quirk_mode = "off",
    };

    var host_executor_init_total_ns: u64 = 0;
    var execute_wall_ns: u64 = 0;
    var execution_context: ?execution.ExecutionContext = null;
    if (!options.dry_run) {
        const executor_init_start_ns = nowNs();
        execution_context = try execution.ExecutionContext.init(allocator, .native, profile, kernel_root, backend_lane);
        host_executor_init_total_ns = elapsedSince(executor_init_start_ns);
        if (execution_context) |*ctx| {
            ctx.configureUploadBehavior(options.upload_buffer_usage_mode, options.upload_submit_every);
            ctx.configureGpuTimestampMode(options.gpu_timestamp_mode);
            ctx.configureQueueWaitMode(options.queue_wait_mode);
            ctx.configureQueueSyncMode(options.queue_sync_mode);
            trace_summary.host_upload_prewarm_total_ns += try prewarmNativeExecutionBootstrap(ctx);
            if (ctx.telemetry()) |selection| {
                trace_summary.execution_backend = execution.backend_id_name(selection.backend_id);
                trace_summary.backend_selection_reason = selection.backend_selection_reason;
                trace_summary.fallback_used = selection.fallback_used;
                trace_summary.selection_policy_hash = selection.selection_policy_hash;
                trace_summary.shader_artifact_manifest_path = selection.shader_artifact_manifest_path;
                trace_summary.shader_artifact_manifest_hash = selection.shader_artifact_manifest_hash;
                if (selection.queue_family_policy) |policy| trace_summary.queue_family_policy = policy;
                if (selection.queue_family_kind) |kind| trace_summary.queue_family_kind = kind;
                if (selection.queue_family_queue_count) |queue_count| trace_summary.queue_family_queue_count = queue_count;
                if (selection.queue_family_timestamp_valid_bits) |valid_bits| trace_summary.queue_family_timestamp_valid_bits = valid_bits;
                if (selection.queue_family_supports_graphics) |supports_graphics| trace_summary.queue_family_supports_graphics = supports_graphics;
            }
        }
    }
    defer if (execution_context) |*ctx| ctx.deinit();
    trace_summary.host_executor_init_total_ns = host_executor_init_total_ns;

    const execute_start_ns = nowNs();
    var op_id_storage = try allocator.alloc([32]u8, executable_commands.len);
    defer allocator.free(op_id_storage);
    for (executable_commands, 0..) |item, idx| {
        const semantic = semanticContext(idx, item.semantic_phase, loaded.plan.plan_sha256, &op_id_storage[idx]);
        const command_label = switch (item.payload) {
            .runtime => |command| main_print.commandName(command),
            .buffer_load => "buffer_load",
        };
        const kernel_name = switch (item.payload) {
            .runtime => |command| main_print.commandKernel(command),
            .buffer_load => null,
        };
        const timestamp_ns = nowNs();
        const execution_result = if (execution_context) |*ctx| switch (item.payload) {
            .runtime => |command| try ctx.execute_with_semantic(command, semantic),
            .buffer_load => |command| try executeBufferLoadWithSemantic(allocator, ctx, command, semantic),
        } else switch (item.payload) {
            .runtime => |command| makeDryRunExecutionResult(
                switch (command) {
                    .kernel_dispatch => 1,
                    else => 0,
                },
                backend_lane,
                options.plan_path,
                loaded.plan.plan_sha256,
            ),
            .buffer_load => makeDryRunExecutionResult(0, backend_lane, options.plan_path, loaded.plan.plan_sha256),
        };

        trace_summary.execution_row_count += 1;
        trace_summary.execution_total_ns += execution_result.duration_ns;
        trace_summary.execution_setup_total_ns += execution_result.setup_ns;
        trace_summary.execution_encode_total_ns += execution_result.encode_ns;
        trace_summary.execution_submit_wait_total_ns += execution_result.submit_wait_ns;
        trace_summary.execution_dispatch_count += execution_result.dispatch_count;
        trace_summary.execution_submit_count += execution_result.submit_count;
        trace_summary.execution_gpu_timestamp_total_ns += execution_result.gpu_timestamp_ns;
        if (execution_result.gpu_timestamp_attempted) trace_summary.execution_gpu_timestamp_attempted_count += 1;
        if (execution_result.gpu_timestamp_valid) trace_summary.execution_gpu_timestamp_valid_count += 1;
        trace_summary.execution_backend = execution_result.backend;
        if (execution_result.backend_selection_reason) |reason| trace_summary.backend_selection_reason = reason;
        if (execution_result.fallback_used) |fallback| trace_summary.fallback_used = fallback;
        if (execution_result.selection_policy_hash) |hash| trace_summary.selection_policy_hash = hash;
        if (execution_result.shader_artifact_manifest_path) |path| trace_summary.shader_artifact_manifest_path = path;
        if (execution_result.shader_artifact_manifest_hash) |hash| trace_summary.shader_artifact_manifest_hash = hash;
        if (execution_result.host_plan_artifact_path) |path| trace_summary.host_plan_artifact_path = path;
        if (execution_result.host_plan_artifact_hash) |hash| trace_summary.host_plan_artifact_hash = hash;
        if (execution_result.backend_lane) |lane| trace_summary.backend_lane = lane;
        if (execution_result.adapter_ordinal) |ordinal| trace_summary.adapter_ordinal = ordinal;
        if (execution_result.queue_family_index) |queue_family_index| trace_summary.queue_family_index = queue_family_index;
        if (execution_result.present_capable) |present_capable| trace_summary.present_capable = present_capable;
        if (execution_result.queue_family_policy) |policy| trace_summary.queue_family_policy = policy;
        if (execution_result.queue_family_kind) |kind| trace_summary.queue_family_kind = kind;
        if (execution_result.queue_family_queue_count) |queue_count| trace_summary.queue_family_queue_count = queue_count;
        if (execution_result.queue_family_timestamp_valid_bits) |valid_bits| trace_summary.queue_family_timestamp_valid_bits = valid_bits;
        if (execution_result.queue_family_supports_graphics) |supports_graphics| trace_summary.queue_family_supports_graphics = supports_graphics;

        switch (execution_result.status) {
            .ok => trace_summary.execution_success_count += 1,
            .@"error" => trace_summary.execution_error_count += 1,
            .unsupported => trace_summary.execution_unsupported_count += 1,
            .skipped => trace_summary.execution_skipped_count += 1,
        }

        const previous_hash = trace_state.previous_hash;
        const row_hash = trace.tracePayloadHashWithSemantic(
            trace_state,
            idx,
            command_label,
            switch (item.payload) {
                .runtime => |command| command,
                .buffer_load => |command| .{
                    .buffer_write = .{
                        .handle = command.handle,
                        .offset = command.offset,
                        .buffer_size = command.buffer_size,
                        .data = @constCast(&[_]u32{}),
                    },
                },
            },
            kernel_name,
            semantic,
            TraceDecisionWrapper{ .decision = EMPTY_DECISION },
        );
        var buffered_row = BufferedTraceRow{
            .seq = idx,
            .command_label = command_label,
            .kernel_name = kernel_name,
            .semantic = semantic,
            .decision = EMPTY_DECISION,
            .timestamp_ns = timestamp_ns,
            .hash = row_hash,
            .previous_hash = previous_hash,
            .execution_result = execution_result,
        };
        try buffered_row.snapshotExecutionTelemetry();
        try trace_rows.append(allocator, buffered_row);
        trace_summary.seq_max = @intCast(idx);
        trace_summary.row_count += 1;
        trace_summary.final_previous_hash = previous_hash;
        trace_summary.final_hash = row_hash;
        trace_state.previous_hash = row_hash;
    }
    execute_wall_ns = elapsedSince(execute_start_ns);
    if (execute_wall_ns > trace_summary.execution_total_ns) {
        trace_summary.host_command_orchestration_total_ns = execute_wall_ns - trace_summary.execution_total_ns;
    }

    if (execution_context) |*ctx| {
        const flush_start_ns = nowNs();
        const flush_ns = try ctx.flushQueue();
        const flush_elapsed_ns = elapsedSince(flush_start_ns);
        if (flush_ns > 0 and trace_rows.items.len > 0) {
            const last_row = &trace_rows.items[trace_rows.items.len - 1];
            if (last_row.execution_result) |*exec| {
                exec.submit_wait_ns += flush_ns;
                exec.duration_ns += flush_ns;
            }
            trace_summary.execution_submit_wait_total_ns += flush_ns;
            trace_summary.execution_total_ns += flush_ns;
        }
        if (flush_elapsed_ns > flush_ns) {
            trace_summary.host_command_orchestration_total_ns += flush_elapsed_ns - flush_ns;
        }
    }

    const artifact_finalize_start_ns = nowNs();
    try ensureParentDir(options.trace_meta_path);
    try ensureParentDir(options.trace_jsonl_path);
    const trace_jsonl_timing = try trace_jsonl_emit.writeBufferedPlanTraceRows(
        allocator,
        options.trace_jsonl_path,
        DEFAULT_MODULE_NAME,
        trace_rows.items,
    );
    trace_summary.host_artifact_trace_jsonl_serialize_total_ns = trace_jsonl_timing.serialize_ns;
    trace_summary.host_artifact_trace_jsonl_write_total_ns = trace_jsonl_timing.write_ns;
    trace_summary.host_artifact_finalize_total_ns = elapsedSince(artifact_finalize_start_ns);
    try trace.writeTraceMeta(options.trace_meta_path, trace_summary);
}
