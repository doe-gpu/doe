const std = @import("std");
const backend_policy = @import("../backend_policy.zig");
const common_timing = @import("../common/timing.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const vk_async_probes = @import("vk_async_probes.zig");
const vk_resources = @import("vk_resources.zig");

pub const AsyncProbeResult = vk_async_probes.AsyncProbeResult;
pub const WGPUTextureFormat = model_gpu_types.WGPUTextureFormat;

pub fn lifecycle_probe(self: anytype, iterations: u32) !u64 {
    const count = if (iterations > 0) iterations else 1;
    const start_ns = common_timing.now_ns();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try vk_resources.create_destroy_lifecycle_buffer(self, 256);
    }
    return common_timing.ns_delta(common_timing.now_ns(), start_ns);
}

pub fn pipeline_async_probe(self: anytype, allocator: std.mem.Allocator, kernel_name: []const u8, iterations: u32) !u64 {
    const spirv_words = try self.load_kernel_spirv(allocator, kernel_name);
    defer allocator.free(spirv_words);

    const count = if (iterations > 0) iterations else 1;
    const start_ns = common_timing.now_ns();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try self.rebuild_compute_shader_spirv(spirv_words);
    }
    return common_timing.ns_delta(common_timing.now_ns(), start_ns);
}

pub fn resource_table_immediates_emulation_probe(
    self: anytype,
    iterations: u32,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !u64 {
    const count = if (iterations > 0) iterations else 1;
    const start_ns = common_timing.now_ns();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try vk_resources.create_destroy_lifecycle_buffer(self, 256);
        try self.upload_bytes(64, .copy_dst, upload_path_policy);
        _ = try self.flush_queue();
    }
    return common_timing.ns_delta(common_timing.now_ns(), start_ns);
}

pub fn pixel_local_storage_emulation_probe(
    self: anytype,
    iterations: u32,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !u64 {
    const count = if (iterations > 0) iterations else 1;
    const start_ns = common_timing.now_ns();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try vk_resources.create_destroy_lifecycle_buffer(self, 512);
        try self.upload_bytes(128, .copy_dst, upload_path_policy);
        _ = try self.barrier(.process_events);
    }
    _ = try self.flush_queue();
    return common_timing.ns_delta(common_timing.now_ns(), start_ns);
}

pub fn resource_table_immediates_probe(self: anytype, iterations: u32) !AsyncProbeResult {
    return vk_async_probes.resource_table_immediates_probe(self, iterations);
}

pub fn pixel_local_storage_probe(
    self: anytype,
    iterations: u32,
    target_format: WGPUTextureFormat,
) !AsyncProbeResult {
    return vk_async_probes.pixel_local_storage_probe(self, iterations, target_format);
}
