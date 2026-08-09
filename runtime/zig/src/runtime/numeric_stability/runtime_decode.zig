const std = @import("std");
const execution = @import("../../runtime/execution.zig");
const model_commands = @import("../../contracts/command.zig");
const model_transfer_types = @import("../../contracts/model/model_compute_types.zig");
const numeric_stability_service = @import("service/numeric_stability.zig");
const runtime_plan = @import("runtime_plan.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const KernelDispatchCommand = model_transfer_types.KernelDispatchCommand;
};

pub const GREEDY_DECODE_MODE = "greedy-argmax";
pub const SAMPLED_DECODE_MODE = "sampled-cdf";
pub const FULL_VOCAB_COVERAGE = "full-vocab";
pub const SURVIVING_TOKEN_SET_ALL_VOCAB = "all-vocab";
pub const SURVIVING_TOKEN_SET_FILTERED = "filtered-token-ids";
const U32_BYTE_WIDTH: usize = @sizeOf(u32);
const SAMPLE_UNIFORM_EXTENDED_WORDS: usize = 8;
const SAMPLE_UNIFORM_EXTENDED_BYTES: usize = SAMPLE_UNIFORM_EXTENDED_WORDS * U32_BYTE_WIDTH;
const SAMPLE_FLAG_ENABLE_SAMPLING: u32 = 1;
const FULL_VOCAB_RESIDUAL_MASS_UPPER_BOUND: f64 = 0.0;
const DRAW_EPSILON: f64 = 1e-12;

pub const DecodeReceiptData = struct {
    decode_boundary: numeric_stability_service.DecodeBoundaryReceipt,
    selected_token: numeric_stability_service.SelectedTokenReceipt,
};

const DecodeConfig = struct {
    vocab_size: u32,
    temperature: ?f64 = null,
    top_k: ?u32 = null,
    top_p: ?f64 = null,
    rng_seed: ?u64 = null,
    rng_draw: ?f64 = null,
    sampling_enabled: bool = false,
};

const ReplayCandidate = struct {
    token_id: u32,
    scaled_logit: f64,
    probability: f64 = 0,
};

const ReplayLaneResult = struct {
    selected_token: u32,
    top1_margin: f64,
    top_k_boundary_gap: ?f64 = null,
    top_p_boundary_gap: ?f64 = null,
    cdf_distance_to_draw: ?f64 = null,
    surviving_token_ids: []u32,
};

const ReplaySummary = struct {
    config: DecodeConfig,
    fast: ReplayLaneResult,
    stable: ReplayLaneResult,
    reference: ReplayLaneResult,
};

pub const StoredDecodeSource = struct {
    logits_handle: u64,
    semantic_op_id: []u8,
    semantic_stage: []u8,
    semantic_phase: []u8,
    trigger_policy_id: []u8,
    routing_policy_id: []u8,
    fast_policy_id: []u8,
    stable_policy_id: []u8,
    reference_policy_id: []u8,
    candidates: []numeric_stability_service.ReceiptCandidate,
    execution_identity: numeric_stability_service.ExecutionIdentityReceipt,
    first_divergence: ?numeric_stability_service.FirstDivergence = null,
    selected_token: numeric_stability_service.SelectedTokenReceipt,
    trigger: numeric_stability_service.TriggerReceipt,
    route: numeric_stability_service.RouteReceipt,

    pub fn clone(
        allocator: std.mem.Allocator,
        logits_handle: u64,
        semantic_op_id: []const u8,
        semantic_stage: []const u8,
        semantic_phase: []const u8,
        trigger_policy_id: []const u8,
        routing_policy_id: []const u8,
        fast_policy_id: []const u8,
        stable_policy_id: []const u8,
        reference_policy_id: []const u8,
        candidates: []const numeric_stability_service.ReceiptCandidate,
        execution_identity: numeric_stability_service.ExecutionIdentityReceipt,
        first_divergence: ?numeric_stability_service.FirstDivergence,
        selected_token: numeric_stability_service.SelectedTokenReceipt,
        trigger: numeric_stability_service.TriggerReceipt,
        route: numeric_stability_service.RouteReceipt,
    ) !StoredDecodeSource {
        var owned_candidates = try allocator.alloc(numeric_stability_service.ReceiptCandidate, candidates.len);
        for (candidates, 0..) |candidate, index| {
            owned_candidates[index] = .{
                .tokenId = candidate.tokenId,
                .label = if (candidate.label) |label| try allocator.dupe(u8, label) else null,
                .fastLogit = candidate.fastLogit,
                .stableLogit = candidate.stableLogit,
                .referenceLogit = candidate.referenceLogit,
            };
        }
        return .{
            .logits_handle = logits_handle,
            .semantic_op_id = try allocator.dupe(u8, semantic_op_id),
            .semantic_stage = try allocator.dupe(u8, semantic_stage),
            .semantic_phase = try allocator.dupe(u8, semantic_phase),
            .trigger_policy_id = try allocator.dupe(u8, trigger_policy_id),
            .routing_policy_id = try allocator.dupe(u8, routing_policy_id),
            .fast_policy_id = try allocator.dupe(u8, fast_policy_id),
            .stable_policy_id = try allocator.dupe(u8, stable_policy_id),
            .reference_policy_id = try allocator.dupe(u8, reference_policy_id),
            .candidates = owned_candidates,
            .execution_identity = try cloneExecutionIdentity(allocator, execution_identity),
            .first_divergence = if (first_divergence) |value| try cloneFirstDivergence(allocator, value) else null,
            .selected_token = selected_token,
            .trigger = .{
                .fired = trigger.fired,
                .checks = trigger.checks,
                .proofLinks = trigger.proofLinks,
            },
            .route = .{
                .decision = route.decision,
                .selectionMode = route.selectionMode,
                .committedResultMode = route.committedResultMode,
                .downstreamAction = route.downstreamAction,
                .effectApplied = route.effectApplied,
                .selectedPolicyId = route.selectedPolicyId,
                .selectedToken = route.selectedToken,
                .proofLinks = route.proofLinks,
                .selectionProofLinks = route.selectionProofLinks,
            },
        };
    }

    pub fn deinit(self: *StoredDecodeSource, allocator: std.mem.Allocator) void {
        allocator.free(self.trigger_policy_id);
        allocator.free(self.semantic_op_id);
        allocator.free(self.semantic_stage);
        allocator.free(self.semantic_phase);
        allocator.free(self.routing_policy_id);
        allocator.free(self.fast_policy_id);
        allocator.free(self.stable_policy_id);
        allocator.free(self.reference_policy_id);
        for (self.candidates) |candidate| {
            if (candidate.label) |label| allocator.free(label);
        }
        allocator.free(self.candidates);
        freeOptionalString(allocator, self.execution_identity.kernelPath);
        freeOptionalString(allocator, self.execution_identity.kernelBasename);
        freeOptionalString(allocator, self.execution_identity.layoutFingerprint);
        freeOptionalString(allocator, self.execution_identity.compiledPlanHash);
        freeOptionalString(allocator, self.execution_identity.backend);
        freeOptionalString(allocator, self.execution_identity.backendLane);
        freeOptionalString(allocator, self.execution_identity.profileVendor);
        freeOptionalString(allocator, self.execution_identity.profileApi);
        freeOptionalString(allocator, self.execution_identity.profileFamily);
        freeOptionalString(allocator, self.execution_identity.profileDriver);
        freeOptionalString(allocator, self.execution_identity.selectionPolicyHash);
        freeOptionalString(allocator, self.execution_identity.hostPlanArtifactHash);
        if (self.first_divergence) |*value| {
            allocator.free(value.semanticOpId);
            allocator.free(value.semanticStage);
            allocator.free(value.semanticPhase);
            allocator.free(value.fastDigest);
            allocator.free(value.stableDigest);
        }
    }
};

pub fn matchesDecodeSampleCommand(
    command: model.Command,
    semantic_op_id: ?[]const u8,
    semantic_phase: ?[]const u8,
) bool {
    const dispatch = switch (command) {
        .kernel_dispatch => |payload| payload,
        else => return false,
    };
    if (!std.mem.eql(u8, std.fs.path.basename(dispatch.kernel), "sample.wgsl")) return false;
    if (semantic_op_id) |value| return std.mem.eql(u8, value, "decode.sample_token");
    if (semantic_phase) |value| return std.mem.eql(u8, value, "sample_token");
    return false;
}

pub fn logitsHandleForSampleDispatch(dispatch: model.KernelDispatchCommand) !u64 {
    const logits_binding = try runtime_plan.requireBufferBinding(dispatch, 1);
    return logits_binding.resource_handle;
}

pub fn readDecodeReceipt(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    dispatch: model.KernelDispatchCommand,
    source: *const StoredDecodeSource,
) !DecodeReceiptData {
    const uniform_bytes = try runtime_plan.captureBindingBytes(allocator, execution_context, dispatch, 0);
    const output_binding = try runtime_plan.requireBufferBinding(dispatch, 2);
    const greedy_selected_token = buildSelectedTokenReceipt(source.candidates);
    ensureReplayMatchesSource(source.selected_token, greedy_selected_token, source.trigger.checks) catch {
        return error.NumericStabilityDecodeReplayMismatch;
    };
    const replay = try replayDecodeBoundary(allocator, source.candidates, uniform_bytes);
    const replay_selected_token = numeric_stability_service.SelectedTokenReceipt{
        .fast = replay.fast.selected_token,
        .stable = replay.stable.selected_token,
        .reference = replay.reference.selected_token,
        .fastMatchesReference = replay.fast.selected_token == replay.reference.selected_token,
        .stableMatchesReference = replay.stable.selected_token == replay.reference.selected_token,
    };
    if (replay.config.sampling_enabled) {
        try writeDecodeToken(
            execution_context,
            output_binding.resource_handle,
            output_binding.buffer_offset,
            output_binding.buffer_size,
            replay_selected_token.fast,
        );
        if (std.mem.eql(u8, source.route.selectionMode, "stable")) {
            try writeDecodeToken(
                execution_context,
                output_binding.resource_handle,
                output_binding.buffer_offset,
                output_binding.buffer_size,
                replay_selected_token.stable,
            );
        }
    }
    const live_selected_token = try readLiveSelectedToken(
        allocator,
        execution_context,
        output_binding.resource_handle,
        output_binding.buffer_offset,
        output_binding.buffer_size,
    );
    var links = try allocator.alloc(numeric_stability_service.UpstreamReceiptLink, 1);
    links[0] = .{
        .semanticOpId = source.semantic_op_id,
        .semanticStage = source.semantic_stage,
        .semanticPhase = source.semantic_phase,
        .selectedPolicyId = source.route.selectedPolicyId,
        .decision = source.route.decision,
    };
    const committed_selected_token = if (std.mem.eql(u8, source.route.selectionMode, "stable"))
        replay_selected_token.stable
    else if (std.mem.eql(u8, source.route.selectionMode, "fast"))
        replay_selected_token.fast
    else
        null;
    const surviving_token_ids = if (replay.fast.surviving_token_ids.len < replay.config.vocab_size)
        replay.fast.surviving_token_ids
    else
        null;
    return .{
        .decode_boundary = .{
            .decodeMode = if (replay.config.sampling_enabled) SAMPLED_DECODE_MODE else GREEDY_DECODE_MODE,
            .logitsCoverage = FULL_VOCAB_COVERAGE,
            .vocabSize = replay.config.vocab_size,
            .residualMassUpperBound = FULL_VOCAB_RESIDUAL_MASS_UPPER_BOUND,
            .temperature = replay.config.temperature,
            .topK = replay.config.top_k,
            .topP = replay.config.top_p,
            .rngSeed = replay.config.rng_seed,
            .rngDraw = replay.config.rng_draw,
            .survivingTokenSetKind = if (surviving_token_ids == null)
                SURVIVING_TOKEN_SET_ALL_VOCAB
            else
                SURVIVING_TOKEN_SET_FILTERED,
            .survivingTokenIds = surviving_token_ids,
            .liveSelectedToken = live_selected_token,
            .liveSelectedMatchesCommittedSelection = if (committed_selected_token) |value|
                live_selected_token == value
            else
                false,
            .metrics = .{
                .fastTop1Margin = replay.fast.top1_margin,
                .stableTop1Margin = replay.stable.top1_margin,
                .referenceTop1Margin = replay.reference.top1_margin,
                .topKBoundaryGap = replay.fast.top_k_boundary_gap,
                .topPBoundaryGap = replay.fast.top_p_boundary_gap,
                .cdfDistanceToDraw = replay.fast.cdf_distance_to_draw,
                .adjacentDecodePersistence = null,
                .actualSelectedTokenChanged = replay_selected_token.fast != replay_selected_token.stable or
                    replay_selected_token.fast != replay_selected_token.reference,
                .liveSelectedMatchesFast = live_selected_token == replay_selected_token.fast,
                .liveSelectedMatchesStable = live_selected_token == replay_selected_token.stable,
                .liveSelectedMatchesReference = live_selected_token == replay_selected_token.reference,
            },
            .upstreamLinks = links,
        },
        .selected_token = replay_selected_token,
    };
}

fn buildSelectedTokenReceipt(
    candidates: []const numeric_stability_service.ReceiptCandidate,
) numeric_stability_service.SelectedTokenReceipt {
    const fast_index = selectedIndex(candidates, .fast);
    const stable_index = selectedIndex(candidates, .stable);
    const reference_index = selectedIndex(candidates, .reference);
    return .{
        .fast = candidates[fast_index].tokenId,
        .stable = candidates[stable_index].tokenId,
        .reference = candidates[reference_index].tokenId,
        .fastMatchesReference = candidates[fast_index].tokenId == candidates[reference_index].tokenId,
        .stableMatchesReference = candidates[stable_index].tokenId == candidates[reference_index].tokenId,
    };
}

const DecodeLane = enum {
    fast,
    stable,
    reference,
};

fn selectedIndex(
    candidates: []const numeric_stability_service.ReceiptCandidate,
    lane: DecodeLane,
) usize {
    var best_index: usize = 0;
    var best_value = candidateLogit(candidates[0], lane);
    for (candidates[1..], 1..) |candidate, index| {
        const value = candidateLogit(candidate, lane);
        if (value > best_value) {
            best_value = value;
            best_index = index;
        }
    }
    return best_index;
}

fn top1Margin(
    candidates: []const numeric_stability_service.ReceiptCandidate,
    lane: DecodeLane,
) f64 {
    var best_value = candidateLogit(candidates[0], lane);
    var second_value = -std.math.inf(f64);
    for (candidates[1..]) |candidate| {
        const value = candidateLogit(candidate, lane);
        if (value > best_value) {
            second_value = best_value;
            best_value = value;
        } else if (value > second_value) {
            second_value = value;
        }
    }
    if (!std.math.isFinite(second_value)) return 0;
    return best_value - second_value;
}

fn replayDecodeBoundary(
    allocator: std.mem.Allocator,
    candidates: []const numeric_stability_service.ReceiptCandidate,
    uniform_bytes: []const u8,
) !ReplaySummary {
    const config = parseDecodeConfig(uniform_bytes);
    return .{
        .config = config,
        .fast = try replayDecodeLane(allocator, candidates, .fast, config),
        .stable = try replayDecodeLane(allocator, candidates, .stable, config),
        .reference = try replayDecodeLane(allocator, candidates, .reference, config),
    };
}

fn parseDecodeConfig(uniform_bytes: []const u8) DecodeConfig {
    const vocab_size = runtime_plan.readUniformU32(uniform_bytes, 0);
    if (uniform_bytes.len < SAMPLE_UNIFORM_EXTENDED_BYTES) {
        return .{ .vocab_size = vocab_size };
    }
    const top_k_raw = runtime_plan.readUniformU32(uniform_bytes, 1);
    const top_p_raw = @as(f64, @floatCast(runtime_plan.readUniformF32(uniform_bytes, 2)));
    const temperature_raw = @as(f64, @floatCast(runtime_plan.readUniformF32(uniform_bytes, 3)));
    const rng_seed = readUniformU64(uniform_bytes, 4);
    const rng_draw_raw = @as(f64, @floatCast(runtime_plan.readUniformF32(uniform_bytes, 6)));
    const flags = runtime_plan.readUniformU32(uniform_bytes, 7);
    return .{
        .vocab_size = vocab_size,
        .temperature = if (temperature_raw > 0) temperature_raw else null,
        .top_k = if (top_k_raw > 0) top_k_raw else null,
        .top_p = if (top_p_raw > 0 and top_p_raw <= 1.0) top_p_raw else null,
        .rng_seed = rng_seed,
        .rng_draw = if ((flags & SAMPLE_FLAG_ENABLE_SAMPLING) != 0)
            clampUnitInterval(rng_draw_raw)
        else
            null,
        .sampling_enabled = (flags & SAMPLE_FLAG_ENABLE_SAMPLING) != 0,
    };
}

fn replayDecodeLane(
    allocator: std.mem.Allocator,
    candidates: []const numeric_stability_service.ReceiptCandidate,
    lane: DecodeLane,
    config: DecodeConfig,
) !ReplayLaneResult {
    var entries = try allocator.alloc(ReplayCandidate, candidates.len);
    defer allocator.free(entries);
    const temperature = effectiveTemperature(config.temperature);
    for (candidates, 0..) |candidate, index| {
        entries[index] = .{
            .token_id = candidate.tokenId,
            .scaled_logit = candidateLogit(candidate, lane) / temperature,
        };
    }
    std.sort.block(ReplayCandidate, entries, {}, replayCandidateLessThan);
    if (entries.len == 0) return error.NumericStabilityDecodeReplayMismatch;

    const maximum = entries[0].scaled_logit;
    var weight_sum: f64 = 0;
    for (entries) |*entry| {
        entry.probability = std.math.exp(entry.scaled_logit - maximum);
        weight_sum += entry.probability;
    }
    for (entries) |*entry| entry.probability /= weight_sum;

    const top1_margin = if (entries.len >= 2)
        @max(0.0, entries[0].probability - entries[1].probability)
    else
        0;
    const top_k_boundary_gap = buildTopKBoundaryGap(entries, config.top_k);
    const top_k_count = survivingCountForTopK(entries.len, config.top_k);
    const top_p_count = survivingCountForTopP(entries, top_k_count, config.top_p);
    const surviving_count = top_p_count;
    var surviving_token_ids = try allocator.alloc(u32, surviving_count);
    var surviving_weight_sum: f64 = 0;
    for (entries[0..surviving_count], 0..) |entry, index| {
        surviving_token_ids[index] = entry.token_id;
        surviving_weight_sum += entry.probability;
    }
    const top_p_boundary_gap = buildTopPBoundaryGap(entries, top_k_count, config.top_p);
    var selected_token = entries[0].token_id;
    var cdf_distance_to_draw: ?f64 = null;
    if (config.sampling_enabled and config.rng_draw != null) {
        const draw = clampSampleDraw(config.rng_draw.?);
        var cumulative: f64 = 0;
        for (entries[0..surviving_count], 0..) |entry, index| {
            const normalized_probability = entry.probability / surviving_weight_sum;
            const lower = cumulative;
            cumulative += normalized_probability;
            const upper = if (index + 1 == surviving_count) 1.0 else cumulative;
            if (draw <= upper or index + 1 == surviving_count) {
                selected_token = entry.token_id;
                cdf_distance_to_draw = @max(
                    0.0,
                    @min(draw - lower, upper - draw),
                );
                break;
            }
        }
    }
    return .{
        .selected_token = selected_token,
        .top1_margin = top1_margin,
        .top_k_boundary_gap = top_k_boundary_gap,
        .top_p_boundary_gap = top_p_boundary_gap,
        .cdf_distance_to_draw = cdf_distance_to_draw,
        .surviving_token_ids = surviving_token_ids,
    };
}

fn replayCandidateLessThan(_: void, lhs: ReplayCandidate, rhs: ReplayCandidate) bool {
    if (lhs.scaled_logit == rhs.scaled_logit) return lhs.token_id < rhs.token_id;
    return lhs.scaled_logit > rhs.scaled_logit;
}

fn effectiveTemperature(temperature: ?f64) f64 {
    return if (temperature) |value| if (value > 0) value else 1.0 else 1.0;
}

fn survivingCountForTopK(entry_count: usize, top_k: ?u32) usize {
    if (top_k == null) return entry_count;
    return @min(entry_count, @as(usize, top_k.?));
}

fn survivingCountForTopP(
    entries: []const ReplayCandidate,
    top_k_count: usize,
    top_p: ?f64,
) usize {
    if (top_p == null) return top_k_count;
    var cumulative: f64 = 0;
    for (entries[0..top_k_count], 0..) |entry, index| {
        cumulative += entry.probability;
        if (cumulative >= top_p.?) return index + 1;
    }
    return top_k_count;
}

fn buildTopKBoundaryGap(entries: []const ReplayCandidate, top_k: ?u32) ?f64 {
    if (top_k == null) return null;
    const boundary_index = @as(usize, top_k.?);
    if (boundary_index == 0 or boundary_index >= entries.len) return null;
    return @max(0.0, entries[boundary_index - 1].probability - entries[boundary_index].probability);
}

fn buildTopPBoundaryGap(
    entries: []const ReplayCandidate,
    top_k_count: usize,
    top_p: ?f64,
) ?f64 {
    if (top_p == null) return null;
    const top_p_count = survivingCountForTopP(entries, top_k_count, top_p);
    if (top_p_count == 0 or top_p_count >= top_k_count or top_p_count >= entries.len) return null;
    return @max(0.0, entries[top_p_count - 1].probability - entries[top_p_count].probability);
}

fn clampUnitInterval(value: f64) f64 {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

fn clampSampleDraw(value: f64) f64 {
    const bounded = clampUnitInterval(value);
    if (bounded >= 1.0) return 1.0 - DRAW_EPSILON;
    return bounded;
}

fn candidateLogit(
    candidate: numeric_stability_service.ReceiptCandidate,
    lane: DecodeLane,
) f64 {
    return switch (lane) {
        .fast => candidate.fastLogit,
        .stable => candidate.stableLogit,
        .reference => candidate.referenceLogit,
    };
}

fn readLiveSelectedToken(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    buffer_handle: u64,
    offset: u64,
    size: u64,
) !u32 {
    const token_bytes = try execution_context.captureBuffer(allocator, buffer_handle, offset, size);
    if (token_bytes.len < U32_BYTE_WIDTH) return error.NumericStabilityDecodeTokenCaptureInvalid;
    const token_chunk: *const [4]u8 = @ptrCast(token_bytes[0..U32_BYTE_WIDTH].ptr);
    return std.mem.readInt(u32, token_chunk, .little);
}

fn writeDecodeToken(
    execution_context: *execution.ExecutionContext,
    buffer_handle: u64,
    offset: u64,
    size: u64,
    token: u32,
) !void {
    var words = [_]u32{token};
    const result = try execution_context.execute(.{ .buffer_write = .{
        .handle = buffer_handle,
        .offset = offset,
        .buffer_size = @max(size, @as(u64, U32_BYTE_WIDTH)),
        .data = words[0..],
    } });
    if (result.status != .ok) return error.NumericStabilityRewriteFailed;
}

fn readUniformU64(bytes: []const u8, word_index: usize) u64 {
    const lo = @as(u64, runtime_plan.readUniformU32(bytes, word_index));
    const hi = @as(u64, runtime_plan.readUniformU32(bytes, word_index + 1));
    return lo | (hi << 32);
}

fn ensureReplayMatchesSource(
    source_selected_token: numeric_stability_service.SelectedTokenReceipt,
    replay_selected_token: numeric_stability_service.SelectedTokenReceipt,
    source_checks: numeric_stability_service.TriggerChecks,
) !void {
    if (source_selected_token.fast != replay_selected_token.fast) return error.NumericStabilityDecodeReplayFastMismatch;
    if (source_selected_token.stable != replay_selected_token.stable) return error.NumericStabilityDecodeReplayStableMismatch;
    if (source_selected_token.reference != replay_selected_token.reference) return error.NumericStabilityDecodeReplayReferenceMismatch;
    if (source_checks.selectedTokenDisagreement !=
        (replay_selected_token.fast != replay_selected_token.stable))
    {
        return error.NumericStabilityDecodeReplayTriggerMismatch;
    }
    if (source_checks.stableMatchesExactReference !=
        (replay_selected_token.stable == replay_selected_token.reference))
    {
        return error.NumericStabilityDecodeReplayTriggerMismatch;
    }
    if (source_checks.fastMissesExactReference !=
        (replay_selected_token.fast != replay_selected_token.reference))
    {
        return error.NumericStabilityDecodeReplayTriggerMismatch;
    }
}

fn cloneExecutionIdentity(
    allocator: std.mem.Allocator,
    value: numeric_stability_service.ExecutionIdentityReceipt,
) !numeric_stability_service.ExecutionIdentityReceipt {
    return .{
        .kernelPath = try dupOptionalString(allocator, value.kernelPath),
        .kernelBasename = try dupOptionalString(allocator, value.kernelBasename),
        .layoutFingerprint = try dupOptionalString(allocator, value.layoutFingerprint),
        .compiledPlanHash = try dupOptionalString(allocator, value.compiledPlanHash),
        .backend = try dupOptionalString(allocator, value.backend),
        .backendLane = try dupOptionalString(allocator, value.backendLane),
        .adapterOrdinal = value.adapterOrdinal,
        .queueFamilyIndex = value.queueFamilyIndex,
        .presentCapable = value.presentCapable,
        .profileVendor = try dupOptionalString(allocator, value.profileVendor),
        .profileApi = try dupOptionalString(allocator, value.profileApi),
        .profileFamily = try dupOptionalString(allocator, value.profileFamily),
        .profileDriver = try dupOptionalString(allocator, value.profileDriver),
        .selectionPolicyHash = try dupOptionalString(allocator, value.selectionPolicyHash),
        .hostPlanArtifactHash = try dupOptionalString(allocator, value.hostPlanArtifactHash),
    };
}

fn cloneFirstDivergence(
    allocator: std.mem.Allocator,
    value: numeric_stability_service.FirstDivergence,
) !numeric_stability_service.FirstDivergence {
    return .{
        .semanticOpId = try allocator.dupe(u8, value.semanticOpId),
        .semanticStage = try allocator.dupe(u8, value.semanticStage),
        .semanticPhase = try allocator.dupe(u8, value.semanticPhase),
        .fastDigest = try allocator.dupe(u8, value.fastDigest),
        .stableDigest = try allocator.dupe(u8, value.stableDigest),
    };
}

fn dupOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn freeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |text| allocator.free(text);
}

test "parseDecodeConfig keeps legacy 16-byte sample uniforms greedy" {
    const bytes = std.mem.sliceAsBytes(&[_]u32{ 2, 0, 0, 0 });
    const config = parseDecodeConfig(bytes);
    try std.testing.expectEqual(@as(u32, 2), config.vocab_size);
    try std.testing.expect(!config.sampling_enabled);
    try std.testing.expect(config.temperature == null);
    try std.testing.expect(config.top_k == null);
    try std.testing.expect(config.top_p == null);
    try std.testing.expect(config.rng_seed == null);
    try std.testing.expect(config.rng_draw == null);
}

test "replayDecodeBoundary samples with shared draw across lanes" {
    const candidates = [_]numeric_stability_service.ReceiptCandidate{
        .{
            .tokenId = 0,
            .label = null,
            .fastLogit = 0.0,
            .stableLogit = 0.0,
            .referenceLogit = 1.0,
        },
        .{
            .tokenId = 1,
            .label = null,
            .fastLogit = 0.5,
            .stableLogit = 0.5,
            .referenceLogit = 0.5,
        },
    };
    const uniform_words = [_]u32{
        2,
        2,
        1061158912, // 0.75
        1065353216, // 1.0
        17,
        0,
        1063256064, // 0.875
        SAMPLE_FLAG_ENABLE_SAMPLING,
    };
    const replay = try replayDecodeBoundary(
        std.testing.allocator,
        candidates[0..],
        std.mem.sliceAsBytes(&uniform_words),
    );
    defer std.testing.allocator.free(replay.fast.surviving_token_ids);
    defer std.testing.allocator.free(replay.stable.surviving_token_ids);
    defer std.testing.allocator.free(replay.reference.surviving_token_ids);
    try std.testing.expect(replay.config.sampling_enabled);
    try std.testing.expectEqual(@as(u32, 0), replay.fast.selected_token);
    try std.testing.expectEqual(@as(u32, 0), replay.stable.selected_token);
    try std.testing.expectEqual(@as(u32, 1), replay.reference.selected_token);
    try std.testing.expect(replay.fast.cdf_distance_to_draw != null);
    try std.testing.expectEqual(@as(usize, 2), replay.fast.surviving_token_ids.len);
}
