//! Immutable, pre-validated execution units for the Hexagonal runtime core.
//!
//! An inbound request (command JSON, native WebGPU call, or plan) is normalized
//! and validated into a PreparedOperation before it reaches any backend port.

const std = @import("std");
const compute_contract = @import("compute.zig");
const identity_contract = @import("identity.zig");
const model_compute = @import("model/model_compute_types.zig");

pub const PreparedComputeOperation = struct {
    operation_id: u64 = 0,
    kernel_source: []const u8,
    entry_point: ?[]const u8 = null,
    workgroups: compute_contract.WorkgroupCount,
    bindings: ?[]const model_compute.KernelBinding = null,
    repeat: u32 = 1,
    repeat_synchronization: model_compute.KernelDispatchRepeatSynchronization = .dependent,
    warmup_dispatch_count: u32 = 0,
    initialize_buffers_on_create: bool = false,
    identity: identity_contract.OperationIdentity = .{},

    pub fn toDispatchRequest(self: PreparedComputeOperation) compute_contract.DispatchRequest {
        return .{
            .kernel = self.kernel_source,
            .entry_point = self.entry_point,
            .workgroups = self.workgroups,
            .repeat = self.repeat,
            .repeat_synchronization = self.repeat_synchronization,
            .warmup_dispatch_count = self.warmup_dispatch_count,
            .initialize_buffers_on_create = self.initialize_buffers_on_create,
            .bindings = self.bindings,
        };
    }
};

pub const PreparedTransferOperation = struct {
    operation_id: u64 = 0,
    buffer_handle: u64,
    offset_bytes: u64 = 0,
    size_bytes: u64,
    data: []const u8,
};

pub const PreparedOperation = union(enum) {
    compute: PreparedComputeOperation,
    transfer: PreparedTransferOperation,
};
