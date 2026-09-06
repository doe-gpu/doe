const std = @import("std");
const objects = @import("../support/doe_native_object_types.zig");
const helpers = @import("../support/doe_native_object_helpers.zig");
const commands = @import("../support/doe_native_command_types.zig");
const exports = @import("../support/doe_native_exports.zig");
const references = @import("../command/doe_command_references.zig");
const trace = @import("../diagnostics/doe_program_identity_trace.zig");
const bindings = @import("doe_compute_bind_groups.zig");
const preconditions = @import("doe_compute_preconditions_native.zig");
const vulkan = @import("doe_compute_fast_vulkan.zig");

pub const ConstructionError = std.mem.Allocator.Error || preconditions.ValidationError || error{ InvalidArgument, InvalidState };

pub const Dispatch = struct {
    pipeline: *objects.DoeComputePipeline,
    bind_groups: [bindings.MAX_COMPUTE_BIND_GROUPS]?*objects.DoeBindGroup =
        [_]?*objects.DoeBindGroup{null} ** bindings.MAX_COMPUTE_BIND_GROUPS,
    workgroups: [3]u32,
};

pub const Copy = struct {
    source: ?*objects.DoeBuffer,
    source_offset: u64,
    destination: ?*objects.DoeBuffer,
    destination_offset: u64,
    size: u64,
};

pub const Builder = struct {
    pending: ?*objects.DoeCommandBuffer,

    pub fn init(allocator: std.mem.Allocator, device: *objects.DoeDevice) ConstructionError!Builder {
        const buffer = try allocator.create(objects.DoeCommandBuffer);
        buffer.* = .{ .allocator = allocator, .dev = device, .device_ref = device };
        helpers.object_add_ref(objects.DoeDevice, helpers.toOpaque(device));
        trace.recordNativeObjectCreate(objects.DoeCommandBuffer, buffer);
        return .{ .pending = buffer };
    }

    pub fn deinit(self: *Builder) void {
        if (self.pending) |buffer| exports.doeNativeCommandBufferRelease(helpers.toOpaque(buffer));
        self.pending = null;
    }

    pub fn finish(self: *Builder) ConstructionError!*objects.DoeCommandBuffer {
        const buffer = self.pending orelse return error.InvalidState;
        self.pending = null;
        return buffer;
    }

    pub fn appendDispatch(self: *Builder, request: Dispatch) ConstructionError!void {
        const buffer = self.pending orelse return error.InvalidState;
        const pipeline = request.pipeline;
        try preconditions.validate_bind_groups(
            pipeline.dispatch_preconditions,
            pipeline.texture_dispatch_preconditions,
            &request.bind_groups,
            request.workgroups,
            .{ pipeline.wg_x, pipeline.wg_y, pipeline.wg_z },
        );
        var command = commands.RecordedCmd{ .dispatch = .{
            .compute_pipeline = helpers.toOpaque(pipeline),
            .pso = pipeline.mtl_pso,
            .needs_sizes_buf = pipeline.needs_sizes_buf,
            .bufs = [_]?*anyopaque{null} ** bindings.MAX_FLAT_BIND,
            .buf_offsets = [_]u64{0} ** bindings.MAX_FLAT_BIND,
            .buf_sizes = [_]u64{0} ** bindings.MAX_FLAT_BIND,
            .buf_count = 0,
            .x = request.workgroups[0],
            .y = request.workgroups[1],
            .z = request.workgroups[2],
            .wg_x = pipeline.wg_x,
            .wg_y = pipeline.wg_y,
            .wg_z = pipeline.wg_z,
        } };
        command.dispatch.buf_count = bindings.populateFlatBindings(
            &request.bind_groups,
            &command.dispatch.bufs,
            &command.dispatch.buf_offsets,
            &command.dispatch.buf_sizes,
        );
        var reference_count: usize = 1;
        for (request.bind_groups, 0..) |maybe_group, index| {
            command.dispatch.bind_groups[index] = if (maybe_group) |group| helpers.toOpaque(group) else null;
            if (maybe_group != null) reference_count += 1;
        }
        vulkan.populateRecordedDispatchBindingState(pipeline, &request.bind_groups, &command.dispatch);
        if (commands.tryMergeDispatchIntoLast(&buffer.cmds, &command)) return;
        try reserve(buffer, reference_count);
        references.retainPipeline(buffer.allocator, &buffer.references, pipeline);
        for (request.bind_groups) |maybe_group| if (maybe_group) |group| {
            references.retainBindGroup(buffer.allocator, &buffer.references, group);
        };
        buffer.cmds.appendAssumeCapacity(command);
    }

    pub fn appendCopy(self: *Builder, request: Copy) ConstructionError!void {
        const buffer = self.pending orelse return error.InvalidState;
        if (request.size == 0) return;
        const source = request.source orelse return error.InvalidArgument;
        const destination = request.destination orelse return error.InvalidArgument;
        if (source.error_object or source.destroyed or destination.error_object or destination.destroyed)
            return error.InvalidArgument;
        try reserve(buffer, 2);
        references.retainBuffer(buffer.allocator, &buffer.references, source);
        references.retainBuffer(buffer.allocator, &buffer.references, destination);
        buffer.cmds.appendAssumeCapacity(.{ .copy_buf = .{
            .src = helpers.toOpaque(source),
            .src_off = request.source_offset,
            .dst = helpers.toOpaque(destination),
            .dst_off = request.destination_offset,
            .size = request.size,
        } });
    }

    fn reserve(buffer: *objects.DoeCommandBuffer, reference_count: usize) !void {
        // No resource ownership changes until both lists can publish without allocation.
        try buffer.cmds.ensureUnusedCapacity(buffer.allocator, 1);
        try buffer.references.ensureUnusedCapacity(buffer.allocator, reference_count);
    }
};

fn allocationFailureScenario(allocator: std.mem.Allocator) !void {
    var device = objects.DoeDevice{};
    var pipeline = objects.DoeComputePipeline{};
    var group = objects.DoeBindGroup{};
    var source = objects.DoeBuffer{ .size = 16 };
    var destination = objects.DoeBuffer{ .size = 16 };
    defer {
        for ([_]u32{ device.ref_count, pipeline.ref_count, group.ref_count, source.ref_count, destination.ref_count }) |count|
            std.testing.expectEqual(@as(u32, 1), count) catch @panic("fused recording leaked a caller reference");
    }
    var builder = try Builder.init(allocator, &device);
    defer builder.deinit();
    var request = Dispatch{ .pipeline = &pipeline, .workgroups = .{ 1, 1, 1 } };
    request.bind_groups[0] = &group;
    // Distinct dispatches force later list growth after earlier dependencies are retained.
    const distinct_dispatch_count = 17;
    for (0..distinct_dispatch_count) |index| {
        request.workgroups[0] = @intCast(index + 1);
        try builder.appendDispatch(request);
    }
    try builder.appendCopy(.{ .source = &source, .source_offset = 0, .destination = &destination, .destination_offset = 0, .size = 16 });
    const buffer = try builder.finish();
    defer exports.doeNativeCommandBufferRelease(helpers.toOpaque(buffer));
    builder.deinit();
    try std.testing.expectEqual(@as(usize, distinct_dispatch_count + 1), buffer.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 2), source.ref_count);
    try std.testing.expectEqual(@as(u32, 2), device.ref_count);
}

test "fused recording rolls back every allocation failure and transfers complete ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyAllocationFailureScenario, .{});
}

fn copyAllocationFailureScenario(allocator: std.mem.Allocator) !void {
    var device = objects.DoeDevice{};
    var buffer = objects.DoeBuffer{ .size = 32 };
    defer {
        std.testing.expectEqual(@as(u32, 1), device.ref_count) catch @panic("copy recording leaked its device");
        std.testing.expectEqual(@as(u32, 1), buffer.ref_count) catch @panic("copy recording leaked an aliased buffer");
    }
    var builder = try Builder.init(allocator, &device);
    defer builder.deinit();
    const copy_count = 17;
    for (0..copy_count) |_| try builder.appendCopy(.{
        .source = &buffer,
        .source_offset = 0,
        .destination = &buffer,
        .destination_offset = 16,
        .size = 16,
    });
    const commands_buffer = try builder.finish();
    defer exports.doeNativeCommandBufferRelease(helpers.toOpaque(commands_buffer));
    try std.testing.expectEqual(@as(u32, 1 + 2 * copy_count), buffer.ref_count);
}

test "merged dispatches reuse storage and invalid copies leave retained work owned" {
    var device = objects.DoeDevice{};
    var pipeline = objects.DoeComputePipeline{};
    var group = objects.DoeBindGroup{};
    var builder = try Builder.init(std.testing.allocator, &device);
    defer builder.deinit();
    var request = Dispatch{ .pipeline = &pipeline, .workgroups = .{ 1, 1, 1 } };
    request.bind_groups[0] = &group;
    try builder.appendDispatch(request);
    const references_before = builder.pending.?.references.items.len;
    try builder.appendDispatch(request);
    try std.testing.expectEqual(@as(usize, 1), builder.pending.?.cmds.items.len);
    try std.testing.expectEqual(references_before, builder.pending.?.references.items.len);
    try std.testing.expectEqual(@as(u32, 2), pipeline.ref_count);
    try std.testing.expectError(error.InvalidArgument, builder.appendCopy(.{
        .source = null,
        .source_offset = 0,
        .destination = null,
        .destination_offset = 0,
        .size = 16,
    }));
    builder.deinit();
    try std.testing.expectEqual(@as(u32, 1), pipeline.ref_count);
    try std.testing.expectEqual(@as(u32, 1), group.ref_count);
    try std.testing.expectEqual(@as(u32, 1), device.ref_count);
    try std.testing.expectError(error.InvalidState, builder.finish());
}
