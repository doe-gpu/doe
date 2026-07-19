const std = @import("std");
const model = @import("../../contracts/model/model_commands.zig");

/// SandboxViolation is raised when a command attempts an operation that exceeds
/// dynamic runtime bounds, potentially compromising memory or expected state.
pub const SandboxViolation = error{
    UploadExceedsAddressSpace,
    UploadZeroBytes,
    CopyZeroBytes,
    CopyInvalidDirection,
    CopyInvalidDimensions,
    DispatchZeroDimensions,
    DispatchIndirectZeroDimensions,
    KernelDispatchZeroDimensions,
    KernelDispatchMissingMarker,
    KernelDispatchZeroRepeat,
};

/// validateCommand acts as the ahead-of-execution execution sandbox boundary.
/// In "Runtime Verification" mode, this protects explicit execution loops
/// from malicious or unbounded parameters before any state is mutated.
/// This function forces deterministic rejects and uses ZERO allocations.
pub fn validateCommand(command: model.Command) !void {
    switch (command) {
        .upload => |upload| {
            if (upload.bytes == 0) return error.UploadZeroBytes;
            // Prevent address space overflow for malicious upload sizes.
            _ = std.math.cast(usize, upload.bytes) orelse return error.UploadExceedsAddressSpace;
        },
        .copy_buffer_to_texture => |copy| {
            if (copy.bytes == 0) return error.CopyZeroBytes;

            // Validate resource matching based on direction
            switch (copy.direction) {
                .buffer_to_buffer => if (copy.src.kind != .buffer or copy.dst.kind != .buffer) return error.CopyInvalidDirection,
                .buffer_to_texture => if (copy.src.kind != .buffer or copy.dst.kind != .texture) return error.CopyInvalidDirection,
                .texture_to_buffer => if (copy.src.kind != .texture or copy.dst.kind != .buffer) return error.CopyInvalidDirection,
                .texture_to_texture => if (copy.src.kind != .texture or copy.dst.kind != .texture) return error.CopyInvalidDirection,
            }

            // Validate dimension bounds
            switch (copy.direction) {
                .buffer_to_texture => if (copy.dst.width == 0 or copy.dst.height == 0 or copy.dst.depth_or_array_layers == 0) return error.CopyInvalidDimensions,
                .texture_to_buffer => if (copy.src.width == 0 or copy.src.height == 0 or copy.src.depth_or_array_layers == 0) return error.CopyInvalidDimensions,
                .texture_to_texture => {
                    if (copy.src.width == 0 or copy.src.height == 0 or copy.src.depth_or_array_layers == 0) return error.CopyInvalidDimensions;
                    if (copy.dst.width == 0 or copy.dst.height == 0 or copy.dst.depth_or_array_layers == 0) return error.CopyInvalidDimensions;
                    if (copy.src.width != copy.dst.width or copy.src.height != copy.dst.height or copy.src.depth_or_array_layers != copy.dst.depth_or_array_layers) return error.CopyInvalidDimensions;
                },
                .buffer_to_buffer => {},
            }
        },
        .dispatch => |dispatch| {
            if (dispatch.x == 0 and dispatch.y == 0 and dispatch.z == 0) return error.DispatchZeroDimensions;
        },
        .dispatch_indirect => |dispatch| {
            if (dispatch.x == 0 and dispatch.y == 0 and dispatch.z == 0) return error.DispatchIndirectZeroDimensions;
        },
        .kernel_dispatch => |kernel| {
            if (kernel.x == 0 and kernel.y == 0 and kernel.z == 0) return error.KernelDispatchZeroDimensions;
            if (kernel.kernel.len == 0) return error.KernelDispatchMissingMarker;
            if (kernel.repeat == 0) return error.KernelDispatchZeroRepeat;
        },
        else => {}, // Other commands are dynamically safe by layout shape or backend limits
    }
}
