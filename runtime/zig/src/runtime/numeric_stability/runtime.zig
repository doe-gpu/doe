const std = @import("std");
const command_metadata = @import("../../contracts/command_metadata.zig");
const execution = @import("../../runtime/execution.zig");
const model_commands = @import("../../contracts/command.zig");
const numeric_stability_annotation = @import("../../contracts/numeric_stability/annotation.zig");
const numeric_stability_policy = @import("policy.zig");
const semantic_trace = @import("../../contracts/semantic.zig");
const trace_numeric_stability = @import("trace_meta.zig");
const artifact = @import("../../contracts/artifact.zig");
const numeric_stability_service = @import("service/numeric_stability.zig");
const runtime_decode = @import("runtime_decode.zig");
const runtime_eval = @import("runtime_eval.zig");
const runtime_plan = @import("runtime_plan.zig");

const model = struct {
    pub const Command = model_commands.Command;
};

const RECEIPT_PATH_SUFFIX = ".numeric-stability.jsonl";

pub const RecordContext = runtime_plan.RecordContext;

pub const RecordOutcome = struct {
    route_decision: ?[]const u8 = null,
    rewrite_applied: bool = false,
    should_stop_downstream: bool = false,
    auto_detected: bool = false,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    loaded_registry: ?numeric_stability_policy.LoadedRegistry = null,
    selected_execution_profile: ?numeric_stability_policy.ExecutionProfile = null,
    receipt_path: ?[]u8 = null,
    receipt_file: ?std.fs.File = null,
    receipt_count: u32 = 0,
    first_divergence_present_count: u32 = 0,
    decision_counts: trace_numeric_stability.TraceNumericStabilityDecisionCounts = .{},
    annotation_count: u32 = 0,
    auto_detect_count: u32 = 0,
    committed_stable_rewrite_count: u32 = 0,
    downstream_stop_count: u32 = 0,
    last_decode_source: ?runtime_decode.StoredDecodeSource = null,

    pub fn init(
        allocator: std.mem.Allocator,
        anchor: ?[]const u8,
        policy_path: ?[]const u8,
        execution_profile_id: ?[]const u8,
    ) !Recorder {
        if (anchor == null) {
            return .{ .allocator = allocator };
        }
        var loaded_registry = try numeric_stability_policy.loadRegistry(
            allocator,
            policy_path orelse numeric_stability_policy.DEFAULT_POLICY_PATH,
        );
        errdefer loaded_registry.deinit(allocator);
        const selected_execution_profile = try numeric_stability_policy.resolveExecutionProfile(
            loaded_registry.parsed.value,
            execution_profile_id orelse loaded_registry.parsed.value.defaultExecutionProfileId,
            numeric_stability_policy.EXECUTION_SURFACE_ORDINARY_EXECUTION,
        );
        return .{
            .allocator = allocator,
            .loaded_registry = loaded_registry,
            .selected_execution_profile = selected_execution_profile,
            .receipt_path = try std.mem.concat(allocator, u8, &.{ anchor.?, RECEIPT_PATH_SUFFIX }),
        };
    }

    pub fn deinit(self: *Recorder) void {
        if (self.receipt_file) |file| {
            file.close();
            self.receipt_file = null;
        }
        if (self.last_decode_source) |*source| source.deinit(self.allocator);
        if (self.receipt_path) |path| self.allocator.free(path);
        if (self.loaded_registry) |*loaded_registry| loaded_registry.deinit(self.allocator);
        self.receipt_path = null;
        self.loaded_registry = null;
        self.selected_execution_profile = null;
        self.last_decode_source = null;
    }

    pub fn enabled(self: *const Recorder) bool {
        return self.loaded_registry != null and self.receipt_path != null;
    }

    pub fn hasEvents(self: *const Recorder) bool {
        return self.receipt_count > 0;
    }

    pub fn record(
        self: *Recorder,
        execution_context: *execution.ExecutionContext,
        command: model.Command,
        semantic: semantic_trace.SemanticContext,
        explicit_annotation: ?numeric_stability_annotation.Annotation,
        future_commands: []const model.Command,
        future_metadata: []const command_metadata.CommandMetadata,
        record_context: RecordContext,
    ) !RecordOutcome {
        if (!self.enabled()) return .{};
        if (semantic.op_id == null or semantic.stage == null or semantic.phase == null) return .{};

        if (try self.recordDecodeBoundaryIfPresent(
            execution_context,
            command,
            semantic,
        )) |outcome| return outcome;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const observation = try resolveObservation(
            allocator,
            self.loaded_registry.?.parsed.value,
            self.selected_execution_profile,
            execution_context,
            command,
            semantic,
            explicit_annotation,
            future_commands,
            future_metadata,
            record_context,
        ) orelse return .{};

        const evaluation: runtime_eval.Evaluation = try switch (observation) {
            .matmul => |obs| runtime_eval.evaluateMatmulObservation(allocator, execution_context, obs),
            .rmsnorm => |obs| runtime_eval.evaluateRmsnormObservation(allocator, execution_context, obs),
            .attention => |obs| runtime_eval.evaluateAttentionObservation(allocator, execution_context, obs),
        };

        const registry = self.loaded_registry.?.parsed.value;
        const trigger_policy = try numeric_stability_policy.resolveTriggerPolicy(
            registry,
            evaluation.trigger_policy_id,
        );
        const routing_policy = try numeric_stability_policy.resolveRoutingPolicy(
            registry,
            evaluation.routing_policy_id,
            evaluation.trigger_policy_id,
        );
        const trigger_checks = numeric_stability_service.TriggerChecks{
            .firstDivergencePresent = !std.mem.eql(u8, evaluation.fast_digest, evaluation.stable_digest),
            .sensitiveOperatorMatched = containsString(
                trigger_policy.allowedSensitiveOperators,
                evaluation.semantic_op_id,
            ) and !std.mem.eql(u8, evaluation.fast_digest, evaluation.stable_digest),
            .selectedTokenDisagreement = evaluation.fast_token != evaluation.stable_token,
            .stableMatchesExactReference = evaluation.stable_token == evaluation.reference_token,
            .fastMissesExactReference = evaluation.fast_token != evaluation.reference_token,
        };
        const trigger_fired =
            (!trigger_policy.requireFirstDivergence or trigger_checks.firstDivergencePresent) and
            trigger_checks.sensitiveOperatorMatched and
            (!trigger_policy.requireSelectedTokenDisagreement or trigger_checks.selectedTokenDisagreement) and
            (!trigger_policy.requireStableMatchesExactReference or trigger_checks.stableMatchesExactReference) and
            (!trigger_policy.requireFastMissesExactReference or trigger_checks.fastMissesExactReference);

        const route_decision = if (trigger_fired)
            routing_policy.triggeredDecision
        else
            routing_policy.fallbackDecision;
        const route_metadata = try numeric_stability_policy.resolveRouteDecisionMetadata(
            registry,
            route_decision,
        );
        const selected_policy_id: ?[]const u8 =
            if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_STABLE))
                evaluation.stable_policy_id
            else if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_FAST))
                evaluation.fast_policy_id
            else
                null;
        const selected_token: ?u32 =
            if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_STABLE))
                evaluation.stable_token
            else if (std.mem.eql(u8, route_metadata.selectionMode, numeric_stability_policy.SELECTION_MODE_FAST))
                evaluation.fast_token
            else
                null;

        const first_divergence = if (std.mem.eql(u8, evaluation.fast_digest, evaluation.stable_digest))
            null
        else
            numeric_stability_service.FirstDivergence{
                .semanticOpId = evaluation.semantic_op_id,
                .semanticStage = evaluation.semantic_stage,
                .semanticPhase = evaluation.semantic_phase,
                .fastDigest = evaluation.fast_digest,
                .stableDigest = evaluation.stable_digest,
            };

        var rewrite_applied = false;
        if (std.mem.eql(
            u8,
            route_metadata.committedResultMode,
            numeric_stability_policy.COMMITTED_RESULT_MODE_STABLE,
        )) {
            try runtime_eval.executeStableRewrite(
                allocator,
                execution_context,
                evaluation.rewrite_target_handle,
                evaluation.rewrite_target_offset,
                evaluation.rewrite_values,
            );
            rewrite_applied = true;
        }

        const should_stop_downstream =
            std.mem.eql(
                u8,
                route_metadata.downstreamAction,
                numeric_stability_policy.DOWNSTREAM_ACTION_STOP,
            ) and future_commands.len > 0;
        const effect_applied = rewrite_applied or should_stop_downstream;

        const receipt = numeric_stability_service.Receipt{
            .schemaVersion = 1,
            .mode = "numeric-stability",
            .operatorFamily = evaluation.operator_family,
            .semanticOpId = evaluation.semantic_op_id,
            .semanticStage = evaluation.semantic_stage,
            .semanticPhase = evaluation.semantic_phase,
            .policyRegistryPath = self.loaded_registry.?.policyRegistryPath,
            .policyRegistryVersion = registry.registryVersion,
            .routeTaxonomyVersion = registry.routeTaxonomyVersion,
            .proofArtifactPath = registry.proofArtifactPath,
            .triggerPolicyId = evaluation.trigger_policy_id,
            .routingPolicyId = evaluation.routing_policy_id,
            .fastPolicyId = evaluation.fast_policy_id,
            .stablePolicyId = evaluation.stable_policy_id,
            .referencePolicyId = evaluation.reference_policy_id,
            .candidates = evaluation.candidates,
            .executionIdentity = evaluation.execution_identity,
            .firstDivergence = first_divergence,
            .decodeBoundary = null,
            .selectedToken = .{
                .fast = evaluation.fast_token,
                .stable = evaluation.stable_token,
                .reference = evaluation.reference_token,
                .fastMatchesReference = evaluation.fast_token == evaluation.reference_token,
                .stableMatchesReference = evaluation.stable_token == evaluation.reference_token,
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
                .effectApplied = effect_applied,
                .selectedPolicyId = selected_policy_id,
                .selectedToken = selected_token,
                .proofLinks = routing_policy.proofLinks,
                .selectionProofLinks = route_metadata.proofLinks,
            },
        };

        try self.ensureReceiptFile();
        const payload = try artifact.jsonStringifyAlloc(allocator, receipt);
        defer allocator.free(payload);
        try self.receipt_file.?.writeAll(payload);
        try self.receipt_file.?.writeAll("\n");

        if (std.mem.eql(u8, evaluation.semantic_op_id, "decode.final_logits")) {
            if (self.last_decode_source) |*source| source.deinit(self.allocator);
            self.last_decode_source = try runtime_decode.StoredDecodeSource.clone(
                self.allocator,
                evaluation.rewrite_target_handle,
                evaluation.semantic_op_id,
                evaluation.semantic_stage,
                evaluation.semantic_phase,
                evaluation.trigger_policy_id,
                evaluation.routing_policy_id,
                evaluation.fast_policy_id,
                evaluation.stable_policy_id,
                evaluation.reference_policy_id,
                evaluation.candidates,
                evaluation.execution_identity,
                first_divergence,
                .{
                    .fast = evaluation.fast_token,
                    .stable = evaluation.stable_token,
                    .reference = evaluation.reference_token,
                    .fastMatchesReference = evaluation.fast_token == evaluation.reference_token,
                    .stableMatchesReference = evaluation.stable_token == evaluation.reference_token,
                },
                .{
                    .fired = trigger_fired,
                    .checks = trigger_checks,
                    .proofLinks = trigger_policy.proofLinks,
                },
                .{
                    .decision = route_decision,
                    .selectionMode = route_metadata.selectionMode,
                    .committedResultMode = route_metadata.committedResultMode,
                    .downstreamAction = route_metadata.downstreamAction,
                    .effectApplied = effect_applied,
                    .selectedPolicyId = selected_policy_id,
                    .selectedToken = selected_token,
                    .proofLinks = routing_policy.proofLinks,
                    .selectionProofLinks = route_metadata.proofLinks,
                },
            );
        }

        self.receipt_count += 1;
        if (first_divergence != null) self.first_divergence_present_count += 1;
        updateDecisionCounts(&self.decision_counts, route_decision);
        if (explicit_annotation != null) {
            self.annotation_count += 1;
        } else {
            self.auto_detect_count += 1;
        }
        if (rewrite_applied) self.committed_stable_rewrite_count += 1;
        if (should_stop_downstream) self.downstream_stop_count += 1;

        return .{
            .route_decision = route_decision,
            .rewrite_applied = rewrite_applied,
            .should_stop_downstream = should_stop_downstream,
            .auto_detected = explicit_annotation == null,
        };
    }

    pub fn summary(self: *const Recorder) ?trace_numeric_stability.TraceNumericStabilitySummary {
        if (!self.enabled() or self.receipt_count == 0) return null;
        return .{
            .policy_registry_path = self.loaded_registry.?.policyRegistryPath,
            .policy_registry_version = self.loaded_registry.?.parsed.value.registryVersion,
            .route_taxonomy_version = self.loaded_registry.?.parsed.value.routeTaxonomyVersion,
            .execution_profile_id = self.selected_execution_profile.?.profileId,
            .receipt_path = self.receipt_path.?,
            .receipt_count = self.receipt_count,
            .decision_counts = self.decision_counts,
            .first_divergence_present_count = self.first_divergence_present_count,
            .annotation_count = self.annotation_count,
            .auto_detect_count = self.auto_detect_count,
            .committed_stable_rewrite_count = self.committed_stable_rewrite_count,
            .downstream_stop_count = self.downstream_stop_count,
        };
    }

    fn ensureReceiptFile(self: *Recorder) !void {
        if (self.receipt_file != null) return;
        const receipt_path = self.receipt_path orelse return error.NumericStabilityRecorderDisabled;
        if (std.fs.path.dirname(receipt_path)) |dir_name| {
            if (dir_name.len != 0) try std.fs.cwd().makePath(dir_name);
        }
        self.receipt_file = try std.fs.cwd().createFile(receipt_path, .{ .truncate = true });
    }

    fn recordDecodeBoundaryIfPresent(
        self: *Recorder,
        execution_context: *execution.ExecutionContext,
        command: model.Command,
        semantic: semantic_trace.SemanticContext,
    ) !?RecordOutcome {
        const source = self.last_decode_source orelse return null;
        if (!runtime_decode.matchesDecodeSampleCommand(command, semantic.op_id, semantic.phase)) return null;
        const dispatch = switch (command) {
            .kernel_dispatch => |payload| payload,
            else => return null,
        };
        const logits_handle = try runtime_decode.logitsHandleForSampleDispatch(dispatch);
        if (logits_handle != source.logits_handle) return null;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const decode_receipt = try runtime_decode.readDecodeReceipt(
            allocator,
            execution_context,
            dispatch,
            &source,
        );
        const decode_route_selected_token = if (std.mem.eql(u8, source.route.selectionMode, "stable"))
            decode_receipt.selected_token.stable
        else if (std.mem.eql(u8, source.route.selectionMode, "fast"))
            decode_receipt.selected_token.fast
        else
            null;
        const receipt = numeric_stability_service.Receipt{
            .schemaVersion = 1,
            .mode = "numeric-stability",
            .operatorFamily = "decode-sample-token",
            .semanticOpId = semantic.op_id.?,
            .semanticStage = semantic.stage.?,
            .semanticPhase = semantic.phase.?,
            .policyRegistryPath = self.loaded_registry.?.policyRegistryPath,
            .policyRegistryVersion = self.loaded_registry.?.parsed.value.registryVersion,
            .routeTaxonomyVersion = self.loaded_registry.?.parsed.value.routeTaxonomyVersion,
            .proofArtifactPath = self.loaded_registry.?.parsed.value.proofArtifactPath,
            .triggerPolicyId = source.trigger_policy_id,
            .routingPolicyId = source.routing_policy_id,
            .fastPolicyId = source.fast_policy_id,
            .stablePolicyId = source.stable_policy_id,
            .referencePolicyId = source.reference_policy_id,
            .candidates = source.candidates,
            .executionIdentity = source.execution_identity,
            .firstDivergence = source.first_divergence,
            .decodeBoundary = decode_receipt.decode_boundary,
            .selectedToken = decode_receipt.selected_token,
            .trigger = source.trigger,
            .route = .{
                .decision = source.route.decision,
                .selectionMode = source.route.selectionMode,
                .committedResultMode = source.route.committedResultMode,
                .downstreamAction = source.route.downstreamAction,
                .effectApplied = source.route.effectApplied,
                .selectedPolicyId = source.route.selectedPolicyId,
                .selectedToken = decode_route_selected_token,
                .proofLinks = source.route.proofLinks,
                .selectionProofLinks = source.route.selectionProofLinks,
            },
        };

        try self.ensureReceiptFile();
        const payload = try artifact.jsonStringifyAlloc(allocator, receipt);
        defer allocator.free(payload);
        try self.receipt_file.?.writeAll(payload);
        try self.receipt_file.?.writeAll("\n");

        self.receipt_count += 1;
        if (source.first_divergence != null) self.first_divergence_present_count += 1;
        updateDecisionCounts(&self.decision_counts, source.route.decision);
        return .{
            .route_decision = source.route.decision,
            .rewrite_applied = false,
            .should_stop_downstream = false,
            .auto_detected = true,
        };
    }
};

fn resolveObservation(
    allocator: std.mem.Allocator,
    registry: numeric_stability_policy.Registry,
    selected_execution_profile: ?numeric_stability_policy.ExecutionProfile,
    execution_context: *execution.ExecutionContext,
    command: model.Command,
    semantic: semantic_trace.SemanticContext,
    explicit_annotation: ?numeric_stability_annotation.Annotation,
    future_commands: []const model.Command,
    future_metadata: []const command_metadata.CommandMetadata,
    record_context: RecordContext,
) !?runtime_plan.Observation {
    if (explicit_annotation) |annotation| {
        return .{ .matmul = try runtime_plan.buildAnnotatedMatmulObservation(
            allocator,
            command,
            semantic,
            annotation,
            record_context,
        ) };
    }
    switch (command) {
        .kernel_dispatch => |dispatch| {
            const profile = numeric_stability_policy.resolveAutoDetectProfile(
                registry,
                semantic.op_id.?,
                semantic.stage,
                semantic.phase,
                std.fs.path.basename(dispatch.kernel),
            ) catch |err| switch (err) {
                numeric_stability_policy.PolicyLoadError.UnknownAutoDetectProfile => return null,
                else => return err,
            };
            const routing_policy_id = try resolveAutoDetectRoutingPolicyId(
                registry,
                profile,
                selected_execution_profile,
            );
            if (std.mem.eql(u8, profile.capturePlanId, runtime_plan.MATMUL_CAPTURE_PLAN_ID)) {
                return .{ .matmul = try runtime_plan.buildAutoMatmulObservation(
                    allocator,
                    execution_context,
                    dispatch,
                    semantic,
                    profile,
                    routing_policy_id,
                    record_context,
                ) };
            }
            if (std.mem.eql(u8, profile.capturePlanId, runtime_plan.MATMUL_DECODE_CAPTURE_PLAN_ID)) {
                return .{ .matmul = try runtime_plan.buildAutoDecodeFinalLogitsObservation(
                    allocator,
                    execution_context,
                    dispatch,
                    semantic,
                    profile,
                    routing_policy_id,
                    record_context,
                ) };
            }
            if (std.mem.eql(u8, profile.capturePlanId, runtime_plan.RMSNORM_CAPTURE_PLAN_ID)) {
                return .{ .rmsnorm = try runtime_plan.buildAutoRmsnormObservation(
                    allocator,
                    execution_context,
                    dispatch,
                    semantic,
                    profile,
                    routing_policy_id,
                    future_commands,
                    future_metadata,
                    record_context,
                ) };
            }
            if (std.mem.eql(u8, profile.capturePlanId, runtime_plan.ATTENTION_CAPTURE_PLAN_ID)) {
                return .{ .attention = try runtime_plan.buildAutoAttentionObservation(
                    allocator,
                    execution_context,
                    dispatch,
                    semantic,
                    profile,
                    routing_policy_id,
                    record_context,
                ) };
            }
            return error.NumericStabilityUnsupportedCapturePlan;
        },
        else => return null,
    }
}

fn resolveAutoDetectRoutingPolicyId(
    registry: numeric_stability_policy.Registry,
    profile: numeric_stability_policy.AutoDetectProfile,
    execution_profile: ?numeric_stability_policy.ExecutionProfile,
) ![]const u8 {
    const routing_policy_id = if (execution_profile) |selected_profile|
        selected_profile.routingPolicyId
    else
        profile.routingPolicyId;
    _ = try numeric_stability_policy.resolveRoutingPolicy(
        registry,
        routing_policy_id,
        profile.triggerPolicyId,
    );
    return routing_policy_id;
}

fn updateDecisionCounts(
    counts: *trace_numeric_stability.TraceNumericStabilityDecisionCounts,
    decision: []const u8,
) void {
    if (std.mem.eql(u8, decision, "accept-fast")) {
        counts.accept_fast += 1;
    } else if (std.mem.eql(u8, decision, "prefer-stable")) {
        counts.prefer_stable += 1;
    } else if (std.mem.eql(u8, decision, "abstain")) {
        counts.abstain += 1;
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
