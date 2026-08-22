//! Domain contracts for evidence requirements, checkpoints, events, and dispositions.
//!
//! Hexagonal rule: Pure data contracts defining evidence collection policies.
//! Contains no filesystem I/O or stateful emitter logic.

const std = @import("std");
const identity = @import("identity.zig");
const exactness = @import("exactness.zig");

pub const EvidenceDisposition = enum {
    none,
    trace_events_only,
    execution_receipt_required,
    oracle_verification_required,
    full_deterministic_replay_required,
};

pub const EvidenceCheckpoint = struct {
    checkpoint_id: []const u8,
    timestamp_mono_ns: u64,
    event_digest: identity.Sha256Digest,
};

pub const EvidenceRequirement = struct {
    disposition: EvidenceDisposition = .none,
    record_gpu_timestamps: bool = true,
    expected_source_digest: ?identity.Sha256Digest = null,
    tolerance_policy: ?exactness.TolerancePolicy = null,
};

pub const EvidenceEvent = struct {
    seq: u64,
    operation_id: u64,
    checkpoint: EvidenceCheckpoint,
    source_program_digest: identity.Sha256Digest,
};
