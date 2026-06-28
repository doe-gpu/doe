const std = @import("std");
const backend_runtime_telemetry = @import("../backend/backend_runtime_telemetry.zig");
const execution = @import("../execution.zig");
const main_print = @import("../main_print.zig");
const model_commands = @import("../model_commands.zig");
const model_policy = @import("../model_policy.zig");
const model_profile = @import("../model_profile.zig");
const numeric_stability = @import("../experimental/numeric_stability/mod.zig");
const operator_artifacts = @import("../operator_artifacts.zig");
const quirk = @import("../quirk/mod.zig");
const replay = @import("../replay.zig");
const tooling_io_context = @import("../tooling_io_context.zig");
const trace = @import("../trace.zig");
const runtime_cli_args = @import("runtime_cli_args.zig");
const runtime_cli_artifacts = @import("runtime_cli_artifacts.zig");
const runtime_cli_inputs = @import("runtime_cli_inputs.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const SemVer = model_profile.SemVer;
    pub const parse_api = model_policy.parse_api;
};

const BufferedTraceRow = runtime_cli_artifacts.BufferedTraceRow;

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

fn maxUploadBytes(commands: []const model.Command) u64 {
    var max_bytes: u64 = 0;
    for (commands) |command| {
        switch (command) {
            .upload => |upload| {
                if (upload.bytes > max_bytes) {
                    max_bytes = upload.bytes;
                }
            },
            .buffer_write => |buffer_write| {
                const bytes = std.mem.sliceAsBytes(buffer_write.data).len;
                if (bytes > max_bytes) max_bytes = bytes;
            },
            else => {},
        }
    }
    return max_bytes;
}

fn operatorArtifactAnchor(trace_meta_path: ?[]const u8, trace_jsonl_path: ?[]const u8) ?[]const u8 {
    return trace_meta_path orelse trace_jsonl_path;
}

fn prewarmKernelDispatches(ctx: *execution.ExecutionContext, commands: []const model.Command) void {
    for (commands) |command| {
        switch (command) {
            .kernel_dispatch => |kd| {
                ctx.prewarmKernelDispatch(
                    kd.kernel,
                    kd.entry_point,
                    kd.bindings,
                    kd.initialize_buffers_on_create,
                ) catch |err| {
                    std.debug.print("warn: runtime_cli: kernel dispatch prewarm: {s}\n", .{@errorName(err)});
                };
            },
            else => {},
        }
    }
}

fn executionRowTotalNs(executed: execution.ExecutionResult) u64 {
    const component_total_ns = executed.setup_ns +| executed.encode_ns +| executed.submit_wait_ns;
    if (component_total_ns > 0) {
        return @max(executed.duration_ns, component_total_ns);
    }
    return executed.duration_ns;
}

fn applyDeferredFlushToTraceRows(
    flush_ns: u64,
    compact_upload_trace_row_totals: ?*std.ArrayList(u64),
    buffered_trace_rows: ?*std.ArrayList(BufferedTraceRow),
) void {
    if (flush_ns == 0) return;
    if (compact_upload_trace_row_totals) |rows| {
        if (rows.items.len > 0) {
            rows.items[rows.items.len - 1] +|= flush_ns;
        }
    }
    if (buffered_trace_rows) |rows| {
        if (rows.items.len > 0) {
            const last_row = &rows.items[rows.items.len - 1];
            if (last_row.execution_result) |*exec| {
                exec.submit_wait_ns +|= flush_ns;
                exec.duration_ns +|= flush_ns;
            }
        }
    }
}

pub fn runCli() !void {
    const allocator = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const options = switch (try runtime_cli_args.parseArgs(argv, stdout)) {
        .run => |value| value,
        .exit_requested => return,
    };

    var load_result = try runtime_cli_inputs.loadWithIo(allocator, tooling_io_context.IoContext.sync(), options);
    defer load_result.inputs.deinit(allocator);

    const commands = load_result.inputs.commands;
    const command_metadata = load_result.inputs.command_metadata;
    const quirks = load_result.inputs.quirks;

    const command_repeat_usize = std.math.cast(usize, options.command_repeat) orelse {
        try trace.writef(stdout, "invalid --command-repeat value: {d}\n", .{options.command_repeat});
        return;
    };
    const physical_command_count = std.math.mul(u64, @as(u64, @intCast(commands.len)), @as(u64, options.command_repeat)) catch {
        try trace.writef(stdout, "invalid --command-repeat value: physical command count overflow\n", .{});
        return;
    };
    const physical_command_count_usize = std.math.cast(usize, physical_command_count) orelse {
        try trace.writef(stdout, "invalid --command-repeat value: physical command count overflow\n", .{});
        return;
    };

    var requires_numeric_stability = false;
    for (command_metadata) |metadata| {
        if (metadata.numeric_stability != null) {
            requires_numeric_stability = true;
            break;
        }
    }
    if (requires_numeric_stability and options.command_repeat > 1) {
        try trace.writef(stdout, "numeric-stability annotations do not support --command-repeat > 1\n", .{});
        return;
    }
    if (requires_numeric_stability and !options.execute) {
        try trace.writef(stdout, "numeric-stability annotations require --execute\n", .{});
        return;
    }
    if (requires_numeric_stability and options.backend_mode != .native) {
        try trace.writef(stdout, "numeric-stability annotations require --backend native\n", .{});
        return;
    }
    if (requires_numeric_stability and options.trace_meta_path == null) {
        try trace.writef(stdout, "numeric-stability annotations require --trace-meta\n", .{});
        return;
    }

    var host_timing = runtime_cli_artifacts.HostTimingTotals{
        .host_input_read_total_ns = load_result.timings.host_input_read_total_ns,
        .host_input_parse_total_ns = load_result.timings.host_input_parse_total_ns,
    };
    var host_command_orchestration_total_ns: u64 = 0;

    const profile_prepare_start_ns = nowNs();
    const profile = model.DeviceProfile{
        .vendor = options.profile_vendor,
        .api = try model.parse_api(options.profile_api),
        .device_family = options.profile_family,
        .driver_version = try model.SemVer.parse(options.profile_driver),
    };
    host_timing.host_workload_prepare_total_ns += elapsedSince(profile_prepare_start_ns);

    const backend_lane = if (options.backend_lane_value) |raw_lane| blk: {
        if (execution.parseBackendLane(raw_lane)) |lane| {
            break :blk lane;
        }
        try trace.writef(stdout, "invalid --backend-lane value: {s}\n", .{raw_lane});
        return;
    } else execution.defaultBackendLane(profile);

    if (options.emit_normalized) {
        var repeat_idx: usize = 0;
        var normalized_idx: usize = 0;
        while (repeat_idx < command_repeat_usize) : (repeat_idx += 1) {
            var command_idx: usize = 0;
            while (command_idx < commands.len) : (command_idx += 1) {
                try main_print.printNormalizedCommand(stdout, normalized_idx, commands[command_idx]);
                normalized_idx += 1;
            }
        }
        return;
    }

    const dispatch_context_start_ns = nowNs();
    var dispatch_context = try quirk.runtime.buildProfileDispatchContext(allocator, profile, quirks);
    host_timing.host_workload_prepare_total_ns += elapsedSince(dispatch_context_start_ns);
    defer dispatch_context.deinit();
    var trace_state = trace.TraceState{};

    if (options.execute and options.backend_mode == .trace) {
        try trace.writef(stdout, "cannot execute with backend=trace. use --backend native\n", .{});
        return;
    }

    var execution_context: ?execution.ExecutionContext = null;
    if (options.execute) {
        // Must be set BEFORE backend init so the Metal and Vulkan backends'
        // cache-init guards see the flag. Both wrappers are cross-platform-safe
        // no-ops outside their home platform.
        backend_runtime_telemetry.set_metal_pipeline_cache_disabled(options.no_pipeline_cache);
        backend_runtime_telemetry.set_vulkan_pipeline_cache_disabled(options.no_pipeline_cache);
        backend_runtime_telemetry.set_vulkan_pipeline_cache_dir(options.pipeline_cache_dir);
        const executor_init_start_ns = nowNs();
        execution_context = try execution.ExecutionContext.init(
            allocator,
            options.backend_mode,
            profile,
            options.kernel_root,
            backend_lane,
        );
        if (execution_context) |*ctx| {
            ctx.configureUploadBehavior(options.upload_buffer_usage_mode, options.upload_submit_every);
            ctx.configureGpuTimestampMode(options.gpu_timestamp_mode);
            ctx.configureQueueWaitMode(options.queue_wait_mode);
            ctx.configureWebgpuFfiQueueWaitTimeoutNs(options.webgpu_ffi_queue_wait_timeout_ns);
            ctx.configureQueueSyncMode(options.queue_sync_mode);
            host_timing.host_executor_init_total_ns += elapsedSince(executor_init_start_ns);

            const max_upload_bytes = maxUploadBytes(commands);
            if (max_upload_bytes > 0) {
                const upload_prewarm_start_ns = nowNs();
                try ctx.prewarmUploadPath(max_upload_bytes);
                host_timing.host_upload_prewarm_total_ns += elapsedSince(upload_prewarm_start_ns);
            }

            const kernel_prewarm_start_ns = nowNs();
            prewarmKernelDispatches(ctx, commands);
            host_timing.host_kernel_prewarm_total_ns += elapsedSince(kernel_prewarm_start_ns);
        } else {
            host_timing.host_executor_init_total_ns += elapsedSince(executor_init_start_ns);
        }
    }
    defer {
        if (execution_context) |*ctx| {
            ctx.deinit();
        }
    }

    const compact_upload_trace = blk: {
        if (options.emit_trace) break :blk false;
        if (options.emit_trace_jsonl == null) break :blk false;
        if (load_result.inputs.replay_expectations != null) break :blk false;
        if (physical_command_count_usize <= 1) break :blk false;
        for (commands) |command| {
            switch (command) {
                .upload => {},
                else => break :blk false,
            }
        }
        break :blk true;
    };

    var compact_upload_trace_row_totals: ?std.ArrayList(u64) = null;
    if (compact_upload_trace) {
        compact_upload_trace_row_totals = try std.ArrayList(u64).initCapacity(allocator, physical_command_count_usize);
    }
    defer if (compact_upload_trace_row_totals) |*rows| rows.deinit(allocator);

    var buffered_trace_rows: ?std.ArrayList(BufferedTraceRow) = null;
    if (options.emit_trace_jsonl != null and !compact_upload_trace) {
        buffered_trace_rows = try std.ArrayList(BufferedTraceRow).initCapacity(allocator, 0);
    }
    defer if (buffered_trace_rows) |*rows| rows.deinit(allocator);

    var artifact_recorder = try operator_artifacts.Recorder.init(
        allocator,
        operatorArtifactAnchor(options.trace_meta_path, options.emit_trace_jsonl),
    );
    defer artifact_recorder.deinit();
    var numeric_stability_recorder = try numeric_stability.runtime.Recorder.init(
        allocator,
        options.trace_meta_path,
        options.numeric_stability_policy_path,
        options.numeric_stability_execution_profile_id,
    );
    defer numeric_stability_recorder.deinit();

    var trace_summary = runtime_cli_artifacts.initTraceSummary(
        physical_command_count,
        host_timing,
        profile,
        options.profile_vendor,
        options.profile_family,
        options.profile_driver,
        backend_lane,
        options.queue_wait_mode,
        options.webgpu_ffi_queue_wait_timeout_ns,
        options.queue_sync_mode,
        options.quirk_mode,
        if (execution_context) |*ctx| ctx else null,
    );

    const command_loop_start_ns = nowNs();
    var repeat_idx: usize = 0;
    var physical_idx: usize = 0;
    command_loop: while (repeat_idx < command_repeat_usize) : (repeat_idx += 1) {
        var idx: usize = 0;
        while (idx < commands.len) : (idx += 1) {
            const command = commands[idx];
            const metadata = command_metadata[idx];
            const physical_command_index = physical_idx;
            physical_idx += 1;
            if (metadata.semantic.present()) {
                trace_summary.semantic_tracing_enabled = true;
            }
            const result = quirk.dispatchWithMode(options.quirk_mode, profile, dispatch_context, command);
            const target = result.command;
            const kernel_name = main_print.commandKernel(target);
            const command_label = main_print.commandName(target);
            const timestamp_ns: u64 = @intCast(std.time.nanoTimestamp());
            var execute_result: ?execution.ExecutionResult = null;
            const emit_trace_payload = options.emit_trace or
                (buffered_trace_rows != null) or
                (options.trace_meta_path != null) or
                (load_result.inputs.replay_expectations != null);

            if (execution_context) |*ctx| {
                const executed = try ctx.execute_with_semantic(target, metadata.semantic);
                execute_result = executed;
                trace_summary.execution_row_count += 1;
                trace_summary.execution_total_ns += executed.duration_ns;
                trace_summary.execution_setup_total_ns += executed.setup_ns;
                trace_summary.execution_encode_total_ns += executed.encode_ns;
                trace_summary.execution_submit_wait_total_ns += executed.submit_wait_ns;
                trace_summary.execution_dispatch_count += @as(u64, executed.dispatch_count);
                trace_summary.execution_submit_count += @as(u64, executed.submit_count);
                trace_summary.execution_gpu_timestamp_total_ns += executed.gpu_timestamp_ns;
                if (executed.gpu_timestamp_attempted) trace_summary.execution_gpu_timestamp_attempted_count += 1;
                if (executed.gpu_timestamp_valid) trace_summary.execution_gpu_timestamp_valid_count += 1;
                trace_summary.execution_backend = executed.backend;
                if (executed.backend_selection_reason) |reason| trace_summary.backend_selection_reason = reason;
                if (executed.fallback_used) |fallback| trace_summary.fallback_used = fallback;
                if (executed.selection_policy_hash) |hash| trace_summary.selection_policy_hash = hash;
                if (executed.shader_artifact_manifest_path) |path| trace_summary.shader_artifact_manifest_path = path;
                if (executed.shader_artifact_manifest_hash) |hash| trace_summary.shader_artifact_manifest_hash = hash;
                if (executed.host_plan_artifact_path) |path| trace_summary.host_plan_artifact_path = path;
                if (executed.host_plan_artifact_hash) |hash| trace_summary.host_plan_artifact_hash = hash;
                if (executed.backend_lane) |lane| trace_summary.backend_lane = lane;
                if (executed.adapter_ordinal) |ordinal| trace_summary.adapter_ordinal = ordinal;
                if (executed.queue_family_index) |queue_family_index| trace_summary.queue_family_index = queue_family_index;
                if (executed.present_capable) |present_capable| trace_summary.present_capable = present_capable;
                if (executed.queue_family_policy) |policy| trace_summary.queue_family_policy = policy;
                if (executed.queue_family_kind) |kind| trace_summary.queue_family_kind = kind;
                if (executed.queue_family_queue_count) |queue_count| trace_summary.queue_family_queue_count = queue_count;
                if (executed.queue_family_timestamp_valid_bits) |valid_bits| trace_summary.queue_family_timestamp_valid_bits = valid_bits;
                if (executed.queue_family_supports_graphics) |supports_graphics| trace_summary.queue_family_supports_graphics = supports_graphics;
                switch (executed.status) {
                    .ok => trace_summary.execution_success_count += 1,
                    .@"error" => trace_summary.execution_error_count += 1,
                    .unsupported => trace_summary.execution_unsupported_count += 1,
                    .skipped => trace_summary.execution_skipped_count += 1,
                }
            }

            if (result.decision.matched_quirk_id != null) {
                trace_summary.matched_count += 1;
                if (result.decision.verification_mode) |mode| {
                    if (mode == .lean_required) trace_summary.lean_required_count += 1;
                }
            }
            if (result.decision.requires_lean) trace_summary.requires_lean_count += 1;
            if (result.decision.is_blocking) trace_summary.blocking_count += 1;

            if (compact_upload_trace) {
                if (execute_result) |executed| {
                    if (compact_upload_trace_row_totals) |*rows| {
                        try rows.append(allocator, executionRowTotalNs(executed));
                    }
                }
            } else if (emit_trace_payload) {
                const previous_hash = trace_state.previous_hash;
                const semantic_hash = trace.tracePayloadHashWithSemantic(
                    trace_state,
                    physical_command_index,
                    command_label,
                    target,
                    kernel_name,
                    metadata.semantic,
                    result,
                );
                if (load_result.inputs.replay_expectations) |expectation_set| {
                    const expectations = expectation_set.expectations;
                    if (physical_command_index >= expectations.len) return replay.ReplayValidationError.ReplayMissingRow;
                    const expected = expectations[physical_command_index];
                    if (expected.seq != physical_command_index) return replay.ReplayValidationError.ReplaySeqMismatch;
                    if (!std.mem.eql(u8, expected.command, command_label)) return replay.ReplayValidationError.ReplayCommandMismatch;
                    if (!replay.matchOptionalText(expected.kernel, kernel_name)) return replay.ReplayValidationError.ReplayKernelMismatch;
                    if (expected.previous_hash != previous_hash) return replay.ReplayValidationError.ReplayPreviousHashMismatch;
                    if (expected.hash != semantic_hash) return replay.ReplayValidationError.ReplayHashMismatch;
                }
                if (options.emit_trace) {
                    try trace.printTraceLineWithSemantic(
                        stdout,
                        physical_command_index,
                        command_label,
                        kernel_name,
                        metadata.semantic,
                        result,
                        @intCast(timestamp_ns),
                        semantic_hash,
                        trace_state.previous_hash,
                        execute_result,
                    );
                }
                if (buffered_trace_rows) |*rows| {
                    try rows.append(allocator, .{
                        .seq = physical_command_index,
                        .command_label = command_label,
                        .kernel_name = kernel_name,
                        .semantic = metadata.semantic,
                        .decision = result.decision,
                        .timestamp_ns = @intCast(timestamp_ns),
                        .hash = semantic_hash,
                        .previous_hash = trace_state.previous_hash,
                        .execution_result = execute_result,
                    });
                }
                try artifact_recorder.record(
                    if (execution_context) |*ctx| ctx else null,
                    .{
                        .source_index = physical_command_index,
                        .command = target,
                        .command_label = command_label,
                        .kernel_name = kernel_name,
                        .semantic = metadata.semantic,
                        .capture = metadata.capture,
                        .execution_result = execute_result,
                        .profile_vendor = options.profile_vendor,
                        .profile_api = trace.apiName(profile.api),
                        .profile_family = options.profile_family,
                        .profile_driver = options.profile_driver,
                        .trace_hash = semantic_hash,
                        .trace_previous_hash = trace_state.previous_hash,
                        .trace_meta_path = options.trace_meta_path,
                    },
                );
                if (execute_result) |executed| {
                    if (executed.status == .ok) {
                        if (execution_context) |*ctx| {
                            const numeric_outcome = try numeric_stability_recorder.record(
                                ctx,
                                target,
                                metadata.semantic,
                                metadata.numeric_stability,
                                commands[idx + 1 ..],
                                command_metadata[idx + 1 ..],
                                .{
                                    .profile_vendor = options.profile_vendor,
                                    .profile_api = trace.apiName(profile.api),
                                    .profile_family = options.profile_family,
                                    .profile_driver = options.profile_driver,
                                    .execution_result = executed,
                                },
                            );
                            if (numeric_outcome.should_stop_downstream) {
                                trace_summary.execution_skipped_count += @as(u32, @intCast(physical_command_count_usize - physical_idx));
                                break :command_loop;
                            }
                        }
                    }
                }
                trace_summary.seq_max = @intCast(physical_command_index);
                trace_summary.row_count += 1;
                trace_summary.final_previous_hash = trace_state.previous_hash;
                trace_summary.final_hash = semantic_hash;
                trace_state.previous_hash = semantic_hash;
            } else if (result.decision.matched_quirk_id) |id| {
                try stdout.print(
                    "cmd[{d}] matched={s} verification={s} proof={s} requiresLean={} blocking={} score={} matched_count={d}\\n",
                    .{
                        physical_command_index,
                        id,
                        trace.verificationModeName(result.decision.verification_mode),
                        trace.proofLevelName(result.decision.proof_level),
                        result.decision.requires_lean,
                        result.decision.is_blocking,
                        result.decision.score,
                        result.decision.matched_count,
                    },
                );
            } else {
                try stdout.print("cmd[{d}] matched=<none> score=0 matched_count={d}\\n", .{ physical_command_index, result.decision.matched_count });
            }
            if (!emit_trace_payload) try main_print.printCommandSummary(stdout, target, execute_result);
        }
    }

    const command_loop_wall_ns = elapsedSince(command_loop_start_ns);
    if (command_loop_wall_ns > trace_summary.execution_total_ns) {
        host_command_orchestration_total_ns = command_loop_wall_ns - trace_summary.execution_total_ns;
    }

    if (execution_context) |*ctx| {
        const needs_explicit_drain = options.queue_sync_mode == .deferred or
            options.upload_submit_every > 1 or
            std.mem.eql(u8, trace_summary.execution_backend orelse "", "doe_vulkan");
        if (needs_explicit_drain) {
            const flush_start_ns = nowNs();
            const flush_ns = try ctx.flushQueue();
            const flush_elapsed_ns = elapsedSince(flush_start_ns);
            if (flush_ns > 0) {
                applyDeferredFlushToTraceRows(
                    flush_ns,
                    if (compact_upload_trace_row_totals) |*rows| rows else null,
                    if (buffered_trace_rows) |*rows| rows else null,
                );
                trace_summary.execution_submit_wait_total_ns += flush_ns;
                trace_summary.execution_total_ns += flush_ns;
            }
            if (flush_elapsed_ns > flush_ns) {
                host_command_orchestration_total_ns += flush_elapsed_ns - flush_ns;
            }
        }
    }

    const artifact_totals = try runtime_cli_artifacts.finalizeArtifacts(
        allocator,
        options.emit_trace_jsonl,
        if (compact_upload_trace_row_totals) |*rows| rows else null,
        if (buffered_trace_rows) |*rows| rows else null,
        &artifact_recorder,
        &numeric_stability_recorder,
        &trace_summary,
    );
    trace_summary.host_command_orchestration_total_ns = host_command_orchestration_total_ns;
    trace_summary.host_artifact_finalize_total_ns = artifact_totals.host_artifact_finalize_total_ns;
    trace_summary.host_artifact_trace_jsonl_serialize_total_ns = artifact_totals.host_artifact_trace_jsonl_serialize_total_ns;
    trace_summary.host_artifact_trace_jsonl_write_total_ns = artifact_totals.host_artifact_trace_jsonl_write_total_ns;
    trace_summary.host_artifact_operator_manifest_finalize_total_ns = artifact_totals.host_artifact_operator_manifest_finalize_total_ns;

    if (options.trace_meta_path) |path| {
        // Apple Metal pipeline cache state + warmup telemetry (zero/disabled on
        // non-Mac builds and on non-Metal backends). Routed through the
        // standard backend telemetry surface so the cli/ -> backend/metal/
        // import-fence boundary stays clean. State (enabled/disabled) and
        // reason (cli-flag/default/platform-unsupported) are derived inside
        // writeTraceMeta from this bool plus builtin.os.tag.
        trace_summary.pipeline_cache_disabled = options.no_pipeline_cache;
        if (execution_context) |*ctx_ref| {
            if (ctx_ref.telemetry()) |snapshot| {
                trace_summary.pipeline_cache_active = snapshot.pipeline_cache_active;
                trace_summary.pipeline_cache_warmup_count = snapshot.pipeline_cache_warmup_count;
                trace_summary.pipeline_cache_warmup_ns = snapshot.pipeline_cache_warmup_ns;
            }
        }
        try trace.writeTraceMeta(path, trace_summary);
    }
    if (load_result.inputs.replay_expectations) |expectation_set| {
        const expectations = expectation_set.expectations;
        if (expectations.len != physical_command_count_usize) {
            return replay.ReplayValidationError.ReplayRowCountMismatch;
        }
    }
}
