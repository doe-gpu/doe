const std = @import("std");
const builtin = @import("builtin");
const vk_upload = @import("../../src/backend/vulkan/vk_upload.zig");
const vk_resources = @import("../../src/backend/vulkan/vk_resources.zig");
const vk_device = @import("../../src/backend/vulkan/vk_device.zig");
const vk_constants = @import("../../src/backend/vulkan/vk_constants.zig");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const native_runtime = @import("../../src/backend/vulkan/native_runtime.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const model = @import("../../src/contracts/model/model_gpu_types.zig");

// ============================================================
// Upload path classification — pure logic
// ============================================================

test "vulkan: classify_upload_path returns fast_mapped for small copy_dst with mapped shortcuts" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, 1024);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, result);
}

test "vulkan: classify_upload_path returns fast_mapped at exact FAST_UPLOAD_BUFFER_MAX_BYTES boundary" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, result);
}

test "vulkan: classify_upload_path returns direct_mapped just above fast threshold" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1);
    try std.testing.expectEqual(vk_upload.UploadPathKind.direct_mapped, result);
}

test "vulkan: classify_upload_path returns direct_mapped at exact DIRECT_UPLOAD_BUFFER_MAX_BYTES" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.direct_mapped, result);
}

test "vulkan: classify_upload_path returns staged_copy above direct threshold" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES + 1);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, result);
}

test "vulkan: classify_upload_path returns staged_copy for copy_dst_copy_src regardless of size" {
    const small = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst_copy_src, 1024);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, small);

    const medium = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst_copy_src, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, medium);

    const large = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst_copy_src, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, large);
}

test "vulkan: classify_upload_path with staged_copy_only allows fast_mapped for small, forces staged for rest" {
    // Small host-visible buffers use fast_mapped to match Dawn's WriteBuffer
    // behavior (direct memcpy, no GPU submit).
    const tiny = vk_upload.classify_upload_path(.staged_copy_only, .copy_dst, 64);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, tiny);

    // Medium and large still go through staged copy under strict policy.
    const large = vk_upload.classify_upload_path(.staged_copy_only, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, large);

    const src_mode = vk_upload.classify_upload_path(.staged_copy_only, .copy_dst_copy_src, 1024);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, src_mode);
}

// ============================================================
// upload_uses_fast_path / upload_uses_direct_path — convenience wrappers
// ============================================================

test "vulkan: upload_uses_fast_path matches classify_upload_path for fast_mapped" {
    try std.testing.expect(vk_upload.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024));
    try std.testing.expect(vk_upload.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES));
    try std.testing.expect(!vk_upload.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1));
    try std.testing.expect(vk_upload.upload_uses_fast_path(.staged_copy_only, .copy_dst, 512));
}

test "vulkan: upload_uses_direct_path matches classify_upload_path for direct_mapped" {
    try std.testing.expect(vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1));
    try std.testing.expect(vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES));
    try std.testing.expect(!vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES));
    try std.testing.expect(!vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES + 1));
    try std.testing.expect(!vk_upload.upload_uses_direct_path(.staged_copy_only, .copy_dst, 2 * 1024 * 1024));
}

// ============================================================
// bounded_upload_fill_len — pure helper
// ============================================================

test "vulkan: bounded_upload_fill_len clamps to MAX_UPLOAD_ZERO_FILL_BYTES" {
    const small = vk_upload.bounded_upload_fill_len(512);
    try std.testing.expectEqual(@as(usize, 512), small);

    const exact = vk_upload.bounded_upload_fill_len(vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES);
    try std.testing.expectEqual(@as(usize, vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES), exact);

    const over = vk_upload.bounded_upload_fill_len(vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES + 100);
    try std.testing.expectEqual(@as(usize, vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES), over);
}

test "vulkan: bounded_upload_fill_len returns zero for zero input" {
    try std.testing.expectEqual(@as(usize, 0), vk_upload.bounded_upload_fill_len(0));
}

test "vulkan: bounded_upload_fill_len handles single byte" {
    try std.testing.expectEqual(@as(usize, 1), vk_upload.bounded_upload_fill_len(1));
}

// ============================================================
// Upload constants — value verification
// ============================================================

test "vulkan: MAX_UPLOAD_BYTES is zero (no artificial cap)" {
    try std.testing.expectEqual(@as(u64, 0), vk_upload.MAX_UPLOAD_BYTES);
}

test "vulkan: MAX_UPLOAD_ZERO_FILL_BYTES is 1MB" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES);
}

test "vulkan: FAST_UPLOAD_BUFFER_MAX_BYTES is 1MB" {
    try std.testing.expectEqual(@as(u64, 1024 * 1024), vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES);
}

test "vulkan: DIRECT_UPLOAD_BUFFER_MAX_BYTES is 4GB" {
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
}

test "vulkan: WAIT_TIMEOUT_NS is max u64" {
    try std.testing.expectEqual(std.math.maxInt(u64), vk_upload.WAIT_TIMEOUT_NS);
}

test "vulkan: MAX_POOL_ENTRIES_PER_SIZE is 8" {
    try std.testing.expectEqual(@as(usize, 8), vk_upload.MAX_POOL_ENTRIES_PER_SIZE);
}

test "vulkan: HOT_UPLOAD_POOL_CACHE_MAX_BYTES is 64KB" {
    try std.testing.expectEqual(@as(u64, 64 * 1024), vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES);
}

// ============================================================
// Upload path threshold ordering — fast < direct < staged
// ============================================================

test "vulkan: upload path thresholds are ordered correctly" {
    try std.testing.expect(vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES < vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
}

// ============================================================
// Hot pool operations — pure logic
// ============================================================

test "vulkan: hot_pool_pop returns null when entry is null" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    const result = vk_upload.hot_pool_pop(&entry, &size, 1024);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), result);
}

test "vulkan: hot_pool_pop returns null when size does not match" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 42, .memory = 43, .mapped = null };
    var size: u64 = 2048;
    const result = vk_upload.hot_pool_pop(&entry, &size, 1024);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), result);
    // Entry should not be consumed on mismatch.
    try std.testing.expect(entry != null);
}

test "vulkan: hot_pool_pop returns entry when size matches and within threshold" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 42, .memory = 43, .mapped = null };
    var size: u64 = 1024;
    const result = vk_upload.hot_pool_pop(&entry, &size, 1024);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(vk_constants.VkBuffer, 42), result.?.buffer);
    try std.testing.expectEqual(@as(vk_constants.VkDeviceMemory, 43), result.?.memory);
    // Entry should be cleared after consumption.
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), entry);
    try std.testing.expectEqual(@as(u64, 0), size);
}

test "vulkan: hot_pool_pop rejects sizes above HOT_UPLOAD_POOL_CACHE_MAX_BYTES" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 1, .memory = 2, .mapped = null };
    const too_large = vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES + 1;
    var size: u64 = too_large;
    const result = vk_upload.hot_pool_pop(&entry, &size, too_large);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), result);
    // Entry should not be consumed.
    try std.testing.expect(entry != null);
}

test "vulkan: hot_pool_store succeeds when slot is empty and size is within limit" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    const value = vk_upload.VkPoolEntry{ .buffer = 10, .memory = 20, .mapped = null };
    const stored = vk_upload.hot_pool_store(&entry, &size, 1024, value);
    try std.testing.expect(stored);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 1024), size);
}

test "vulkan: hot_pool_store fails when slot is already occupied" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 1, .memory = 2, .mapped = null };
    var size: u64 = 512;
    const value = vk_upload.VkPoolEntry{ .buffer = 10, .memory = 20, .mapped = null };
    const stored = vk_upload.hot_pool_store(&entry, &size, 1024, value);
    try std.testing.expect(!stored);
    // Original entry should be preserved.
    try std.testing.expectEqual(@as(vk_constants.VkBuffer, 1), entry.?.buffer);
}

test "vulkan: hot_pool_store fails when size exceeds HOT_UPLOAD_POOL_CACHE_MAX_BYTES" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    const value = vk_upload.VkPoolEntry{ .buffer = 10, .memory = 20, .mapped = null };
    const stored = vk_upload.hot_pool_store(&entry, &size, vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES + 1, value);
    try std.testing.expect(!stored);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), entry);
}

// ============================================================
// vk_pool_pop — pure pool lookup logic
// ============================================================

test "vulkan: vk_pool_pop returns null from empty pool" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);
    const result = vk_upload.vk_pool_pop(&pool, 1024);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), result);
}

test "vulkan: vk_pool_pop returns null for missing size key" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);

    // Insert an entry for size 2048 but look up size 1024.
    var list = std.ArrayListUnmanaged(vk_upload.VkPoolEntry){};
    try list.append(std.testing.allocator, .{ .buffer = 42, .memory = 43, .mapped = null });
    try pool.put(std.testing.allocator, 2048, list);

    const result = vk_upload.vk_pool_pop(&pool, 1024);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), result);

    // Cleanup.
    if (pool.getPtr(2048)) |l| {
        _ = l.pop();
        l.deinit(std.testing.allocator);
    }
}

test "vulkan: vk_pool_pop returns entry for matching size and removes it" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);

    var list = std.ArrayListUnmanaged(vk_upload.VkPoolEntry){};
    try list.append(std.testing.allocator, .{ .buffer = 100, .memory = 200, .mapped = null });
    try pool.put(std.testing.allocator, 4096, list);

    const result = vk_upload.vk_pool_pop(&pool, 4096);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(vk_constants.VkBuffer, 100), result.?.buffer);

    // Pool should now be empty for that size.
    const second = vk_upload.vk_pool_pop(&pool, 4096);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), second);

    // Cleanup.
    if (pool.getPtr(4096)) |l| {
        l.deinit(std.testing.allocator);
    }
}

// ============================================================
// PendingUpload — struct defaults
// ============================================================

test "vulkan: PendingUpload default byte_count is zero" {
    const upload = vk_upload.PendingUpload{
        .src_buffer = 0,
        .src_memory = 0,
        .dst_buffer = 0,
        .dst_memory = 0,
    };
    try std.testing.expectEqual(@as(u64, 0), upload.byte_count);
    try std.testing.expectEqual(@as(?*anyopaque, null), upload.src_mapped);
}

test "vulkan: PendingUpload stores explicit byte count" {
    const upload = vk_upload.PendingUpload{
        .src_buffer = 1,
        .src_memory = 2,
        .dst_buffer = 3,
        .dst_memory = 4,
        .byte_count = 65536,
        .src_mapped = null,
    };
    try std.testing.expectEqual(@as(u64, 65536), upload.byte_count);
}

// ============================================================
// Queue selection scoring — pure function
// ============================================================

test "vulkan: queue_selection_score rewards graphics capability" {
    const compute_only = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    const with_graphics = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = true,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    try std.testing.expect(vk_device.queue_selection_score(with_graphics) > vk_device.queue_selection_score(compute_only));
}

test "vulkan: queue_selection_score_for_policy can prefer compute-only queues" {
    const compute_only = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 64,
        .queue_count = 1,
    };
    const with_graphics = vk_device.QueueFamilySelection{
        .index = 1,
        .supports_graphics = true,
        .timestamp_valid_bits = 64,
        .queue_count = 1,
    };
    try std.testing.expect(
        vk_device.queue_selection_score_for_policy(compute_only, .prefer_compute_only) >
            vk_device.queue_selection_score_for_policy(with_graphics, .prefer_compute_only),
    );
}

test "vulkan: queue_family_kind records selected family role" {
    const compute_only = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    const with_graphics = vk_device.QueueFamilySelection{
        .index = 1,
        .supports_graphics = true,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    try std.testing.expectEqual(webgpu.QueueFamilyKind.compute_only, vk_device.queue_family_kind(compute_only));
    try std.testing.expectEqual(webgpu.QueueFamilyKind.graphics_compute, vk_device.queue_family_kind(with_graphics));
}

test "vulkan: queue_selection_score rewards timestamp support" {
    const no_timestamp = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    const with_timestamp = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 64,
        .queue_count = 1,
    };
    try std.testing.expect(vk_device.queue_selection_score(with_timestamp) > vk_device.queue_selection_score(no_timestamp));
}

test "vulkan: queue_selection_score scales with queue count" {
    const one_queue = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    const four_queues = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 4,
    };
    try std.testing.expect(vk_device.queue_selection_score(four_queues) > vk_device.queue_selection_score(one_queue));
}

test "vulkan: queue_selection_score graphics bonus exceeds timestamp bonus" {
    // Graphics bonus (10000) should exceed timestamp bonus (1000).
    const timestamp_only = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 64,
        .queue_count = 1,
    };
    const graphics_only = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = true,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    try std.testing.expect(vk_device.queue_selection_score(graphics_only) > vk_device.queue_selection_score(timestamp_only));
}

test "vulkan: queue_selection_score full-featured queue gets highest score" {
    const full = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = true,
        .timestamp_valid_bits = 64,
        .queue_count = 16,
    };
    const minimal = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 1,
    };
    const full_score = vk_device.queue_selection_score(full);
    const min_score = vk_device.queue_selection_score(minimal);
    try std.testing.expect(full_score > min_score);
    // Full: 16*100 + 10000 + 1000 = 12600
    // Min: 1*100 = 100
    try std.testing.expectEqual(@as(u64, 12600), full_score);
    try std.testing.expectEqual(@as(u64, 100), min_score);
}

test "vulkan: queue_selection_score zero queue_count gives zero base" {
    const zero = vk_device.QueueFamilySelection{
        .index = 0,
        .supports_graphics = false,
        .timestamp_valid_bits = 0,
        .queue_count = 0,
    };
    try std.testing.expectEqual(@as(u64, 0), vk_device.queue_selection_score(zero));
}

// ============================================================
// Vulkan constants — value verification
// ============================================================

test "vulkan: VK_API_VERSION_1_0 matches Vulkan 1.0 packed version" {
    try std.testing.expectEqual(@as(u32, 0x00400000), vk_constants.VK_API_VERSION_1_0);
}

test "vulkan: MAX_DESCRIPTOR_SETS is 4" {
    try std.testing.expectEqual(@as(usize, 4), vk_constants.MAX_DESCRIPTOR_SETS);
    try std.testing.expectEqual(@as(u32, 4), vk_constants.MAX_DESCRIPTOR_SETS_U32);
}

test "vulkan: VK_WHOLE_SIZE is max u64" {
    try std.testing.expectEqual(std.math.maxInt(u64), vk_constants.VK_WHOLE_SIZE);
}

test "vulkan: queue bit constants are distinct power-of-two flags" {
    try std.testing.expectEqual(@as(u32, 1), vk_constants.VK_QUEUE_GRAPHICS_BIT);
    try std.testing.expectEqual(@as(u32, 2), vk_constants.VK_QUEUE_COMPUTE_BIT);
    // Graphics and compute bits should be non-overlapping.
    try std.testing.expectEqual(@as(u32, 0), vk_constants.VK_QUEUE_GRAPHICS_BIT & vk_constants.VK_QUEUE_COMPUTE_BIT);
}

test "vulkan: memory property bits are distinct" {
    const device_local = vk_constants.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    const host_visible = vk_constants.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    const host_coherent = vk_constants.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    try std.testing.expectEqual(@as(u32, 0), device_local & host_visible);
    try std.testing.expectEqual(@as(u32, 0), device_local & host_coherent);
    try std.testing.expectEqual(@as(u32, 0), host_visible & host_coherent);
}

test "vulkan: buffer usage bits are non-overlapping" {
    const all_bits = [_]u32{
        vk_constants.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        vk_constants.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        vk_constants.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    };
    for (all_bits, 0..) |a, i| {
        for (all_bits[i + 1 ..]) |b| {
            try std.testing.expectEqual(@as(u32, 0), a & b);
        }
    }
}

test "vulkan: VK_FORMAT_R8G8B8A8_UNORM is 37" {
    try std.testing.expectEqual(@as(u32, 37), vk_constants.VK_FORMAT_R8G8B8A8_UNORM);
}

test "vulkan: DEFAULT_SURFACE_MAX_FRAME_LATENCY is 2" {
    try std.testing.expectEqual(@as(u32, 2), vk_constants.DEFAULT_SURFACE_MAX_FRAME_LATENCY);
}

test "vulkan: VK_SUBPASS_EXTERNAL is max u32" {
    try std.testing.expectEqual(std.math.maxInt(u32), vk_constants.VK_SUBPASS_EXTERNAL);
}

// ============================================================
// Texture helpers — pure functions from vk_resources
// ============================================================

test "vulkan: texture_format_to_vk maps RGBA8Unorm correctly" {
    const vk_format = try vk_resources.texture_format_to_vk(model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expectEqual(@as(u32, 37), vk_format); // VK_FORMAT_R8G8B8A8_UNORM
}

test "vulkan: texture_format_to_vk returns error for unsupported format" {
    const result = vk_resources.texture_format_to_vk(model.WGPUTextureFormat_Undefined);
    try std.testing.expectError(error.UnsupportedFeature, result);
}

test "vulkan: bytes_per_pixel_for_texture_format returns 4 for RGBA8Unorm" {
    const bpp = vk_resources.bytes_per_pixel_for_texture_format(model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expectEqual(@as(u32, 4), bpp);
}

test "vulkan: bytes_per_pixel_for_texture_format defaults to 4 for unknown formats" {
    const bpp = vk_resources.bytes_per_pixel_for_texture_format(model.WGPUTextureFormat_Undefined);
    try std.testing.expectEqual(@as(u32, 4), bpp);
}

test "vulkan: effective_texture_usage returns default when requested is zero" {
    const usage = vk_resources.effective_texture_usage(0);
    try std.testing.expectEqual(vk_resources.DEFAULT_RUNTIME_TEXTURE_USAGE, usage);
}

test "vulkan: effective_texture_usage adds CopyDst to non-zero request" {
    const requested = model.WGPUTextureUsage_TextureBinding;
    const usage = vk_resources.effective_texture_usage(requested);
    // Should include both the original flag and CopyDst.
    try std.testing.expect((usage & model.WGPUTextureUsage_TextureBinding) != 0);
    try std.testing.expect((usage & model.WGPUTextureUsage_CopyDst) != 0);
}

test "vulkan: effective_texture_usage preserves all requested flags" {
    const requested = model.WGPUTextureUsage_StorageBinding | model.WGPUTextureUsage_CopySrc;
    const usage = vk_resources.effective_texture_usage(requested);
    try std.testing.expect((usage & model.WGPUTextureUsage_StorageBinding) != 0);
    try std.testing.expect((usage & model.WGPUTextureUsage_CopySrc) != 0);
    try std.testing.expect((usage & model.WGPUTextureUsage_CopyDst) != 0);
}

test "vulkan: image_usage_for_texture always includes TRANSFER_DST" {
    const no_flags = vk_resources.image_usage_for_texture(0, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((no_flags & vk_constants.VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0);
}

test "vulkan: image_usage_for_texture maps TextureBinding to SAMPLED" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_TextureBinding, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_SAMPLED_BIT) != 0);
}

test "vulkan: image_usage_for_texture maps StorageBinding to STORAGE" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_StorageBinding, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_STORAGE_BIT) != 0);
}

test "vulkan: image_usage_for_texture maps CopySrc to TRANSFER_SRC" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_CopySrc, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0);
}

test "vulkan: image_usage_for_texture maps CopyDst to TRANSFER_DST" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_CopyDst, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0);
}

// ============================================================
// Texture transition source — pure layout-to-barrier mapping
// ============================================================

test "vulkan: texture_transition_source for UNDEFINED layout" {
    const source = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_UNDEFINED);
    try std.testing.expectEqual(@as(u32, 0), source.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, source.src_stage);
}

test "vulkan: texture_transition_source for TRANSFER_DST_OPTIMAL layout" {
    const source = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    try std.testing.expectEqual(vk_constants.VK_ACCESS_TRANSFER_WRITE_BIT, source.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TRANSFER_BIT, source.src_stage);
}

test "vulkan: texture_transition_source for GENERAL layout" {
    const source = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_GENERAL);
    const expected_access = vk_constants.VK_ACCESS_SHADER_READ_BIT | vk_constants.VK_ACCESS_SHADER_WRITE_BIT;
    try std.testing.expectEqual(expected_access, source.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, source.src_stage);
}

test "vulkan: texture_transition_source for unknown layout falls back to top-of-pipe" {
    const source = vk_resources.texture_transition_source(999);
    try std.testing.expectEqual(@as(u32, 0), source.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, source.src_stage);
}

// ============================================================
// NativeVulkanRuntime — default state
// ============================================================

test "vulkan: NativeVulkanRuntime default state is uninitialized" {
    const rt = native_runtime.NativeVulkanRuntime{
        .allocator = std.testing.allocator,
        .kernel_root = null,
    };
    try std.testing.expect(!rt.has_instance);
    try std.testing.expect(!rt.has_device);
    try std.testing.expect(!rt.has_command_pool);
    try std.testing.expect(!rt.has_primary_command_buffer);
    try std.testing.expect(!rt.has_fence);
    try std.testing.expect(rt.shared_pipeline == null);
    try std.testing.expect(!rt.has_pipeline_layout);
    try std.testing.expect(!rt.has_pipeline);
    try std.testing.expect(!rt.has_descriptor_pool);
    try std.testing.expect(!rt.has_deferred_submissions);
    try std.testing.expect(!rt.upload_recording_active);
    try std.testing.expectEqual(@as(?vk_upload.PendingUpload, null), rt.hot_pending_upload);
}

test "vulkan: NativeVulkanRuntime default queue_family_index is zero" {
    const rt = native_runtime.NativeVulkanRuntime{
        .allocator = std.testing.allocator,
        .kernel_root = null,
    };
    try std.testing.expectEqual(@as(u32, 0), rt.queue_family_index);
    try std.testing.expectEqual(@as(?u32, null), rt.queue_family_index_value_cache);
    try std.testing.expectEqual(@as(?u32, null), rt.adapter_ordinal_value);
    try std.testing.expectEqual(@as(?bool, null), rt.present_capable_value);
}

test "vulkan: NativeVulkanRuntime default descriptor sets are null" {
    const rt = native_runtime.NativeVulkanRuntime{
        .allocator = std.testing.allocator,
        .kernel_root = null,
    };
    try std.testing.expectEqual(@as(u32, 0), rt.descriptor_set_count);
    try std.testing.expectEqual(@as(u64, 0), rt.current_pipeline_hash);
    try std.testing.expectEqual(@as(u64, 0), rt.current_layout_hash);
    try std.testing.expectEqual(@as(usize, 0), rt.shared_pipelines.entries.items.len);
}

test "vulkan: NativeVulkanRuntime default fast upload state is uninitialized" {
    const rt = native_runtime.NativeVulkanRuntime{
        .allocator = std.testing.allocator,
        .kernel_root = null,
    };
    try std.testing.expectEqual(@as(u64, 0), rt.fast_upload_capacity);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.fast_upload_mapped);
}

test "vulkan: NativeVulkanRuntime adapter info caches default to null" {
    const rt = native_runtime.NativeVulkanRuntime{
        .allocator = std.testing.allocator,
        .kernel_root = null,
    };
    try std.testing.expectEqual(@as(?u32, null), rt.adapter_ordinal_value);
    try std.testing.expectEqual(@as(?u32, null), rt.queue_family_index_value_cache);
    try std.testing.expectEqual(@as(?bool, null), rt.present_capable_value);
}

// ============================================================
// DispatchMetrics — struct layout and defaults
// ============================================================

test "vulkan: DispatchMetrics default values are zero" {
    const m = native_runtime.DispatchMetrics{};
    try std.testing.expectEqual(@as(u64, 0), m.encode_ns);
    try std.testing.expectEqual(@as(u64, 0), m.submit_wait_ns);
    try std.testing.expectEqual(@as(u64, 0), m.gpu_timestamp_ns);
    try std.testing.expect(!m.gpu_timestamp_attempted);
    try std.testing.expect(!m.gpu_timestamp_valid);
}

test "vulkan: DispatchMetrics stores gpu timestamp fields" {
    const m = native_runtime.DispatchMetrics{
        .encode_ns = 1000,
        .submit_wait_ns = 2000,
        .gpu_timestamp_ns = 500,
        .gpu_timestamp_attempted = true,
        .gpu_timestamp_valid = true,
    };
    try std.testing.expectEqual(@as(u64, 500), m.gpu_timestamp_ns);
    try std.testing.expect(m.gpu_timestamp_attempted);
    try std.testing.expect(m.gpu_timestamp_valid);
}
