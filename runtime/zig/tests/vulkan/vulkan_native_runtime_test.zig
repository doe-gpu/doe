const std = @import("std");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const native_runtime = @import("../../src/backend/vulkan/native_runtime.zig");

test "vulkan mapped fast upload path stays bounded when shortcuts are allowed" {
    try std.testing.expect(native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024));
    try std.testing.expect(native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024 + 1));
    try std.testing.expect(!native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, .copy_dst_copy_src, 1024));
    try std.testing.expect(!native_runtime.upload_uses_fast_path(.allow_mapped_shortcuts, webgpu.UploadBufferUsageMode.copy_dst_copy_src, 1024 * 1024));
}

test "vulkan large copy-dst uploads use direct mapped path when shortcuts are allowed" {
    try std.testing.expect(native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024 + 1));
    try std.testing.expect(native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024 * 1024));
    try std.testing.expect(native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 4 * 1024 * 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst, 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(.allow_mapped_shortcuts, .copy_dst_copy_src, 4 * 1024 * 1024));
}

test "strict Vulkan upload policy allows fast_mapped for small, forces staged for large" {
    const strict_policy = backend_policy.UploadPathPolicy.staged_copy_only;
    // Small host-visible buffers use fast_mapped (direct memcpy) to match
    // Dawn's WriteBuffer behavior (CLAUDE.md rules 7/10/11).
    try std.testing.expect(native_runtime.upload_uses_fast_path(strict_policy, .copy_dst, 1024));
    // Large buffers still use staged copy under strict policy.
    try std.testing.expect(!native_runtime.upload_uses_direct_path(strict_policy, .copy_dst, 1024 * 1024 + 1));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(strict_policy, .copy_dst, 4 * 1024 * 1024 * 1024));
    try std.testing.expect(!native_runtime.upload_uses_direct_path(strict_policy, .copy_dst_copy_src, 4 * 1024 * 1024));
}
