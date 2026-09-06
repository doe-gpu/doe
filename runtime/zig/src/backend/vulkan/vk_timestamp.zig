const std = @import("std");
const c = @import("vk_constants.zig");
const resources = @import("vk_resources.zig");
const upload = @import("vk_upload.zig");
const shader_source = @import("vk_shader_source.zig");
const translation = @import("../../compiler/wgsl/pipeline/translate_spirv.zig");
const binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const compute_types = @import("../../contracts/model/model_compute_types.zig");
const options = @import("build_options");

const TIMESTAMP_BYTES = @sizeOf(u64);
const SHADER_CACHE_KEY = "doe:vulkan-timestamp-nanoseconds-v1";
const WORKGROUP_SIZE = options.vulkan_timestamp_workgroup_size;

pub fn shader(allocator: std.mem.Allocator, period: f32, valid_bits: u32) ![]u8 {
    if (!std.math.isFinite(period) or period <= 0 or valid_bits == 0 or valid_bits > 64) return error.InvalidTimestampCalibration;
    const bits: u32 = @bitCast(period);
    const exponent = (bits >> 23) & 255;
    const mantissa = (bits & 0x7fffff) | (if (exponent == 0) @as(u32, 0) else @as(u32, 1 << 23));
    const shift: i32 = if (exponent == 0) -149 else @as(i32, @intCast(exponent)) - 150;
    const mask = @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - valid_bits));
    return std.fmt.allocPrint(allocator, "const MANTISSA = {d}u;\nconst PERIOD_SHIFT = {d}i;\nconst MASK_LOW = {d}u;\nconst MASK_HIGH = {d}u;\nconst WORKGROUP_SIZE = {d}u;\n{s}", .{ mantissa, shift, @as(u32, @truncate(mask)), @as(u32, @truncate(mask >> 32)), WORKGROUP_SIZE, @embedFile("vk_timestamp_normalize.wgsl") });
}

fn compiled_shader(rt: anytype) ![]const u32 {
    if (rt.kernel_spirv_cache.get(SHADER_CACHE_KEY)) |words| return words;
    const source = try shader(rt.allocator, rt.timestamp_period, rt.queue_family_timestamp_valid_bits_value_cache orelse return error.InvalidTimestampCalibration);
    defer rt.allocator.free(source);
    const bytes = try rt.allocator.alloc(u8, translation.MAX_OUTPUT);
    defer rt.allocator.free(bytes);
    const length = try translation.translateToSpirv(rt.allocator, source, bytes);
    const words = try shader_source.words_from_spirv_bytes(rt.allocator, bytes[0..length]);
    errdefer rt.allocator.free(words);
    const key = try rt.allocator.dupe(u8, SHADER_CACHE_KEY);
    errdefer rt.allocator.free(key);
    try rt.kernel_spirv_cache.put(rt.allocator, key, words);
    return words;
}

/// Query-owned scratch has a stable allocation; program-owned caches retain its
/// pipeline and descriptor states exactly like application compute pipelines.
pub const Resolve = struct {
    resource_handle: u64 = 0,

    pub fn init(self: *Resolve, rt: anytype, count: u32) !void {
        _ = try compiled_shader(rt);
        const handle = rt.next_buffer_resource_handle;
        rt.next_buffer_resource_handle = try std.math.add(u64, handle, 1);
        _ = try resources.ensure_compute_buffer_for_binding(rt, binding(handle, count), false);
        self.resource_handle = handle;
    }

    pub fn deinit(self: *Resolve, rt: anytype) void {
        if (self.resource_handle != 0) resources.destroy_compute_buffer(rt, self.resource_handle);
        self.* = .{};
    }

    pub fn record(self: *const Resolve, rt: anytype, pool: c.VkQueryPool, first: u32, count: u32, destination: resources.ComputeBuffer, offset: u64) !void {
        const bindings = [_]compute_types.KernelBinding{binding(self.resource_handle, count)};
        try rt.set_compute_shader_spirv(try compiled_shader(rt), "main", &bindings, false);
        const scratch = rt.compute_buffers.get(self.resource_handle) orelse return error.InvalidState;
        const command_buffer = try rt.begin_prepared_dispatch_replay();
        // Repeated resolutions overwrite scratch after the preceding copy reads it.
        const dependency = c.VkMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        };
        c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, @ptrCast(&dependency), 0, null, 0, null);
        c.vkCmdCopyQueryPoolResults(command_buffer, pool, first, count, scratch.buffer, 0, TIMESTAMP_BYTES, c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT);
        rt.has_pending_transfer_writes = true;
        try rt.record_prepared_dispatch_replay_on(command_buffer, std.math.divCeil(u32, count, WORKGROUP_SIZE) catch unreachable, 1, 1);
        try upload.record_replay_buffer_copy(rt, scratch, 0, destination, offset, @as(u64, count) * TIMESTAMP_BYTES);
    }
};

fn binding(handle: u64, count: u32) compute_types.KernelBinding {
    return .{ .binding = 0, .resource_kind = .buffer, .resource_handle = handle, .buffer_size = @as(u64, count) * TIMESTAMP_BYTES, .buffer_type = binding_types.WGPUBufferBindingType_Storage };
}

test "timestamp shader parameters preserve f32 periods and counter masks" {
    const allocator = std.testing.allocator;
    const fractional = try shader(allocator, 2.5, 48);
    defer allocator.free(fractional);
    try std.testing.expect(std.mem.startsWith(u8, fractional, "const MANTISSA = 10485760u;\nconst PERIOD_SHIFT = -22i;\nconst MASK_LOW = 4294967295u;\nconst MASK_HIGH = 65535u;\n"));
    const subnormal = try shader(allocator, @bitCast(@as(u32, 1)), 64);
    defer allocator.free(subnormal);
    try std.testing.expect(std.mem.startsWith(u8, subnormal, "const MANTISSA = 1u;\nconst PERIOD_SHIFT = -149i;\n"));
    try std.testing.expectError(error.InvalidTimestampCalibration, shader(allocator, 0, 64));
    try std.testing.expectError(error.InvalidTimestampCalibration, shader(allocator, std.math.inf(f32), 64));
    try std.testing.expectError(error.InvalidTimestampCalibration, shader(allocator, 1, 0));
    try std.testing.expectError(error.InvalidTimestampCalibration, shader(allocator, 1, 65));
}
