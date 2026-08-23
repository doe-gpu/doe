const builtin = @import("builtin");

const vk_pipeline_cache_persistent = if (builtin.os.tag == .linux) @import("vulkan/vk_pipeline_cache_persistent.zig") else struct {
    pub const WarmupTelemetry = struct {
        count: u64 = 0,
        ns: u64 = 0,
    };
};

pub const WarmupTelemetry = vk_pipeline_cache_persistent.WarmupTelemetry;

pub fn vulkanPipelineCacheActive(runtime: anytype) bool {
    if (comptime builtin.os.tag != .linux) return false;
    return runtime.pipeline_cache.active();
}

pub fn vulkanPipelineCacheDisabled(runtime: anytype) bool {
    if (comptime builtin.os.tag != .linux) return false;
    return !runtime.pipeline_cache.enabled;
}

pub fn vulkanPipelineCacheWarmupTelemetry(runtime: anytype) WarmupTelemetry {
    if (comptime builtin.os.tag != .linux) return .{};
    return runtime.pipeline_cache.warmupTelemetry();
}

pub fn flushVulkanPipelineCache(runtime: anytype) void {
    if (comptime builtin.os.tag != .linux) return;
    if (runtime.device == null) return;
    runtime.pipeline_cache.flush(runtime.device);
}
