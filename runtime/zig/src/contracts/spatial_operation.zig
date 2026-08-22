//! Prepared spatial and CSL execution operation contracts.

const std = @import("std");
const identity = @import("identity.zig");

pub const SpatialFabricTarget = enum {
    wse2,
    wse3,
    host_simulator,
};

pub const PreparedSpatialOperation = struct {
    operation_id: u64,
    program_identity: identity.ProgramIdentity,
    fabric_target: SpatialFabricTarget = .host_simulator,
    grid_dim_x: u32 = 1,
    grid_dim_y: u32 = 1,
    task_count: u32 = 1,
};
