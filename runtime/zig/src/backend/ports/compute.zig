//! Narrow outbound port interface for compute kernel dispatch.
//!
//! Replaces broad monolithic backend vtables with a focused, single-responsibility
//! contract for executing prepared compute operations.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");
const configuration = @import("../../contracts/runtime_configuration.zig");
const model_compute = @import("../../contracts/model/model_compute_types.zig");

pub const ComputePortVTable = struct {
    execute_compute: *const fn (ctx: *anyopaque, op: prepared.PreparedComputeOperation) anyerror!report.ExecutionReport,
    prewarm_kernel: *const fn (ctx: *anyopaque, kernel: []const u8, entry_point: ?[]const u8, bindings: ?[]const model_compute.KernelBinding, initialize_buffers_on_create: bool) anyerror!void,
    set_gpu_timestamp_mode: *const fn (ctx: *anyopaque, mode: configuration.GpuTimestampMode) void,
};

pub const ComputePort = struct {
    context: *anyopaque,
    vtable: *const ComputePortVTable,

    pub fn execute(self: ComputePort, op: prepared.PreparedComputeOperation) !report.ExecutionReport {
        return self.vtable.execute_compute(self.context, op);
    }

    pub fn prewarmKernel(self: ComputePort, kernel: []const u8, entry_point: ?[]const u8, bindings: ?[]const model_compute.KernelBinding, initialize_buffers_on_create: bool) !void {
        return self.vtable.prewarm_kernel(self.context, kernel, entry_point, bindings, initialize_buffers_on_create);
    }

    pub fn setGpuTimestampMode(self: ComputePort, mode: configuration.GpuTimestampMode) void {
        self.vtable.set_gpu_timestamp_mode(self.context, mode);
    }
};
