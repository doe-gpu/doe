const std = @import("std");

pub const DEFAULT_POLICY_PATH = "config/numeric-stability-policy.json";
const MAX_POLICY_BYTES: usize = 128 * 1024;
const EXPECTED_SCHEMA_VERSION: u32 = 3;
pub const EXECUTION_SURFACE_ORDINARY_EXECUTION = "ordinary-execution";
pub const SELECTION_MODE_FAST = "fast";
pub const SELECTION_MODE_STABLE = "stable";
pub const SELECTION_MODE_NONE = "none";
pub const COMMITTED_RESULT_MODE_FAST = "fast";
pub const COMMITTED_RESULT_MODE_STABLE = "stable";
pub const COMMITTED_RESULT_MODE_NONE = "none";
pub const DOWNSTREAM_ACTION_CONTINUE = "continue";
pub const DOWNSTREAM_ACTION_STOP = "stop";

pub const PolicyLoadError = error{
    InvalidPolicyRegistry,
    UnknownTriggerPolicy,
    UnknownRoutingPolicy,
    UnknownRouteDecisionMetadata,
    UnknownExecutionProfile,
    UnknownAutoDetectProfile,
    TriggerPolicyMismatch,
    ExecutionSurfaceMismatch,
};

pub const ProofLink = struct {
    theorem: []const u8,
    module: []const u8,
    category: []const u8,
    relation: []const u8,
    artifactPath: []const u8,
};

pub const TriggerPolicy = struct {
    triggerPolicyId: []const u8,
    requireFirstDivergence: bool,
    requireSelectedTokenDisagreement: bool,
    requireStableMatchesExactReference: bool,
    requireFastMissesExactReference: bool,
    allowedSensitiveOperators: []const []const u8,
    proofLinks: []const ProofLink,
};

pub const RoutingPolicy = struct {
    policyId: []const u8,
    triggerPolicyId: []const u8,
    triggeredDecision: []const u8,
    fallbackDecision: []const u8,
    proofLinks: []const ProofLink,
};

pub const RouteDecisionMetadata = struct {
    decision: []const u8,
    selectionMode: []const u8,
    committedResultMode: []const u8,
    downstreamAction: []const u8,
    proofLinks: []const ProofLink,
};

pub const AutoDetectProfile = struct {
    profileId: []const u8,
    enabled: bool,
    operatorFamily: []const u8,
    semanticOpId: []const u8,
    semanticStage: ?[]const u8 = null,
    semanticPhase: ?[]const u8 = null,
    kernelBasenames: []const []const u8,
    triggerPolicyId: []const u8,
    routingPolicyId: []const u8,
    fastPolicyId: []const u8,
    stablePolicyId: []const u8,
    referencePolicyId: []const u8,
    capturePlanId: []const u8,
    decisionStrategyId: []const u8,
};

pub const ExecutionProfile = struct {
    profileId: []const u8,
    surface: []const u8,
    description: []const u8,
    routingPolicyId: []const u8,
};

pub const Registry = struct {
    schemaVersion: u32,
    registryVersion: []const u8,
    routeTaxonomyVersion: []const u8,
    proofArtifactPath: []const u8,
    defaultExecutionProfileId: []const u8,
    routeDecisions: []const []const u8,
    routeDecisionMetadata: []const RouteDecisionMetadata,
    executionProfiles: []const ExecutionProfile,
    autoDetectProfiles: []const AutoDetectProfile,
    triggerPolicies: []const TriggerPolicy,
    routingPolicies: []const RoutingPolicy,
};

pub const LoadedRegistry = struct {
    parsed: std.json.Parsed(Registry),
    policyRegistryPath: []u8,

    pub fn deinit(self: *LoadedRegistry, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.policyRegistryPath);
    }
};

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn isValidSelectionMode(value: []const u8) bool {
    return std.mem.eql(u8, value, SELECTION_MODE_FAST) or
        std.mem.eql(u8, value, SELECTION_MODE_STABLE) or
        std.mem.eql(u8, value, SELECTION_MODE_NONE);
}

fn isValidCommittedResultMode(value: []const u8) bool {
    return std.mem.eql(u8, value, COMMITTED_RESULT_MODE_FAST) or
        std.mem.eql(u8, value, COMMITTED_RESULT_MODE_STABLE) or
        std.mem.eql(u8, value, COMMITTED_RESULT_MODE_NONE);
}

fn isValidDownstreamAction(value: []const u8) bool {
    return std.mem.eql(u8, value, DOWNSTREAM_ACTION_CONTINUE) or
        std.mem.eql(u8, value, DOWNSTREAM_ACTION_STOP);
}

fn isValidExecutionSurface(value: []const u8) bool {
    return std.mem.eql(u8, value, EXECUTION_SURFACE_ORDINARY_EXECUTION);
}

pub fn parseRegistry(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Registry) {
    const parsed = try std.json.parseFromSlice(Registry, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try ensureValidRegistry(parsed.value);
    return parsed;
}

pub fn loadRegistry(allocator: std.mem.Allocator, policy_path: []const u8) !LoadedRegistry {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, policy_path, MAX_POLICY_BYTES);
    defer allocator.free(bytes);
    var parsed = try parseRegistry(allocator, bytes);
    errdefer parsed.deinit();
    return .{
        .parsed = parsed,
        .policyRegistryPath = try allocator.dupe(u8, policy_path),
    };
}

pub fn resolveTriggerPolicy(registry: Registry, trigger_policy_id: []const u8) !TriggerPolicy {
    for (registry.triggerPolicies) |entry| {
        if (std.mem.eql(u8, entry.triggerPolicyId, trigger_policy_id)) return entry;
    }
    return PolicyLoadError.UnknownTriggerPolicy;
}

pub fn resolveRoutingPolicy(
    registry: Registry,
    routing_policy_id: []const u8,
    expected_trigger_policy_id: ?[]const u8,
) !RoutingPolicy {
    for (registry.routingPolicies) |entry| {
        if (!std.mem.eql(u8, entry.policyId, routing_policy_id)) continue;
        if (expected_trigger_policy_id) |trigger_policy_id| {
            if (!std.mem.eql(u8, entry.triggerPolicyId, trigger_policy_id)) {
                return PolicyLoadError.TriggerPolicyMismatch;
            }
        }
        return entry;
    }
    return PolicyLoadError.UnknownRoutingPolicy;
}

pub fn resolveRouteDecisionMetadata(registry: Registry, decision: []const u8) !RouteDecisionMetadata {
    for (registry.routeDecisionMetadata) |entry| {
        if (std.mem.eql(u8, entry.decision, decision)) return entry;
    }
    return PolicyLoadError.UnknownRouteDecisionMetadata;
}

pub fn resolveExecutionProfile(
    registry: Registry,
    execution_profile_id: []const u8,
    expected_surface: ?[]const u8,
) !ExecutionProfile {
    for (registry.executionProfiles) |entry| {
        if (!std.mem.eql(u8, entry.profileId, execution_profile_id)) continue;
        if (expected_surface) |surface| {
            if (!std.mem.eql(u8, entry.surface, surface)) {
                return PolicyLoadError.ExecutionSurfaceMismatch;
            }
        }
        return entry;
    }
    return PolicyLoadError.UnknownExecutionProfile;
}

pub fn resolveAutoDetectProfile(
    registry: Registry,
    semantic_op_id: []const u8,
    semantic_stage: ?[]const u8,
    semantic_phase: ?[]const u8,
    kernel_basename: []const u8,
) !AutoDetectProfile {
    for (registry.autoDetectProfiles) |entry| {
        if (!entry.enabled) continue;
        if (!std.mem.eql(u8, entry.semanticOpId, semantic_op_id)) continue;
        if (entry.semanticStage) |required_stage| {
            if (semantic_stage == null or !std.mem.eql(u8, semantic_stage.?, required_stage)) continue;
        }
        if (entry.semanticPhase) |required_phase| {
            if (semantic_phase == null or !std.mem.eql(u8, semantic_phase.?, required_phase)) continue;
        }
        if (!containsString(entry.kernelBasenames, kernel_basename)) continue;
        return entry;
    }
    return PolicyLoadError.UnknownAutoDetectProfile;
}

pub fn ensureValidRegistry(registry: Registry) !void {
    if (registry.schemaVersion != EXPECTED_SCHEMA_VERSION) {
        return PolicyLoadError.InvalidPolicyRegistry;
    }
    if (registry.registryVersion.len == 0 or
        registry.routeTaxonomyVersion.len == 0 or
        registry.proofArtifactPath.len == 0 or
        registry.defaultExecutionProfileId.len == 0)
    {
        return PolicyLoadError.InvalidPolicyRegistry;
    }
    if (registry.routeDecisions.len == 0 or
        registry.routeDecisionMetadata.len == 0 or
        registry.executionProfiles.len == 0 or
        registry.autoDetectProfiles.len == 0 or
        registry.triggerPolicies.len == 0 or
        registry.routingPolicies.len == 0)
    {
        return PolicyLoadError.InvalidPolicyRegistry;
    }
    for (registry.routeDecisionMetadata) |entry| {
        if (!containsString(registry.routeDecisions, entry.decision)) {
            return PolicyLoadError.InvalidPolicyRegistry;
        }
        if (!isValidSelectionMode(entry.selectionMode) or
            !isValidCommittedResultMode(entry.committedResultMode) or
            !isValidDownstreamAction(entry.downstreamAction))
        {
            return PolicyLoadError.InvalidPolicyRegistry;
        }
    }
    for (registry.routeDecisions) |decision| {
        _ = try resolveRouteDecisionMetadata(registry, decision);
    }
    for (registry.executionProfiles) |entry| {
        if (entry.profileId.len == 0 or
            entry.description.len == 0 or
            !isValidExecutionSurface(entry.surface))
        {
            return PolicyLoadError.InvalidPolicyRegistry;
        }
        _ = try resolveRoutingPolicy(registry, entry.routingPolicyId, null);
    }
    _ = try resolveExecutionProfile(
        registry,
        registry.defaultExecutionProfileId,
        EXECUTION_SURFACE_ORDINARY_EXECUTION,
    );
    for (registry.routingPolicies) |entry| {
        if (!containsString(registry.routeDecisions, entry.triggeredDecision)) {
            return PolicyLoadError.InvalidPolicyRegistry;
        }
        if (!containsString(registry.routeDecisions, entry.fallbackDecision)) {
            return PolicyLoadError.InvalidPolicyRegistry;
        }
        _ = try resolveTriggerPolicy(registry, entry.triggerPolicyId);
    }
    for (registry.autoDetectProfiles) |entry| {
        if (entry.profileId.len == 0 or
            entry.operatorFamily.len == 0 or
            entry.semanticOpId.len == 0 or
            entry.kernelBasenames.len == 0 or
            entry.fastPolicyId.len == 0 or
            entry.stablePolicyId.len == 0 or
            entry.referencePolicyId.len == 0 or
            entry.capturePlanId.len == 0 or
            entry.decisionStrategyId.len == 0)
        {
            return PolicyLoadError.InvalidPolicyRegistry;
        }
        const routing_policy = try resolveRoutingPolicy(
            registry,
            entry.routingPolicyId,
            entry.triggerPolicyId,
        );
        _ = routing_policy;
        _ = try resolveTriggerPolicy(registry, entry.triggerPolicyId);
    }
}

test "parse registry and resolve policies" {
    const allocator = std.testing.allocator;
    const fixture =
        \\{
        \\  "schemaVersion": 3,
        \\  "registryVersion": "2026-03-29-execution-profiles-v1",
        \\  "routeTaxonomyVersion": "numeric-stability-routes-v1",
        \\  "proofArtifactPath": "pipeline/lean/artifacts/proven-conditions.json",
        \\  "defaultExecutionProfileId": "execution/default-v1",
        \\  "routeDecisions": ["accept-fast", "prefer-stable", "abstain"],
        \\  "routeDecisionMetadata": [{
        \\    "decision": "accept-fast",
        \\    "selectionMode": "fast",
        \\    "committedResultMode": "fast",
        \\    "downstreamAction": "continue",
        \\    "proofLinks": [{
        \\      "theorem": "demo_select_fast",
        \\      "module": "Doe.Core.NumericStabilityPolicy",
        \\      "category": "lean_verified",
        \\      "relation": "route-fast",
        \\      "artifactPath": "pipeline/lean/artifacts/proven-conditions.json"
        \\    }]
        \\  }, {
        \\    "decision": "prefer-stable",
        \\    "selectionMode": "stable",
        \\    "committedResultMode": "stable",
        \\    "downstreamAction": "continue",
        \\    "proofLinks": [{
        \\      "theorem": "demo_select_stable",
        \\      "module": "Doe.Core.NumericStabilityPolicy",
        \\      "category": "lean_verified",
        \\      "relation": "route-stable",
        \\      "artifactPath": "pipeline/lean/artifacts/proven-conditions.json"
        \\    }]
        \\  }, {
        \\    "decision": "abstain",
        \\    "selectionMode": "none",
        \\    "committedResultMode": "none",
        \\    "downstreamAction": "stop",
        \\    "proofLinks": [{
        \\      "theorem": "demo_select_none",
        \\      "module": "Doe.Core.NumericStabilityPolicy",
        \\      "category": "lean_verified",
        \\      "relation": "route-none",
        \\      "artifactPath": "pipeline/lean/artifacts/proven-conditions.json"
        \\    }]
        \\  }],
        \\  "executionProfiles": [{
        \\    "profileId": "execution/default-v1",
        \\    "surface": "ordinary-execution",
        \\    "description": "default execution profile",
        \\    "routingPolicyId": "route/v1"
        \\  }],
        \\  "autoDetectProfiles": [{
        \\    "profileId": "auto/matmul-v1",
        \\    "enabled": true,
        \\    "operatorFamily": "lm-head-slice",
        \\    "semanticOpId": "matmul.logits",
        \\    "semanticStage": null,
        \\    "semanticPhase": "logits",
        \\    "kernelBasenames": ["matmul_logits_forward_f16accum.wgsl"],
        \\    "triggerPolicyId": "trigger/v1",
        \\    "routingPolicyId": "route/v1",
        \\    "fastPolicyId": "fast/v1",
        \\    "stablePolicyId": "stable/v1",
        \\    "referencePolicyId": "reference/v1",
        \\    "capturePlanId": "capture/v1",
        \\    "decisionStrategyId": "decision/v1"
        \\  }],
        \\  "triggerPolicies": [{
        \\    "triggerPolicyId": "trigger/v1",
        \\    "requireFirstDivergence": true,
        \\    "requireSelectedTokenDisagreement": true,
        \\    "requireStableMatchesExactReference": true,
        \\    "requireFastMissesExactReference": true,
        \\    "allowedSensitiveOperators": ["matmul.logits"],
        \\    "proofLinks": [{
        \\      "theorem": "demo_trigger",
        \\      "module": "Doe.Core.NumericStabilityPolicy",
        \\      "category": "lean_verified",
        \\      "relation": "trigger",
        \\      "artifactPath": "pipeline/lean/artifacts/proven-conditions.json"
        \\    }]
        \\  }],
        \\  "routingPolicies": [{
        \\    "policyId": "route/v1",
        \\    "triggerPolicyId": "trigger/v1",
        \\    "triggeredDecision": "prefer-stable",
        \\    "fallbackDecision": "accept-fast",
        \\    "proofLinks": [{
        \\      "theorem": "demo_route",
        \\      "module": "Doe.Core.NumericStabilityPolicy",
        \\      "category": "lean_verified",
        \\      "relation": "route",
        \\      "artifactPath": "pipeline/lean/artifacts/proven-conditions.json"
        \\    }]
        \\  }]
        \\}
    ;

    var parsed = try parseRegistry(allocator, fixture);
    defer parsed.deinit();

    const trigger_policy = try resolveTriggerPolicy(parsed.value, "trigger/v1");
    try std.testing.expectEqualStrings("trigger/v1", trigger_policy.triggerPolicyId);

    const routing_policy = try resolveRoutingPolicy(parsed.value, "route/v1", "trigger/v1");
    try std.testing.expectEqualStrings("prefer-stable", routing_policy.triggeredDecision);

    const route_metadata = try resolveRouteDecisionMetadata(parsed.value, "prefer-stable");
    try std.testing.expectEqualStrings(SELECTION_MODE_STABLE, route_metadata.selectionMode);
    try std.testing.expectEqualStrings(COMMITTED_RESULT_MODE_STABLE, route_metadata.committedResultMode);
    try std.testing.expectEqualStrings(DOWNSTREAM_ACTION_CONTINUE, route_metadata.downstreamAction);
    const execution_profile = try resolveExecutionProfile(
        parsed.value,
        "execution/default-v1",
        EXECUTION_SURFACE_ORDINARY_EXECUTION,
    );
    try std.testing.expectEqualStrings("route/v1", execution_profile.routingPolicyId);

    const profile = try resolveAutoDetectProfile(
        parsed.value,
        "matmul.logits",
        "real_lm_head_slice",
        "logits",
        "matmul_logits_forward_f16accum.wgsl",
    );
    try std.testing.expectEqualStrings("auto/matmul-v1", profile.profileId);
}
