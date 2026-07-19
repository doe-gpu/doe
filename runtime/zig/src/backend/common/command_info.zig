const model = @import("../../contracts/model/model_commands.zig");

pub fn manifest_module(command: model.Command) []const u8 {
    return switch (command) {
        .upload => "upload",
        .buffer_write => "buffer_write",
        .copy_buffer_to_texture => "copy_buffer_to_texture",
        .barrier => "barrier",
        .dispatch => "dispatch",
        .dispatch_indirect => "dispatch_indirect",
        .kernel_dispatch => "kernel_dispatch",
        .render_draw => "render_draw",
        .draw_indirect => "draw_indirect",
        .draw_indexed_indirect => "draw_indexed_indirect",
        .render_pass => "render_pass",
        .sampler_create => "sampler_create",
        .sampler_destroy => "sampler_destroy",
        .texture_write => "texture_write",
        .texture_query => "texture_query",
        .texture_destroy => "texture_destroy",
        .surface_create => "surface_create",
        .surface_capabilities => "surface_capabilities",
        .surface_configure => "surface_configure",
        .surface_acquire => "surface_acquire",
        .surface_present => "surface_present",
        .surface_unconfigure => "surface_unconfigure",
        .surface_release => "surface_release",
        .async_diagnostics => "async_diagnostics",
        .map_async => "map_async",
    };
}

pub fn shader_artifact_module(command: model.Command) []const u8 {
    return switch (command) {
        .kernel_dispatch => |kernel| kernel.kernel,
        else => manifest_module(command),
    };
}

pub fn is_dispatch(command: model.Command) bool {
    return switch (command) {
        .dispatch, .dispatch_indirect, .kernel_dispatch => true,
        else => false,
    };
}

pub fn operation_count(command: model.Command) u32 {
    return switch (command) {
        .dispatch => 1,
        .dispatch_indirect => 1,
        .kernel_dispatch => |kernel| if (kernel.repeat > 0) kernel.repeat else 1,
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => |render| if (render.draw_count > 0) render.draw_count else 1,
        .async_diagnostics => |diagnostics| if (diagnostics.iterations > 0) diagnostics.iterations else 1,
        else => 1,
    };
}
