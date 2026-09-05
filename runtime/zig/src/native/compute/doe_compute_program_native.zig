const std = @import("std");
const builtin = @import("builtin");
const objects = @import("../support/doe_native_object_types.zig");
const helpers = @import("../support/doe_native_object_helpers.zig");
const exports = @import("../support/doe_native_exports.zig");
const runtime_helpers = @import("../support/doe_native_runtime_helpers.zig");
const Runtime = @import("../support/doe_native_shared_types.zig").NativeVulkanRuntime;
const backend = @import("../../backend/dropin_queue_submit.zig");
const compute = @import("../vulkan/vulkan_compute_native.zig");
const errors = @import("../queue/doe_queue_submit_shared.zig");
const trace = @import("../diagnostics/doe_program_identity_trace.zig");

const alloc = helpers.alloc;

pub export fn doeNativeComputeProgramSupported() callconv(.c) u32 {
    return @intFromBool(builtin.os.tag == .linux);
}
const BufferReference = struct {
    object: *objects.DoeBuffer,
    resource_id: u64,
    buffer: u64 = 0,
    size: u64 = 0,
};

const Program = struct {
    device: *objects.DoeDevice,
    commands: *objects.DoeCommandBuffer,
    runtime: *Runtime,
    gpu: backend.vulkan_compute_program.ComputeProgram = .{},
    buffers: std.ArrayListUnmanaged(BufferReference) = .{},
    pipelines: std.ArrayListUnmanaged(*objects.DoeComputePipeline) = .{},
    dispatch_count: u64 = 0,
    submissions: u64 = 0,

    fn retainBuffer(self: *Program, raw: ?*anyopaque) !void {
        const buffer = helpers.cast(objects.DoeBuffer, raw) orelse return error.InvalidBuffer;
        if (buffer.dev != self.device or buffer.error_object or buffer.vk_id == 0 or buffer.mapped) return error.InvalidBuffer;
        for (self.buffers.items) |reference| if (reference.object == buffer) return;
        try self.buffers.append(alloc, .{ .object = buffer, .resource_id = buffer.vk_id });
        buffer.ref_count += 1;
    }

    fn retainPipeline(self: *Program, raw: ?*anyopaque) !void {
        const pipeline = helpers.cast(objects.DoeComputePipeline, raw) orelse return error.InvalidPipeline;
        for (self.pipelines.items) |retained| if (retained == pipeline) return;
        try self.pipelines.append(alloc, pipeline);
        pipeline.ref_count += 1;
    }

    fn prepare(self: *Program) !void {
        for (self.commands.cmds.items) |command| switch (command) {
            .dispatch => |dispatch| {
                if (dispatch.x == 0 or dispatch.y == 0 or dispatch.z == 0 or !dispatch.vulkan_binding_state.valid) return error.InvalidDispatch;
                for (dispatch.vulkan_binding_state.bindings[0..dispatch.vulkan_binding_state.count]) |binding| {
                    if (binding.resource_kind != .buffer) return error.UnsupportedResourceKind;
                }
                try self.retainPipeline(dispatch.compute_pipeline);
                for (dispatch.bufs[0..dispatch.buf_count]) |buffer| if (buffer != null) try self.retainBuffer(buffer);
                self.dispatch_count = try std.math.add(u64, self.dispatch_count, @max(1, dispatch.repeat_count));
            },
            .clear_buffer => |clear| try self.retainBuffer(clear.buffer),
            .copy_buf => |copy| {
                try self.retainBuffer(copy.src);
                try self.retainBuffer(copy.dst);
            },
            else => return error.UnsupportedCommand,
        };
        if (self.dispatch_count == 0) return error.InvalidDispatch;
        try self.gpu.begin(self.runtime);
        // Resolve all allocation and binding requirements before recording.
        for (self.commands.cmds.items) |*command| if (command.* == .dispatch) {
            if (!compute.vulkan_prepare_recorded_dispatch(self.runtime, &command.dispatch)) return error.PipelinePreparationFailed;
        };
        for (self.buffers.items) |*reference| {
            const buffer = self.runtime.compute_buffers.get(reference.resource_id) orelse return error.InvalidBuffer;
            reference.buffer = buffer.buffer;
            reference.size = buffer.size;
        }
        for (self.commands.cmds.items) |*command| switch (command.*) {
            .dispatch => |*dispatch| {
                if (!compute.vulkan_prepare_recorded_dispatch(self.runtime, dispatch)) return error.PipelinePreparationFailed;
                try compute.vulkan_record_prepared_dispatch(self.runtime, dispatch);
            },
            .clear_buffer => |clear| {
                const object = helpers.cast(objects.DoeBuffer, clear.buffer) orelse return error.InvalidBuffer;
                const buffer = self.runtime.compute_buffers.get(object.vk_id) orelse return error.InvalidBuffer;
                if (try std.math.add(u64, clear.offset, clear.size) > buffer.size) return error.InvalidRange;
                try backend.vulkan_upload.record_replay_buffer_clear(self.runtime, buffer.buffer, clear.offset, clear.size);
            },
            .copy_buf => |copy| {
                const source = helpers.cast(objects.DoeBuffer, copy.src) orelse return error.InvalidBuffer;
                const destination = helpers.cast(objects.DoeBuffer, copy.dst) orelse return error.InvalidBuffer;
                const src = self.runtime.compute_buffers.get(source.vk_id) orelse return error.InvalidBuffer;
                const dst = self.runtime.compute_buffers.get(destination.vk_id) orelse return error.InvalidBuffer;
                if (try std.math.add(u64, copy.src_off, copy.size) > src.size or
                    try std.math.add(u64, copy.dst_off, copy.size) > dst.size) return error.InvalidRange;
                try backend.vulkan_upload.record_replay_buffer_copy(self.runtime, src, copy.src_off, dst, copy.dst_off, copy.size);
            },
            else => unreachable,
        };
        try self.validate();
        try self.gpu.finish(self.runtime);
        trace.recordComputeProgramPrepared(@intFromPtr(self), self.dispatch_count);
    }

    fn validate(self: *const Program) !void {
        for (self.buffers.items) |reference| {
            if (reference.object.mapped or reference.object.vk_id != reference.resource_id) return error.InvalidatedBuffer;
            const buffer = self.runtime.compute_buffers.get(reference.resource_id) orelse return error.InvalidatedBuffer;
            if (buffer.buffer != reference.buffer or buffer.size != reference.size) return error.InvalidatedBuffer;
        }
    }

    fn destroy(self: *Program) void {
        self.gpu.deinit(self.runtime);
        for (self.pipelines.items) |pipeline| exports.doeNativeComputePipelineRelease(helpers.toOpaque(pipeline));
        self.pipelines.deinit(alloc);
        for (self.buffers.items) |reference| exports.doeNativeBufferRelease(helpers.toOpaque(reference.object));
        self.buffers.deinit(alloc);
        exports.doeNativeCommandBufferRelease(helpers.toOpaque(self.commands));
        exports.doeNativeDeviceRelease(helpers.toOpaque(self.device));
        alloc.destroy(self);
    }
};

pub export fn doeNativeComputeProgramPrepare(queue_raw: ?*anyopaque, commands_raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (comptime builtin.os.tag != .linux) return null;
    const queue = helpers.cast(objects.DoeQueue, queue_raw) orelse return null;
    const commands = helpers.cast(objects.DoeCommandBuffer, commands_raw) orelse return null;
    if (commands.dev != queue.dev or queue.dev.backend != .vulkan) {
        errors.deliverInternalError(queue.dev, "compute program: expected Vulkan commands from the selected device", .{});
        return null;
    }
    const rt = runtime_helpers.device_vk_runtime(queue.dev) orelse return null;
    const program = alloc.create(Program) catch return null;
    program.* = .{ .device = queue.dev, .commands = commands, .runtime = rt };
    queue.dev.ref_count += 1;
    commands.ref_count += 1;
    program.prepare() catch |err| {
        errors.deliverInternalError(queue.dev, "compute program preparation: {s}", .{@errorName(err)});
        program.destroy();
        return null;
    };
    return @ptrCast(program);
}

pub export fn doeNativeComputeProgramSubmit(raw: ?*anyopaque) callconv(.c) u32 {
    if (comptime builtin.os.tag != .linux) return 0;
    const program: *Program = @ptrCast(@alignCast(raw orelse return 0));
    program.validate() catch |err| {
        errors.deliverInternalError(program.device, "compute program invalidated: {s}", .{@errorName(err)});
        return 0;
    };
    program.gpu.submit(program.runtime) catch |err| {
        errors.deliverInternalError(program.device, "compute program submission: {s}", .{@errorName(err)});
        return 0;
    };
    program.submissions += 1;
    trace.recordComputeProgramSubmitted(@intFromPtr(program), program.dispatch_count, program.submissions);
    return 1;
}

pub export fn doeNativeComputeProgramRelease(raw: ?*anyopaque) callconv(.c) void {
    if (comptime builtin.os.tag != .linux) return;
    const program: *Program = @ptrCast(@alignCast(raw orelse return));
    program.destroy();
}
