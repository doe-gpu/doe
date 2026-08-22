//! Application request contracts for the Hexagonal core.
//!
//! Represents incoming application intent before normalization and preparation.

const std = @import("std");
const compute_contract = @import("../contracts/compute.zig");
const model_compute = @import("../contracts/model/model_compute_types.zig");

pub const WorkgroupCount = compute_contract.WorkgroupCount;

pub const ComputeRequest = struct {
    kernel_source: []const u8,
    entry_point: ?[]const u8 = null,
    workgroups: compute_contract.WorkgroupCount,
    bindings: ?[]const model_compute.KernelBinding = null,
    repeat: u32 = 1,
    repeat_synchronization: model_compute.KernelDispatchRepeatSynchronization = .dependent,
    warmup_dispatch_count: u32 = 0,
    initialize_buffers_on_create: bool = false,
};

pub const TransferRequest = struct {
    buffer_handle: u64,
    offset_bytes: u64 = 0,
    size_bytes: u64,
    data: []const u8,
};

pub const ApplicationRequest = union(enum) {
    compute: ComputeRequest,
    transfer: TransferRequest,
};
