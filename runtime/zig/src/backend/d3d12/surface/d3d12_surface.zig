const std = @import("std");
const model_gpu_types = @import("../../../contracts/model/model_texture_value_types.zig");
const model_surface_control_types = @import("../../../contracts/model/model_surface_control_types.zig");
const common_timing = @import("../../common/timing.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const SurfaceStatus = enum { created, configured, acquired };

pub const SurfaceEntry = struct {
    handle: u64,
    status: SurfaceStatus = .created,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
    alpha_mode: u32 = 0x00000001,
    tone_mapping_mode: u32 = model_surface_control_types.WGPUCanvasToneMappingMode_Standard,
    swap_chain: ?*anyopaque = null,
    render_target: ?*anyopaque = null,
    rtv_heap: ?*anyopaque = null,
};

pub const SurfaceMap = std.AutoHashMapUnmanaged(u64, SurfaceEntry);

pub const SurfaceState = struct {
    map: SurfaceMap = .{},

    pub fn create_surface(self: *SurfaceState, allocator: std.mem.Allocator, cmd: model_surface_control_types.SurfaceCreateCommand) !u64 {
        const encode_start = common_timing.now_ns();
        self.map.put(allocator, cmd.handle, .{ .handle = cmd.handle }) catch return error.InvalidState;
        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn surface_capabilities(self: *SurfaceState, allocator: std.mem.Allocator, cmd: model_surface_control_types.SurfaceCapabilitiesCommand) !u64 {
        const encode_start = common_timing.now_ns();
        if (!self.map.contains(cmd.handle)) {
            self.map.put(allocator, cmd.handle, .{ .handle = cmd.handle }) catch return error.InvalidState;
        }
        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn configure_surface(
        self: *SurfaceState,
        device: ?*anyopaque,
        queue: ?*anyopaque,
        allocator: std.mem.Allocator,
        cmd: model_surface_control_types.SurfaceConfigureCommand,
    ) !u64 {
        const encode_start = common_timing.now_ns();

        var entry = self.map.get(cmd.handle) orelse {
            self.map.put(allocator, cmd.handle, .{ .handle = cmd.handle }) catch return error.InvalidState;
            return common_timing.ns_delta(common_timing.now_ns(), encode_start);
        };

        if (entry.render_target) |rt| {
            bridge.c.d3d12_bridge_release(rt);
            entry.render_target = null;
        }
        if (entry.swap_chain) |sc| {
            bridge.c.d3d12_bridge_release(sc);
            entry.swap_chain = null;
        }

        const usage_render: u32 = @truncate(model_gpu_types.WGPUTextureUsage_RenderAttachment);
        entry.render_target = bridge.c.d3d12_bridge_device_create_texture_2d(device, cmd.width, cmd.height, 1, cmd.format, usage_render) orelse return error.InvalidState;

        if (entry.rtv_heap == null) {
            entry.rtv_heap = bridge.c.d3d12_bridge_device_create_rtv_heap(device, 1) orelse {
                bridge.c.d3d12_bridge_release(entry.render_target);
                entry.render_target = null;
                return error.InvalidState;
            };
        }
        bridge.c.d3d12_bridge_device_create_rtv(device, entry.render_target, entry.rtv_heap, 0, cmd.format);

        entry.swap_chain = bridge.c.d3d12_bridge_create_swap_chain(queue, cmd.width, cmd.height, cmd.format, cmd.alpha_mode, cmd.tone_mapping_mode);
        if (entry.swap_chain == null) {
            bridge.c.d3d12_bridge_release(entry.render_target);
            entry.render_target = null;
            return error.InvalidState;
        }

        entry.width = cmd.width;
        entry.height = cmd.height;
        entry.format = cmd.format;
        entry.alpha_mode = cmd.alpha_mode;
        entry.tone_mapping_mode = cmd.tone_mapping_mode;
        entry.status = .configured;
        self.map.put(allocator, cmd.handle, entry) catch return error.InvalidState;

        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn acquire_surface(self: *SurfaceState, allocator: std.mem.Allocator, cmd: model_surface_control_types.SurfaceAcquireCommand) !u64 {
        const encode_start = common_timing.now_ns();
        _ = allocator;
        const entry = self.map.getPtr(cmd.handle) orelse return error.InvalidState;
        if (entry.status != .configured) return error.InvalidState;
        entry.status = .acquired;
        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn present_surface(self: *SurfaceState, cmd: model_surface_control_types.SurfacePresentCommand) !u64 {
        const submit_start = common_timing.now_ns();
        const entry = self.map.getPtr(cmd.handle) orelse return error.InvalidState;
        if (entry.swap_chain) |sc| {
            if (bridge.c.d3d12_bridge_swap_chain_present(sc, 0) != 0) return error.InvalidState;
        } else {
            return error.InvalidState;
        }
        entry.status = .configured;
        return common_timing.ns_delta(common_timing.now_ns(), submit_start);
    }

    pub fn unconfigure_surface(self: *SurfaceState, allocator: std.mem.Allocator, cmd: model_surface_control_types.SurfaceUnconfigureCommand) !u64 {
        const encode_start = common_timing.now_ns();
        if (self.map.getPtr(cmd.handle)) |entry| {
            if (entry.render_target) |rt| {
                bridge.c.d3d12_bridge_release(rt);
                entry.render_target = null;
            }
            if (entry.swap_chain) |sc| {
                bridge.c.d3d12_bridge_release(sc);
                entry.swap_chain = null;
            }
            if (entry.rtv_heap) |heap| {
                bridge.c.d3d12_bridge_release(heap);
                entry.rtv_heap = null;
            }
            entry.status = .created;
        }
        _ = allocator;
        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn release_surface(self: *SurfaceState, cmd: model_surface_control_types.SurfaceReleaseCommand) !u64 {
        const encode_start = common_timing.now_ns();
        if (self.map.fetchRemove(cmd.handle)) |kv| {
            var entry = kv.value;
            if (entry.render_target) |rt| bridge.c.d3d12_bridge_release(rt);
            if (entry.rtv_heap) |h| bridge.c.d3d12_bridge_release(h);
            if (entry.swap_chain) |sc| bridge.c.d3d12_bridge_release(sc);
            entry.render_target = null;
            entry.rtv_heap = null;
            entry.swap_chain = null;
        }
        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            if (entry.render_target) |rt| bridge.c.d3d12_bridge_release(rt);
            if (entry.rtv_heap) |h| bridge.c.d3d12_bridge_release(h);
            if (entry.swap_chain) |sc| bridge.c.d3d12_bridge_release(sc);
        }
        self.map.deinit(allocator);
    }
};
