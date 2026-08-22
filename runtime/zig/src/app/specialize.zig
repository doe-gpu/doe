//! Application specialization module.
//!
//! Evaluates specialization policies and workload profiles to configure kernel parameters.

const std = @import("std");
const workload = @import("../contracts/workload_profile.zig");
const specialization = @import("../contracts/specialization_policy.zig");

pub const SpecializationDecision = struct {
    elide_robustness_clamp: bool = false,
    tile_size_x: u32 = 16,
    tile_size_y: u32 = 16,
};

pub fn evaluateSpecialization(profile: workload.WorkloadProfile, policy: specialization.SpecializationPolicy) SpecializationDecision {
    var decision = SpecializationDecision{};
    if (profile.allow_bounds_elision and !policy.strict_parity_mode) {
        decision.elide_robustness_clamp = true;
    }
    if (profile.priority == .interactive_lowest_latency) {
        decision.tile_size_x = 8;
        decision.tile_size_y = 8;
    }
    return decision;
}
