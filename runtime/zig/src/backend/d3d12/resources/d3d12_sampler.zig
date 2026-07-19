const std = @import("std");
const model_render_types = @import("../../../contracts/model/model_render_types.zig");
const common_timing = @import("../../common/timing.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const MAX_SAMPLERS: u32 = 256;

pub const SamplerEntry = struct {
    handle: u64,
    address_mode_u: u32,
    address_mode_v: u32,
    address_mode_w: u32,
    mag_filter: u32,
    min_filter: u32,
    mipmap_filter: u32,
    lod_min_clamp: f32,
    lod_max_clamp: f32,
    compare: u32,
    max_anisotropy: u16,
    heap_index: u32,
};

pub const SamplerMap = std.AutoHashMapUnmanaged(u64, SamplerEntry);

pub const SamplerState = struct {
    map: SamplerMap = .{},
    heap: ?*anyopaque = null,
    next_index: u32 = 0,

    pub fn sampler_create(
        self: *SamplerState,
        device: ?*anyopaque,
        allocator: std.mem.Allocator,
        cmd: model_render_types.SamplerCreateCommand,
    ) !u64 {
        const encode_start = common_timing.now_ns();

        if (self.heap == null) {
            self.heap = bridge.c.d3d12_bridge_device_create_sampler_heap(device, MAX_SAMPLERS) orelse return error.InvalidState;
        }

        if (self.next_index >= MAX_SAMPLERS) return error.UnsupportedFeature;

        const entry = SamplerEntry{
            .handle = cmd.handle,
            .address_mode_u = cmd.address_mode_u,
            .address_mode_v = cmd.address_mode_v,
            .address_mode_w = cmd.address_mode_w,
            .mag_filter = cmd.mag_filter,
            .min_filter = cmd.min_filter,
            .mipmap_filter = cmd.mipmap_filter,
            .lod_min_clamp = cmd.lod_min_clamp,
            .lod_max_clamp = cmd.lod_max_clamp,
            .compare = cmd.compare,
            .max_anisotropy = cmd.max_anisotropy,
            .heap_index = self.next_index,
        };
        self.next_index += 1;

        self.map.put(allocator, cmd.handle, entry) catch return error.InvalidState;

        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn sampler_destroy(
        self: *SamplerState,
        cmd: model_render_types.SamplerDestroyCommand,
    ) !u64 {
        const encode_start = common_timing.now_ns();
        _ = self.map.fetchRemove(cmd.handle);
        return common_timing.ns_delta(common_timing.now_ns(), encode_start);
    }

    pub fn deinit(self: *SamplerState, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        if (self.heap) |h| {
            bridge.c.d3d12_bridge_release(h);
            self.heap = null;
        }
    }
};
