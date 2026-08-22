//! Promotion and revocation receipt contracts for DoeLab optimizations.
//!
//! Cryptographically binds an optimization candidate to physical device validation
//! evidence and oracle exactness before production promotion.

const std = @import("std");
const exactness = @import("exactness.zig");
const identity = @import("identity.zig");

pub const ComparisonDisposition = enum {
    promoted_faster_and_exact,
    rejected_output_divergence,
    rejected_latency_regression,
    rejected_hardware_instability,
    inconclusive_high_variance,
};

pub const PromotionReceipt = struct {
    candidate_id: []const u8,
    disposition: ComparisonDisposition = .promoted_faster_and_exact,
    hardware_adapter_id: []const u8,
    baseline_p50_ns: u64,
    candidate_p50_ns: u64,
    oracle_verdict: exactness.OracleResult,
    source_tree_sha256: identity.Sha256Digest,
    timestamp_unix_sec: u64,

    pub fn isPromoted(self: PromotionReceipt) bool {
        return self.disposition == .promoted_faster_and_exact and self.oracle_verdict.passed;
    }
};

pub const RevocationReceipt = struct {
    candidate_id: []const u8,
    reason: []const u8,
    failing_trace_sha256: identity.Sha256Digest,
    timestamp_unix_sec: u64,
};
