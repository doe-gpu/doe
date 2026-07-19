const model = @import("../contracts/model/model_commands.zig");
const runtime_types = @import("../backend/runtime_types.zig");
const copy_commands = @import("resource/wgpu_commands_copy.zig");
const compute_commands = @import("compute/wgpu_commands_compute.zig");
const texture_commands = @import("resource/wgpu_texture_commands.zig");

pub fn execute(self: anytype, command: model.Command) !?runtime_types.NativeExecutionResult {
    const core_command = model.as_core_command(command) orelse return null;
    return switch (core_command) {
        .upload => |payload| try copy_commands.executeUpload(self, payload),
        .buffer_write => |payload| try copy_commands.executeBufferWrite(self, payload),
        .copy_buffer_to_texture => |payload| try copy_commands.executeCopy(self, payload),
        .barrier => |payload| try compute_commands.executeBarrier(self, payload),
        .dispatch => |payload| try compute_commands.executeDispatch(self, payload),
        .dispatch_indirect => |payload| try compute_commands.executeDispatchIndirect(self, payload),
        .kernel_dispatch => |payload| try compute_commands.executeKernelDispatch(self, payload),
        .texture_write => |payload| try texture_commands.executeTextureWrite(self, payload),
        .texture_query => |payload| try texture_commands.executeTextureQuery(self, payload),
        .texture_destroy => |payload| try texture_commands.executeTextureDestroy(self, payload),
        .map_async => |payload| try copy_commands.executeMapAsync(self, payload),
    };
}
