const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");
const eval = @import("numeric_stability_eval.zig");
const io = @import("numeric_stability_io.zig");
const numeric_stability_policy = @import("../policy.zig");
const trace_numeric_stability = @import("../trace_meta.zig");
const types = @import("numeric_stability_types.zig");

pub const MODULE_ID = types.MODULE_ID;
pub const MATMUL_LOGITS_SLICE_SERVICE_ID = types.MATMUL_LOGITS_SLICE_SERVICE_ID;
pub const SUPPORTED_OPERATOR_FAMILY = types.SUPPORTED_OPERATOR_FAMILY;
pub const SUPPORTED_SEMANTIC_OP_ID = types.SUPPORTED_SEMANTIC_OP_ID;
pub const SUPPORTED_FAST_POLICY_ID = types.SUPPORTED_FAST_POLICY_ID;
pub const SUPPORTED_STABLE_POLICY_ID = types.SUPPORTED_STABLE_POLICY_ID;
pub const REFERENCE_POLICY_ID = types.REFERENCE_POLICY_ID;
pub const CandidateInput = types.CandidateInput;
pub const Request = types.Request;
pub const Policy = types.Policy;
pub const ParsedPolicy = types.ParsedPolicy;
pub const ServiceResult = types.ServiceResult;
pub const ExecutionStats = types.ExecutionStats;
pub const TimingStats = types.TimingStats;
pub const FailureDetails = types.FailureDetails;
pub const ReceiptCandidate = types.ReceiptCandidate;
pub const FirstDivergence = types.FirstDivergence;
pub const SelectedTokenReceipt = types.SelectedTokenReceipt;
pub const TriggerChecks = types.TriggerChecks;
pub const TriggerReceipt = types.TriggerReceipt;
pub const RouteReceipt = types.RouteReceipt;
pub const ExecutionIdentityReceipt = types.ExecutionIdentityReceipt;
pub const UpstreamReceiptLink = types.UpstreamReceiptLink;
pub const DecodeBoundaryMetrics = types.DecodeBoundaryMetrics;
pub const DecodeBoundaryReceipt = types.DecodeBoundaryReceipt;
pub const Receipt = types.Receipt;
pub const ResultNoTrace = types.ResultNoTrace;
pub const Result = types.Result;

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Request) {
    return try std.json.parseFromSlice(Request, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

pub fn parsePolicy(
    allocator: std.mem.Allocator,
    policy_registry_path: []const u8,
    bytes: []const u8,
) !ParsedPolicy {
    var parsed = try numeric_stability_policy.parseRegistry(allocator, bytes);
    errdefer parsed.deinit();
    const owned_path = try allocator.dupe(u8, policy_registry_path);
    errdefer allocator.free(owned_path);
    return .{
        .parsed = parsed,
        .policyRegistryPath = owned_path,
        .value = .{
            .policyRegistryPath = owned_path,
            .registry = parsed.value,
        },
    };
}

pub fn execute(allocator: std.mem.Allocator, request: Request, policy: Policy) !Result {
    try eval.ensureValidRequest(request);
    try eval.ensureValidPolicy(policy);

    const trigger_policy = try numeric_stability_policy.resolveTriggerPolicy(policy.registry, request.triggerPolicyId);
    const routing_policy = try numeric_stability_policy.resolveRoutingPolicy(policy.registry, request.routingPolicyId, request.triggerPolicyId);
    if (!eval.containsString(policy.registry.routeDecisions, routing_policy.triggeredDecision)) {
        return error.UnsupportedRouteDecision;
    }
    if (!eval.containsString(policy.registry.routeDecisions, routing_policy.fallbackDecision)) {
        return error.UnsupportedRouteDecision;
    }

    const start_ns = std.time.nanoTimestamp();
    var fast_logits = try allocator.alloc(f64, request.candidates.len);
    defer allocator.free(fast_logits);
    var stable_logits = try allocator.alloc(f64, request.candidates.len);
    defer allocator.free(stable_logits);
    var reference_logits = try allocator.alloc(f64, request.candidates.len);
    defer allocator.free(reference_logits);

    for (request.candidates, 0..) |candidate, index| {
        fast_logits[index] = eval.evaluateForwardF16(request.hiddenState, candidate.weights, candidate.bias);
        stable_logits[index] = eval.evaluateForwardF32(request.hiddenState, candidate.weights, candidate.bias);
        reference_logits[index] = eval.evaluateForwardF64(request.hiddenState, candidate.weights, candidate.bias);
    }
    const end_ns = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(end_ns - start_ns));

    const fast_digest = try artifact.stableHashJsonAlloc(allocator, fast_logits);
    var free_fast_digest = true;
    defer if (free_fast_digest) allocator.free(fast_digest);
    const stable_digest = try artifact.stableHashJsonAlloc(allocator, stable_logits);
    var free_stable_digest = true;
    defer if (free_stable_digest) allocator.free(stable_digest);

    const fast_index = eval.selectedIndex(fast_logits);
    const stable_index = eval.selectedIndex(stable_logits);
    const reference_index = eval.selectedIndex(reference_logits);
    const fast_token = request.candidates[fast_index].tokenId;
    const stable_token = request.candidates[stable_index].tokenId;
    const reference_token = request.candidates[reference_index].tokenId;

    const first_divergence = if (std.mem.eql(u8, fast_digest, stable_digest))
        null
    else blk: {
        free_fast_digest = false;
        free_stable_digest = false;
        break :blk FirstDivergence{
            .semanticOpId = request.semanticOpId,
            .semanticStage = request.semanticStage,
            .semanticPhase = request.semanticPhase,
            .fastDigest = fast_digest,
            .stableDigest = stable_digest,
        };
    };

    const trigger_checks = TriggerChecks{
        .firstDivergencePresent = first_divergence != null,
        .sensitiveOperatorMatched = first_divergence != null and eval.containsString(trigger_policy.allowedSensitiveOperators, request.semanticOpId),
        .selectedTokenDisagreement = fast_token != stable_token,
        .stableMatchesExactReference = stable_token == reference_token,
        .fastMissesExactReference = fast_token != reference_token,
    };

    const trigger_fired =
        (!trigger_policy.requireFirstDivergence or trigger_checks.firstDivergencePresent) and
        trigger_checks.sensitiveOperatorMatched and
        (!trigger_policy.requireSelectedTokenDisagreement or trigger_checks.selectedTokenDisagreement) and
        (!trigger_policy.requireStableMatchesExactReference or trigger_checks.stableMatchesExactReference) and
        (!trigger_policy.requireFastMissesExactReference or trigger_checks.fastMissesExactReference);

    const route_decision = if (trigger_fired) routing_policy.triggeredDecision else routing_policy.fallbackDecision;
    const route_metadata = try numeric_stability_policy.resolveRouteDecisionMetadata(policy.registry, route_decision);
    const selected_policy_id: ?[]const u8 = if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_STABLE))
        request.stablePolicyId
    else if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_FAST))
        request.fastPolicyId
    else
        null;
    const selected_token: ?u32 = if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_STABLE))
        stable_token
    else if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_FAST))
        fast_token
    else
        null;

    const receipt_candidates = try eval.appendReceiptCandidates(allocator, request, fast_logits, stable_logits, reference_logits);
    errdefer allocator.free(receipt_candidates);

    const receipt = Receipt{
        .schemaVersion = 1,
        .mode = "numeric-stability",
        .operatorFamily = request.operatorFamily,
        .semanticOpId = request.semanticOpId,
        .semanticStage = request.semanticStage,
        .semanticPhase = request.semanticPhase,
        .policyRegistryPath = policy.policyRegistryPath,
        .policyRegistryVersion = policy.registry.registryVersion,
        .routeTaxonomyVersion = policy.registry.routeTaxonomyVersion,
        .proofArtifactPath = policy.registry.proofArtifactPath,
        .triggerPolicyId = request.triggerPolicyId,
        .routingPolicyId = request.routingPolicyId,
        .fastPolicyId = request.fastPolicyId,
        .stablePolicyId = request.stablePolicyId,
        .referencePolicyId = REFERENCE_POLICY_ID,
        .candidates = receipt_candidates,
        .executionIdentity = null,
        .firstDivergence = first_divergence,
        .selectedToken = .{
            .fast = fast_token,
            .stable = stable_token,
            .reference = reference_token,
            .fastMatchesReference = fast_token == reference_token,
            .stableMatchesReference = stable_token == reference_token,
        },
        .trigger = .{
            .fired = trigger_fired,
            .checks = trigger_checks,
            .proofLinks = trigger_policy.proofLinks,
        },
        .route = .{
            .decision = route_decision,
            .selectionMode = route_metadata.selectionMode,
            .committedResultMode = route_metadata.committedResultMode,
            .downstreamAction = route_metadata.downstreamAction,
            .effectApplied = false,
            .selectedPolicyId = selected_policy_id,
            .selectedToken = selected_token,
            .proofLinks = routing_policy.proofLinks,
            .selectionProofLinks = route_metadata.proofLinks,
        },
    };

    if (request.receiptPath) |receipt_path| {
        try io.writeReceiptJsonl(allocator, receipt_path, receipt);
    }

    if (request.traceMetaPath) |trace_meta_path| {
        const summary = trace_numeric_stability.TraceNumericStabilitySummary{
            .policy_registry_path = policy.policyRegistryPath,
            .policy_registry_version = policy.registry.registryVersion,
            .route_taxonomy_version = policy.registry.routeTaxonomyVersion,
            .receipt_path = request.receiptPath orelse "",
            .receipt_count = if (request.receiptPath != null) 1 else 0,
            .decision_counts = io.buildDecisionCounts(route_decision),
            .first_divergence_present_count = if (first_divergence != null) 1 else 0,
            .annotation_count = 0,
            .auto_detect_count = 0,
            .committed_stable_rewrite_count = 0,
            .downstream_stop_count = 0,
        };
        try io.writeTraceMetaJson(allocator, trace_meta_path, summary);
    }

    const payload = ResultNoTrace{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "result",
        .serviceId = request.serviceId,
        .serviceResult = .{ .status = "ok" },
        .executionStats = .{
            .dispatchCount = 0,
            .bytesMoved = eval.totalBytesMoved(request),
            .candidateCount = request.candidates.len,
        },
        .timingStats = .{
            .setupNs = 0,
            .encodeNs = 0,
            .submitNs = 0,
            .dispatchNs = elapsed_ns,
        },
        .failureDetails = .{ .code = "none" },
        .routeDecision = route_decision,
        .selectedToken = selected_token,
        .receiptPath = request.receiptPath,
        .traceMetaPath = request.traceMetaPath,
        .receipt = receipt,
    };

    const request_hash = try artifact.stableHashJsonAlloc(allocator, request);
    errdefer allocator.free(request_hash);
    const policy_hash = try artifact.stableHashJsonAlloc(allocator, policy);
    errdefer allocator.free(policy_hash);
    const result_hash = try artifact.stableHashJsonAlloc(allocator, payload);

    return .{
        .schemaVersion = payload.schemaVersion,
        .moduleId = payload.moduleId,
        .artifactKind = payload.artifactKind,
        .serviceId = payload.serviceId,
        .serviceResult = payload.serviceResult,
        .executionStats = payload.executionStats,
        .timingStats = payload.timingStats,
        .failureDetails = payload.failureDetails,
        .routeDecision = payload.routeDecision,
        .selectedToken = payload.selectedToken,
        .receiptPath = payload.receiptPath,
        .traceMetaPath = payload.traceMetaPath,
        .receipt = payload.receipt,
        .traceLink = .{
            .moduleIdentity = MODULE_ID,
            .requestHash = request_hash,
            .policyHash = policy_hash,
            .resultHash = result_hash,
        },
    };
}

test "prefer-stable fires when stable matches reference and fast misses" {
    const allocator = std.testing.allocator;
    const request = Request{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "request",
        .serviceId = MATMUL_LOGITS_SLICE_SERVICE_ID,
        .operatorFamily = SUPPORTED_OPERATOR_FAMILY,
        .semanticOpId = SUPPORTED_SEMANTIC_OP_ID,
        .semanticStage = "lm_head_slice",
        .semanticPhase = "logits",
        .triggerPolicyId = "numeric-instability/selected-token-disagreement-with-reference-improvement-v1",
        .routingPolicyId = "numeric-stability/prefer-stable-on-selected-token-disagreement-v1",
        .fastPolicyId = SUPPORTED_FAST_POLICY_ID,
        .stablePolicyId = SUPPORTED_STABLE_POLICY_ID,
        .hiddenState = &.{ 1.0, 1.0, 1.0 },
        .candidates = &.{
            .{
                .tokenId = 11,
                .label = "keep",
                .weights = &.{ 10000.0, 0.01, -10000.0 },
            },
            .{
                .tokenId = 22,
                .label = "flip",
                .weights = &.{ 0.0, 0.001, 0.0 },
            },
        },
    };
    const policy = Policy{
        .policyRegistryPath = "config/numeric-stability-policy.json",
        .registry = .{
            .schemaVersion = 3,
            .registryVersion = "2026-03-29-execution-profiles-v1",
            .routeTaxonomyVersion = "numeric-stability-routes-v1",
            .proofArtifactPath = "pipeline/lean/artifacts/proven-conditions.json",
            .defaultExecutionProfileId = "execution/default-v1",
            .routeDecisions = &.{ "accept-fast", "prefer-stable", "abstain" },
            .routeDecisionMetadata = &.{
                .{ .decision = "accept-fast", .selectionMode = "fast", .committedResultMode = "fast", .downstreamAction = "continue", .proofLinks = &.{} },
                .{ .decision = "prefer-stable", .selectionMode = "stable", .committedResultMode = "stable", .downstreamAction = "continue", .proofLinks = &.{} },
                .{ .decision = "abstain", .selectionMode = "none", .committedResultMode = "none", .downstreamAction = "stop", .proofLinks = &.{} },
            },
            .executionProfiles = &.{
                .{
                    .profileId = "execution/default-v1",
                    .surface = numeric_stability_policy.EXECUTION_SURFACE_ORDINARY_EXECUTION,
                    .description = "default execution profile",
                    .routingPolicyId = request.routingPolicyId,
                },
            },
            .autoDetectProfiles = &.{},
            .triggerPolicies = &.{
                .{
                    .triggerPolicyId = request.triggerPolicyId,
                    .requireFirstDivergence = true,
                    .requireSelectedTokenDisagreement = true,
                    .requireStableMatchesExactReference = true,
                    .requireFastMissesExactReference = true,
                    .allowedSensitiveOperators = &.{SUPPORTED_SEMANTIC_OP_ID},
                    .proofLinks = &.{},
                },
            },
            .routingPolicies = &.{
                .{
                    .policyId = request.routingPolicyId,
                    .triggerPolicyId = request.triggerPolicyId,
                    .triggeredDecision = "prefer-stable",
                    .fallbackDecision = "accept-fast",
                    .proofLinks = &.{},
                },
            },
        },
    };

    const result = try execute(allocator, request, policy);
    try std.testing.expectEqualStrings("prefer-stable", result.routeDecision);
    try std.testing.expectEqual(@as(?u32, 11), result.selectedToken);
    try std.testing.expectEqualStrings("numeric-stability-routes-v1", result.receipt.routeTaxonomyVersion);
    try std.testing.expectEqualStrings(numeric_stability_policy.SELECTION_MODE_STABLE, result.receipt.route.selectionMode);
}

test "accept-fast falls back when no divergence is present" {
    const allocator = std.testing.allocator;
    const request = Request{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "request",
        .serviceId = MATMUL_LOGITS_SLICE_SERVICE_ID,
        .operatorFamily = SUPPORTED_OPERATOR_FAMILY,
        .semanticOpId = SUPPORTED_SEMANTIC_OP_ID,
        .semanticStage = "lm_head_slice",
        .semanticPhase = "logits",
        .triggerPolicyId = "numeric-instability/selected-token-disagreement-with-reference-improvement-v1",
        .routingPolicyId = "numeric-stability/prefer-stable-on-selected-token-disagreement-v1",
        .fastPolicyId = SUPPORTED_FAST_POLICY_ID,
        .stablePolicyId = SUPPORTED_STABLE_POLICY_ID,
        .hiddenState = &.{ 1.0, 2.0 },
        .candidates = &.{
            .{
                .tokenId = 1,
                .label = "fast",
                .weights = &.{ 0.25, 0.75 },
            },
            .{
                .tokenId = 2,
                .label = "slow",
                .weights = &.{ 0.1, 0.2 },
            },
        },
    };
    const policy = Policy{
        .policyRegistryPath = "config/numeric-stability-policy.json",
        .registry = .{
            .schemaVersion = 3,
            .registryVersion = "2026-03-29-execution-profiles-v1",
            .routeTaxonomyVersion = "numeric-stability-routes-v1",
            .proofArtifactPath = "pipeline/lean/artifacts/proven-conditions.json",
            .defaultExecutionProfileId = "execution/default-v1",
            .routeDecisions = &.{ "accept-fast", "prefer-stable", "abstain" },
            .routeDecisionMetadata = &.{
                .{ .decision = "accept-fast", .selectionMode = "fast", .committedResultMode = "fast", .downstreamAction = "continue", .proofLinks = &.{} },
                .{ .decision = "prefer-stable", .selectionMode = "stable", .committedResultMode = "stable", .downstreamAction = "continue", .proofLinks = &.{} },
                .{ .decision = "abstain", .selectionMode = "none", .committedResultMode = "none", .downstreamAction = "stop", .proofLinks = &.{} },
            },
            .executionProfiles = &.{
                .{
                    .profileId = "execution/default-v1",
                    .surface = numeric_stability_policy.EXECUTION_SURFACE_ORDINARY_EXECUTION,
                    .description = "default execution profile",
                    .routingPolicyId = request.routingPolicyId,
                },
            },
            .autoDetectProfiles = &.{},
            .triggerPolicies = &.{
                .{
                    .triggerPolicyId = request.triggerPolicyId,
                    .requireFirstDivergence = true,
                    .requireSelectedTokenDisagreement = true,
                    .requireStableMatchesExactReference = true,
                    .requireFastMissesExactReference = true,
                    .allowedSensitiveOperators = &.{SUPPORTED_SEMANTIC_OP_ID},
                    .proofLinks = &.{},
                },
            },
            .routingPolicies = &.{
                .{
                    .policyId = request.routingPolicyId,
                    .triggerPolicyId = request.triggerPolicyId,
                    .triggeredDecision = "prefer-stable",
                    .fallbackDecision = "accept-fast",
                    .proofLinks = &.{},
                },
            },
        },
    };

    const result = try execute(allocator, request, policy);
    try std.testing.expectEqualStrings("accept-fast", result.routeDecision);
    try std.testing.expectEqual(@as(?u32, 1), result.selectedToken);
    try std.testing.expectEqualStrings(numeric_stability_policy.SELECTION_MODE_FAST, result.receipt.route.selectionMode);
}
