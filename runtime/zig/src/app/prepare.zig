//! Prepares, validates, and freezes application requests into immutable PreparedOperations.

const std = @import("std");
const request = @import("request.zig");
const prepared = @import("../contracts/prepared_operation.zig");
const model_compute = @import("../contracts/model/model_compute_types.zig");

pub fn prepareCompute(req: request.ComputeRequest, operation_id: u64) prepared.PreparedComputeOperation {
    return .{
        .operation_id = operation_id,
        .kernel_source = req.kernel_source,
        .entry_point = req.entry_point,
        .workgroups = req.workgroups,
        .bindings = req.bindings,
        .repeat = req.repeat,
        .repeat_synchronization = req.repeat_synchronization,
        .warmup_dispatch_count = req.warmup_dispatch_count,
        .initialize_buffers_on_create = req.initialize_buffers_on_create,
    };
}

pub fn prepareComputeFromCommand(cmd: model_compute.KernelDispatchCommand, operation_id: u64) prepared.PreparedComputeOperation {
    return .{
        .operation_id = operation_id,
        .kernel_source = cmd.kernel,
        .entry_point = cmd.entry_point,
        .workgroups = .{ .x = cmd.x, .y = cmd.y, .z = cmd.z },
        .bindings = cmd.bindings,
        .repeat = cmd.repeat,
        .repeat_synchronization = cmd.repeat_synchronization,
        .warmup_dispatch_count = cmd.warmup_dispatch_count,
        .initialize_buffers_on_create = cmd.initialize_buffers_on_create,
    };
}

pub fn prepareTransfer(req: request.TransferRequest, operation_id: u64) prepared.PreparedTransferOperation {
    return .{
        .operation_id = operation_id,
        .buffer_handle = req.buffer_handle,
        .offset_bytes = req.offset_bytes,
        .size_bytes = req.size_bytes,
        .data = req.data,
    };
}
