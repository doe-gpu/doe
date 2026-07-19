// handle_safety_test.zig — Tests for Doe handle safety contracts.
//
// Documents and validates the safety properties of native.cast, native.make,
// and handle magic values. Catches alignment and initialization issues that
// caused SIGABRT crashes in earlier test rounds.
//
// Key contracts tested:
// 1. cast(T, ptr) must return null for corrupted magic — not crash
// 2. cast(T, null) must return null
// 3. make(T) returns uninitialized memory — caller must assign .* = .{}
// 4. All magic constants are unique and use D0E1 prefix
// 5. All C ABI exports accept null gracefully (no crash)
// 6. Structs with non-nullable pointer fields cannot be zeroed via std.mem.zeroes

const std = @import("std");
const native = @import("../../src/native/mod.zig");

// ============================================================
// Contract 1: cast rejects corrupted magic without crashing
// ============================================================

test "cast: null returns null for every handle type" {
    try std.testing.expect(native.cast(native.DoeInstance, null) == null);
    try std.testing.expect(native.cast(native.DoeAdapter, null) == null);
    try std.testing.expect(native.cast(native.DoeDevice, null) == null);
    try std.testing.expect(native.cast(native.DoeBuffer, null) == null);
    try std.testing.expect(native.cast(native.DoeShaderModule, null) == null);
    try std.testing.expect(native.cast(native.DoeBindGroupLayout, null) == null);
    try std.testing.expect(native.cast(native.DoePipelineLayout, null) == null);
    try std.testing.expect(native.cast(native.DoeTexture, null) == null);
    try std.testing.expect(native.cast(native.DoeSampler, null) == null);
    try std.testing.expect(native.cast(native.DoeRenderPipeline, null) == null);
}

test "cast: corrupted magic returns null for same-type pointer" {
    // This pattern is safe: same-type, same-alignment, just wrong magic.
    var inst = native.DoeInstance{};
    inst.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeInstance, @ptrCast(&inst)) == null);

    var adapter = native.DoeAdapter{};
    adapter.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeAdapter, @ptrCast(&adapter)) == null);

    var dev = native.DoeDevice{};
    dev.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeDevice, @ptrCast(&dev)) == null);

    var buf = native.DoeBuffer{};
    buf.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeBuffer, @ptrCast(&buf)) == null);

    var shader = native.DoeShaderModule{};
    shader.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeShaderModule, @ptrCast(&shader)) == null);

    var bgl = native.DoeBindGroupLayout{};
    bgl.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeBindGroupLayout, @ptrCast(&bgl)) == null);

    var pl = native.DoePipelineLayout{};
    pl.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoePipelineLayout, @ptrCast(&pl)) == null);

    var tex = native.DoeTexture{};
    tex.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeTexture, @ptrCast(&tex)) == null);

    var samp = native.DoeSampler{};
    samp.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeSampler, @ptrCast(&samp)) == null);

    var rp = native.DoeRenderPipeline{};
    rp.magic = 0xDEADBEEF;
    try std.testing.expect(native.cast(native.DoeRenderPipeline, @ptrCast(&rp)) == null);
}

test "cast: correct magic succeeds" {
    var buf = native.DoeBuffer{};
    try std.testing.expect(native.cast(native.DoeBuffer, @ptrCast(&buf)) != null);

    var inst = native.DoeInstance{};
    try std.testing.expect(native.cast(native.DoeInstance, @ptrCast(&inst)) != null);

    var adapter = native.DoeAdapter{};
    try std.testing.expect(native.cast(native.DoeAdapter, @ptrCast(&adapter)) != null);
}

// ============================================================
// Contract 2: make() returns uninitialized memory
// ============================================================

test "make: returned pointer must be explicitly initialized" {
    // make() calls alloc.create() which does NOT run default initializers.
    // Callers MUST assign .* = .{} before using the struct.
    const ptr = native.make(native.DoeBuffer);
    try std.testing.expect(ptr != null);
    const buf = ptr.?;

    // Without initialization, magic is arbitrary. Initialize explicitly:
    buf.* = .{};
    try std.testing.expectEqual((native.DoeBuffer{}).magic, buf.magic);
    try std.testing.expectEqual(@as(u64, 0), buf.size);
    try std.testing.expectEqual(@as(?*anyopaque, null), buf.mtl);

    native.alloc.destroy(buf);
}

// ============================================================
// Contract 3: toOpaque round-trip preserves identity
// ============================================================

test "toOpaque: round-trip preserves pointer identity" {
    var buf = native.DoeBuffer{};
    const raw = native.toOpaque(&buf);
    try std.testing.expect(raw != null);
    const recovered = native.cast(native.DoeBuffer, raw);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqual(&buf, recovered.?);
}

// ============================================================
// Contract 4: magic constants are unique with D0E1 prefix
// ============================================================

test "magic constants: all handle types have unique D0E1-prefixed magic" {
    // Types with non-nullable pointer fields and private TYPE_MAGIC are excluded.
    // They are tested via native_shader_render_test which accesses them through
    // public API exports. The types included here cover all default-constructible handles.
    const magics = [_]u32{
        (native.DoeInstance{}).magic,
        (native.DoeAdapter{}).magic,
        (native.DoeDevice{}).magic,
        native.DoeQueue.TYPE_MAGIC,
        native.DoeBuffer.TYPE_MAGIC,
        (native.DoeShaderModule{}).magic,
        native.DoeComputePipeline.TYPE_MAGIC,
        (native.DoeBindGroupLayout{}).magic,
        (native.DoePipelineLayout{}).magic,
        native.DoeBindGroup.TYPE_MAGIC,
        (native.DoeTexture{}).magic,
        (native.DoeSampler{}).magic,
        (native.DoeRenderPipeline{}).magic,
    };

    // All unique
    for (magics, 0..) |a, i| {
        for (magics[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }

    // All have D0E1 prefix
    for (magics) |m| {
        try std.testing.expectEqual(@as(u32, 0xD0E1), m >> 16);
    }
}

// ============================================================
// Contract 5: structs with non-nullable pointers cannot use zeroes
// ============================================================

test "handle type alignment: all types can be stack-allocated safely" {
    // Verify every handle type can be default-initialized on the stack.
    // Types with non-nullable pointer fields use default values (not zeroes).
    _ = native.DoeInstance{};
    _ = native.DoeAdapter{};
    _ = native.DoeDevice{};
    _ = native.DoeBuffer{};
    _ = native.DoeShaderModule{};
    _ = native.DoeBindGroupLayout{};
    _ = native.DoePipelineLayout{};
    _ = native.DoeTexture{};
    _ = native.DoeSampler{};
    _ = native.DoeRenderPipeline{};
    // DoeQueue, DoeComputePass, DoeCommandBuffer, DoeTextureView, DoeRenderPass
    // have required non-nullable pointer fields — they CANNOT be default-initialized
    // without a valid parent. This is by design.
}

// ============================================================
// Contract 6: C ABI exports handle null gracefully
// ============================================================

test "C ABI null safety: buffer lifecycle" {
    try std.testing.expect(native.doeNativeDeviceCreateBuffer(null, null) == null);
    native.doeNativeBufferRelease(null);
    native.doeNativeBufferUnmap(null);
    try std.testing.expect(native.doeNativeBufferGetConstMappedRange(null, 0, 0) == null);
    try std.testing.expect(native.doeNativeBufferGetMappedRange(null, 0, 0) == null);
}

test "C ABI null safety: encoder lifecycle" {
    try std.testing.expect(native.doeNativeDeviceCreateCommandEncoder(null, null) == null);
    native.doeNativeCommandEncoderRelease(null);
    try std.testing.expect(native.doeNativeCommandEncoderFinish(null, null) == null);
}

test "C ABI null safety: queue operations" {
    var empty = [_]?*anyopaque{};
    native.doeNativeQueueSubmit(null, 0, &empty);
    var dummy_data = [_]u8{};
    native.doeNativeQueueWriteBuffer(null, null, 0, &dummy_data, 0);
}

test "C ABI null safety: render lifecycle" {
    const render = @import("../../src/native/render/doe_render_native.zig");
    try std.testing.expect(render.doeNativeDeviceCreateTexture(null, null) == null);
    render.doeNativeTextureRelease(null);
    try std.testing.expect(render.doeNativeTextureCreateView(null, null) == null);
    render.doeNativeTextureViewRelease(null);
    try std.testing.expect(render.doeNativeDeviceCreateSampler(null, null) == null);
    render.doeNativeSamplerRelease(null);
    try std.testing.expect(render.doeNativeDeviceCreateRenderPipeline(null, null) == null);
    render.doeNativeRenderPipelineRelease(null);
    try std.testing.expect(render.doeNativeCommandEncoderBeginRenderPass(null, null) == null);
    render.doeNativeRenderPassEnd(null);
    render.doeNativeRenderPassRelease(null);
    render.doeNativeRenderPassSetPipeline(null, null);
    render.doeNativeRenderPassDraw(null, 0, 0, 0, 0);
    render.doeNativeRenderPassSetBindGroup(null, 0, null, 0, null);
    render.doeNativeRenderPassDrawIndexed(null, 0, 0, 0, 0, 0);
    render.doeNativeRenderPassSetVertexBuffer(null, 0, null, 0, 0);
    render.doeNativeRenderPassSetIndexBuffer(null, null, 0, 0, 0);
}

test "C ABI null safety: shader lifecycle" {
    const shader = @import("../../src/native/shader/doe_shader_native.zig");
    try std.testing.expect(shader.doeNativeDeviceCreateShaderModule(null, null) == null);
    shader.doeNativeShaderModuleRelease(null);
    try std.testing.expect(shader.doeNativeDeviceCreateComputePipeline(null, null) == null);
    shader.doeNativeComputePipelineRelease(null);
}

test "C ABI null safety: query lifecycle" {
    const query = @import("../../src/native/resource/doe_query_native.zig");
    try std.testing.expect(query.doeNativeDeviceCreateQuerySet(null, 0, 0) == null);
    query.doeNativeQuerySetDestroy(null);
    query.doeNativeCommandEncoderWriteTimestamp(null, null, 0);
    query.doeNativeCommandEncoderResolveQuerySet(null, null, 0, 2, null, 0);
}

test "C ABI null safety: instance lifecycle" {
    const inst_dev = @import("../../src/native/lifecycle/doe_instance_device_native.zig");
    inst_dev.doeNativeInstanceRelease(null);
    inst_dev.doeNativeAdapterRelease(null);
    inst_dev.doeNativeDeviceRelease(null);
    try std.testing.expect(inst_dev.doeNativeDeviceGetQueue(null) == null);
}

test "C ABI null safety: bind group lifecycle" {
    const bg = @import("../../src/native/resource/doe_bind_group_native.zig");
    native.doeNativeBindGroupRelease(null);
    native.doeNativeBindGroupLayoutRelease(null);
    native.doeNativePipelineLayoutRelease(null);
    try std.testing.expect(bg.doeNativeDeviceCreateBindGroup(null, null) == null);
    try std.testing.expect(bg.doeNativeDeviceCreateBindGroupLayout(null, null) == null);
}
