const std = @import("std");
const builtin = @import("builtin");
const d3d12_runtime = @import("../../src/backend/d3d12/d3d12_native_runtime.zig");
const d3d12_upload = @import("../../src/backend/d3d12/d3d12_runtime_upload.zig");
const path_utils = @import("../../src/backend/common/path_utils.zig");
const dc = @import("../../src/backend/d3d12/d3d12_constants.zig");

// ============================================================
// file_exists — pure filesystem check
// ============================================================

test "d3d12: file_exists returns false for nonexistent path" {
    const exists = path_utils.file_exists("/tmp/definitely_nonexistent_doe_test_file_12345.xyz");
    try std.testing.expect(!exists);
}

test "d3d12: file_exists returns false for empty path" {
    const exists = path_utils.file_exists("");
    try std.testing.expect(!exists);
}

// ============================================================
// D3D12 constants — value verification
// ============================================================

test "d3d12: HEAP_TYPE_UPLOAD constant is 2" {
    try std.testing.expectEqual(@as(c_int, 2), dc.HEAP_TYPE_UPLOAD);
}

test "d3d12: RESOURCE_STATE_PRESENT is 0" {
    try std.testing.expectEqual(@as(c_int, 0), dc.RESOURCE_STATE_PRESENT);
}

test "d3d12: RESOURCE_STATE_RENDER_TARGET is 0x4" {
    try std.testing.expectEqual(@as(c_int, 0x00000004), dc.RESOURCE_STATE_RENDER_TARGET);
}

test "d3d12: RESOURCE_STATE_COPY_SOURCE is 0x800" {
    try std.testing.expectEqual(@as(c_int, 0x00000800), dc.RESOURCE_STATE_COPY_SOURCE);
}

test "d3d12: RESOURCE_STATE_COPY_DEST is 0x400" {
    try std.testing.expectEqual(@as(c_int, 0x00000400), dc.RESOURCE_STATE_COPY_DEST);
}

test "d3d12: RESOURCE_STATE_PIXEL_SHADER_RESOURCE is 0x80" {
    try std.testing.expectEqual(@as(c_int, 0x00000080), dc.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
}

test "d3d12: RESOURCE_STATE_GENERIC_READ is combined read states" {
    // GENERIC_READ = VERTEX_CONSTANT_BUFFER | INDEX_BUFFER | NON_PIXEL_SHADER_RESOURCE |
    //                PIXEL_SHADER_RESOURCE | INDIRECT_ARGUMENT | COPY_DEST
    const expected: c_int = 0x00000001 | 0x00000002 | 0x00000040 | 0x00000080 | 0x00000200 | 0x00000800;
    try std.testing.expectEqual(expected, dc.RESOURCE_STATE_GENERIC_READ);
}

test "d3d12: D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST is 4" {
    try std.testing.expectEqual(@as(c_int, 4), dc.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
}

test "d3d12: resource state constants are non-overlapping where expected" {
    // PRESENT (0) and RENDER_TARGET (4) must not share bits.
    try std.testing.expectEqual(
        @as(c_int, 0),
        dc.RESOURCE_STATE_RENDER_TARGET & dc.RESOURCE_STATE_COPY_SOURCE,
    );
    // COPY_SOURCE and COPY_DEST must not share bits.
    try std.testing.expectEqual(
        @as(c_int, 0),
        dc.RESOURCE_STATE_COPY_SOURCE & dc.RESOURCE_STATE_COPY_DEST,
    );
}

// ============================================================
// Runtime constants — value verification
// ============================================================

test "d3d12: MAX_UPLOAD_BYTES is 64MB" {
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), d3d12_runtime.MAX_UPLOAD_BYTES);
}

test "d3d12: MAX_KERNEL_SOURCE_BYTES is 2MB" {
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), d3d12_runtime.MAX_KERNEL_SOURCE_BYTES);
}

test "d3d12: DEFAULT_KERNEL_ROOT is bench/kernels" {
    try std.testing.expectEqualStrings("bench/kernels", d3d12_runtime.DEFAULT_KERNEL_ROOT);
}

test "d3d12: MAX_POOL_ENTRIES_PER_SIZE is 8" {
    try std.testing.expectEqual(@as(usize, 8), d3d12_runtime.MAX_POOL_ENTRIES_PER_SIZE);
}

test "d3d12: DXC_PROFILE is cs_6_0" {
    try std.testing.expectEqualStrings("cs_6_0", d3d12_runtime.DXC_PROFILE);
}

test "d3d12: DXC_ENTRYPOINT is main" {
    try std.testing.expectEqualStrings("main", d3d12_runtime.DXC_ENTRYPOINT);
}

test "d3d12: HEAP_TYPE_DEFAULT is 1" {
    try std.testing.expectEqual(@as(c_int, 1), d3d12_runtime.HEAP_TYPE_DEFAULT);
}

test "d3d12: MAX_DXC_OUTPUT_BYTES is 64KB" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), d3d12_runtime.MAX_DXC_OUTPUT_BYTES);
}

test "d3d12: GENERATED_SHADER_DIR is correct path" {
    try std.testing.expectEqualStrings(
        "bench/out/shader-artifacts/generated",
        d3d12_runtime.GENERATED_SHADER_DIR,
    );
}

// ============================================================
// DispatchMetrics — struct layout and defaults
// ============================================================

test "d3d12: DispatchMetrics default values are zero" {
    const m = d3d12_runtime.DispatchMetrics{};
    try std.testing.expectEqual(@as(u64, 0), m.encode_ns);
    try std.testing.expectEqual(@as(u64, 0), m.submit_wait_ns);
    try std.testing.expectEqual(@as(u32, 0), m.dispatch_count);
}

test "d3d12: DispatchMetrics stores explicit values" {
    const m = d3d12_runtime.DispatchMetrics{
        .encode_ns = 5000,
        .submit_wait_ns = 10000,
        .dispatch_count = 16,
    };
    try std.testing.expectEqual(@as(u64, 5000), m.encode_ns);
    try std.testing.expectEqual(@as(u64, 10000), m.submit_wait_ns);
    try std.testing.expectEqual(@as(u32, 16), m.dispatch_count);
}

// ============================================================
// NativeD3D12Runtime — default state initialization
// ============================================================

test "d3d12: NativeD3D12Runtime default state is uninitialized" {
    const rt = d3d12_runtime.NativeD3D12Runtime{
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.device);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.queue);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.fence);
    try std.testing.expectEqual(@as(u64, 0), rt.fence_value);
    try std.testing.expectEqual(@as(u64, 0), rt.completed_fence_value);
    try std.testing.expect(!rt.has_device);
    try std.testing.expect(!rt.has_deferred_submissions);
    try std.testing.expectEqual(@as(usize, 0), rt.pending_submit_batches.items.len);
}

test "d3d12: NativeD3D12Runtime default compute state is uninitialized" {
    const rt = d3d12_runtime.NativeD3D12Runtime{
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.root_signature);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.compute_pipeline);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.compute_allocator);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.compute_cmd_list);
    try std.testing.expectEqual(@as(u64, 0), rt.current_shader_hash);
    try std.testing.expect(!rt.has_root_signature);
    try std.testing.expect(!rt.has_compute_pipeline);
    try std.testing.expect(!rt.has_compute_cmd);
}

test "d3d12: NativeD3D12Runtime default kernel_root is null" {
    const rt = d3d12_runtime.NativeD3D12Runtime{
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), rt.kernel_root);
}

test "d3d12: NativeD3D12Runtime kernel_root can be set at construction" {
    const rt = d3d12_runtime.NativeD3D12Runtime{
        .allocator = std.testing.allocator,
        .kernel_root = "bench/kernels",
    };
    try std.testing.expectEqualStrings("bench/kernels", rt.kernel_root.?);
}

test "d3d12: NativeD3D12Runtime default pending_uploads is empty" {
    const rt = d3d12_runtime.NativeD3D12Runtime{
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 0), rt.pending_uploads.items.len);
}

// ============================================================
// d3d12_pool_pop — pure pool lookup logic
// ============================================================

test "d3d12: d3d12_pool_pop returns null from empty pool" {
    var pool = d3d12_upload.D3D12Pool{};
    defer pool.deinit(std.testing.allocator);
    const result = d3d12_upload.d3d12PoolPop(&pool, 1024);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "d3d12: d3d12_pool_pop returns null for missing size key" {
    var pool = d3d12_upload.D3D12Pool{};
    defer pool.deinit(std.testing.allocator);

    // Insert an entry for size 2048 but look up size 1024.
    var list = std.ArrayListUnmanaged(d3d12_upload.PoolEntry){};
    const sentinel: usize = 0xDEAD;
    try list.append(std.testing.allocator, .{ .buffer = @ptrFromInt(sentinel) });
    try pool.put(std.testing.allocator, 2048, list);

    const result = d3d12_upload.d3d12PoolPop(&pool, 1024);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);

    // Cleanup: pop the inserted entry.
    if (pool.getPtr(2048)) |l| {
        _ = l.pop();
        l.deinit(std.testing.allocator);
    }
}

test "d3d12: d3d12_pool_pop returns entry for matching size and removes it" {
    var pool = d3d12_upload.D3D12Pool{};
    defer pool.deinit(std.testing.allocator);

    const sentinel: usize = 0xBEEF;
    var list = std.ArrayListUnmanaged(d3d12_upload.PoolEntry){};
    try list.append(std.testing.allocator, .{ .buffer = @ptrFromInt(sentinel) });
    try pool.put(std.testing.allocator, 4096, list);

    const result = d3d12_upload.d3d12PoolPop(&pool, 4096);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, sentinel), @intFromPtr(result.?));

    // Pool should now be empty for that size.
    const second = d3d12_upload.d3d12PoolPop(&pool, 4096);
    try std.testing.expectEqual(@as(?*anyopaque, null), second);

    // Cleanup.
    if (pool.getPtr(4096)) |l| {
        l.deinit(std.testing.allocator);
    }
}

// ============================================================
// PoolEntry — struct layout
// ============================================================

test "d3d12: PoolEntry stores buffer pointer" {
    const sentinel: usize = 0xCAFE;
    const entry = d3d12_runtime.PoolEntry{
        .buffer = @ptrFromInt(sentinel),
    };
    try std.testing.expectEqual(@as(usize, sentinel), @intFromPtr(entry.buffer.?));
}

test "d3d12: PoolEntry can have null buffer" {
    const entry = d3d12_runtime.PoolEntry{
        .buffer = null,
    };
    try std.testing.expectEqual(@as(?*anyopaque, null), entry.buffer);
}

// ============================================================
// PendingUpload — struct layout
// ============================================================

test "d3d12: PendingUpload stores all fields" {
    const upload = d3d12_runtime.PendingUpload{
        .cmd_allocator = null,
        .cmd_list = null,
        .src_buffer = null,
        .dst_buffer = null,
        .byte_count = 8192,
    };
    try std.testing.expectEqual(@as(?*anyopaque, null), upload.cmd_allocator);
    try std.testing.expectEqual(@as(?*anyopaque, null), upload.cmd_list);
    try std.testing.expectEqual(@as(?*anyopaque, null), upload.src_buffer);
    try std.testing.expectEqual(@as(?*anyopaque, null), upload.dst_buffer);
    try std.testing.expectEqual(@as(usize, 8192), upload.byte_count);
}

// ============================================================
// Constant relationship invariants
// ============================================================

test "d3d12: HEAP_TYPE_DEFAULT differs from HEAP_TYPE_UPLOAD" {
    // Default heap (GPU-only) must be distinct from Upload heap (CPU-writable).
    try std.testing.expect(d3d12_runtime.HEAP_TYPE_DEFAULT != dc.HEAP_TYPE_UPLOAD);
}

test "d3d12: MAX_UPLOAD_BYTES is a power of two" {
    const max = d3d12_runtime.MAX_UPLOAD_BYTES;
    try std.testing.expect(max > 0);
    try std.testing.expectEqual(@as(u64, 0), max & (max - 1));
}

test "d3d12: MAX_KERNEL_SOURCE_BYTES is a power of two" {
    const max = d3d12_runtime.MAX_KERNEL_SOURCE_BYTES;
    try std.testing.expect(max > 0);
    try std.testing.expectEqual(@as(usize, 0), max & (max - 1));
}

test "d3d12: MAX_DXC_OUTPUT_BYTES is a power of two" {
    const max = d3d12_runtime.MAX_DXC_OUTPUT_BYTES;
    try std.testing.expect(max > 0);
    try std.testing.expectEqual(@as(usize, 0), max & (max - 1));
}

test "d3d12: pool capacity limit is reasonable" {
    try std.testing.expect(d3d12_runtime.MAX_POOL_ENTRIES_PER_SIZE > 0);
    try std.testing.expect(d3d12_runtime.MAX_POOL_ENTRIES_PER_SIZE <= 32);
}
