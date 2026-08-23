const std = @import("std");
const metal_pipeline_cache = @import("metal/metal_pipeline_cache.zig");

pub const MetalPipelineCache = metal_pipeline_cache.MetalPipelineCache;

pub fn init(
    allocator: std.mem.Allocator,
    device: ?*anyopaque,
    cache_dir: []const u8,
) !*MetalPipelineCache {
    return metal_pipeline_cache.MetalPipelineCache.init(allocator, device, cache_dir);
}
