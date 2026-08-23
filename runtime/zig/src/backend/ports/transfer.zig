//! Narrow outbound port interface for memory transfers and buffer updates.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");
const configuration = @import("../../contracts/runtime_configuration.zig");

pub const TransferPortVTable = struct {
    execute_transfer: *const fn (ctx: *anyopaque, op: prepared.PreparedTransferOperation) anyerror!report.ExecutionReport,
    prewarm_upload: *const fn (ctx: *anyopaque, max_upload_bytes: u64) anyerror!void,
    set_upload_behavior: *const fn (ctx: *anyopaque, mode: configuration.UploadBufferUsageMode, submit_every: u32) void,
};

pub const TransferPort = struct {
    context: *anyopaque,
    vtable: *const TransferPortVTable,

    pub fn execute(self: TransferPort, op: prepared.PreparedTransferOperation) !report.ExecutionReport {
        return self.vtable.execute_transfer(self.context, op);
    }

    pub fn prewarmUpload(self: TransferPort, max_upload_bytes: u64) !void {
        return self.vtable.prewarm_upload(self.context, max_upload_bytes);
    }

    pub fn setUploadBehavior(self: TransferPort, mode: configuration.UploadBufferUsageMode, submit_every: u32) void {
        self.vtable.set_upload_behavior(self.context, mode, submit_every);
    }
};
