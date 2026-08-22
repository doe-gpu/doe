//! Specialization policy contracts for DoeLab optimization cohorts.
//!
//! Encapsulates optimization candidate flags, tile geometries, and dispatch heuristics
//! that can be systematically evaluated in differential testing before promotion.

const std = @import("std");
const workload = @import("workload_profile.zig");

pub const OptimizationKind = enum {
    robustness_clamp_elision,
    tile_dimension_specialization,
    constant_propagation,
    loop_unroll_specialization,
    shared_memory_coalescing,
};

pub const OptimizationCandidate = struct {
    id: []const u8,
    kind: OptimizationKind,
    target_shader_sha256: [32]u8 = [_]u8{0} ** 32,
    enabled_by_default: bool = false,
};

pub const ExperimentCohort = struct {
    cohort_id: []const u8,
    profile: workload.WorkloadProfile,
    candidates: []const OptimizationCandidate,
};

pub const SpecializationPolicy = struct {
    allow_speculative_hoisting: bool = true,
    strict_parity_mode: bool = true,
    active_cohort: ?ExperimentCohort = null,
};
