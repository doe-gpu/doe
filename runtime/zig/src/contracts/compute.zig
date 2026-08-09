//! Backend-neutral contracts for the promoted compute-dispatch path.

const backend_contract = @import("backend.zig");
const execution_contract = @import("execution.zig");
const model_compute = @import("model/model_compute_types.zig");

pub const WorkgroupCount = struct {
    x: u32,
    y: u32,
    z: u32,
};

/// The deliberately small state slice visible at the backend dispatch seam.
/// Native resource, encoder, queue, and synchronization state remains owned by
/// the concrete backend behind `state`.
pub const ComputeContext = struct {
    backend: backend_contract.BackendId,
    state: *anyopaque,
};

pub const DispatchRequest = struct {
    kernel: []const u8,
    entry_point: ?[]const u8 = null,
    workgroups: WorkgroupCount,
    repeat: u32 = 1,
    repeat_synchronization: model_compute.KernelDispatchRepeatSynchronization = .dependent,
    warmup_dispatch_count: u32 = 0,
    initialize_buffers_on_create: bool = false,
    bindings: ?[]const model_compute.KernelBinding = null,
    output_oracle: ?model_compute.KernelDispatchOutputOracle = null,

    pub fn fromCommand(command: model_compute.KernelDispatchCommand) DispatchRequest {
        return .{
            .kernel = command.kernel,
            .entry_point = command.entry_point,
            .workgroups = .{ .x = command.x, .y = command.y, .z = command.z },
            .repeat = command.repeat,
            .repeat_synchronization = command.repeat_synchronization,
            .warmup_dispatch_count = command.warmup_dispatch_count,
            .initialize_buffers_on_create = command.initialize_buffers_on_create,
            .bindings = command.bindings,
            .output_oracle = command.output_oracle,
        };
    }

    pub fn toCommand(self: DispatchRequest) model_compute.KernelDispatchCommand {
        return .{
            .kernel = self.kernel,
            .entry_point = self.entry_point,
            .x = self.workgroups.x,
            .y = self.workgroups.y,
            .z = self.workgroups.z,
            .repeat = self.repeat,
            .repeat_synchronization = self.repeat_synchronization,
            .warmup_dispatch_count = self.warmup_dispatch_count,
            .initialize_buffers_on_create = self.initialize_buffers_on_create,
            .bindings = self.bindings,
            .output_oracle = self.output_oracle,
        };
    }
};

/// Common dispatch result. Receipt-bearing timing and status fields retain the
/// single definitions in the execution contract.
pub const DispatchReport = struct {
    execution: execution_contract.NativeExecutionResult,
};

test "dispatch request preserves the canonical command payload" {
    const std = @import("std");
    const binding = model_compute.KernelBinding{
        .binding = 2,
        .resource_kind = .buffer,
        .resource_handle = 9,
    };
    const command = model_compute.KernelDispatchCommand{
        .kernel = "sha256.wgsl",
        .entry_point = "main",
        .x = 3,
        .y = 5,
        .z = 7,
        .repeat = 11,
        .repeat_synchronization = .independent,
        .warmup_dispatch_count = 13,
        .initialize_buffers_on_create = true,
        .bindings = &.{binding},
    };

    const round_trip = DispatchRequest.fromCommand(command).toCommand();
    try std.testing.expectEqualStrings(command.kernel, round_trip.kernel);
    try std.testing.expectEqualStrings(command.entry_point.?, round_trip.entry_point.?);
    try std.testing.expectEqual(command.x, round_trip.x);
    try std.testing.expectEqual(command.y, round_trip.y);
    try std.testing.expectEqual(command.z, round_trip.z);
    try std.testing.expectEqual(command.repeat, round_trip.repeat);
    try std.testing.expectEqual(command.repeat_synchronization, round_trip.repeat_synchronization);
    try std.testing.expectEqual(command.warmup_dispatch_count, round_trip.warmup_dispatch_count);
    try std.testing.expectEqual(command.initialize_buffers_on_create, round_trip.initialize_buffers_on_create);
    try std.testing.expectEqual(command.bindings.?[0].resource_handle, round_trip.bindings.?[0].resource_handle);
}
