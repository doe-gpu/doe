const std = @import("std");
const model = @import("../contracts/command.zig");
const command_json = @import("command_json.zig");
const command_json_raw = @import("command_json_raw.zig");
const numeric_stability_annotation = @import("../contracts/numeric_stability/annotation.zig");
const semantic_trace = @import("../contracts/semantic.zig");
const command_metadata = @import("../contracts/command_metadata.zig");

const RawCommand = command_json_raw.RawCommand;

pub const CommandMetadata = command_metadata.CommandMetadata;

pub const ParsedCommandStream = struct {
    commands: []model.Command,
    metadata: []CommandMetadata,

    pub fn deinit(self: ParsedCommandStream, allocator: std.mem.Allocator) void {
        for (self.metadata) |entry| {
            if (entry.numeric_stability) |annotation| {
                allocator.free(annotation.candidates);
            }
        }
        command_json.freeCommands(allocator, self.commands);
        allocator.free(self.metadata);
    }
};

pub fn metadata_for_slice(
    allocator: std.mem.Allocator,
    commands: []const model.Command,
) ![]CommandMetadata {
    const metadata = try allocator.alloc(CommandMetadata, commands.len);
    @memset(metadata, .{});
    return metadata;
}

pub fn parse_command_stream(
    allocator: std.mem.Allocator,
    text: []const u8,
) anyerror!ParsedCommandStream {
    const commands = try command_json.parseCommands(allocator, text);
    errdefer command_json.freeCommands(allocator, commands);

    if (std.mem.eql(u8, std.mem.trim(u8, text, " \n\r\t"), "[]")) {
        return .{
            .commands = commands,
            .metadata = try metadata_for_slice(allocator, commands),
        };
    }

    const cleanly_trimmed = std.mem.trimRight(u8, text, " \n\r\t\\n");
    const raw = try std.json.parseFromSliceLeaky([]const RawCommand, allocator, cleanly_trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (raw.len != commands.len) return error.InvalidCommandStream;

    const metadata = try allocator.alloc(CommandMetadata, raw.len);
    errdefer allocator.free(metadata);
    @memset(metadata, .{});

    for (raw, 0..) |entry, idx| {
        metadata[idx] = .{
            .semantic = .{
                .op_id = entry.semantic_op_id orelse entry.semanticOpId,
                .stage = entry.semantic_stage orelse entry.semanticStage,
                .phase = entry.semantic_phase orelse entry.semanticPhase,
                .token_index = entry.semantic_token_index orelse entry.semanticTokenIndex,
                .layer_index = entry.semantic_layer_index orelse entry.semanticLayerIndex,
                .execution_plan_hash = entry.semantic_execution_plan_hash orelse entry.semanticExecutionPlanHash,
            },
            .capture = parse_capture(entry),
            .numeric_stability = try parse_numeric_stability(allocator, entry),
        };
    }

    return .{
        .commands = commands,
        .metadata = metadata,
    };
}

fn parse_capture(raw: RawCommand) ?semantic_trace.CaptureRequest {
    const handle = raw.capture_buffer_handle orelse raw.captureBufferHandle orelse return null;
    const size = raw.capture_size orelse raw.captureSize orelse return null;
    if (size == 0) return null;
    return .{
        .buffer_handle = handle,
        .offset = raw.capture_offset orelse raw.captureOffset orelse 0,
        .size = size,
    };
}

fn parse_vector_capture(raw: command_json_raw.RawNumericStabilityVectorCapture) !numeric_stability_annotation.VectorCapture {
    const buffer_handle = raw.buffer_handle orelse raw.bufferHandle orelse return error.InvalidCommandStream;
    const element_count = raw.element_count orelse raw.elementCount orelse return error.InvalidCommandStream;
    if (element_count == 0) return error.InvalidCommandStream;
    return .{
        .buffer_handle = buffer_handle,
        .offset = raw.offset orelse 0,
        .element_count = element_count,
    };
}

fn parse_weights_capture(raw: command_json_raw.RawNumericStabilityWeightsCapture) !numeric_stability_annotation.WeightsCapture {
    const buffer_handle = raw.buffer_handle orelse raw.bufferHandle orelse return error.InvalidCommandStream;
    const row_stride_elements = raw.row_stride_elements orelse raw.rowStrideElements orelse return error.InvalidCommandStream;
    if (row_stride_elements == 0) return error.InvalidCommandStream;
    return .{
        .buffer_handle = buffer_handle,
        .offset = raw.offset orelse 0,
        .row_stride_elements = row_stride_elements,
    };
}

fn parse_numeric_stability_candidate(raw: command_json_raw.RawNumericStabilityCandidate) !numeric_stability_annotation.Candidate {
    const token_id = raw.token_id orelse raw.tokenId orelse return error.InvalidCommandStream;
    const row_index = raw.row_index orelse raw.rowIndex orelse return error.InvalidCommandStream;
    return .{
        .token_id = token_id,
        .label = raw.label,
        .row_index = row_index,
        .bias = raw.bias,
    };
}

fn parse_numeric_stability(
    allocator: std.mem.Allocator,
    raw: RawCommand,
) !?numeric_stability_annotation.Annotation {
    const payload = raw.numeric_stability orelse raw.numericStability orelse return null;
    const hidden_state = try parse_vector_capture(payload.hidden_state orelse payload.hiddenState orelse return error.InvalidCommandStream);
    const logits = try parse_vector_capture(payload.logits orelse return error.InvalidCommandStream);
    const weights = try parse_weights_capture(payload.weights orelse return error.InvalidCommandStream);
    const raw_candidates = payload.candidates orelse return error.InvalidCommandStream;
    if (raw_candidates.len < 2) return error.InvalidCommandStream;
    const candidates = try allocator.alloc(numeric_stability_annotation.Candidate, raw_candidates.len);
    errdefer allocator.free(candidates);
    for (raw_candidates, candidates) |candidate, *dest| {
        dest.* = try parse_numeric_stability_candidate(candidate);
    }
    return .{
        .operator_family = payload.operator_family orelse payload.operatorFamily orelse numeric_stability_annotation.DEFAULT_OPERATOR_FAMILY,
        .trigger_policy_id = payload.trigger_policy_id orelse payload.triggerPolicyId orelse numeric_stability_annotation.DEFAULT_TRIGGER_POLICY_ID,
        .routing_policy_id = payload.routing_policy_id orelse payload.routingPolicyId orelse numeric_stability_annotation.DEFAULT_ROUTING_POLICY_ID,
        .fast_policy_id = payload.fast_policy_id orelse payload.fastPolicyId orelse numeric_stability_annotation.DEFAULT_FAST_POLICY_ID,
        .stable_policy_id = payload.stable_policy_id orelse payload.stablePolicyId orelse numeric_stability_annotation.DEFAULT_STABLE_POLICY_ID,
        .hidden_state = hidden_state,
        .logits = logits,
        .weights = weights,
        .candidates = candidates,
    };
}
