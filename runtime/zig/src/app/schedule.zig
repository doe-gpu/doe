//! Application command scheduling and ordering pass.

const std = @import("std");
const prepared = @import("../contracts/prepared_operation.zig");

pub const ScheduledBatch = struct {
    operations: []const prepared.PreparedOperation,
    sync_after_batch: bool = true,
};

pub fn createSingleOperationBatch(op: prepared.PreparedOperation) ScheduledBatch {
    const static_holder = struct {
        var single_op_buf: [1]prepared.PreparedOperation = undefined;
    };
    static_holder.single_op_buf[0] = op;
    return .{
        .operations = &static_holder.single_op_buf,
        .sync_after_batch = true,
    };
}
