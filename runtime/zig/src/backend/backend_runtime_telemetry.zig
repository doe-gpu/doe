const std = @import("std");
const builtin = @import("builtin");
const vulkan_backend = if (builtin.os.tag == .linux) @import("vulkan/mod.zig") else struct {};
const metal_backend = if (builtin.os.tag == .macos) @import("metal/mod.zig") else struct {};

/// Apple Metal pipeline cache opt-out, cross-platform-safe wrapper. No-op on
/// non-Mac builds. Called by cli/runtime_cli.zig when --no-pipeline-cache is
/// present; must be invoked *before* backend init so the cache init skip
/// check sees the flag set.
pub fn set_metal_pipeline_cache_disabled(disabled: bool) void {
    if (comptime builtin.os.tag == .macos) {
        metal_backend.set_pipeline_cache_disabled(disabled);
    } else {
        // Silence unused-parameter diagnostic on non-Mac builds; the flag
        // has no effect off Apple platforms.
        std.mem.doNotOptimizeAway(disabled);
    }
}

/// Doe Vulkan pipeline cache opt-out, cross-platform-safe wrapper. No-op on
/// non-Linux builds. Called by cli/runtime_cli.zig when --no-pipeline-cache is
/// present; must be invoked *before* backend init so the cache init skip
/// check in vk_pipeline_cache_persistent.create_process_pipeline_cache sees
/// the flag set.
pub fn set_vulkan_pipeline_cache_disabled(disabled: bool) void {
    if (comptime builtin.os.tag == .linux) {
        vulkan_backend.set_pipeline_cache_disabled(disabled);
    } else {
        std.mem.doNotOptimizeAway(disabled);
    }
}

/// Configure the Vulkan pipeline-cache disk directory. Empty slice disables
/// disk persistence; the cache then stays in-memory for the process lifetime.
/// Must be invoked *before* backend init (parallel to the disabled flag).
pub fn set_vulkan_pipeline_cache_dir(dir: []const u8) void {
    if (comptime builtin.os.tag == .linux) {
        vulkan_backend.set_pipeline_cache_dir(dir);
    } else {
        std.mem.doNotOptimizeAway(dir);
    }
}
