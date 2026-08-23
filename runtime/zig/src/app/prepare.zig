//! Prepares requests into read-only PreparedOperations for synchronous execution.

const std = @import("std");
const request = @import("request.zig");
const command_contract = @import("../contracts/command.zig");
const prepared = @import("../contracts/prepared_operation.zig");
const model_compute = @import("../contracts/model/model_compute_types.zig");

pub fn prepareCompute(req: request.ComputeRequest, operation_id: u64) prepared.PreparedComputeOperation {
    return prepareComputeFromCommand(.{
        .kernel = req.kernel_source,
        .entry_point = req.entry_point,
        .x = req.workgroups.x,
        .y = req.workgroups.y,
        .z = req.workgroups.z,
        .bindings = req.bindings,
        .repeat = req.repeat,
        .repeat_synchronization = req.repeat_synchronization,
        .warmup_dispatch_count = req.warmup_dispatch_count,
        .initialize_buffers_on_create = req.initialize_buffers_on_create,
    }, operation_id);
}

pub fn prepareComputeFromCommand(cmd: model_compute.KernelDispatchCommand, operation_id: u64) prepared.PreparedComputeOperation {
    return prepareCommand(.{ .kernel_dispatch = cmd }, operation_id).compute;
}

pub fn prepareTransfer(req: request.TransferRequest, operation_id: u64) prepared.PreparedTransferOperation {
    return prepared.directBufferWrite(.{
        .handle = req.buffer_handle,
        .offset_bytes = req.offset_bytes,
        .buffer_size = req.size_bytes,
        .data = req.data,
    }, operation_id).transfer;
}

pub fn prepareCommand(command: command_contract.Command, operation_id: u64) prepared.PreparedOperation {
    return prepared.fromCommand(command, operation_id);
}
