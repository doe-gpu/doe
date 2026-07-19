const model = @import("../../contracts/model/model_commands.zig");
const command_info = @import("command_info.zig");
const capabilities = @import("capabilities.zig");

pub const CommandRequirements = struct {
    manifest_module: []const u8,
    is_dispatch: bool,
    operation_count: u32,
    required_capabilities: capabilities.CapabilitySet,
};

pub fn requirements(command: model.Command) CommandRequirements {
    return .{
        .manifest_module = command_info.manifest_module(command),
        .is_dispatch = command_info.is_dispatch(command),
        .operation_count = command_info.operation_count(command),
        .required_capabilities = capabilities.required_capabilities(command),
    };
}
