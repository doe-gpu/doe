const std = @import("std");
const command_metadata = @import("../../contracts/command_metadata.zig");
const execution = @import("../../runtime/execution.zig");
const model_commands = @import("../../contracts/command.zig");
const model_transfer_types = @import("../../contracts/model/model_compute_types.zig");
const numeric_stability_annotation = @import("../../contracts/numeric_stability/annotation.zig");
const numeric_stability_policy = @import("policy.zig");
const semantic_trace = @import("../../contracts/semantic.zig");
const artifact = @import("../../contracts/artifact.zig");
const numeric_stability_service = @import("service/numeric_stability.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const KernelBinding = model_transfer_types.KernelBinding;
    pub const KernelDispatchCommand = model_transfer_types.KernelDispatchCommand;
};

const F32_BYTE_WIDTH: u64 = @sizeOf(f32);
pub const MATMUL_CAPTURE_PLAN_ID = "matmul-logits-bindings-v1";
pub const MATMUL_DECODE_CAPTURE_PLAN_ID = "decode-final-logits-matmul-gemv-bindings-v1";
pub const RMSNORM_CAPTURE_PLAN_ID = "rmsnorm-output-bindings-v1";
pub const ATTENTION_CAPTURE_PLAN_ID = "attention-output-bindings-v1";
pub const SELECTED_ROW_DECISION_STRATEGY_ID = "selected-row-argmax-v1";
pub const RMSNORM_DECISION_STRATEGY_ID = "rmsnorm-then-matmul-logits-selected-row-v1";

pub const RecordContext = struct {
    profile_vendor: []const u8,
    profile_api: []const u8,
    profile_family: ?[]const u8,
    profile_driver: []const u8,
    execution_result: execution.ExecutionResult,
};

pub const MatmulObservation = struct {
    operator_family: []const u8,
    trigger_policy_id: []const u8,
    routing_policy_id: []const u8,
    fast_policy_id: []const u8,
    stable_policy_id: []const u8,
    reference_policy_id: []const u8,
    hidden_state: numeric_stability_annotation.VectorCapture,
    logits: numeric_stability_annotation.VectorCapture,
    weights: numeric_stability_annotation.WeightsCapture,
    candidates: []const numeric_stability_annotation.Candidate,
    execution_identity: numeric_stability_service.ExecutionIdentityReceipt,
    semantic_op_id: []const u8,
    semantic_stage: []const u8,
    semantic_phase: []const u8,
};

pub const DownstreamMatmul = struct {
    weights: numeric_stability_annotation.WeightsCapture,
    candidates: []const numeric_stability_annotation.Candidate,
};

pub const RmsnormObservation = struct {
    operator_family: []const u8,
    trigger_policy_id: []const u8,
    routing_policy_id: []const u8,
    fast_policy_id: []const u8,
    stable_policy_id: []const u8,
    reference_policy_id: []const u8,
    input: numeric_stability_annotation.VectorCapture,
    weight: numeric_stability_annotation.VectorCapture,
    output: numeric_stability_annotation.VectorCapture,
    size: u32,
    eps: f64,
    downstream_matmul: DownstreamMatmul,
    execution_identity: numeric_stability_service.ExecutionIdentityReceipt,
    semantic_op_id: []const u8,
    semantic_stage: []const u8,
    semantic_phase: []const u8,
};

pub const AttentionObservation = struct {
    operator_family: []const u8,
    trigger_policy_id: []const u8,
    routing_policy_id: []const u8,
    fast_policy_id: []const u8,
    stable_policy_id: []const u8,
    reference_policy_id: []const u8,
    q: numeric_stability_annotation.VectorCapture,
    k: numeric_stability_annotation.VectorCapture,
    v: numeric_stability_annotation.VectorCapture,
    output: numeric_stability_annotation.VectorCapture,
    seq_len: u32,
    head_dim: u32,
    scale: f64,
    candidates: []const numeric_stability_annotation.Candidate,
    execution_identity: numeric_stability_service.ExecutionIdentityReceipt,
    semantic_op_id: []const u8,
    semantic_stage: []const u8,
    semantic_phase: []const u8,
};

pub const Observation = union(enum) {
    matmul: MatmulObservation,
    rmsnorm: RmsnormObservation,
    attention: AttentionObservation,
};

pub fn buildAnnotatedMatmulObservation(
    allocator: std.mem.Allocator,
    command: model.Command,
    semantic: semantic_trace.SemanticContext,
    annotation: numeric_stability_annotation.Annotation,
    record_context: RecordContext,
) !MatmulObservation {
    try ensureValidAnnotation(annotation, semantic);
    const dispatch = switch (command) {
        .kernel_dispatch => |kd| kd,
        else => return error.NumericStabilityUnsupportedCommandKind,
    };
    const layout_fingerprint = try buildLayoutFingerprint(allocator, dispatch.bindings);
    return .{
        .operator_family = annotation.operator_family,
        .trigger_policy_id = annotation.trigger_policy_id,
        .routing_policy_id = annotation.routing_policy_id,
        .fast_policy_id = annotation.fast_policy_id,
        .stable_policy_id = annotation.stable_policy_id,
        .reference_policy_id = numeric_stability_service.REFERENCE_POLICY_ID,
        .hidden_state = annotation.hidden_state,
        .logits = annotation.logits,
        .weights = annotation.weights,
        .candidates = annotation.candidates,
        .execution_identity = buildExecutionIdentity(
            dispatch.kernel,
            layout_fingerprint,
            semantic.execution_plan_hash,
            record_context,
        ),
        .semantic_op_id = semantic.op_id.?,
        .semantic_stage = semantic.stage.?,
        .semantic_phase = semantic.phase.?,
    };
}

pub fn buildAutoMatmulObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    dispatch: model.KernelDispatchCommand,
    semantic: semantic_trace.SemanticContext,
    profile: numeric_stability_policy.AutoDetectProfile,
    routing_policy_id: []const u8,
    record_context: RecordContext,
) !MatmulObservation {
    const uniform_bytes = try captureBindingBytes(allocator, execution_context, dispatch, 0);
    const rows = readUniformU32(uniform_bytes, 0);
    const cols = readUniformU32(uniform_bytes, 1);
    const hidden_binding = try requireBufferBinding(dispatch, 1);
    const weights_binding = try requireBufferBinding(dispatch, 2);
    const output_binding = try requireBufferBinding(dispatch, 3);
    const candidates = try buildRowCandidates(allocator, rows);
    const layout_fingerprint = try buildLayoutFingerprint(allocator, dispatch.bindings);
    return .{
        .operator_family = profile.operatorFamily,
        .trigger_policy_id = profile.triggerPolicyId,
        .routing_policy_id = routing_policy_id,
        .fast_policy_id = profile.fastPolicyId,
        .stable_policy_id = profile.stablePolicyId,
        .reference_policy_id = profile.referencePolicyId,
        .hidden_state = .{
            .buffer_handle = hidden_binding.resource_handle,
            .offset = hidden_binding.buffer_offset,
            .element_count = cols,
        },
        .logits = .{
            .buffer_handle = output_binding.resource_handle,
            .offset = output_binding.buffer_offset,
            .element_count = rows,
        },
        .weights = .{
            .buffer_handle = weights_binding.resource_handle,
            .offset = weights_binding.buffer_offset,
            .row_stride_elements = cols,
        },
        .candidates = candidates,
        .execution_identity = buildExecutionIdentity(
            dispatch.kernel,
            layout_fingerprint,
            semantic.execution_plan_hash,
            record_context,
        ),
        .semantic_op_id = semantic.op_id.?,
        .semantic_stage = semantic.stage.?,
        .semantic_phase = semantic.phase.?,
    };
}

pub fn buildAutoDecodeFinalLogitsObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    dispatch: model.KernelDispatchCommand,
    semantic: semantic_trace.SemanticContext,
    profile: numeric_stability_policy.AutoDetectProfile,
    routing_policy_id: []const u8,
    record_context: RecordContext,
) !MatmulObservation {
    const uniform_bytes = try captureBindingBytes(allocator, execution_context, dispatch, 0);
    const rows = readUniformU32(uniform_bytes, 0);
    const cols = readUniformU32(uniform_bytes, 1);
    const weights_binding = try requireBufferBinding(dispatch, 1);
    const hidden_binding = try requireBufferBinding(dispatch, 2);
    const output_binding = try requireBufferBinding(dispatch, 3);
    const candidates = try buildRowCandidates(allocator, rows);
    const layout_fingerprint = try buildLayoutFingerprint(allocator, dispatch.bindings);
    return .{
        .operator_family = profile.operatorFamily,
        .trigger_policy_id = profile.triggerPolicyId,
        .routing_policy_id = routing_policy_id,
        .fast_policy_id = profile.fastPolicyId,
        .stable_policy_id = profile.stablePolicyId,
        .reference_policy_id = profile.referencePolicyId,
        .hidden_state = .{
            .buffer_handle = hidden_binding.resource_handle,
            .offset = hidden_binding.buffer_offset,
            .element_count = cols,
        },
        .logits = .{
            .buffer_handle = output_binding.resource_handle,
            .offset = output_binding.buffer_offset,
            .element_count = rows,
        },
        .weights = .{
            .buffer_handle = weights_binding.resource_handle,
            .offset = weights_binding.buffer_offset,
            .row_stride_elements = cols,
        },
        .candidates = candidates,
        .execution_identity = buildExecutionIdentity(
            dispatch.kernel,
            layout_fingerprint,
            semantic.execution_plan_hash,
            record_context,
        ),
        .semantic_op_id = semantic.op_id.?,
        .semantic_stage = semantic.stage.?,
        .semantic_phase = semantic.phase.?,
    };
}

pub fn buildAutoRmsnormObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    dispatch: model.KernelDispatchCommand,
    semantic: semantic_trace.SemanticContext,
    profile: numeric_stability_policy.AutoDetectProfile,
    routing_policy_id: []const u8,
    future_commands: []const model.Command,
    future_metadata: []const command_metadata.CommandMetadata,
    record_context: RecordContext,
) !RmsnormObservation {
    const uniform_bytes = try captureBindingBytes(allocator, execution_context, dispatch, 0);
    const size = readUniformU32(uniform_bytes, 0);
    const eps = @as(f64, @floatCast(readUniformF32(uniform_bytes, 1)));
    const input_binding = try requireBufferBinding(dispatch, 1);
    const weight_binding = try requireBufferBinding(dispatch, 2);
    const output_binding = try requireBufferBinding(dispatch, 3);
    const downstream = try resolveDownstreamMatmul(
        allocator,
        execution_context,
        future_commands,
        future_metadata,
    );
    const output_count = @as(u32, @intCast(output_binding.buffer_size / F32_BYTE_WIDTH));
    const layout_fingerprint = try buildLayoutFingerprint(allocator, dispatch.bindings);
    return .{
        .operator_family = profile.operatorFamily,
        .trigger_policy_id = profile.triggerPolicyId,
        .routing_policy_id = routing_policy_id,
        .fast_policy_id = profile.fastPolicyId,
        .stable_policy_id = profile.stablePolicyId,
        .reference_policy_id = profile.referencePolicyId,
        .input = .{
            .buffer_handle = input_binding.resource_handle,
            .offset = input_binding.buffer_offset,
            .element_count = output_count,
        },
        .weight = .{
            .buffer_handle = weight_binding.resource_handle,
            .offset = weight_binding.buffer_offset,
            .element_count = @as(u32, @intCast(weight_binding.buffer_size / F32_BYTE_WIDTH)),
        },
        .output = .{
            .buffer_handle = output_binding.resource_handle,
            .offset = output_binding.buffer_offset,
            .element_count = output_count,
        },
        .size = size,
        .eps = eps,
        .downstream_matmul = downstream,
        .execution_identity = buildExecutionIdentity(
            dispatch.kernel,
            layout_fingerprint,
            semantic.execution_plan_hash,
            record_context,
        ),
        .semantic_op_id = semantic.op_id.?,
        .semantic_stage = semantic.stage.?,
        .semantic_phase = semantic.phase.?,
    };
}

pub fn buildAutoAttentionObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    dispatch: model.KernelDispatchCommand,
    semantic: semantic_trace.SemanticContext,
    profile: numeric_stability_policy.AutoDetectProfile,
    routing_policy_id: []const u8,
    record_context: RecordContext,
) !AttentionObservation {
    const uniform_bytes = try captureBindingBytes(allocator, execution_context, dispatch, 0);
    const seq_len = readUniformU32(uniform_bytes, 0);
    const head_dim = readUniformU32(uniform_bytes, 1);
    const scale = @as(f64, @floatCast(readUniformF32(uniform_bytes, 2)));
    const q_binding = try requireBufferBinding(dispatch, 1);
    const k_binding = try requireBufferBinding(dispatch, 2);
    const v_binding = try requireBufferBinding(dispatch, 3);
    const output_binding = try requireBufferBinding(dispatch, 4);
    const candidate_count = @as(u32, @intCast(output_binding.buffer_size / F32_BYTE_WIDTH));
    const candidates = try buildRowCandidates(allocator, candidate_count);
    const layout_fingerprint = try buildLayoutFingerprint(allocator, dispatch.bindings);
    return .{
        .operator_family = profile.operatorFamily,
        .trigger_policy_id = profile.triggerPolicyId,
        .routing_policy_id = routing_policy_id,
        .fast_policy_id = profile.fastPolicyId,
        .stable_policy_id = profile.stablePolicyId,
        .reference_policy_id = profile.referencePolicyId,
        .q = .{
            .buffer_handle = q_binding.resource_handle,
            .offset = q_binding.buffer_offset,
            .element_count = @as(u32, @intCast(q_binding.buffer_size / F32_BYTE_WIDTH)),
        },
        .k = .{
            .buffer_handle = k_binding.resource_handle,
            .offset = k_binding.buffer_offset,
            .element_count = @as(u32, @intCast(k_binding.buffer_size / F32_BYTE_WIDTH)),
        },
        .v = .{
            .buffer_handle = v_binding.resource_handle,
            .offset = v_binding.buffer_offset,
            .element_count = @as(u32, @intCast(v_binding.buffer_size / F32_BYTE_WIDTH)),
        },
        .output = .{
            .buffer_handle = output_binding.resource_handle,
            .offset = output_binding.buffer_offset,
            .element_count = candidate_count,
        },
        .seq_len = seq_len,
        .head_dim = head_dim,
        .scale = scale,
        .candidates = candidates,
        .execution_identity = buildExecutionIdentity(
            dispatch.kernel,
            layout_fingerprint,
            semantic.execution_plan_hash,
            record_context,
        ),
        .semantic_op_id = semantic.op_id.?,
        .semantic_stage = semantic.stage.?,
        .semantic_phase = semantic.phase.?,
    };
}

fn resolveDownstreamMatmul(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    future_commands: []const model.Command,
    future_metadata: []const command_metadata.CommandMetadata,
) !DownstreamMatmul {
    var index: usize = 0;
    while (index < future_commands.len and index < future_metadata.len) : (index += 1) {
        const metadata = future_metadata[index];
        if (metadata.semantic.op_id == null or !std.mem.eql(u8, metadata.semantic.op_id.?, "matmul.logits")) continue;
        const dispatch = switch (future_commands[index]) {
            .kernel_dispatch => |kd| kd,
            else => continue,
        };
        const uniform_bytes = try captureBindingBytes(allocator, execution_context, dispatch, 0);
        const rows = readUniformU32(uniform_bytes, 0);
        const cols = readUniformU32(uniform_bytes, 1);
        const weights_binding = try requireBufferBinding(dispatch, 2);
        return .{
            .weights = .{
                .buffer_handle = weights_binding.resource_handle,
                .offset = weights_binding.buffer_offset,
                .row_stride_elements = cols,
            },
            .candidates = try buildRowCandidates(allocator, rows),
        };
    }
    return error.NumericStabilityMissingDownstreamMatmul;
}

pub fn buildExecutionIdentity(
    kernel_path: []const u8,
    layout_fingerprint: []const u8,
    compiled_plan_hash: ?[]const u8,
    record_context: RecordContext,
) numeric_stability_service.ExecutionIdentityReceipt {
    const resolved_compiled_plan_hash =
        compiled_plan_hash orelse record_context.execution_result.host_plan_artifact_hash;
    return .{
        .kernelPath = kernel_path,
        .kernelBasename = std.fs.path.basename(kernel_path),
        .layoutFingerprint = layout_fingerprint,
        .compiledPlanHash = resolved_compiled_plan_hash,
        .backend = record_context.execution_result.backend,
        .backendLane = record_context.execution_result.backend_lane,
        .adapterOrdinal = record_context.execution_result.adapter_ordinal,
        .queueFamilyIndex = record_context.execution_result.queue_family_index,
        .presentCapable = record_context.execution_result.present_capable,
        .profileVendor = record_context.profile_vendor,
        .profileApi = record_context.profile_api,
        .profileFamily = record_context.profile_family,
        .profileDriver = record_context.profile_driver,
        .selectionPolicyHash = record_context.execution_result.selection_policy_hash,
        .hostPlanArtifactHash = record_context.execution_result.host_plan_artifact_hash,
    };
}

pub fn buildLayoutFingerprint(
    allocator: std.mem.Allocator,
    bindings: ?[]const model.KernelBinding,
) ![]const u8 {
    const binding_entries = bindings orelse return try allocator.dupe(u8, "0000000000000000000000000000000000000000000000000000000000000000");
    const Entry = struct {
        binding: u32,
        group: u32,
        resourceKind: u8,
        visibility: u64,
        bufferOffset: u64,
        bufferSize: u64,
        bufferType: u32,
        textureSampleType: u32,
        textureViewDimension: u32,
        storageTextureAccess: u32,
        textureAspect: u32,
        textureFormat: u32,
        textureMultisampled: bool,
    };
    var entries = try allocator.alloc(Entry, binding_entries.len);
    for (binding_entries, 0..) |binding, index| {
        entries[index] = .{
            .binding = binding.binding,
            .group = binding.group,
            .resourceKind = @intFromEnum(binding.resource_kind),
            .visibility = binding.visibility,
            .bufferOffset = binding.buffer_offset,
            .bufferSize = binding.buffer_size,
            .bufferType = binding.buffer_type,
            .textureSampleType = binding.texture_sample_type,
            .textureViewDimension = binding.texture_view_dimension,
            .storageTextureAccess = binding.storage_texture_access,
            .textureAspect = binding.texture_aspect,
            .textureFormat = binding.texture_format,
            .textureMultisampled = binding.texture_multisampled,
        };
    }
    return try artifact.stableHashJsonAlloc(allocator, entries);
}

pub fn requireBufferBinding(dispatch: model.KernelDispatchCommand, binding_index: u32) !model.KernelBinding {
    const bindings = dispatch.bindings orelse return error.NumericStabilityMissingBindings;
    for (bindings) |binding| {
        if (binding.binding == binding_index and binding.group == 0) return binding;
    }
    return error.NumericStabilityMissingBinding;
}

pub fn captureBindingBytes(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    dispatch: model.KernelDispatchCommand,
    binding_index: u32,
) ![]u8 {
    const binding = try requireBufferBinding(dispatch, binding_index);
    return try execution_context.captureBuffer(
        allocator,
        binding.resource_handle,
        binding.buffer_offset,
        binding.buffer_size,
    );
}

pub fn buildRowCandidates(
    allocator: std.mem.Allocator,
    count: u32,
) ![]numeric_stability_annotation.Candidate {
    var candidates = try allocator.alloc(numeric_stability_annotation.Candidate, count);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        candidates[index] = .{
            .token_id = index,
            .label = null,
            .row_index = index,
            .bias = null,
        };
    }
    return candidates;
}

pub fn readUniformU32(bytes: []const u8, word_index: usize) u32 {
    const start = word_index * @sizeOf(u32);
    const chunk: *const [4]u8 = @ptrCast(bytes[start .. start + @sizeOf(u32)].ptr);
    return std.mem.readInt(u32, chunk, .little);
}

pub fn readUniformF32(bytes: []const u8, word_index: usize) f32 {
    return @bitCast(readUniformU32(bytes, word_index));
}

pub fn ensureValidAnnotation(
    annotation: numeric_stability_annotation.Annotation,
    semantic: semantic_trace.SemanticContext,
) !void {
    if (annotation.candidates.len < 2) return error.NumericStabilityCandidateCountInvalid;
    if (annotation.hidden_state.element_count == 0) return error.NumericStabilityHiddenStateInvalid;
    if (annotation.logits.element_count != annotation.candidates.len) return error.NumericStabilityLogitCountMismatch;
    if (annotation.weights.row_stride_elements < annotation.hidden_state.element_count) {
        return error.NumericStabilityWeightsStrideInvalid;
    }
    if (semantic.op_id == null or !std.mem.eql(u8, semantic.op_id.?, "matmul.logits")) {
        return error.NumericStabilityUnsupportedSemanticOpId;
    }
}
