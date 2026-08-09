const std = @import("std");
const numeric_stability_policy = @import("../policy.zig");
const trace_numeric_stability = @import("../trace_meta.zig");

pub const MODULE_ID = "doe_numeric_stability";
pub const MATMUL_LOGITS_SLICE_SERVICE_ID = "matmul_logits_slice";
pub const SUPPORTED_OPERATOR_FAMILY = "lm-head-slice";
pub const SUPPORTED_SEMANTIC_OP_ID = "matmul.logits";
pub const SUPPORTED_FAST_POLICY_ID = "lm-head-slice/forward-f16accum-v1";
pub const SUPPORTED_STABLE_POLICY_ID = "lm-head-slice/forward-serial-v1";
pub const REFERENCE_POLICY_ID = "lm-head-slice/cpu-f64-serial-v1";
pub const ZERO_HASH = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

pub const CandidateInput = struct {
    tokenId: u32,
    label: ?[]const u8 = null,
    weights: []const f64,
    bias: ?f64 = null,
};

pub const Request = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    serviceId: []const u8,
    operatorFamily: []const u8,
    semanticOpId: []const u8,
    semanticStage: []const u8,
    semanticPhase: []const u8,
    triggerPolicyId: []const u8,
    routingPolicyId: []const u8,
    fastPolicyId: []const u8,
    stablePolicyId: []const u8,
    candidates: []const CandidateInput,
    hiddenState: []const f64,
    receiptPath: ?[]const u8 = null,
    traceMetaPath: ?[]const u8 = null,
};

pub const Policy = struct {
    policyRegistryPath: []const u8,
    registry: numeric_stability_policy.Registry,
};

pub const ParsedPolicy = struct {
    parsed: std.json.Parsed(numeric_stability_policy.Registry),
    policyRegistryPath: []u8,
    value: Policy,

    pub fn deinit(self: *ParsedPolicy, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.policyRegistryPath);
    }
};

pub const ServiceResult = struct {
    status: []const u8,
};

pub const ExecutionStats = struct {
    dispatchCount: u64,
    bytesMoved: u64,
    candidateCount: u64,
};

pub const TimingStats = struct {
    setupNs: u64,
    encodeNs: u64,
    submitNs: u64,
    dispatchNs: u64,
};

pub const FailureDetails = struct {
    code: []const u8,
};

pub const ReceiptCandidate = struct {
    tokenId: u32,
    label: ?[]const u8 = null,
    fastLogit: f64,
    stableLogit: f64,
    referenceLogit: f64,
};

pub const FirstDivergence = struct {
    semanticOpId: []const u8,
    semanticStage: []const u8,
    semanticPhase: []const u8,
    fastDigest: []const u8,
    stableDigest: []const u8,
};

pub const SelectedTokenReceipt = struct {
    fast: u32,
    stable: u32,
    reference: u32,
    fastMatchesReference: bool,
    stableMatchesReference: bool,
};

pub const TriggerChecks = struct {
    firstDivergencePresent: bool,
    sensitiveOperatorMatched: bool,
    selectedTokenDisagreement: bool,
    stableMatchesExactReference: bool,
    fastMissesExactReference: bool,
};

pub const TriggerReceipt = struct {
    fired: bool,
    checks: TriggerChecks,
    proofLinks: []const numeric_stability_policy.ProofLink,
};

pub const RouteReceipt = struct {
    decision: []const u8,
    selectionMode: []const u8,
    committedResultMode: []const u8,
    downstreamAction: []const u8,
    effectApplied: bool,
    selectedPolicyId: ?[]const u8 = null,
    selectedToken: ?u32 = null,
    proofLinks: []const numeric_stability_policy.ProofLink,
    selectionProofLinks: []const numeric_stability_policy.ProofLink,
};

pub const ExecutionIdentityReceipt = struct {
    kernelPath: ?[]const u8 = null,
    kernelBasename: ?[]const u8 = null,
    layoutFingerprint: ?[]const u8 = null,
    compiledPlanHash: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    backendLane: ?[]const u8 = null,
    adapterOrdinal: ?u32 = null,
    queueFamilyIndex: ?u32 = null,
    presentCapable: ?bool = null,
    profileVendor: ?[]const u8 = null,
    profileApi: ?[]const u8 = null,
    profileFamily: ?[]const u8 = null,
    profileDriver: ?[]const u8 = null,
    selectionPolicyHash: ?[]const u8 = null,
    hostPlanArtifactHash: ?[]const u8 = null,
};

pub const UpstreamReceiptLink = struct {
    semanticOpId: []const u8,
    semanticStage: []const u8,
    semanticPhase: []const u8,
    selectedPolicyId: ?[]const u8 = null,
    decision: []const u8,
};

pub const DecodeBoundaryMetrics = struct {
    fastTop1Margin: f64,
    stableTop1Margin: f64,
    referenceTop1Margin: f64,
    topKBoundaryGap: ?f64 = null,
    topPBoundaryGap: ?f64 = null,
    cdfDistanceToDraw: ?f64 = null,
    adjacentDecodePersistence: ?u32 = null,
    actualSelectedTokenChanged: bool,
    liveSelectedMatchesFast: bool,
    liveSelectedMatchesStable: bool,
    liveSelectedMatchesReference: bool,
};

pub const DecodeBoundaryReceipt = struct {
    decodeMode: []const u8,
    logitsCoverage: []const u8,
    vocabSize: u32,
    residualMassUpperBound: ?f64 = null,
    temperature: ?f64 = null,
    topK: ?u32 = null,
    topP: ?f64 = null,
    rngSeed: ?u64 = null,
    rngDraw: ?f64 = null,
    survivingTokenSetKind: []const u8,
    survivingTokenIds: ?[]const u32 = null,
    liveSelectedToken: u32,
    liveSelectedMatchesCommittedSelection: bool,
    metrics: DecodeBoundaryMetrics,
    upstreamLinks: []const UpstreamReceiptLink,
};

pub const Receipt = struct {
    schemaVersion: u32,
    mode: []const u8,
    operatorFamily: []const u8,
    semanticOpId: []const u8,
    semanticStage: []const u8,
    semanticPhase: []const u8,
    policyRegistryPath: []const u8,
    policyRegistryVersion: []const u8,
    routeTaxonomyVersion: []const u8,
    proofArtifactPath: []const u8,
    triggerPolicyId: []const u8,
    routingPolicyId: []const u8,
    fastPolicyId: []const u8,
    stablePolicyId: []const u8,
    referencePolicyId: []const u8,
    candidates: []const ReceiptCandidate,
    executionIdentity: ?ExecutionIdentityReceipt = null,
    firstDivergence: ?FirstDivergence = null,
    decodeBoundary: ?DecodeBoundaryReceipt = null,
    selectedToken: SelectedTokenReceipt,
    trigger: TriggerReceipt,
    route: RouteReceipt,
};

pub const ResultNoTrace = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    serviceId: []const u8,
    serviceResult: ServiceResult,
    executionStats: ExecutionStats,
    timingStats: TimingStats,
    failureDetails: FailureDetails,
    routeDecision: []const u8,
    selectedToken: ?u32,
    receiptPath: ?[]const u8 = null,
    traceMetaPath: ?[]const u8 = null,
    receipt: Receipt,
};

pub const Result = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    serviceId: []const u8,
    serviceResult: ServiceResult,
    executionStats: ExecutionStats,
    timingStats: TimingStats,
    failureDetails: FailureDetails,
    routeDecision: []const u8,
    selectedToken: ?u32,
    receiptPath: ?[]const u8 = null,
    traceMetaPath: ?[]const u8 = null,
    receipt: Receipt,
    traceLink: @import("../../../contracts/artifact.zig").TraceLink,
};

pub const HashlessTraceMeta = struct {
    traceVersion: u32,
    module: []const u8,
    seqMax: u32,
    rowCount: u32,
    numericStability: trace_numeric_stability.TraceNumericStabilitySummary,
};

pub const TraceMetaFile = struct {
    traceVersion: u32,
    module: []const u8,
    seqMax: u32,
    rowCount: u32,
    hash: []const u8,
    previousHash: []const u8,
    numericStability: trace_numeric_stability.TraceNumericStabilitySummary,
};
