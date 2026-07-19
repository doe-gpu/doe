const model = @import("../../contracts/model/model_commands.zig");
const runtime_types = @import("../runtime_types.zig");

pub fn should_emit_shader_artifact(command: model.Command) bool {
    return switch (command) {
        .dispatch,
        .dispatch_indirect,
        .kernel_dispatch,
        .render_draw,
        .draw_indirect,
        .draw_indexed_indirect,
        .render_pass,
        => true,
        else => false,
    };
}

pub fn artifact_status_code(result: runtime_types.NativeExecutionResult) []const u8 {
    if (result.status_message.len != 0) return result.status_message;
    return switch (result.status) {
        .ok => "ok",
        .unsupported => "unsupported",
        .@"error" => "error",
    };
}
