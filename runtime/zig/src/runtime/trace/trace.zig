const std = @import("std");
const builtin = @import("builtin");
const model_commands = @import("../../contracts/model/model_commands.zig");
const model_policy = @import("../../contracts/model/model_policy.zig");
const model_quirks = @import("../../contracts/model/model_quirks.zig");
const execution = @import("../execution.zig");
const semantic_trace = @import("semantic_trace.zig");
const trace_text = @import("trace_text.zig");
const trace_determinism = @import("trace_determinism.zig");
const numeric_stability = @import("../../experimental/numeric_stability/mod.zig");

const model = struct {
    pub const Api = model_policy.Api;
    pub const Command = model_commands.Command;
    pub const ProofLevel = model_policy.ProofLevel;
    pub const QuirkAction = model_quirks.QuirkAction;
    pub const SafetyClass = model_policy.SafetyClass;
    pub const Scope = model_policy.Scope;
    pub const VerificationMode = model_policy.VerificationMode;
    pub const command_kind = model_commands.command_kind;
    pub const proof_level_name = model_policy.proof_level_name;
    pub const safety_class_name = model_policy.safety_class_name;
    pub const scope_name = model_policy.scope_name;
    pub const verification_mode_name = model_policy.verification_mode_name;
};

pub const TraceState = struct {
    previous_hash: u64 = 0x9e3779b97f4a7c15,
};

pub const TraceRunSummary = struct {
    trace_version: u8,
    module_name: []const u8,
    seq_max: u64,
    row_count: u64,
    command_count: u64,
    matched_count: u64,
    blocking_count: u64,
    requires_lean_count: u64,
    lean_required_count: u64,
    execution_row_count: u64,
    execution_success_count: u64,
    execution_error_count: u64,
    execution_skipped_count: u64,
    execution_unsupported_count: u64,
    execution_total_ns: u64,
    execution_setup_total_ns: u64,
    execution_encode_total_ns: u64,
    execution_submit_wait_total_ns: u64,
    execution_dispatch_count: u64,
    execution_submit_count: u64,
    host_input_read_total_ns: u64 = 0,
    host_input_parse_total_ns: u64 = 0,
    host_workload_prepare_total_ns: u64 = 0,
    host_executor_init_total_ns: u64 = 0,
    host_upload_prewarm_total_ns: u64 = 0,
    host_kernel_prewarm_total_ns: u64 = 0,
    host_command_orchestration_total_ns: u64 = 0,
    host_artifact_finalize_total_ns: u64 = 0,
    host_artifact_trace_jsonl_serialize_total_ns: u64 = 0,
    host_artifact_trace_jsonl_write_total_ns: u64 = 0,
    host_artifact_operator_manifest_finalize_total_ns: u64 = 0,
    execution_gpu_timestamp_total_ns: u64,
    execution_gpu_timestamp_attempted_count: u64,
    execution_gpu_timestamp_valid_count: u64,
    execution_backend: ?[]const u8,
    backend_selection_reason: ?[]const u8,
    fallback_used: ?bool,
    selection_policy_hash: ?[]const u8,
    shader_artifact_manifest_path: ?[]const u8,
    shader_artifact_manifest_hash: ?[]const u8,
    host_plan_artifact_path: ?[]const u8 = null,
    host_plan_artifact_hash: ?[]const u8 = null,
    semantic_tracing_enabled: bool = false,
    semantic_op_row_count: u64 = 0,
    semantic_capture_count: u64 = 0,
    semantic_repro_count: u64 = 0,
    operator_record_manifest_path: ?[]const u8 = null,
    operator_record_manifest_hash: ?[]const u8 = null,
    backend_lane: ?[]const u8,
    adapter_ordinal: ?u32 = null,
    queue_family_index: ?u32 = null,
    present_capable: ?bool = null,
    queue_family_policy: ?[]const u8 = null,
    queue_family_kind: ?[]const u8 = null,
    queue_family_queue_count: ?u32 = null,
    queue_family_timestamp_valid_bits: ?u32 = null,
    queue_family_supports_graphics: ?bool = null,
    final_hash: u64,
    final_previous_hash: u64,
    profile_vendor: []const u8,
    profile_api: []const u8,
    profile_family: ?[]const u8,
    profile_driver: []const u8,
    queue_wait_mode: ?[]const u8 = null,
    webgpu_ffi_queue_wait_timeout_ns: ?u64 = null,
    queue_sync_mode: ?[]const u8 = null,
    quirk_mode: ?[]const u8 = null,
    determinism: ?trace_determinism.TraceDeterminismSummary = null,
    numeric_stability: ?numeric_stability.trace_meta.TraceNumericStabilitySummary = null,
    // Apple Metal pipeline cache state and warmup telemetry. `pipeline_cache_
    // active` is populated by backend_runtime_telemetry.refresh from the active
    // Metal backend's process-level cache pointer; it is true only when Doe's
    // Metal native runtime opened an MTLBinaryArchive. `pipeline_cache_disabled`
    // reflects the --no-pipeline-cache CLI choice. The state/reason pair
    // emitted into trace_meta is derived from BOTH (see writeTraceMeta below)
    // so a dawn_delegate Metal run reports state=disabled reason=non-doe-backend
    // even when the CLI flag is absent. See bench/lib/metal_pipeline_cache_
    // manifest.py for the reader and CLAUDE.md non-negotiable #7 (hardware-
    // path asymmetry).
    pipeline_cache_active: bool = false,
    pipeline_cache_disabled: bool = false,
    pipeline_cache_warmup_count: u64 = 0,
    pipeline_cache_warmup_ns: u64 = 0,
};

pub const writef = trace_text.writef;

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try trace_text.writeJsonString(writer, value);
}

pub fn normalizeExecutionStatusCode(
    message: []const u8,
    fallback: []const u8,
    buffer: *[160]u8,
) []const u8 {
    return trace_text.normalizeExecutionStatusCode(message, fallback, buffer);
}

pub fn actionName(action: ?model.QuirkAction) []const u8 {
    const actual = action orelse return "none";
    return @tagName(actual);
}

pub fn scopeName(value: ?model.Scope) []const u8 {
    const scope = value orelse return "none";
    return model.scope_name(scope);
}

pub fn safetyClassName(value: ?model.SafetyClass) []const u8 {
    const safety = value orelse return "none";
    return model.safety_class_name(safety);
}

pub fn proofLevelName(value: ?model.ProofLevel) []const u8 {
    const proof = value orelse return "none";
    return model.proof_level_name(proof);
}

pub fn verificationModeName(value: ?model.VerificationMode) []const u8 {
    const mode = value orelse return "none";
    return model.verification_mode_name(mode);
}

pub fn apiName(value: model.Api) []const u8 {
    return @tagName(value);
}

fn traceHashByte(value: u64, byte: u8) u64 {
    return (value ^ @as(u64, byte)) *% 1099511628211;
}

fn traceHashBytes(value: u64, bytes: []const u8) u64 {
    var state = value;
    for (bytes) |byte| {
        state = traceHashByte(state, byte);
    }
    return state;
}

fn traceHashU64(value: u64, input: u64) u64 {
    return traceHashBytes(value, std.mem.asBytes(&input));
}

fn traceHashBool(value: u64, input: bool) u64 {
    return traceHashByte(value, if (input) 1 else 0);
}

fn traceHashStr(value: u64, input: ?[]const u8) u64 {
    if (input) |text| {
        return traceHashBytes(value, text);
    }
    return traceHashByte(value, 0);
}

fn traceHashOptionalU32(value: u64, input: ?u32) u64 {
    if (input) |number| {
        return traceHashU64(value, number);
    }
    return traceHashByte(value, 0);
}

pub fn commandToTag(command: model.Command) []const u8 {
    return switch (command) {
        .upload => "upload",
        .buffer_write => "buffer_write",
        .copy_buffer_to_texture => "copy_buffer_to_texture",
        .barrier => "barrier",
        .dispatch => "dispatch",
        .dispatch_indirect => "dispatch_indirect",
        .kernel_dispatch => "kernel_dispatch",
        .render_draw => "render_draw",
        .draw_indirect => "draw_indirect",
        .draw_indexed_indirect => "draw_indexed_indirect",
        .render_pass => "render_pass",
        .sampler_create => "sampler_create",
        .sampler_destroy => "sampler_destroy",
        .texture_write => "texture_write",
        .texture_query => "texture_query",
        .texture_destroy => "texture_destroy",
        .surface_create => "surface_create",
        .surface_capabilities => "surface_capabilities",
        .surface_configure, .surface_acquire, .surface_present, .surface_unconfigure, .surface_release => "frame",
        .async_diagnostics => "diagnostics",
        .map_async => "sync",
    };
}

pub fn tracePayloadHash(
    state: TraceState,
    seq: usize,
    command_label: []const u8,
    command: model.Command,
    kernel_name: ?[]const u8,
    result: anytype,
) u64 {
    return tracePayloadHashWithSemantic(state, seq, command_label, command, kernel_name, .{}, result);
}

pub fn tracePayloadHashWithSemantic(
    state: TraceState,
    seq: usize,
    command_label: []const u8,
    command: model.Command,
    kernel_name: ?[]const u8,
    semantic: semantic_trace.SemanticContext,
    result: anytype,
) u64 {
    var next = state.previous_hash;
    next = traceHashU64(next, @as(u64, seq));
    next = traceHashStr(next, command_label);
    next = traceHashStr(next, commandToTag(command));
    next = traceHashStr(next, kernel_name);
    next = traceHashStr(next, result.decision.matched_quirk_id);
    next = traceHashStr(next, result.decision.applied_toggle);
    next = traceHashStr(next, scopeName(result.decision.matched_scope));
    next = traceHashStr(next, safetyClassName(result.decision.matched_safety_class));
    next = traceHashStr(next, verificationModeName(result.decision.verification_mode));
    next = traceHashStr(next, proofLevelName(result.decision.proof_level));
    next = traceHashStr(next, actionName(result.decision.action));
    next = traceHashStr(next, semantic.op_id);
    next = traceHashStr(next, semantic.stage);
    next = traceHashStr(next, semantic.phase);
    next = traceHashOptionalU32(next, semantic.token_index);
    next = traceHashOptionalU32(next, semantic.layer_index);
    next = traceHashStr(next, semantic.execution_plan_hash);
    next = traceHashU64(next, result.decision.score);
    next = traceHashU64(next, result.decision.matched_count);
    next = traceHashBool(next, result.decision.requires_lean);
    next = traceHashBool(next, result.decision.is_blocking);
    return next;
}

pub fn printTraceLine(
    stdout: anytype,
    seq: usize,
    command_label: []const u8,
    kernel_name: ?[]const u8,
    result: anytype,
    timestamp_ns: u64,
    hash: u64,
    previous_hash: u64,
    maybe_execution: ?execution.ExecutionResult,
) !void {
    return printTraceLineWithSemantic(stdout, seq, command_label, kernel_name, .{}, result, timestamp_ns, hash, previous_hash, maybe_execution);
}

pub fn printTraceLineWithSemantic(
    stdout: anytype,
    seq: usize,
    command_label: []const u8,
    kernel_name: ?[]const u8,
    semantic: semantic_trace.SemanticContext,
    result: anytype,
    timestamp_ns: u64,
    hash: u64,
    previous_hash: u64,
    maybe_execution: ?execution.ExecutionResult,
) !void {
    try writef(
        stdout,
        "{{\"traceVersion\":1,\"module\":\"doe-zig-runtime\",\"opCode\":\"dispatch\",\"seq\":{},\"timestampMonoNs\":{},\"hash\":\"0x{x}\",\"previousHash\":\"0x{x}\",\"command\":",
        .{
            seq,
            timestamp_ns,
            hash,
            previous_hash,
        },
    );
    try writeJsonString(stdout, command_label);
    try stdout.writeByte(',');

    if (kernel_name) |kernel| {
        try stdout.writeAll("\"kernel\":");
        try writeJsonString(stdout, kernel);
        try stdout.writeByte(',');
    }

    if (semantic.op_id) |value| {
        try stdout.writeAll("\"semanticOpId\":");
        try writeJsonString(stdout, value);
        try stdout.writeByte(',');
    }
    if (semantic.stage) |value| {
        try stdout.writeAll("\"semanticStage\":");
        try writeJsonString(stdout, value);
        try stdout.writeByte(',');
    }
    if (semantic.phase) |value| {
        try stdout.writeAll("\"semanticPhase\":");
        try writeJsonString(stdout, value);
        try stdout.writeByte(',');
    }
    if (semantic.token_index) |value| {
        try writef(stdout, "\"semanticTokenIndex\":{},", .{value});
    }
    if (semantic.layer_index) |value| {
        try writef(stdout, "\"semanticLayerIndex\":{},", .{value});
    }
    if (semantic.execution_plan_hash) |value| {
        try stdout.writeAll("\"semanticExecutionPlanHash\":");
        try writeJsonString(stdout, value);
        try stdout.writeByte(',');
    }

    if (result.decision.matched_quirk_id) |quirk| {
        try stdout.writeAll("\"matched\":");
        try writeJsonString(stdout, quirk);
        try stdout.writeByte(',');
    } else {
        try stdout.writeAll("\"matched\":null,");
    }

    try stdout.writeAll("\"scope\":");
    try writeJsonString(stdout, scopeName(result.decision.matched_scope));
    try stdout.writeAll(",\"safetyClass\":");
    try writeJsonString(stdout, safetyClassName(result.decision.matched_safety_class));
    try stdout.writeAll(",\"verificationMode\":");
    try writeJsonString(stdout, verificationModeName(result.decision.verification_mode));
    try stdout.writeAll(",\"proofLevel\":");
    try writeJsonString(stdout, proofLevelName(result.decision.proof_level));
    try writef(
        stdout,
        ",\"requiresLean\":{},\"blocking\":{},\"score\":{},\"matched_count\":{},\"action\":",
        .{
            result.decision.requires_lean,
            result.decision.is_blocking,
            result.decision.score,
            result.decision.matched_count,
        },
    );
    try writeJsonString(stdout, actionName(result.decision.action));
    try stdout.writeAll(",\"toggle\":");
    try writeJsonString(stdout, result.decision.applied_toggle orelse "none");

    if (maybe_execution) |exec| {
        var status_code_buffer: [160]u8 = undefined;
        const status_name = execution.executionStatusName(exec.status);
        const status_code = normalizeExecutionStatusCode(
            exec.status_code,
            status_name,
            &status_code_buffer,
        );
        try stdout.writeAll(",\"executionBackend\":");
        try writeJsonString(stdout, exec.backend);
        try stdout.writeAll(",\"backendId\":");
        try writeJsonString(stdout, exec.backend);
        if (exec.backend_lane) |value| {
            try stdout.writeAll(",\"executionBackendLane\":");
            try writeJsonString(stdout, value);
        }
        try stdout.writeAll(",\"executionStatus\":");
        try writeJsonString(stdout, status_name);
        try stdout.writeAll(",\"executionStatusCode\":");
        try writeJsonString(stdout, status_code);
        try stdout.writeAll(",\"executionStatusMessage\":");
        try writeJsonString(stdout, exec.status_code);
        try writef(
            stdout,
            ",\"executionDurationNs\":{},\"executionSetupNs\":{},\"executionEncodeNs\":{},\"executionSubmitWaitNs\":{},\"executionDispatchCount\":{},\"executionSubmitCount\":{},\"executionGpuTimestampNs\":{},\"executionGpuTimestampAttempted\":{},\"executionGpuTimestampValid\":{}",
            .{
                exec.duration_ns,
                exec.setup_ns,
                exec.encode_ns,
                exec.submit_wait_ns,
                exec.dispatch_count,
                exec.submit_count,
                exec.gpu_timestamp_ns,
                exec.gpu_timestamp_attempted,
                exec.gpu_timestamp_valid,
            },
        );
        if (exec.selection_policy_hash) |value| {
            try stdout.writeAll(",\"executionSelectionPolicyHash\":");
            try writeJsonString(stdout, value);
        }
        if (exec.shader_artifact_manifest_path) |value| {
            try stdout.writeAll(",\"executionShaderArtifactManifestPath\":");
            try writeJsonString(stdout, value);
        }
        if (exec.shader_artifact_manifest_hash) |value| {
            try stdout.writeAll(",\"executionShaderArtifactManifestHash\":");
            try writeJsonString(stdout, value);
        }
        if (exec.host_plan_artifact_path) |value| {
            try stdout.writeAll(",\"executionHostPlanArtifactPath\":");
            try writeJsonString(stdout, value);
        }
        if (exec.host_plan_artifact_hash) |value| {
            try stdout.writeAll(",\"executionHostPlanArtifactHash\":");
            try writeJsonString(stdout, value);
        }
        if (exec.adapter_ordinal) |value| {
            try writef(stdout, ",\"executionAdapterOrdinal\":{}", .{value});
        }
        if (exec.queue_family_index) |value| {
            try writef(stdout, ",\"executionQueueFamilyIndex\":{}", .{value});
        }
        if (exec.present_capable) |value| {
            try writef(stdout, ",\"executionPresentCapable\":{}", .{value});
        }
        if (exec.queue_family_policy) |value| {
            try stdout.writeAll(",\"executionQueueFamilyPolicy\":");
            try writeJsonString(stdout, value);
        }
        if (exec.queue_family_kind) |value| {
            try stdout.writeAll(",\"executionQueueFamilyKind\":");
            try writeJsonString(stdout, value);
        }
        if (exec.queue_family_queue_count) |value| {
            try writef(stdout, ",\"executionQueueFamilyQueueCount\":{}", .{value});
        }
        if (exec.queue_family_timestamp_valid_bits) |value| {
            try writef(stdout, ",\"executionQueueFamilyTimestampValidBits\":{}", .{value});
        }
        if (exec.queue_family_supports_graphics) |value| {
            try writef(stdout, ",\"executionQueueFamilySupportsGraphics\":{}", .{value});
        }
    }

    try writef(stdout, "}}\n", .{});
}

// --- Inline tests ---

test "traceHashByte is deterministic for same inputs" {
    const a = traceHashByte(0x9e3779b97f4a7c15, 42);
    const b = traceHashByte(0x9e3779b97f4a7c15, 42);
    try std.testing.expectEqual(a, b);
}

test "traceHashByte differs for different bytes" {
    const a = traceHashByte(0x9e3779b97f4a7c15, 0);
    const b = traceHashByte(0x9e3779b97f4a7c15, 1);
    try std.testing.expect(a != b);
}

test "traceHashBytes produces chained result matching sequential traceHashByte" {
    const input = "abc";
    const chained = traceHashBytes(0x9e3779b97f4a7c15, input);
    var manual: u64 = 0x9e3779b97f4a7c15;
    manual = traceHashByte(manual, 'a');
    manual = traceHashByte(manual, 'b');
    manual = traceHashByte(manual, 'c');
    try std.testing.expectEqual(manual, chained);
}

test "traceHashStr hashes null as single zero byte" {
    const from_null = traceHashStr(0x9e3779b97f4a7c15, null);
    const from_zero_byte = traceHashByte(0x9e3779b97f4a7c15, 0);
    try std.testing.expectEqual(from_zero_byte, from_null);
}

test "traceHashStr with value differs from null" {
    const from_null = traceHashStr(0x9e3779b97f4a7c15, null);
    const from_value = traceHashStr(0x9e3779b97f4a7c15, "hello");
    try std.testing.expect(from_null != from_value);
}

test "traceHashBool encodes true as 1 and false as 0" {
    const from_true = traceHashBool(0x9e3779b97f4a7c15, true);
    const from_false = traceHashBool(0x9e3779b97f4a7c15, false);
    const from_byte_1 = traceHashByte(0x9e3779b97f4a7c15, 1);
    const from_byte_0 = traceHashByte(0x9e3779b97f4a7c15, 0);
    try std.testing.expectEqual(from_byte_1, from_true);
    try std.testing.expectEqual(from_byte_0, from_false);
}

test "normalizeExecutionStatusCode lowercases and replaces non-alnum with underscores" {
    var buf: [160]u8 = undefined;
    const result = normalizeExecutionStatusCode("Hello World!", "fallback", &buf);
    try std.testing.expectEqualStrings("hello_world", result);
}

test "normalizeExecutionStatusCode collapses consecutive separators" {
    var buf: [160]u8 = undefined;
    const result = normalizeExecutionStatusCode("a---b", "fallback", &buf);
    try std.testing.expectEqualStrings("a_b", result);
}

test "normalizeExecutionStatusCode uses fallback when message is empty" {
    var buf: [160]u8 = undefined;
    const result = normalizeExecutionStatusCode("", "my_fallback", &buf);
    try std.testing.expectEqualStrings("my_fallback", result);
}

test "normalizeExecutionStatusCode strips trailing underscores" {
    var buf: [160]u8 = undefined;
    const result = normalizeExecutionStatusCode("trailing!!!", "fb", &buf);
    try std.testing.expectEqualStrings("trailing", result);
}

test "normalizeExecutionStatusCode returns fallback verbatim when all chars are separators" {
    var buf: [160]u8 = undefined;
    const result = normalizeExecutionStatusCode("!!!", "fallback_code", &buf);
    try std.testing.expectEqualStrings("fallback_code", result);
}

test "actionName returns correct strings for all variants and null" {
    try std.testing.expectEqualStrings("none", actionName(null));
    try std.testing.expectEqualStrings("no_op", actionName(.no_op));
    const toggle_action = model.QuirkAction{ .toggle = .{ .toggle_name = "test_toggle" } };
    try std.testing.expectEqualStrings("toggle", actionName(toggle_action));
}

test "scopeName returns none for null and correct name for values" {
    try std.testing.expectEqualStrings("none", scopeName(null));
    try std.testing.expectEqualStrings("barrier", scopeName(.barrier));
    try std.testing.expectEqualStrings("memory", scopeName(.memory));
}

test "safetyClassName returns none for null and correct name for values" {
    try std.testing.expectEqualStrings("none", safetyClassName(null));
    try std.testing.expectEqualStrings("critical", safetyClassName(.critical));
    try std.testing.expectEqualStrings("low", safetyClassName(.low));
}

test "verificationModeName returns none for null and correct name for values" {
    try std.testing.expectEqualStrings("none", verificationModeName(null));
    try std.testing.expectEqualStrings("lean_required", verificationModeName(.lean_required));
}

test "proofLevelName returns none for null and correct name for values" {
    try std.testing.expectEqualStrings("none", proofLevelName(null));
    try std.testing.expectEqualStrings("proven", proofLevelName(.proven));
    try std.testing.expectEqualStrings("rejected", proofLevelName(.rejected));
}

test "apiName returns correct string for each Api variant" {
    try std.testing.expectEqualStrings("vulkan", apiName(.vulkan));
    try std.testing.expectEqualStrings("metal", apiName(.metal));
    try std.testing.expectEqualStrings("d3d12", apiName(.d3d12));
    try std.testing.expectEqualStrings("webgpu", apiName(.webgpu));
}

test "commandToTag maps command variants to expected tags" {
    const upload_cmd = model.Command{ .upload = .{ .bytes = 0, .align_bytes = 0 } };
    try std.testing.expectEqualStrings("upload", commandToTag(upload_cmd));

    const barrier_cmd = model.Command{ .barrier = .{ .dependency_count = 1 } };
    try std.testing.expectEqualStrings("barrier", commandToTag(barrier_cmd));

    const diag_cmd = model.Command{ .async_diagnostics = .{} };
    try std.testing.expectEqualStrings("diagnostics", commandToTag(diag_cmd));

    const map_cmd = model.Command{ .map_async = .{ .bytes = 64 } };
    try std.testing.expectEqualStrings("sync", commandToTag(map_cmd));
}

test "writeJsonString escapes special characters correctly" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try writeJsonString(writer, "hello\"world\\end\nnew\ttab");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\"hello\\\"world\\\\end\\nnew\\ttab\"", result);
}

test "writeJsonString escapes control characters as unicode escapes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try writeJsonString(writer, &[_]u8{0x01});
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\"\\u0001\"", result);
}

test "TraceState default previous_hash is golden ratio constant" {
    const state = TraceState{};
    try std.testing.expectEqual(@as(u64, 0x9e3779b97f4a7c15), state.previous_hash);
}

pub fn writeTraceMeta(path: []const u8, summary: TraceRunSummary) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var writer = file.deprecatedWriter();

    try writef(writer, "{{\"traceVersion\":{},\"module\":", .{summary.trace_version});
    try writeJsonString(&writer, summary.module_name);
    try writef(writer, ",\"seqMax\":{},\"rowCount\":{},\"commandCount\":{},\"matchedCount\":{},\"blockingCount\":{},\"requiresLeanCount\":{},\"leanRequiredCount\":{},\"executionRowCount\":{},\"executionSuccessCount\":{},\"executionErrorCount\":{},\"executionSkippedCount\":{},\"executionUnsupportedCount\":{},\"executionTotalNs\":{},\"executionSetupTotalNs\":{},\"executionEncodeTotalNs\":{},\"executionSubmitWaitTotalNs\":{},\"executionDispatchCount\":{},\"executionSubmitCount\":{},", .{
        summary.seq_max,
        summary.row_count,
        summary.command_count,
        summary.matched_count,
        summary.blocking_count,
        summary.requires_lean_count,
        summary.lean_required_count,
        summary.execution_row_count,
        summary.execution_success_count,
        summary.execution_error_count,
        summary.execution_skipped_count,
        summary.execution_unsupported_count,
        summary.execution_total_ns,
        summary.execution_setup_total_ns,
        summary.execution_encode_total_ns,
        summary.execution_submit_wait_total_ns,
        summary.execution_dispatch_count,
        summary.execution_submit_count,
    });
    try writef(writer, "\"hostInputReadTotalNs\":{},\"hostInputParseTotalNs\":{},\"hostWorkloadPrepareTotalNs\":{},\"hostExecutorInitTotalNs\":{},\"hostUploadPrewarmTotalNs\":{},\"hostKernelPrewarmTotalNs\":{},\"hostCommandOrchestrationTotalNs\":{},\"hostArtifactFinalizeTotalNs\":{},\"hostArtifactTraceJsonlSerializeTotalNs\":{},\"hostArtifactTraceJsonlWriteTotalNs\":{},\"hostArtifactOperatorManifestFinalizeTotalNs\":{},\"executionGpuTimestampTotalNs\":{},\"executionGpuTimestampAttemptedCount\":{},\"executionGpuTimestampValidCount\":{},\"semanticTracingEnabled\":{},\"semanticOpRowCount\":{},\"semanticCaptureCount\":{},\"semanticReproCount\":{},\"hash\":\"0x{x}\",\"previousHash\":\"0x{x}\",", .{
        summary.host_input_read_total_ns,
        summary.host_input_parse_total_ns,
        summary.host_workload_prepare_total_ns,
        summary.host_executor_init_total_ns,
        summary.host_upload_prewarm_total_ns,
        summary.host_kernel_prewarm_total_ns,
        summary.host_command_orchestration_total_ns,
        summary.host_artifact_finalize_total_ns,
        summary.host_artifact_trace_jsonl_serialize_total_ns,
        summary.host_artifact_trace_jsonl_write_total_ns,
        summary.host_artifact_operator_manifest_finalize_total_ns,
        summary.execution_gpu_timestamp_total_ns,
        summary.execution_gpu_timestamp_attempted_count,
        summary.execution_gpu_timestamp_valid_count,
        summary.semantic_tracing_enabled,
        summary.semantic_op_row_count,
        summary.semantic_capture_count,
        summary.semantic_repro_count,
        summary.final_hash,
        summary.final_previous_hash,
    });
    if (summary.execution_backend) |backend| {
        try writer.writeAll("\"executionBackend\":");
        try writeJsonString(&writer, backend);
        try writer.writeAll(",");
        try writer.writeAll("\"backendId\":");
        try writeJsonString(&writer, backend);
        try writer.writeAll(",");
    }
    if (summary.backend_selection_reason) |reason| {
        try writer.writeAll("\"backendSelectionReason\":");
        try writeJsonString(&writer, reason);
        try writer.writeAll(",");
    }
    if (summary.fallback_used) |fallback| {
        try writef(writer, "\"fallbackUsed\":{},", .{fallback});
    }
    if (summary.selection_policy_hash) |hash| {
        try writer.writeAll("\"selectionPolicyHash\":");
        try writeJsonString(&writer, hash);
        try writer.writeAll(",");
    }
    if (summary.shader_artifact_manifest_path) |manifest_path| {
        try writer.writeAll("\"shaderArtifactManifestPath\":");
        try writeJsonString(&writer, manifest_path);
        try writer.writeAll(",");
    }
    if (summary.shader_artifact_manifest_hash) |hash| {
        try writer.writeAll("\"shaderArtifactManifestHash\":");
        try writeJsonString(&writer, hash);
        try writer.writeAll(",");
    }
    if (summary.host_plan_artifact_path) |artifact_path| {
        try writer.writeAll("\"hostPlanArtifactPath\":");
        try writeJsonString(&writer, artifact_path);
        try writer.writeAll(",");
    }
    if (summary.host_plan_artifact_hash) |hash| {
        try writer.writeAll("\"hostPlanArtifactHash\":");
        try writeJsonString(&writer, hash);
        try writer.writeAll(",");
    }
    if (summary.operator_record_manifest_path) |manifest_path| {
        try writer.writeAll("\"operatorRecordManifestPath\":");
        try writeJsonString(&writer, manifest_path);
        try writer.writeAll(",");
    }
    if (summary.operator_record_manifest_hash) |hash| {
        try writer.writeAll("\"operatorRecordManifestHash\":");
        try writeJsonString(&writer, hash);
        try writer.writeAll(",");
    }
    if (summary.backend_lane) |lane| {
        try writer.writeAll("\"backendLane\":");
        try writeJsonString(&writer, lane);
        try writer.writeAll(",");
    }
    if (summary.adapter_ordinal) |ordinal| {
        try writef(writer, "\"adapterOrdinal\":{},", .{ordinal});
    }
    if (summary.queue_family_index) |queue_family_index| {
        try writef(writer, "\"queueFamilyIndex\":{},", .{queue_family_index});
    }
    if (summary.present_capable) |present_capable| {
        try writef(writer, "\"presentCapable\":{},", .{present_capable});
    }
    if (summary.queue_family_policy) |policy| {
        try writer.writeAll("\"queueFamilyPolicy\":");
        try writeJsonString(&writer, policy);
        try writer.writeAll(",");
    }
    if (summary.queue_family_kind) |kind| {
        try writer.writeAll("\"queueFamilyKind\":");
        try writeJsonString(&writer, kind);
        try writer.writeAll(",");
    }
    if (summary.queue_family_queue_count) |queue_count| {
        try writef(writer, "\"queueFamilyQueueCount\":{},", .{queue_count});
    }
    if (summary.queue_family_timestamp_valid_bits) |valid_bits| {
        try writef(writer, "\"queueFamilyTimestampValidBits\":{},", .{valid_bits});
    }
    if (summary.queue_family_supports_graphics) |supports_graphics| {
        try writef(writer, "\"queueFamilySupportsGraphics\":{},", .{supports_graphics});
    }
    if (summary.queue_sync_mode) |sync_mode| {
        try writer.writeAll("\"queueSyncMode\":");
        try writeJsonString(&writer, sync_mode);
        try writer.writeAll(",");
    }
    if (summary.queue_wait_mode) |wait_mode| {
        try writer.writeAll("\"queueWaitMode\":");
        try writeJsonString(&writer, wait_mode);
        try writer.writeAll(",");
    }
    if (summary.webgpu_ffi_queue_wait_timeout_ns) |timeout_ns| {
        try writef(writer, "\"webgpuFfiQueueWaitTimeoutNs\":{},", .{timeout_ns});
    }
    if (summary.quirk_mode) |qmode| {
        try writer.writeAll("\"quirkMode\":");
        try writeJsonString(&writer, qmode);
        try writer.writeAll(",");
    }
    if (summary.determinism) |determinism| {
        try writer.writeAll("\"determinism\":");
        try trace_determinism.writeDeterminismMeta(&writer, determinism);
        try writer.writeAll(",");
    }
    if (summary.numeric_stability) |numeric_stability_summary| {
        try writer.writeAll("\"numericStability\":");
        try numeric_stability.trace_meta.writeNumericStabilityMeta(&writer, numeric_stability_summary);
        try writer.writeAll(",");
    }
    try writer.writeAll("\"profile\":{");
    try writer.writeAll("\"vendor\":");
    try writeJsonString(&writer, summary.profile_vendor);
    try writer.writeAll(",\"api\":");
    try writeJsonString(&writer, summary.profile_api);
    if (summary.profile_family) |family| {
        try writer.writeAll(",\"deviceFamily\":");
        try writeJsonString(&writer, family);
    } else {
        try writer.writeAll(",\"deviceFamily\":null");
    }
    try writer.writeAll(",\"driver\":");
    try writeJsonString(&writer, summary.profile_driver);
    try writer.writeAll("}");
    // Pipeline cache state + warmup telemetry. Emitted as a nested
    // `pipelineCache` object so bench/native_compare_modules/run_artifact.py
    // can surface it in the run-receipt's runtimeIdentity.pipelineCache. State
    // is "enabled" iff Doe's native runtime actually opened a persistent
    // pipeline cache in this process (MTLBinaryArchive on Metal, VkPipelineCache
    // on Vulkan). Reason values:
    //   "default"               - cache active (state=enabled)
    //   "cli-flag"              - --no-pipeline-cache disabled init (state=disabled)
    //   "non-doe-backend"       - Mac or Linux build, but no Doe native backend
    //                             was active (e.g. dawn_delegate Metal). The Doe
    //                             cache code path was not reached on this run.
    //   "platform-unsupported"  - build target with no Doe cache implementation
    //                             for the active backend (state=disabled)
    // The schema slot is always emitted so a comparison gate can hard-assert
    // which mode each side ran in. Warmup count/ns stay zero on platforms
    // without Doe cache support and on cache-disabled runs.
    const cache_state: []const u8 = if (summary.pipeline_cache_active) "enabled" else "disabled";
    const cache_supported = comptime (builtin.os.tag == .macos or builtin.os.tag == .linux);
    const cache_reason: []const u8 = if (!cache_supported)
        "platform-unsupported"
    else if (summary.pipeline_cache_disabled)
        "cli-flag"
    else if (summary.pipeline_cache_active)
        "default"
    else
        "non-doe-backend";
    try writer.writeAll(",\"pipelineCache\":{\"state\":");
    try writeJsonString(&writer, cache_state);
    try writer.writeAll(",\"reason\":");
    try writeJsonString(&writer, cache_reason);
    try writef(writer, ",\"warmupCount\":{},\"warmupNs\":{}", .{
        summary.pipeline_cache_warmup_count,
        summary.pipeline_cache_warmup_ns,
    });
    try writer.writeAll("}}\n");
}
