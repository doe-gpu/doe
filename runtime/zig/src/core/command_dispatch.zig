const model = @import("../contracts/command.zig");
const execution_contract = @import("../contracts/execution.zig");
const copy_commands = @import("resource/wgpu_commands_copy.zig");
const compute_commands = @import("compute/wgpu_commands_compute.zig");
const texture_commands = @import("resource/wgpu_texture_commands.zig");

pub fn execute(self: anytype, command: model.Command) !?execution_contract.NativeExecutionResult {
    if (!model.isCoreKind(model.kind(command))) return null;
    return switch (command) {
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
        else => unreachable,
    };
}
