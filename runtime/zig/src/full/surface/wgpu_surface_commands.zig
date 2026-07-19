const std = @import("std");
const log = std.log.scoped(.wgpu_surface_commands);
const common_timing = @import("../../backend/common/timing.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");
const abi_execution = @import("../../core/abi/wgpu_execution_types.zig");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const loader = @import("../../core/abi/wgpu_loader.zig");
const resources = @import("../../core/resource/wgpu_resources.zig");
const surface_macos_mod = @import("wgpu_surface_macos.zig");
const surface_procs_mod = @import("wgpu_surface_procs.zig");

const SURFACE_TEXTURE_STATUS_SUCCESS_OPTIMAL: u32 = 0x00000001;
const SURFACE_TEXTURE_STATUS_SUCCESS_SUBOPTIMAL: u32 = 0x00000002;
const SURFACE_ALPHA_MODE_AUTO: u32 = 0x00000000;
const SURFACE_PRESENT_MODE_FIFO: u32 = 0x00000001;

pub fn executeSurfaceCreate(self: anytype, surface_cmd: model_surface_control_types.SurfaceCreateCommand) !abi_execution.NativeExecutionResult {
    const encode_start = common_timing.now_ns();
    if (self.full.surfaces.contains(surface_cmd.handle)) {
        return unsupported_encode_result("surface handle already exists", encode_start);
    }
    const platform_surface = surface_macos_mod.createPlatformSurface() catch {
        return error_encode_result("surface platform creation failed", encode_start);
    };
    errdefer surface_macos_mod.releasePlatformSurface(platform_surface);
    var metal_layer_chain = surface_procs_mod.SurfaceSourceMetalLayer{
        .chain = .{
            .next = null,
            .sType = surface_procs_mod.SurfaceSourceMetalLayerSType,
        },
        .layer = if (platform_surface) |surface| surface.layer else null,
    };
    const surface = self.createSurface(.{
        .nextInChain = if (platform_surface != null) &metal_layer_chain.chain else null,
        .label = loader.emptyStringView(),
    }) catch {
        return error_encode_result("surface creation failed", encode_start);
    };
    errdefer self.releaseSurface(surface);
    try self.full.surfaces.put(surface_cmd.handle, .{
        .surface = surface,
        .platform_surface = platform_surface,
    });
    return ok_encode_result("surface created", encode_start);
}

pub fn executeSurfaceCapabilities(self: anytype, surface_cmd: model_surface_control_types.SurfaceCapabilitiesCommand) !abi_execution.NativeExecutionResult {
    const encode_start = common_timing.now_ns();
    const managed = self.full.surfaces.get(surface_cmd.handle) orelse {
        return unsupported_encode_result("surface handle not found", encode_start);
    };
    const capabilities = self.getSurfaceCapabilities(managed.surface) catch {
        return error_encode_result("surface capabilities query failed", encode_start);
    };
    defer self.freeSurfaceCapabilities(capabilities);
    if (capabilities.formatCount == 0 or capabilities.presentModeCount == 0) {
        return error_encode_result("surface capabilities are empty", encode_start);
    }
    return ok_encode_result("surface capabilities queried", encode_start);
}

pub fn executeSurfaceConfigure(self: anytype, surface_cmd: model_surface_control_types.SurfaceConfigureCommand) !abi_execution.NativeExecutionResult {
    const encode_start = common_timing.now_ns();
    const managed = self.full.surfaces.getPtr(surface_cmd.handle) orelse {
        return unsupported_encode_result("surface handle not found", encode_start);
    };
    if (managed.acquired_texture != null) {
        self.core.procs.?.wgpuTextureRelease(managed.acquired_texture);
        managed.acquired_texture = null;
    }
    if (managed.platform_surface) |surface| {
        surface_macos_mod.configureSurfaceLayer(surface.retained_host, surface_cmd.width, surface_cmd.height);
    }
    const config = surface_procs_mod.SurfaceConfiguration{
        .nextInChain = null,
        .device = self.core.device.?,
        .format = resources.normalizeTextureFormat(surface_cmd.format),
        .usage = if (surface_cmd.usage == 0) abi_texture.WGPUTextureUsage_RenderAttachment else surface_cmd.usage,
        .width = surface_cmd.width,
        .height = surface_cmd.height,
        .viewFormatCount = 0,
        .viewFormats = null,
        .alphaMode = if (surface_cmd.alpha_mode == 0) SURFACE_ALPHA_MODE_AUTO else surface_cmd.alpha_mode,
        .presentMode = if (surface_cmd.present_mode == 0) SURFACE_PRESENT_MODE_FIFO else surface_cmd.present_mode,
    };
    self.configureSurface(managed.surface, config) catch {
        return error_encode_result("surface configure failed", encode_start);
    };
    managed.configured = true;
    return ok_encode_result("surface configured", encode_start);
}

pub fn executeSurfaceAcquire(self: anytype, surface_cmd: model_surface_control_types.SurfaceAcquireCommand) !abi_execution.NativeExecutionResult {
    const encode_start = common_timing.now_ns();
    const managed = self.full.surfaces.getPtr(surface_cmd.handle) orelse {
        return unsupported_encode_result("surface handle not found", encode_start);
    };
    if (!managed.configured) return unsupported_encode_result("surface must be configured before acquire", encode_start);
    if (managed.acquired_texture != null) return unsupported_encode_result("surface already has an acquired texture", encode_start);

    const surface_texture = self.getCurrentSurfaceTexture(managed.surface) catch {
        return error_encode_result("surface acquire failed", encode_start);
    };
    if (!isSuccessfulSurfaceTextureStatus(surface_texture.status) or surface_texture.texture == null) {
        var message_buf: [96]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buf,
            "surface acquire returned status={} texture_null={}",
            .{ surface_texture.status, surface_texture.texture == null },
        ) catch "surface acquire returned non-success status";
        return error_encode_result(message, encode_start);
    }
    managed.acquired_texture = surface_texture.texture;
    managed.last_texture_status = surface_texture.status;
    return ok_encode_result("surface texture acquired", encode_start);
}

pub fn executeSurfacePresent(self: anytype, surface_cmd: model_surface_control_types.SurfacePresentCommand) !abi_execution.NativeExecutionResult {
    const submit_wait_start = common_timing.now_ns();
    const managed = self.full.surfaces.getPtr(surface_cmd.handle) orelse {
        return unsupported_submit_result("surface handle not found", submit_wait_start);
    };
    if (!managed.configured) return unsupported_submit_result("surface must be configured before present", submit_wait_start);
    if (managed.acquired_texture == null) return unsupported_submit_result("surface present requires an acquired texture", submit_wait_start);

    self.presentSurface(managed.surface) catch {
        return error_submit_result("surface present failed", submit_wait_start);
    };
    self.core.procs.?.wgpuTextureRelease(managed.acquired_texture);
    managed.acquired_texture = null;
    return ok_submit_result("surface presented", submit_wait_start);
}

pub fn executeSurfaceUnconfigure(self: anytype, surface_cmd: model_surface_control_types.SurfaceUnconfigureCommand) !abi_execution.NativeExecutionResult {
    const encode_start = common_timing.now_ns();
    const managed = self.full.surfaces.getPtr(surface_cmd.handle) orelse {
        return unsupported_encode_result("surface handle not found", encode_start);
    };
    if (managed.acquired_texture != null) {
        self.core.procs.?.wgpuTextureRelease(managed.acquired_texture);
        managed.acquired_texture = null;
    }
    self.unconfigureSurface(managed.surface) catch {
        return error_encode_result("surface unconfigure failed", encode_start);
    };
    managed.configured = false;
    return ok_encode_result("surface unconfigured", encode_start);
}

pub fn executeSurfaceRelease(self: anytype, surface_cmd: model_surface_control_types.SurfaceReleaseCommand) !abi_execution.NativeExecutionResult {
    const encode_start = common_timing.now_ns();
    const removed = self.full.surfaces.fetchRemove(surface_cmd.handle) orelse {
        return unsupported_encode_result("surface handle not found", encode_start);
    };
    if (removed.value.acquired_texture != null) {
        self.core.procs.?.wgpuTextureRelease(removed.value.acquired_texture);
    }
    if (removed.value.configured) {
        _ = self.unconfigureSurface(removed.value.surface) catch |err| {
            log.warn("surface unconfigure during release: {s}", .{@errorName(err)});
        };
    }
    self.releaseSurface(removed.value.surface);
    surface_macos_mod.releasePlatformSurface(removed.value.platform_surface);
    return ok_encode_result("surface released", encode_start);
}

fn isSuccessfulSurfaceTextureStatus(status: u32) bool {
    return status == SURFACE_TEXTURE_STATUS_SUCCESS_OPTIMAL or
        status == SURFACE_TEXTURE_STATUS_SUCCESS_SUBOPTIMAL;
}

fn ok_encode_result(message: []const u8, encode_start: u64) abi_execution.NativeExecutionResult {
    return .{
        .status = .ok,
        .status_message = message,
        .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start),
    };
}

fn error_encode_result(message: []const u8, encode_start: u64) abi_execution.NativeExecutionResult {
    return .{
        .status = .@"error",
        .status_message = message,
        .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start),
    };
}

fn unsupported_encode_result(message: []const u8, encode_start: u64) abi_execution.NativeExecutionResult {
    return .{
        .status = .unsupported,
        .status_message = message,
        .encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start),
    };
}

fn ok_submit_result(message: []const u8, submit_wait_start: u64) abi_execution.NativeExecutionResult {
    return .{
        .status = .ok,
        .status_message = message,
        .submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_wait_start),
    };
}

fn error_submit_result(message: []const u8, submit_wait_start: u64) abi_execution.NativeExecutionResult {
    return .{
        .status = .@"error",
        .status_message = message,
        .submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_wait_start),
    };
}

fn unsupported_submit_result(message: []const u8, submit_wait_start: u64) abi_execution.NativeExecutionResult {
    return .{
        .status = .unsupported,
        .status_message = message,
        .submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_wait_start),
    };
}
