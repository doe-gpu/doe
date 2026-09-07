const objects = @import("../support/doe_native_object_types.zig");
const commands = @import("../support/doe_native_command_types.zig");
const errors = @import("../../runtime/diagnostics/error_scope.zig");
const contract = @import("../../contracts/command_recording.zig");

pub fn fail(encoder: *objects.DoeCommandEncoder, cause: contract.Failure) void {
    if (encoder.state.fail(cause))
        encoder.dev.error_scopes.deliver(errors.zig_error_to_type(cause), switch (cause) {
            error.OutOfMemory => "command recording could not allocate owned storage",
            error.InvalidState => "command recording requires an open encoder",
            error.InvalidArgument => "command recording received an invalid dependency",
        });
}

pub fn requireOpen(encoder: *objects.DoeCommandEncoder) bool {
    if (encoder.state == .open) return true;
    fail(encoder, error.InvalidState);
    return false;
}

pub fn reserve(encoder: *objects.DoeCommandEncoder, command_count: usize, reference_count: usize) bool {
    if (!requireOpen(encoder)) return false;
    encoder.cmds.ensureUnusedCapacity(encoder.allocator, command_count) catch |err| {
        fail(encoder, err);
        return false;
    };
    encoder.references.ensureUnusedCapacity(encoder.allocator, reference_count) catch |err| {
        fail(encoder, err);
        return false;
    };
    return true;
}

pub fn append(encoder: *objects.DoeCommandEncoder, command: commands.RecordedCmd) bool {
    if (!reserve(encoder, 1, 0)) return false;
    encoder.cmds.appendAssumeCapacity(command);
    return true;
}
