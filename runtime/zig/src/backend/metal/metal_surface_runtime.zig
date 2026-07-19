const std = @import("std");
const common_timing = @import("../common/timing.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_value_types.zig");
const bridge = @import("metal_bridge_decls.zig");
const metal_bridge_command_buffer_wait_completed = bridge.metal_bridge_command_buffer_wait_completed;
const metal_bridge_create_command_buffer = bridge.metal_bridge_create_command_buffer;
const doe_surface_acquire_drawable = bridge.doe_surface_acquire_drawable;
const doe_surface_configure = bridge.doe_surface_configure;
const doe_surface_create_from_layer = bridge.doe_surface_create_from_layer;
const doe_surface_create_offscreen = bridge.doe_surface_create_offscreen;
const doe_surface_discard_drawable = bridge.doe_surface_discard_drawable;
const doe_surface_present_drawable = bridge.doe_surface_present_drawable;
const doe_surface_release = bridge.doe_surface_release;
const doe_surface_resize = bridge.doe_surface_resize;
const doe_surface_supports_format = bridge.doe_surface_supports_format;
const doe_surface_unconfigure = bridge.doe_surface_unconfigure;
const metal_bridge_release = bridge.metal_bridge_release;

pub const SurfaceState = struct {
    surface_host: ?*anyopaque = null,
    drawable: ?*anyopaque = null,
    texture: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    alpha_mode: u32 = 0,
    present_mode: u32 = 0,
    tone_mapping_mode: u32 = 0,
    configured: bool = false,
    acquired: bool = false,
};

pub fn create_surface(self: anytype, cmd: model_surface_control_types.SurfaceCreateCommand) !void {
    var entry = try surface_entry(self, cmd.handle);
    if (entry.surface_host == null) {
        entry.surface_host = doe_surface_create_offscreen() orelse return error.InvalidState;
    }
}

pub fn surface_capabilities(self: anytype, cmd: model_surface_control_types.SurfaceCapabilitiesCommand) !void {
    _ = try surface_entry(self, cmd.handle);
}

pub fn attach_canvas_layer(self: anytype, handle: u64, layer: ?*anyopaque) !void {
    if (layer == null) return error.InvalidArgument;
    var entry = try surface_entry(self, handle);
    if (entry.drawable) |drawable| {
        doe_surface_discard_drawable(drawable);
        entry.drawable = null;
    }
    if (entry.texture) |texture| {
        metal_bridge_release(texture);
        entry.texture = null;
    }
    if (entry.surface_host) |host| {
        doe_surface_unconfigure(host);
        doe_surface_release(host);
        entry.surface_host = null;
    }
    entry.surface_host = doe_surface_create_from_layer(layer) orelse return error.InvalidState;
    entry.configured = false;
    entry.acquired = false;
}

pub fn update_surface_size(self: anytype, handle: u64, width: u32, height: u32, dpi_scale: f32) !void {
    if (width == 0 or height == 0) return error.InvalidArgument;
    var entry = try surface_entry(self, handle);
    const host = entry.surface_host orelse return error.SurfaceUnavailable;
    doe_surface_resize(host, width, height, dpi_scale);
    entry.width = width;
    entry.height = height;
}

pub fn configure_surface(self: anytype, cmd: model_surface_control_types.SurfaceConfigureCommand) !void {
    var entry = try surface_entry(self, cmd.handle);
    if (cmd.width == 0 or cmd.height == 0) return error.InvalidArgument;
    if (!surface_configuration_supported(cmd.format, cmd.tone_mapping_mode)) return error.UnsupportedFeature;

    if (entry.surface_host == null) {
        entry.surface_host = doe_surface_create_offscreen() orelse return error.InvalidState;
    }

    if (entry.drawable) |drawable| {
        doe_surface_discard_drawable(drawable);
        entry.drawable = null;
    }
    if (entry.texture) |texture| {
        metal_bridge_release(texture);
        entry.texture = null;
    }

    const alpha_opaque = alpha_mode_is_opaque(cmd.alpha_mode);
    const present_mode = map_present_mode(cmd.present_mode) orelse return error.InvalidArgument;

    doe_surface_unconfigure(entry.surface_host);
    if (doe_surface_configure(
        entry.surface_host,
        self.device,
        cmd.width,
        cmd.height,
        cmd.format,
        present_mode,
        cmd.tone_mapping_mode,
        if (alpha_opaque) 1 else 0,
        1.0,
    ) == 0) return error.UnsupportedFeature;

    entry.width = cmd.width;
    entry.height = cmd.height;
    entry.format = cmd.format;
    entry.alpha_mode = cmd.alpha_mode;
    entry.present_mode = cmd.present_mode;
    entry.tone_mapping_mode = cmd.tone_mapping_mode;
    entry.configured = true;
    entry.acquired = false;
}

pub fn acquire_surface(self: anytype, cmd: model_surface_control_types.SurfaceAcquireCommand) !void {
    var entry = try surface_entry(self, cmd.handle);
    if (!entry.configured) return error.SurfaceUnavailable;
    const host = entry.surface_host orelse return error.SurfaceUnavailable;
    if (entry.acquired) return error.SurfaceUnavailable;
    if (entry.drawable) |drawable| {
        doe_surface_discard_drawable(drawable);
        entry.drawable = null;
    }
    if (entry.texture) |texture| {
        metal_bridge_release(texture);
        entry.texture = null;
    }
    var drawable: ?*anyopaque = null;
    const texture = doe_surface_acquire_drawable(host, &drawable) orelse return error.SurfaceUnavailable;
    entry.texture = texture;
    entry.drawable = drawable;
    entry.acquired = true;
}

pub fn present_surface(self: anytype, cmd: model_surface_control_types.SurfacePresentCommand) !u64 {
    var entry = try surface_entry(self, cmd.handle);
    if (!entry.configured or !entry.acquired or entry.texture == null or entry.drawable == null) return error.SurfaceUnavailable;
    const start_ns = common_timing.now_ns();
    const cmd_buf = metal_bridge_create_command_buffer(self.queue) orelse {
        doe_surface_discard_drawable(entry.drawable);
        metal_bridge_release(entry.texture);
        entry.drawable = null;
        entry.texture = null;
        entry.acquired = false;
        return error.InvalidState;
    };
    doe_surface_present_drawable(cmd_buf, entry.drawable);
    metal_bridge_command_buffer_wait_completed(cmd_buf);
    metal_bridge_release(cmd_buf);
    doe_surface_discard_drawable(entry.drawable);
    metal_bridge_release(entry.texture);
    entry.drawable = null;
    entry.texture = null;
    entry.acquired = false;
    return common_timing.ns_delta(common_timing.now_ns(), start_ns);
}

pub fn unconfigure_surface(self: anytype, cmd: model_surface_control_types.SurfaceUnconfigureCommand) !void {
    var entry = try surface_entry(self, cmd.handle);
    if (entry.drawable) |drawable| {
        doe_surface_discard_drawable(drawable);
        entry.drawable = null;
    }
    if (entry.texture) |texture| {
        metal_bridge_release(texture);
        entry.texture = null;
    }
    if (entry.surface_host) |host| {
        doe_surface_unconfigure(host);
    }
    entry.configured = false;
    entry.acquired = false;
    entry.width = 0;
    entry.height = 0;
    entry.format = 0;
    entry.alpha_mode = 0;
    entry.present_mode = 0;
    entry.tone_mapping_mode = 0;
}

pub fn release_surface(self: anytype, cmd: model_surface_control_types.SurfaceReleaseCommand) !void {
    if (self.surfaces.fetchRemove(cmd.handle)) |removed| {
        if (removed.value.drawable) |drawable| {
            doe_surface_discard_drawable(drawable);
        }
        if (removed.value.texture) |texture| {
            metal_bridge_release(texture);
        }
        if (removed.value.surface_host) |host| {
            doe_surface_unconfigure(host);
            doe_surface_release(host);
        }
    }
}

fn surface_entry(self: anytype, handle: u64) !*SurfaceState {
    const gop = try self.surfaces.getOrPut(self.allocator, handle);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

fn alpha_mode_is_opaque(alpha_mode: u32) bool {
    return switch (alpha_mode) {
        0, 0x00000001 => true, // auto / opaque
        0x00000002, 0x00000003, 0x00000004 => false,
        else => false,
    };
}

fn map_present_mode(present_mode: u32) ?u32 {
    return switch (present_mode) {
        0x00000001, 0x00000002 => 0x00000003, // fifo / fifo-relaxed
        0x00000003 => 0x00000001, // immediate
        0x00000004 => 0x00000002, // mailbox
        else => null,
    };
}

fn surface_configuration_supported(format: u32, tone_mapping_mode: u32) bool {
    if (doe_surface_supports_format(format) == 0) return false;
    return tone_mapping_mode_compatible_with_format(format, tone_mapping_mode);
}

fn tone_mapping_mode_compatible_with_format(format: u32, tone_mapping_mode: u32) bool {
    return switch (tone_mapping_mode) {
        0, model_surface_control_types.WGPUCanvasToneMappingMode_Standard => true,
        model_surface_control_types.WGPUCanvasToneMappingMode_Extended => format == model_texture_types.WGPUTextureFormat_RGBA16Float,
        else => false,
    };
}

test "tone_mapping_mode_compatible_with_format rejects extended tone mapping on 8-bit surface formats" {
    try std.testing.expect(!tone_mapping_mode_compatible_with_format(
        model_texture_types.WGPUTextureFormat_BGRA8Unorm,
        model_surface_control_types.WGPUCanvasToneMappingMode_Extended,
    ));
}

test "tone_mapping_mode_compatible_with_format accepts extended tone mapping on rgba16float" {
    try std.testing.expect(tone_mapping_mode_compatible_with_format(
        model_texture_types.WGPUTextureFormat_RGBA16Float,
        model_surface_control_types.WGPUCanvasToneMappingMode_Extended,
    ));
}
