// metal_resource_commands.zig — Texture and sampler lifecycle commands.
// Sharded from metal_native_runtime.zig to stay under the line-limit policy.
//
// Performance: sampler create/destroy uses a descriptor cache to avoid
// redundant MTLSamplerState allocations. Texture and uncached sampler
// destroys go through the deferred release pool, which batch-drains at
// command buffer boundaries instead of per-call CFRelease.

const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const bridge = @import("metal_bridge_decls.zig");
const metal_bridge_device_new_texture = bridge.metal_bridge_device_new_texture;
const metal_bridge_texture_depth = bridge.metal_bridge_texture_depth;
const metal_bridge_texture_height = bridge.metal_bridge_texture_height;
const metal_bridge_texture_replace_region = bridge.metal_bridge_texture_replace_region;
const metal_bridge_texture_sample_count = bridge.metal_bridge_texture_sample_count;
const metal_bridge_texture_width = bridge.metal_bridge_texture_width;

const model = struct {
    pub const SamplerCreateCommand = model_render_types.SamplerCreateCommand;
    pub const SamplerDestroyCommand = model_render_types.SamplerDestroyCommand;
    pub const TextureDestroyCommand = model_texture_types.TextureDestroyCommand;
    pub const TextureQueryCommand = model_texture_types.TextureQueryCommand;
    pub const TextureWriteCommand = model_texture_types.TextureWriteCommand;
};

pub fn sampler_create(self: anytype, cmd: model.SamplerCreateCommand) !void {
    const h = try self.sampler_cache.acquire(self.device, cmd);
    const gop = try self.samplers.getOrPut(self.allocator, cmd.handle);
    if (gop.found_existing) {
        // Release old sampler — try cache first, fall back to deferred pool.
        const old = gop.value_ptr.*;
        if (!self.sampler_cache.release(old)) {
            self.deferred_pool.enqueue(old);
        }
    }
    gop.value_ptr.* = h;
}

pub fn sampler_destroy(self: anytype, cmd: model.SamplerDestroyCommand) !void {
    if (self.samplers.fetchRemove(cmd.handle)) |e| {
        // Try returning to sampler cache first (decrements ref count).
        // If not cache-managed, enqueue for batch release at next flush.
        if (!self.sampler_cache.release(e.value)) {
            self.deferred_pool.enqueue(e.value);
        }
    }
}

pub fn texture_write(self: anytype, cmd: model.TextureWriteCommand) !void {
    const t = &cmd.texture;
    const mip_w = @max(t.width >> @intCast(t.mip_level), 1);
    const mip_h = @max(t.height >> @intCast(t.mip_level), 1);

    const gop = try self.textures.getOrPut(self.allocator, t.handle);
    if (!gop.found_existing or gop.value_ptr.* == null) {
        const mip_count: u32 = if (t.mip_level > 0) t.mip_level + 1 else 1;
        const tex = metal_bridge_device_new_texture(
            self.device,
            t.width,
            t.height,
            t.depth_or_array_layers,
            mip_count,
            t.sample_count,
            t.format,
            @intCast(t.usage),
            t.dimension,
        ) orelse return error.InvalidState;
        if (gop.found_existing and gop.value_ptr.* != null) {
            self.deferred_pool.enqueue(gop.value_ptr.*);
        }
        gop.value_ptr.* = tex;
    }

    if (cmd.data.len > 0) {
        const rows = if (t.rows_per_image > 0) t.rows_per_image else mip_h;
        const bytes_per_image: u32 = rows * t.bytes_per_row;
        metal_bridge_texture_replace_region(
            gop.value_ptr.*,
            mip_w,
            mip_h,
            t.depth_or_array_layers,
            cmd.data.ptr,
            t.bytes_per_row,
            bytes_per_image,
            t.mip_level,
        );
    }
}

pub fn texture_query(self: anytype, cmd: model.TextureQueryCommand) !void {
    const tex = self.textures.get(cmd.handle) orelse return error.InvalidState;
    if (cmd.expected_width) |w| if (metal_bridge_texture_width(tex) != w) return error.InvalidState;
    if (cmd.expected_height) |h| if (metal_bridge_texture_height(tex) != h) return error.InvalidState;
    if (cmd.expected_depth_or_array_layers) |d| {
        if (d != 1 and metal_bridge_texture_depth(tex) != d) return error.InvalidState;
    }
    if (cmd.expected_sample_count) |sc| if (metal_bridge_texture_sample_count(tex) != sc) return error.InvalidState;
}

pub fn texture_destroy(self: anytype, cmd: model.TextureDestroyCommand) !void {
    if (self.textures.fetchRemove(cmd.handle)) |e| {
        self.deferred_pool.enqueue(e.value);
    }
}
