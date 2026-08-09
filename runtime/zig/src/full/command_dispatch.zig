const model = @import("../contracts/command.zig");
const runtime_types = @import("../backend/runtime_types.zig");
const render_commands = @import("render/wgpu_render_commands.zig");
const sampler_commands = @import("render/wgpu_sampler_commands.zig");
const surface_commands = @import("surface/wgpu_surface_commands.zig");
const async_diagnostics_command = @import("lifecycle/wgpu_async_diagnostics_command.zig");

pub fn execute(self: anytype, command: model.Command) !?runtime_types.NativeExecutionResult {
    if (!model.isFullOnlyKind(model.kind(command))) return null;
    return switch (command) {
        .render_draw => |payload| try render_commands.executeRenderDraw(self, payload, false),
        .draw_indirect => |payload| try render_commands.executeRenderDraw(self, payload, true),
        .draw_indexed_indirect => |payload| try render_commands.executeRenderDraw(self, payload, true),
        .render_pass => |payload| try render_commands.executeRenderDraw(self, payload, false),
        .sampler_create => |payload| try sampler_commands.executeSamplerCreate(self, payload),
        .sampler_destroy => |payload| try sampler_commands.executeSamplerDestroy(self, payload),
        .surface_create => |payload| try surface_commands.executeSurfaceCreate(self, payload),
        .surface_capabilities => |payload| try surface_commands.executeSurfaceCapabilities(self, payload),
        .surface_configure => |payload| try surface_commands.executeSurfaceConfigure(self, payload),
        .surface_acquire => |payload| try surface_commands.executeSurfaceAcquire(self, payload),
        .surface_present => |payload| try surface_commands.executeSurfacePresent(self, payload),
        .surface_unconfigure => |payload| try surface_commands.executeSurfaceUnconfigure(self, payload),
        .surface_release => |payload| try surface_commands.executeSurfaceRelease(self, payload),
        .async_diagnostics => |payload| try async_diagnostics_command.executeAsyncDiagnostics(self, payload),
        else => unreachable,
    };
}
