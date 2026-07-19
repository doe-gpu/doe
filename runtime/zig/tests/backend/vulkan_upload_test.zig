// Vulkan upload path, staging buffer pool, format mapping, and resource
// helper tests. All tests are pure-logic (no GPU required).

const std = @import("std");
const vk_upload = @import("../../src/backend/vulkan/vk_upload.zig");
const vk_resources = @import("../../src/backend/vulkan/vk_resources.zig");
const vk_constants = @import("../../src/backend/vulkan/vk_constants.zig");
const vk_formats = @import("../../src/backend/vulkan/vk_formats.zig");
const vulkan_errors = @import("../../src/backend/vulkan/vulkan_errors.zig");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const model = @import("../../src/contracts/model/model.zig");

// ============================================================
// Upload constant stability
// ============================================================

test "vulkan upload: MAX_UPLOAD_BYTES is zero (driver-limit only)" {
    try std.testing.expectEqual(@as(u64, 0), vk_upload.MAX_UPLOAD_BYTES);
}

test "vulkan upload: MAX_UPLOAD_ZERO_FILL_BYTES is exactly 1 MiB" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES);
}

test "vulkan upload: FAST_UPLOAD_BUFFER_MAX_BYTES is exactly 1 MiB" {
    try std.testing.expectEqual(@as(u64, 1024 * 1024), vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES);
}

test "vulkan upload: DIRECT_UPLOAD_BUFFER_MAX_BYTES is exactly 4 GiB" {
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
}

test "vulkan upload: DIRECT_UPLOAD_REUSE_SKIP_ZERO_FILL_MIN_BYTES matches DIRECT max" {
    try std.testing.expectEqual(
        vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES,
        vk_upload.DIRECT_UPLOAD_REUSE_SKIP_ZERO_FILL_MIN_BYTES,
    );
}

test "vulkan upload: HOT_UPLOAD_POOL_CACHE_MAX_BYTES is 64 KiB" {
    try std.testing.expectEqual(@as(u64, 64 * 1024), vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES);
}

test "vulkan upload: WAIT_TIMEOUT_NS is max u64" {
    try std.testing.expectEqual(std.math.maxInt(u64), vk_upload.WAIT_TIMEOUT_NS);
}

test "vulkan upload: MAX_POOL_ENTRIES_PER_SIZE is 8" {
    try std.testing.expectEqual(@as(usize, 8), vk_upload.MAX_POOL_ENTRIES_PER_SIZE);
}

test "vulkan upload: threshold ordering fast < direct" {
    try std.testing.expect(vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES < vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
}

test "vulkan upload: hot pool cache max < fast upload max" {
    try std.testing.expect(vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES < vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES);
}

// ============================================================
// UploadPathKind enum values
// ============================================================

test "vulkan upload: UploadPathKind has exactly three variants" {
    const fields = @typeInfo(vk_upload.UploadPathKind).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
}

test "vulkan upload: UploadPathKind variants have stable ordinals" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(vk_upload.UploadPathKind.fast_mapped));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(vk_upload.UploadPathKind.direct_mapped));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(vk_upload.UploadPathKind.staged_copy));
}

// ============================================================
// classify_upload_path — comprehensive path classification
// ============================================================

test "vulkan upload: classify fast_mapped for small copy_dst with allow_mapped" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, 512);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, result);
}

test "vulkan upload: classify fast_mapped at exact fast threshold" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, result);
}

test "vulkan upload: classify direct_mapped just above fast threshold" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1);
    try std.testing.expectEqual(vk_upload.UploadPathKind.direct_mapped, result);
}

test "vulkan upload: classify direct_mapped at exact direct threshold" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES);
    try std.testing.expectEqual(vk_upload.UploadPathKind.direct_mapped, result);
}

test "vulkan upload: classify staged_copy above direct threshold" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES + 1);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, result);
}

test "vulkan upload: classify staged_copy for copy_dst_copy_src regardless of size" {
    const sizes = [_]u64{ 1, 512, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES };
    for (sizes) |s| {
        try std.testing.expectEqual(
            vk_upload.UploadPathKind.staged_copy,
            vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst_copy_src, s),
        );
    }
}

test "vulkan upload: staged_copy_only still allows fast_mapped for small copy_dst (Dawn parity)" {
    // Per vk_upload.zig: small copy_dst returns fast_mapped even under staged_copy_only
    // to match Dawn's WriteBuffer behavior (CLAUDE.md rules 7/10/11).
    // staged_copy_only blocks only the middle range (direct_mapped).
    const result = vk_upload.classify_upload_path(.staged_copy_only, .copy_dst, 64);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, result);
}

test "vulkan upload: staged_copy_only blocks direct_mapped for medium sizes" {
    const medium = vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1;
    const result = vk_upload.classify_upload_path(.staged_copy_only, .copy_dst, medium);
    try std.testing.expectEqual(vk_upload.UploadPathKind.staged_copy, result);
}

test "vulkan upload: zero-byte classify returns fast_mapped for copy_dst" {
    const result = vk_upload.classify_upload_path(.allow_mapped_shortcuts, .copy_dst, 0);
    try std.testing.expectEqual(vk_upload.UploadPathKind.fast_mapped, result);
}

// ============================================================
// upload_uses_fast_path / upload_uses_direct_path — convenience wrappers
// ============================================================

test "vulkan upload: uses_fast_path true for small copy_dst" {
    try std.testing.expect(vk_upload.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024));
}

test "vulkan upload: uses_fast_path false above threshold" {
    try std.testing.expect(!vk_upload.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1));
}

test "vulkan upload: uses_direct_path true in range" {
    try std.testing.expect(vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES + 1));
}

test "vulkan upload: uses_direct_path false at fast threshold" {
    try std.testing.expect(!vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.FAST_UPLOAD_BUFFER_MAX_BYTES));
}

test "vulkan upload: uses_direct_path false above direct threshold" {
    try std.testing.expect(!vk_upload.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, vk_upload.DIRECT_UPLOAD_BUFFER_MAX_BYTES + 1));
}

test "vulkan upload: uses_direct_path false under staged_copy_only" {
    try std.testing.expect(!vk_upload.upload_uses_direct_path(.staged_copy_only, .copy_dst, 2 * 1024 * 1024));
}

// ============================================================
// bounded_upload_fill_len — fill size clamping
// ============================================================

test "vulkan upload: bounded_upload_fill_len zero input" {
    try std.testing.expectEqual(@as(usize, 0), vk_upload.bounded_upload_fill_len(0));
}

test "vulkan upload: bounded_upload_fill_len small input passthrough" {
    try std.testing.expectEqual(@as(usize, 256), vk_upload.bounded_upload_fill_len(256));
}

test "vulkan upload: bounded_upload_fill_len at exact MAX_UPLOAD_ZERO_FILL_BYTES" {
    try std.testing.expectEqual(
        @as(usize, vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES),
        vk_upload.bounded_upload_fill_len(vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES),
    );
}

test "vulkan upload: bounded_upload_fill_len clamps above MAX_UPLOAD_ZERO_FILL_BYTES" {
    const over = vk_upload.bounded_upload_fill_len(vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES + 999);
    try std.testing.expectEqual(@as(usize, vk_upload.MAX_UPLOAD_ZERO_FILL_BYTES), over);
}

test "vulkan upload: bounded_upload_fill_len single byte" {
    try std.testing.expectEqual(@as(usize, 1), vk_upload.bounded_upload_fill_len(1));
}

test "vulkan upload: bounded_upload_fill_len large value clamps to 1 MiB" {
    const big: u64 = 1024 * 1024 * 1024; // 1 GiB
    try std.testing.expectEqual(@as(usize, 1024 * 1024), vk_upload.bounded_upload_fill_len(big));
}

// ============================================================
// Hot pool operations — pure logic
// ============================================================

test "vulkan upload: hot_pool_pop null entry returns null" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.hot_pool_pop(&entry, &size, 1024));
}

test "vulkan upload: hot_pool_pop size mismatch returns null, preserves entry" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 42, .memory = 43, .mapped = null };
    var size: u64 = 2048;
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.hot_pool_pop(&entry, &size, 1024));
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 2048), size);
}

test "vulkan upload: hot_pool_pop exact match consumes entry" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 10, .memory = 20, .mapped = null };
    var size: u64 = 4096;
    const result = vk_upload.hot_pool_pop(&entry, &size, 4096);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 10), result.?.buffer);
    try std.testing.expectEqual(@as(u64, 20), result.?.memory);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), entry);
    try std.testing.expectEqual(@as(u64, 0), size);
}

test "vulkan upload: hot_pool_pop rejects above HOT_UPLOAD_POOL_CACHE_MAX_BYTES" {
    const too_big = vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES + 1;
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 1, .memory = 2, .mapped = null };
    var size: u64 = too_big;
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.hot_pool_pop(&entry, &size, too_big));
    try std.testing.expect(entry != null);
}

test "vulkan upload: hot_pool_pop at exact HOT_UPLOAD_POOL_CACHE_MAX_BYTES succeeds" {
    const exact = vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES;
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 5, .memory = 6, .mapped = null };
    var size: u64 = exact;
    const result = vk_upload.hot_pool_pop(&entry, &size, exact);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), entry);
}

test "vulkan upload: hot_pool_store into empty slot succeeds" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    const val = vk_upload.VkPoolEntry{ .buffer = 99, .memory = 100, .mapped = null };
    try std.testing.expect(vk_upload.hot_pool_store(&entry, &size, 2048, val));
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 2048), size);
    try std.testing.expectEqual(@as(u64, 99), entry.?.buffer);
}

test "vulkan upload: hot_pool_store fails when slot occupied" {
    var entry: ?vk_upload.VkPoolEntry = .{ .buffer = 1, .memory = 2, .mapped = null };
    var size: u64 = 512;
    const val = vk_upload.VkPoolEntry{ .buffer = 99, .memory = 100, .mapped = null };
    try std.testing.expect(!vk_upload.hot_pool_store(&entry, &size, 1024, val));
    try std.testing.expectEqual(@as(u64, 1), entry.?.buffer);
}

test "vulkan upload: hot_pool_store fails when size exceeds limit" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    const val = vk_upload.VkPoolEntry{ .buffer = 1, .memory = 2, .mapped = null };
    try std.testing.expect(!vk_upload.hot_pool_store(&entry, &size, vk_upload.HOT_UPLOAD_POOL_CACHE_MAX_BYTES + 1, val));
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), entry);
}

test "vulkan upload: hot_pool roundtrip store then pop" {
    var entry: ?vk_upload.VkPoolEntry = null;
    var size: u64 = 0;
    const val = vk_upload.VkPoolEntry{ .buffer = 77, .memory = 88, .mapped = null };

    try std.testing.expect(vk_upload.hot_pool_store(&entry, &size, 1024, val));
    const popped = vk_upload.hot_pool_pop(&entry, &size, 1024);
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(u64, 77), popped.?.buffer);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), entry);
}

// ============================================================
// VkPool (HashMap pool) — pure logic
// ============================================================

test "vulkan upload: vk_pool_pop from empty pool returns null" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.vk_pool_pop(&pool, 1024));
}

test "vulkan upload: vk_pool_pop missing size key returns null" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);

    var list = std.ArrayListUnmanaged(vk_upload.VkPoolEntry){};
    try list.append(std.testing.allocator, .{ .buffer = 42, .memory = 43, .mapped = null });
    try pool.put(std.testing.allocator, 2048, list);

    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.vk_pool_pop(&pool, 1024));

    if (pool.getPtr(2048)) |l| {
        _ = l.pop();
        l.deinit(std.testing.allocator);
    }
}

test "vulkan upload: vk_pool_pop returns and removes matching entry" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);

    var list = std.ArrayListUnmanaged(vk_upload.VkPoolEntry){};
    try list.append(std.testing.allocator, .{ .buffer = 55, .memory = 66, .mapped = null });
    try pool.put(std.testing.allocator, 4096, list);

    const result = vk_upload.vk_pool_pop(&pool, 4096);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 55), result.?.buffer);

    // Second pop should be empty.
    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.vk_pool_pop(&pool, 4096));

    if (pool.getPtr(4096)) |l| l.deinit(std.testing.allocator);
}

test "vulkan upload: vk_pool_pop with multiple entries returns last pushed" {
    var pool = vk_upload.VkPool{};
    defer pool.deinit(std.testing.allocator);

    var list = std.ArrayListUnmanaged(vk_upload.VkPoolEntry){};
    try list.append(std.testing.allocator, .{ .buffer = 1, .memory = 10, .mapped = null });
    try list.append(std.testing.allocator, .{ .buffer = 2, .memory = 20, .mapped = null });
    try pool.put(std.testing.allocator, 8192, list);

    const first = vk_upload.vk_pool_pop(&pool, 8192);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(u64, 2), first.?.buffer);

    const second = vk_upload.vk_pool_pop(&pool, 8192);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(@as(u64, 1), second.?.buffer);

    try std.testing.expectEqual(@as(?vk_upload.VkPoolEntry, null), vk_upload.vk_pool_pop(&pool, 8192));

    if (pool.getPtr(8192)) |l| l.deinit(std.testing.allocator);
}

// ============================================================
// PendingUpload struct defaults
// ============================================================

test "vulkan upload: PendingUpload default byte_count is zero" {
    const upload = vk_upload.PendingUpload{
        .src_buffer = 0,
        .src_memory = 0,
        .dst_buffer = 0,
        .dst_memory = 0,
    };
    try std.testing.expectEqual(@as(u64, 0), upload.byte_count);
    try std.testing.expectEqual(@as(?*anyopaque, null), upload.src_mapped);
}

test "vulkan upload: PendingUpload stores explicit values" {
    const upload = vk_upload.PendingUpload{
        .src_buffer = 1,
        .src_memory = 2,
        .dst_buffer = 3,
        .dst_memory = 4,
        .byte_count = 65536,
        .src_mapped = null,
    };
    try std.testing.expectEqual(@as(u64, 65536), upload.byte_count);
    try std.testing.expectEqual(@as(u64, 1), upload.src_buffer);
    try std.testing.expectEqual(@as(u64, 4), upload.dst_memory);
}

test "vulkan upload: VkPoolEntry stores mapped pointer" {
    var dummy: u8 = 0;
    const entry = vk_upload.VkPoolEntry{
        .buffer = 10,
        .memory = 20,
        .mapped = @ptrCast(&dummy),
    };
    try std.testing.expect(entry.mapped != null);
    try std.testing.expectEqual(@as(u64, 10), entry.buffer);
}

// ============================================================
// Format mapping — WebGPU to VkFormat
// ============================================================

test "vulkan upload: RGBA8Unorm maps to VK_FORMAT_R8G8B8A8_UNORM (37)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expectEqual(@as(u32, 37), vk_fmt);
}

test "vulkan upload: BGRA8Unorm maps to VK_FORMAT_B8G8R8A8_UNORM (44)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_BGRA8Unorm);
    try std.testing.expectEqual(@as(u32, 44), vk_fmt);
}

test "vulkan upload: R32Float maps to VK_FORMAT_R32_SFLOAT (100)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_R32Float);
    try std.testing.expectEqual(@as(u32, 100), vk_fmt);
}

test "vulkan upload: RGBA16Float maps to VK_FORMAT_R16G16B16A16_SFLOAT (97)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_RGBA16Float);
    try std.testing.expectEqual(@as(u32, 97), vk_fmt);
}

test "vulkan upload: RGBA32Float maps to VK_FORMAT_R32G32B32A32_SFLOAT (109)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_RGBA32Float);
    try std.testing.expectEqual(@as(u32, 109), vk_fmt);
}

test "vulkan upload: Depth32Float maps to VK_FORMAT_D32_SFLOAT (126)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_Depth32Float);
    try std.testing.expectEqual(@as(u32, 126), vk_fmt);
}

test "vulkan upload: Depth24PlusStencil8 maps to VK_FORMAT_D24_UNORM_S8_UINT (129)" {
    const vk_fmt = try vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_Depth24PlusStencil8);
    try std.testing.expectEqual(@as(u32, 129), vk_fmt);
}

test "vulkan upload: Undefined format returns UnsupportedFeature" {
    try std.testing.expectError(error.UnsupportedFeature, vk_formats.wgpu_format_to_vk_format(model.WGPUTextureFormat_Undefined));
}

test "vulkan upload: bogus format value returns UnsupportedFeature" {
    try std.testing.expectError(error.UnsupportedFeature, vk_formats.wgpu_format_to_vk_format(0xFFFF));
}

// ============================================================
// Format metadata — bytes per pixel
// ============================================================

test "vulkan upload: bytes_per_pixel R8Unorm is 1" {
    try std.testing.expectEqual(@as(u32, 1), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_R8Unorm));
}

test "vulkan upload: bytes_per_pixel RG8Unorm is 2" {
    try std.testing.expectEqual(@as(u32, 2), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_RG8Unorm));
}

test "vulkan upload: bytes_per_pixel RGBA8Unorm is 4" {
    try std.testing.expectEqual(@as(u32, 4), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA8Unorm));
}

test "vulkan upload: bytes_per_pixel RGBA16Float is 8" {
    try std.testing.expectEqual(@as(u32, 8), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA16Float));
}

test "vulkan upload: bytes_per_pixel RGBA32Float is 16" {
    try std.testing.expectEqual(@as(u32, 16), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA32Float));
}

test "vulkan upload: bytes_per_pixel Depth16Unorm is 2" {
    try std.testing.expectEqual(@as(u32, 2), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_Depth16Unorm));
}

test "vulkan upload: bytes_per_pixel Depth32Float is 4" {
    try std.testing.expectEqual(@as(u32, 4), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_Depth32Float));
}

test "vulkan upload: bytes_per_pixel Depth32FloatStencil8 is 8" {
    try std.testing.expectEqual(@as(u32, 8), try vk_formats.bytes_per_pixel(model.WGPUTextureFormat_Depth32FloatStencil8));
}

test "vulkan upload: bytes_per_pixel_for_texture_format defaults to 4 for unknown" {
    try std.testing.expectEqual(@as(u32, 4), vk_resources.bytes_per_pixel_for_texture_format(model.WGPUTextureFormat_Undefined));
}

// ============================================================
// Format metadata — aspect mask
// ============================================================

test "vulkan upload: aspect_mask color format returns COLOR_BIT" {
    try std.testing.expectEqual(vk_formats.VK_IMAGE_ASPECT_COLOR_BIT, vk_formats.aspect_mask_for_format(model.WGPUTextureFormat_RGBA8Unorm));
}

test "vulkan upload: aspect_mask Depth16Unorm returns DEPTH_BIT" {
    try std.testing.expectEqual(vk_formats.VK_IMAGE_ASPECT_DEPTH_BIT, vk_formats.aspect_mask_for_format(model.WGPUTextureFormat_Depth16Unorm));
}

test "vulkan upload: aspect_mask Depth32Float returns DEPTH_BIT" {
    try std.testing.expectEqual(vk_formats.VK_IMAGE_ASPECT_DEPTH_BIT, vk_formats.aspect_mask_for_format(model.WGPUTextureFormat_Depth32Float));
}

test "vulkan upload: aspect_mask Depth24PlusStencil8 returns DEPTH|STENCIL" {
    const expected = vk_formats.VK_IMAGE_ASPECT_DEPTH_BIT | vk_formats.VK_IMAGE_ASPECT_STENCIL_BIT;
    try std.testing.expectEqual(expected, vk_formats.aspect_mask_for_format(model.WGPUTextureFormat_Depth24PlusStencil8));
}

test "vulkan upload: aspect_mask Stencil8 returns STENCIL_BIT" {
    try std.testing.expectEqual(vk_formats.VK_IMAGE_ASPECT_STENCIL_BIT, vk_formats.aspect_mask_for_format(model.WGPUTextureFormat_Stencil8));
}

// ============================================================
// Format metadata — is_depth_stencil
// ============================================================

test "vulkan upload: is_depth_stencil true for depth formats" {
    try std.testing.expect(vk_formats.is_depth_stencil(model.WGPUTextureFormat_Depth16Unorm));
    try std.testing.expect(vk_formats.is_depth_stencil(model.WGPUTextureFormat_Depth32Float));
    try std.testing.expect(vk_formats.is_depth_stencil(model.WGPUTextureFormat_Depth24Plus));
    try std.testing.expect(vk_formats.is_depth_stencil(model.WGPUTextureFormat_Depth24PlusStencil8));
    try std.testing.expect(vk_formats.is_depth_stencil(model.WGPUTextureFormat_Depth32FloatStencil8));
    try std.testing.expect(vk_formats.is_depth_stencil(model.WGPUTextureFormat_Stencil8));
}

test "vulkan upload: is_depth_stencil false for color formats" {
    try std.testing.expect(!vk_formats.is_depth_stencil(model.WGPUTextureFormat_RGBA8Unorm));
    try std.testing.expect(!vk_formats.is_depth_stencil(model.WGPUTextureFormat_BGRA8Unorm));
    try std.testing.expect(!vk_formats.is_depth_stencil(model.WGPUTextureFormat_R32Float));
    try std.testing.expect(!vk_formats.is_depth_stencil(model.WGPUTextureFormat_RGBA32Float));
}

// ============================================================
// Vertex format mapping
// ============================================================

test "vulkan upload: vertex format Float32x4 maps to R32G32B32A32_SFLOAT" {
    const vk_fmt = try vk_formats.wgpu_vertex_format_to_vk(0x1C); // FLOAT32X4
    try std.testing.expectEqual(vk_formats.VK_FORMAT_R32G32B32A32_SFLOAT, vk_fmt);
}

test "vulkan upload: vertex format Uint8x4 maps to R8G8B8A8_UINT" {
    const vk_fmt = try vk_formats.wgpu_vertex_format_to_vk(0x03); // UINT8X4
    try std.testing.expectEqual(vk_formats.VK_FORMAT_R8G8B8A8_UINT, vk_fmt);
}

test "vulkan upload: vertex format invalid returns UnsupportedFeature" {
    try std.testing.expectError(error.UnsupportedFeature, vk_formats.wgpu_vertex_format_to_vk(0xFF));
}

// ============================================================
// Vulkan constant values — buffer usage flags match Vulkan spec
// ============================================================

test "vulkan upload: VK_BUFFER_USAGE_TRANSFER_SRC_BIT is 0x01" {
    try std.testing.expectEqual(@as(u32, 0x00000001), vk_constants.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
}

test "vulkan upload: VK_BUFFER_USAGE_TRANSFER_DST_BIT is 0x02" {
    try std.testing.expectEqual(@as(u32, 0x00000002), vk_constants.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
}

test "vulkan upload: VK_BUFFER_USAGE_STORAGE_BUFFER_BIT is 0x20" {
    try std.testing.expectEqual(@as(u32, 0x00000020), vk_constants.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
}

test "vulkan upload: all buffer usage bits are distinct" {
    const bits = [_]u32{
        vk_constants.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        vk_constants.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        vk_constants.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        vk_constants.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
    };
    for (bits, 0..) |a, i| {
        for (bits[i + 1 ..]) |b| {
            try std.testing.expectEqual(@as(u32, 0), a & b);
        }
    }
}

// ============================================================
// Vulkan constant values — memory property flags
// ============================================================

test "vulkan upload: VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT is 0x01" {
    try std.testing.expectEqual(@as(u32, 0x00000001), vk_constants.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
}

test "vulkan upload: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT is 0x02" {
    try std.testing.expectEqual(@as(u32, 0x00000002), vk_constants.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
}

test "vulkan upload: VK_MEMORY_PROPERTY_HOST_COHERENT_BIT is 0x04" {
    try std.testing.expectEqual(@as(u32, 0x00000004), vk_constants.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
}

test "vulkan upload: memory property bits are distinct" {
    const d = vk_constants.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    const v = vk_constants.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    const c = vk_constants.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    try std.testing.expectEqual(@as(u32, 0), d & v);
    try std.testing.expectEqual(@as(u32, 0), d & c);
    try std.testing.expectEqual(@as(u32, 0), v & c);
}

// ============================================================
// Vulkan constant values — image layout identifiers
// ============================================================

test "vulkan upload: image layout constants have correct values" {
    try std.testing.expectEqual(@as(u32, 0), vk_constants.VK_IMAGE_LAYOUT_UNDEFINED);
    try std.testing.expectEqual(@as(u32, 1), vk_constants.VK_IMAGE_LAYOUT_GENERAL);
    try std.testing.expectEqual(@as(u32, 2), vk_constants.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    try std.testing.expectEqual(@as(u32, 6), vk_constants.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    try std.testing.expectEqual(@as(u32, 7), vk_constants.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
}

// ============================================================
// Vulkan error mapping
// ============================================================

test "vulkan upload: check_vk succeeds on VK_SUCCESS" {
    try vulkan_errors.check_vk(0);
}

test "vulkan upload: check_vk returns error on negative VkResult" {
    try std.testing.expectError(error.UnsupportedFeature, vulkan_errors.check_vk(-7)); // VK_ERROR_EXTENSION_NOT_PRESENT
}

test "vulkan upload: map_vk_result maps known error codes to UnsupportedFeature" {
    const codes = [_]i32{ -7, -8, -9, -10, -11, -12, -13 };
    for (codes) |code| {
        try std.testing.expectEqual(error.UnsupportedFeature, vulkan_errors.map_vk_result(code));
    }
}

test "vulkan upload: map_vk_result maps unknown negative to InvalidState" {
    try std.testing.expectEqual(error.InvalidState, vulkan_errors.map_vk_result(-999));
}

test "vulkan upload: vulkanResultName returns VK_SUCCESS for 0" {
    try std.testing.expectEqualStrings("VK_SUCCESS", vulkan_errors.vulkanResultName(0));
}

test "vulkan upload: vulkanResultName returns VK_UNKNOWN for unrecognized code" {
    try std.testing.expectEqualStrings("VK_UNKNOWN", vulkan_errors.vulkanResultName(-9999));
}

// ============================================================
// Resource helpers — effective_texture_usage
// ============================================================

test "vulkan upload: effective_texture_usage zero returns default" {
    const usage = vk_resources.effective_texture_usage(0);
    try std.testing.expectEqual(vk_resources.DEFAULT_RUNTIME_TEXTURE_USAGE, usage);
}

test "vulkan upload: effective_texture_usage non-zero adds CopyDst" {
    const requested = model.WGPUTextureUsage_TextureBinding;
    const usage = vk_resources.effective_texture_usage(requested);
    try std.testing.expect((usage & model.WGPUTextureUsage_CopyDst) != 0);
    try std.testing.expect((usage & model.WGPUTextureUsage_TextureBinding) != 0);
}

test "vulkan upload: effective_texture_usage preserves all input flags" {
    const requested = model.WGPUTextureUsage_StorageBinding | model.WGPUTextureUsage_CopySrc;
    const usage = vk_resources.effective_texture_usage(requested);
    try std.testing.expect((usage & model.WGPUTextureUsage_StorageBinding) != 0);
    try std.testing.expect((usage & model.WGPUTextureUsage_CopySrc) != 0);
    try std.testing.expect((usage & model.WGPUTextureUsage_CopyDst) != 0);
}

// ============================================================
// Resource helpers — image_usage_for_texture
// ============================================================

test "vulkan upload: image_usage_for_texture always includes TRANSFER_DST" {
    try std.testing.expect((vk_resources.image_usage_for_texture(0, model.WGPUTextureFormat_RGBA8Unorm) & vk_constants.VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0);
}

test "vulkan upload: image_usage_for_texture TextureBinding adds SAMPLED" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_TextureBinding, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_SAMPLED_BIT) != 0);
}

test "vulkan upload: image_usage_for_texture StorageBinding adds STORAGE" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_StorageBinding, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_STORAGE_BIT) != 0);
}

test "vulkan upload: image_usage_for_texture CopySrc adds TRANSFER_SRC" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_CopySrc, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0);
}

test "vulkan upload: image_usage_for_texture RenderAttachment color adds COLOR_ATTACHMENT" {
    const usage = vk_resources.image_usage_for_texture(model.WGPUTextureUsage_RenderAttachment, model.WGPUTextureFormat_RGBA8Unorm);
    try std.testing.expect((usage & vk_constants.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) != 0);
}

// ============================================================
// Resource helpers — texture transition source
// ============================================================

test "vulkan upload: texture_transition_source UNDEFINED has zero access and TOP_OF_PIPE stage" {
    const src = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_UNDEFINED);
    try std.testing.expectEqual(@as(u32, 0), src.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, src.src_stage);
}

test "vulkan upload: texture_transition_source TRANSFER_SRC has TRANSFER_READ and TRANSFER stage" {
    const src = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    try std.testing.expectEqual(vk_constants.VK_ACCESS_TRANSFER_READ_BIT, src.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TRANSFER_BIT, src.src_stage);
}

test "vulkan upload: texture_transition_source TRANSFER_DST has TRANSFER_WRITE and TRANSFER stage" {
    const src = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    try std.testing.expectEqual(vk_constants.VK_ACCESS_TRANSFER_WRITE_BIT, src.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TRANSFER_BIT, src.src_stage);
}

test "vulkan upload: texture_transition_source GENERAL has SHADER_READ|WRITE and COMPUTE stage" {
    const src = vk_resources.texture_transition_source(vk_constants.VK_IMAGE_LAYOUT_GENERAL);
    const expected_access = vk_constants.VK_ACCESS_SHADER_READ_BIT | vk_constants.VK_ACCESS_SHADER_WRITE_BIT;
    try std.testing.expectEqual(expected_access, src.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, src.src_stage);
}

test "vulkan upload: texture_transition_source unknown layout falls back to TOP_OF_PIPE" {
    const src = vk_resources.texture_transition_source(12345);
    try std.testing.expectEqual(@as(u32, 0), src.src_access_mask);
    try std.testing.expectEqual(vk_constants.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, src.src_stage);
}

// ============================================================
// VK_NULL_U64 sentinel
// ============================================================

test "vulkan upload: VK_NULL_U64 is zero" {
    try std.testing.expectEqual(@as(u64, 0), vk_constants.VK_NULL_U64);
}

// ============================================================
// Sample count constants
// ============================================================

test "vulkan upload: sample count bits are powers of two" {
    try std.testing.expectEqual(@as(u32, 0x01), vk_constants.VK_SAMPLE_COUNT_1_BIT);
    try std.testing.expectEqual(@as(u32, 0x02), vk_constants.VK_SAMPLE_COUNT_2_BIT);
    try std.testing.expectEqual(@as(u32, 0x04), vk_constants.VK_SAMPLE_COUNT_4_BIT);
    try std.testing.expectEqual(@as(u32, 0x08), vk_constants.VK_SAMPLE_COUNT_8_BIT);
    try std.testing.expectEqual(@as(u32, 0x10), vk_constants.VK_SAMPLE_COUNT_16_BIT);
}

// ============================================================
// Structure type constants
// ============================================================

test "vulkan upload: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO is 12" {
    try std.testing.expectEqual(@as(i32, 12), vk_constants.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
}

test "vulkan upload: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO is 5" {
    // Per canonical vulkan_core.h. Previously asserted 17, which was
    // actually VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO -- every
    // vkAllocateMemory call silently passed a wrong sType that the AMDGPU
    // driver tolerated in release builds.
    try std.testing.expectEqual(@as(i32, 5), vk_constants.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
}

test "vulkan upload: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO is 42" {
    try std.testing.expectEqual(@as(i32, 42), vk_constants.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO);
}

test "vulkan upload: VK_STRUCTURE_TYPE_SUBMIT_INFO is 4" {
    try std.testing.expectEqual(@as(i32, 4), vk_constants.VK_STRUCTURE_TYPE_SUBMIT_INFO);
}
