// native_api_core_test.zig — Unit tests for Doe native C ABI modules.
// Verifies export existence, null-safety, constants, helper functions,
// and parameter validation without requiring Metal hardware.

const std = @import("std");
const builtin = @import("builtin");

const native = @import("../../src/native/mod.zig");
const caps = @import("../../src/native/support/doe_device_caps.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");
const buffer_ops = @import("../../src/native/resource/doe_buffer_ops_native.zig");
const texture_sampler = @import("../../src/native/resource/doe_texture_sampler_native.zig");
const abi_core = @import("../../src/core/abi/wgpu_core_base_types.zig");
const abi_pipeline = @import("../../src/core/abi/wgpu_pipeline_descriptor_types.zig");
const abi_texture = @import("../../src/core/abi/wgpu_texture_base_types.zig");

// ============================================================
// 1. doe_wgpu_native.zig — Export existence via comptime @hasDecl
// ============================================================

test "doe_wgpu_native: all re-exported C ABI symbols exist" {
    // Buffer lifecycle
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateBuffer"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateBufferFlat"));
    try std.testing.expect(@hasDecl(native, "doeNativeBufferRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeBufferUnmap"));
    try std.testing.expect(@hasDecl(native, "doeNativeBufferMapAsync"));
    try std.testing.expect(@hasDecl(native, "doeNativeBufferGetConstMappedRange"));
    try std.testing.expect(@hasDecl(native, "doeNativeBufferGetMappedRange"));

    // Instance / adapter / device lifecycle (re-exported from doe_instance_device_native)
    try std.testing.expect(@hasDecl(native, "doeNativeCreateInstance"));
    try std.testing.expect(@hasDecl(native, "doeNativeInstanceRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeInstanceWaitAny"));
    try std.testing.expect(@hasDecl(native, "doeNativeRequestAdapterFlat"));
    try std.testing.expect(@hasDecl(native, "doeNativeInstanceRequestAdapter"));
    try std.testing.expect(@hasDecl(native, "doeNativeAdapterRequestDevice"));
    try std.testing.expect(@hasDecl(native, "doeNativeAdapterRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeRequestDeviceFlat"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceGetQueue"));

    // Shader module and compute pipeline (re-exported from doe_shader_native)
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateShaderModule"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateShaderModuleWgsl"));
    try std.testing.expect(@hasDecl(native, "doeNativeShaderModuleRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateComputePipeline"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateComputePipelineMain"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePipelineRelease"));

    // Bind group, bind group layout, pipeline layout (re-exported from doe_bind_group_native)
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateBindGroupLayout"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateBufferBindGroupLayoutFlat4"));
    try std.testing.expect(@hasDecl(native, "doeNativeBindGroupLayoutRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateBindGroup"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateBufferBindGroupFlat4"));
    try std.testing.expect(@hasDecl(native, "doeNativeBindGroupRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreatePipelineLayout"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreatePipelineLayoutOne"));
    try std.testing.expect(@hasDecl(native, "doeNativePipelineLayoutRelease"));

    // Command encoder and command buffer (re-exported from doe_encoder_native)
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateCommandEncoder"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderBeginComputePass"));
    try std.testing.expect(@hasDecl(native, "doeNativeCopyBufferToBuffer"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderCopyBufferToTexture"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderCopyTextureToBuffer"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderFinish"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandBufferRelease"));

    // Queue (re-exported from doe_queue_submit_native)
    try std.testing.expect(@hasDecl(native, "doeNativeQueueSubmit"));
    try std.testing.expect(@hasDecl(native, "doeNativeQueueFlush"));
    try std.testing.expect(@hasDecl(native, "doeNativeQueueWriteBuffer"));
    try std.testing.expect(@hasDecl(native, "doeNativeQueueWriteBufferBatch"));
    try std.testing.expect(@hasDecl(native, "doeNativeQueueWriteBufferBatchDataPtrs"));
    try std.testing.expect(@hasDecl(native, "doeNativeQueueRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeQueueOnSubmittedWorkDone"));

    // Compute pass (re-exported from doe_compute_ext_native)
    try std.testing.expect(@hasDecl(native, "doeNativeComputePassSetPipeline"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePassSetBindGroup"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePassDispatch"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePassEnd"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePassRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePipelineGetBindGroupLayout"));
    try std.testing.expect(@hasDecl(native, "doeNativeComputePassDispatchIndirect"));

    // Device caps (re-exported from doe_device_caps)
    try std.testing.expect(@hasDecl(native, "doeNativeAdapterHasFeature"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceHasFeature"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceGetLimits"));
    try std.testing.expect(@hasDecl(native, "doeNativeAdapterGetLimits"));

    // Render (re-exported from doe_render_native)
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateTexture"));
    try std.testing.expect(@hasDecl(native, "doeNativeTextureCreateView"));
    try std.testing.expect(@hasDecl(native, "doeNativeTextureRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeTextureViewRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateSampler"));
    try std.testing.expect(@hasDecl(native, "doeNativeSamplerRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateRenderPipeline"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPipelineRelease"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderBeginRenderPass"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassSetPipeline"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassSetBindGroup"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassSetVertexBuffer"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassSetIndexBuffer"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassDraw"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassDrawIndexed"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassEnd"));
    try std.testing.expect(@hasDecl(native, "doeNativeRenderPassRelease"));

    // Query set (re-exported from doe_query_native)
    try std.testing.expect(@hasDecl(native, "doeNativeDeviceCreateQuerySet"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderWriteTimestamp"));
    try std.testing.expect(@hasDecl(native, "doeNativeCommandEncoderResolveQuerySet"));
    try std.testing.expect(@hasDecl(native, "doeNativeQuerySetDestroy"));

    // Instance process events
    try std.testing.expect(@hasDecl(native, "doeNativeInstanceProcessEvents"));

    // Fast compute path
    try std.testing.expect(@hasDecl(native, "flush_pending_work"));
    try std.testing.expect(@hasDecl(native, "try_schedule_deferred_copy"));
}

// ============================================================
// 2. doe_wgpu_native.zig — Constants and handle magic values
// ============================================================

test "doe_wgpu_native: bind slot constants are correct" {
    try std.testing.expectEqual(@as(usize, 16), native.MAX_BIND);
    try std.testing.expectEqual(@as(usize, 4), native.MAX_RENDER_BIND_GROUPS);
    try std.testing.expectEqual(@as(usize, 4), native.MAX_COMPUTE_BIND_GROUPS);
    try std.testing.expectEqual(@as(usize, 64), native.MAX_FLAT_BIND);
    try std.testing.expectEqual(@as(usize, 8), native.MAX_VERTEX_BUFFERS);
    try std.testing.expectEqual(@as(u32, 8), native.VERTEX_BUFFER_SLOT_BASE);
    try std.testing.expectEqual(@as(usize, 512), native.ERR_CAP);
}

test "doe_wgpu_native: MAX_FLAT_BIND equals MAX_BIND * MAX_COMPUTE_BIND_GROUPS" {
    try std.testing.expectEqual(native.MAX_BIND * native.MAX_COMPUTE_BIND_GROUPS, native.MAX_FLAT_BIND);
}

test "doe_wgpu_native: handle type magic values are distinct" {
    // Each handle type has a unique magic. Verify by constructing default instances
    // and checking their magic fields do not collide with each other.
    const instance_magic = (native.DoeInstance{}).magic;
    const adapter_magic = (native.DoeAdapter{}).magic;
    const buffer_magic = (native.DoeBuffer{}).magic;
    const queue_magic = native.DoeQueue.TYPE_MAGIC;
    const bind_group_magic = native.DoeBindGroup.TYPE_MAGIC;
    const compute_pipe_magic = native.DoeComputePipeline.TYPE_MAGIC;

    // Verify they are all different
    const magics = [_]u32{ instance_magic, adapter_magic, buffer_magic, queue_magic, bind_group_magic, compute_pipe_magic };
    for (magics, 0..) |a, i| {
        for (magics[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }
}

test "doe_wgpu_native: handle magic values follow 0xD0E1 prefix convention" {
    // All magics share the 0xD0E1_xxxx prefix
    const instance_magic = (native.DoeInstance{}).magic;
    try std.testing.expectEqual(@as(u32, 0xD0E1_0000), instance_magic & 0xFFFF_0000);

    const buffer_magic = (native.DoeBuffer{}).magic;
    try std.testing.expectEqual(@as(u32, 0xD0E1_0000), buffer_magic & 0xFFFF_0000);

    const queue_magic = native.DoeQueue.TYPE_MAGIC;
    try std.testing.expectEqual(@as(u32, 0xD0E1_0000), queue_magic & 0xFFFF_0000);
}

fn testBufferDescriptor(usage: types.WGPUBufferUsage, mapped_at_creation: types.WGPUBool) types.WGPUBufferDescriptor {
    return .{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .usage = usage,
        .size = 256,
        .mappedAtCreation = mapped_at_creation,
    };
}

test "Metal buffer storage: GPU-only buffers prefer private storage" {
    var storage = testBufferDescriptor(types.WGPUBufferUsage_Storage | types.WGPUBufferUsage_CopyDst, types.WGPU_FALSE);
    try std.testing.expect(buffer_ops.metalBufferUsageEligibleForPrivateStorage(&storage));

    var uniform = testBufferDescriptor(types.WGPUBufferUsage_Uniform | types.WGPUBufferUsage_CopyDst, types.WGPU_FALSE);
    try std.testing.expect(buffer_ops.metalBufferUsageEligibleForPrivateStorage(&uniform));
}

test "Metal buffer storage: host-visible and query-resolve buffers stay shared" {
    var readback = testBufferDescriptor(types.WGPUBufferUsage_MapRead | types.WGPUBufferUsage_CopyDst, types.WGPU_FALSE);
    try std.testing.expect(!buffer_ops.metalBufferUsageEligibleForPrivateStorage(&readback));

    var mapped = testBufferDescriptor(types.WGPUBufferUsage_Storage | types.WGPUBufferUsage_CopyDst, types.WGPU_TRUE);
    try std.testing.expect(!buffer_ops.metalBufferUsageEligibleForPrivateStorage(&mapped));

    var query_resolve = testBufferDescriptor(types.WGPUBufferUsage_QueryResolve | types.WGPUBufferUsage_CopySrc, types.WGPU_FALSE);
    try std.testing.expect(!buffer_ops.metalBufferUsageEligibleForPrivateStorage(&query_resolve));

    var transfer_only = testBufferDescriptor(types.WGPUBufferUsage_CopySrc | types.WGPUBufferUsage_CopyDst, types.WGPU_FALSE);
    try std.testing.expect(!buffer_ops.metalBufferUsageEligibleForPrivateStorage(&transfer_only));
}

test "Metal buffer storage: private storage is opt-in while upload path remains benchmarked" {
    var storage = testBufferDescriptor(types.WGPUBufferUsage_Storage | types.WGPUBufferUsage_CopyDst, types.WGPU_FALSE);
    try std.testing.expect(!buffer_ops.metalBufferShouldUsePrivateStorage(&storage));
}

// ============================================================
// 3. doe_wgpu_native.zig — cast() null-safety and type validation
// ============================================================

test "doe_wgpu_native: cast returns null for null input" {
    try std.testing.expectEqual(@as(?*native.DoeBuffer, null), native.cast(native.DoeBuffer, null));
    try std.testing.expectEqual(@as(?*native.DoeInstance, null), native.cast(native.DoeInstance, null));
    try std.testing.expectEqual(@as(?*native.DoeAdapter, null), native.cast(native.DoeAdapter, null));
    try std.testing.expectEqual(@as(?*native.DoeDevice, null), native.cast(native.DoeDevice, null));
}

test "doe_wgpu_native: cast rejects wrong magic" {
    // Create a DoeBuffer with corrupted magic — should fail the magic check.
    var buf = native.DoeBuffer{};
    buf.magic = 0xDEADBEEF;
    const result = native.cast(native.DoeBuffer, @ptrCast(&buf));
    try std.testing.expectEqual(@as(?*native.DoeBuffer, null), result);
}

test "doe_wgpu_native: cast succeeds with correct magic" {
    var buf = native.DoeBuffer{};
    const result = native.cast(native.DoeBuffer, @ptrCast(&buf));
    try std.testing.expect(result != null);
    try std.testing.expectEqual(native.DoeBuffer.TYPE_MAGIC, result.?.magic);
}

test "DoeBuffer records its owning device for Metal map completion" {
    var dev = native.DoeDevice{};
    const buf = native.DoeBuffer{ .dev = &dev };
    try std.testing.expectEqual(&dev, buf.dev.?);
}

test "doe_wgpu_native: cast cross-type rejection is comprehensive" {
    // Verify that corrupted magic prevents cast for each handle type.
    // Note: cross-type @ptrCast between differently-sized structs can cause
    // @alignCast panics, so we test same-type with wrong magic instead.
    var inst = native.DoeInstance{};
    inst.magic = 0xBAD00001;
    try std.testing.expectEqual(@as(?*native.DoeInstance, null), native.cast(native.DoeInstance, @ptrCast(&inst)));

    var adapter = native.DoeAdapter{};
    adapter.magic = 0xBAD00002;
    try std.testing.expectEqual(@as(?*native.DoeAdapter, null), native.cast(native.DoeAdapter, @ptrCast(&adapter)));

    var buf = native.DoeBuffer{};
    buf.magic = 0xBAD00003;
    try std.testing.expectEqual(@as(?*native.DoeBuffer, null), native.cast(native.DoeBuffer, @ptrCast(&buf)));
}

// ============================================================
// 4. doe_wgpu_native.zig — extractWorkgroupSize helper
// ============================================================

test "extractWorkgroupSize: basic 3-component" {
    const result = native.extractWorkgroupSize("@workgroup_size(8,4,2)");
    try std.testing.expectEqual(@as(u32, 8), result.x);
    try std.testing.expectEqual(@as(u32, 4), result.y);
    try std.testing.expectEqual(@as(u32, 2), result.z);
}

test "extractWorkgroupSize: single component defaults y,z to 1" {
    const result = native.extractWorkgroupSize("@workgroup_size(64)");
    try std.testing.expectEqual(@as(u32, 64), result.x);
    try std.testing.expectEqual(@as(u32, 1), result.y);
    try std.testing.expectEqual(@as(u32, 1), result.z);
}

test "extractWorkgroupSize: two components default z to 1" {
    const result = native.extractWorkgroupSize("@workgroup_size(16,8)");
    try std.testing.expectEqual(@as(u32, 16), result.x);
    try std.testing.expectEqual(@as(u32, 8), result.y);
    try std.testing.expectEqual(@as(u32, 1), result.z);
}

test "extractWorkgroupSize: missing annotation returns zero triple" {
    const result = native.extractWorkgroupSize("fn main() {}");
    try std.testing.expectEqual(@as(u32, 0), result.x);
    try std.testing.expectEqual(@as(u32, 0), result.y);
    try std.testing.expectEqual(@as(u32, 0), result.z);
}

test "extractWorkgroupSize: embedded in larger WGSL source" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\@compute @workgroup_size(256,1,1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\  data[gid.x] = 0.0;
        \\}
    ;
    const result = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 256), result.x);
    try std.testing.expectEqual(@as(u32, 1), result.y);
    try std.testing.expectEqual(@as(u32, 1), result.z);
}

test "extractWorkgroupSize: spaces around values" {
    const result = native.extractWorkgroupSize("@workgroup_size( 32 , 16 , 8 )");
    try std.testing.expectEqual(@as(u32, 32), result.x);
    try std.testing.expectEqual(@as(u32, 16), result.y);
    try std.testing.expectEqual(@as(u32, 8), result.z);
}

test "extractWorkgroupSize: no closing paren returns zero" {
    const result = native.extractWorkgroupSize("@workgroup_size(64");
    try std.testing.expectEqual(@as(u32, 0), result.x);
    try std.testing.expectEqual(@as(u32, 0), result.y);
    try std.testing.expectEqual(@as(u32, 0), result.z);
}

test "extractWorkgroupSize: empty string returns zero" {
    const result = native.extractWorkgroupSize("");
    try std.testing.expectEqual(@as(u32, 0), result.x);
    try std.testing.expectEqual(@as(u32, 0), result.y);
    try std.testing.expectEqual(@as(u32, 0), result.z);
}

test "extractWorkgroupSize: large workgroup size 1024" {
    const result = native.extractWorkgroupSize("@workgroup_size(1024)");
    try std.testing.expectEqual(@as(u32, 1024), result.x);
    try std.testing.expectEqual(@as(u32, 1), result.y);
    try std.testing.expectEqual(@as(u32, 1), result.z);
}

// ============================================================
// 5. doe_wgpu_native.zig — DoeBuffer default fields
// ============================================================

test "DoeBuffer: default fields are correct" {
    const buf = native.DoeBuffer{};
    try std.testing.expectEqual(native.DoeBuffer.TYPE_MAGIC, buf.magic);
    try std.testing.expectEqual(@as(?*anyopaque, null), buf.mtl);
    try std.testing.expectEqual(@as(u64, 0), buf.size);
    try std.testing.expectEqual(@as(u64, 0), buf.usage);
    try std.testing.expectEqual(false, buf.mapped);
}

// ============================================================
// 6. doe_wgpu_native.zig — DoeBindGroup default fields
// ============================================================

test "DoeBindGroup: default fields are initialized" {
    const bg = native.DoeBindGroup{};
    try std.testing.expectEqual(native.DoeBindGroup.TYPE_MAGIC, bg.magic);
    try std.testing.expectEqual(@as(u32, 0), bg.count);
    // All buffer slots should be null
    for (bg.buffers) |b| {
        try std.testing.expectEqual(@as(?*anyopaque, null), b);
    }
    // All offsets should be zero
    for (bg.offsets) |o| {
        try std.testing.expectEqual(@as(u64, 0), o);
    }
    try std.testing.expectEqual(@as(u64, 0), bg.vk_buffer_binding_mask);
    try std.testing.expectEqual(false, bg.vk_buffer_binding_cache_complete);
    for (bg.vk_buffer_handles) |handle| {
        try std.testing.expectEqual(@as(u64, 0), handle);
    }
}

// ============================================================
// 7. doe_wgpu_native.zig — DoeShaderModule default fields
// ============================================================

test "DoeShaderModule: workgroup size defaults to zero" {
    const sm = native.DoeShaderModule{};
    try std.testing.expectEqual(@as(u32, 0), sm.wg_x);
    try std.testing.expectEqual(@as(u32, 0), sm.wg_y);
    try std.testing.expectEqual(@as(u32, 0), sm.wg_z);
    try std.testing.expectEqual(@as(u32, 0), sm.binding_count);
    try std.testing.expectEqual(@as(?*anyopaque, null), sm.mtl_library);
    try std.testing.expect(!sm.mtl_library_borrowed);
}

test "DoeBindGroupLayout: inline entries are disabled by default" {
    const layout = native.DoeBindGroupLayout{};
    try std.testing.expectEqual(@as(u32, 0), layout.entry_count);
    try std.testing.expect(layout.entries == null);
    try std.testing.expect(!layout.entries_inline);
}

// ============================================================
// 8. doe_wgpu_native.zig — DoeComputePipeline default fields
// ============================================================

test "DoeComputePipeline: default fields" {
    const cp = native.DoeComputePipeline{};
    try std.testing.expectEqual(native.DoeComputePipeline.TYPE_MAGIC, cp.magic);
    try std.testing.expectEqual(@as(?*anyopaque, null), cp.mtl_pso);
    try std.testing.expectEqual(@as(u32, 0), cp.binding_count);
    try std.testing.expectEqual(@as(u32, 0), cp.wg_x);
    try std.testing.expectEqual(@as(u32, 0), cp.wg_y);
    try std.testing.expectEqual(@as(u32, 0), cp.wg_z);
}

// ============================================================
// 9. doe_wgpu_native.zig — DoeRenderPipeline topology defaults
// ============================================================

test "DoeRenderPipeline: default topology is triangle-list (0x04)" {
    const rp = native.DoeRenderPipeline{};
    try std.testing.expectEqual(@as(u32, 0x00000004), rp.topology);
    try std.testing.expectEqual(@as(u32, 0x00000001), rp.front_face);
    try std.testing.expectEqual(@as(u32, 0x00000001), rp.cull_mode);
    try std.testing.expectEqual(false, rp.depth_write_enabled);
    try std.testing.expectEqual(false, rp.unclipped_depth);
}

// ============================================================
// 10. doe_wgpu_native.zig — Null-safety of buffer exports
// ============================================================

test "doeNativeDeviceCreateBuffer: null device returns null" {
    const result = native.doeNativeDeviceCreateBuffer(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeDeviceCreateBuffer: null descriptor returns null" {
    // Even with a non-null pointer that has wrong magic, should return null.
    var fake = native.DoeDevice{};
    fake.magic = 0xDEADBEEF;
    const result = native.doeNativeDeviceCreateBuffer(@ptrCast(&fake), null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeBufferRelease: null input is safe" {
    // Must not crash.
    native.doeNativeBufferRelease(null);
}

test "doeNativeBufferRelease: wrong magic input is safe" {
    var fake = native.DoeBuffer{};
    fake.magic = 0xDEADBEEF;
    native.doeNativeBufferRelease(@ptrCast(&fake));
}

test "doeNativeBufferUnmap: null input is safe" {
    native.doeNativeBufferUnmap(null);
}

test "doeNativeBufferGetConstMappedRange: null input returns null" {
    const result = native.doeNativeBufferGetConstMappedRange(null, 0, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeBufferGetMappedRange: null input returns null" {
    const result = native.doeNativeBufferGetMappedRange(null, 0, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

// ============================================================
// 11. doe_wgpu_native.zig — Null-safety of instance/process events exports
// ============================================================

test "doeNativeInstanceProcessEvents: null input is safe" {
    native.doeNativeInstanceProcessEvents(null);
}

test "doeNativeInstanceRelease: null input is safe" {
    native.doeNativeInstanceRelease(null);
}

test "doeNativeAdapterRelease: null input is safe" {
    native.doeNativeAdapterRelease(null);
}

test "doeNativeDeviceRelease: null input is safe" {
    native.doeNativeDeviceRelease(null);
}

test "doeNativeDeviceGetQueue: null input returns null" {
    const result = native.doeNativeDeviceGetQueue(null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

// ============================================================
// 12. doe_encoder_native.zig — Export existence
// ============================================================

test "doe_encoder_native: exports exist via doe_wgpu_native re-export" {
    // Verify that the encoder symbols are callable function pointers.
    comptime {
        _ = @TypeOf(native.doeNativeDeviceCreateCommandEncoder);
        _ = @TypeOf(native.doeNativeCommandEncoderRelease);
        _ = @TypeOf(native.doeNativeCommandEncoderBeginComputePass);
        _ = @TypeOf(native.doeNativeCopyBufferToBuffer);
        _ = @TypeOf(native.doeNativeCommandEncoderCopyBufferToTexture);
        _ = @TypeOf(native.doeNativeCommandEncoderCopyTextureToBuffer);
        _ = @TypeOf(native.doeNativeCommandEncoderFinish);
        _ = @TypeOf(native.doeNativeCommandBufferRelease);
    }
}

// ============================================================
// 13. doe_encoder_native.zig — Null-safety
// ============================================================

test "doeNativeDeviceCreateCommandEncoder: null device returns null" {
    const result = native.doeNativeDeviceCreateCommandEncoder(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeCommandEncoderRelease: null input is safe" {
    native.doeNativeCommandEncoderRelease(null);
}

test "doeNativeCommandEncoderBeginComputePass: null input returns null" {
    const result = native.doeNativeCommandEncoderBeginComputePass(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeCopyBufferToBuffer: all null inputs are safe" {
    // Should silently return without crashing.
    native.doeNativeCopyBufferToBuffer(null, null, 0, null, 0, 0);
}

test "doeNativeCommandEncoderFinish: null input returns null" {
    const result = native.doeNativeCommandEncoderFinish(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeCommandBufferRelease: null input is safe" {
    native.doeNativeCommandBufferRelease(null);
}

test "doeNativeCommandEncoderCopyBufferToTexture: null inputs are safe" {
    native.doeNativeCommandEncoderCopyBufferToTexture(null, null, 0, 0, 0, null, 0, 0, 0, 0);
}

test "doeNativeCommandEncoderCopyTextureToBuffer: null inputs are safe" {
    native.doeNativeCommandEncoderCopyTextureToBuffer(null, null, 0, null, 0, 0, 0, 0, 0, 0);
}

// ============================================================
// 14. doe_device_caps.zig — Export existence
// ============================================================

test "doe_device_caps: all C ABI symbols exist" {
    try std.testing.expect(@hasDecl(caps, "doeNativeAdapterHasFeature"));
    try std.testing.expect(@hasDecl(caps, "doeNativeDeviceHasFeature"));
    try std.testing.expect(@hasDecl(caps, "doeNativeDeviceGetLimits"));
    try std.testing.expect(@hasDecl(caps, "doeNativeAdapterGetLimits"));
    try std.testing.expect(@hasDecl(caps, "doeNativeDeviceGetLimitsFromMtl"));
    try std.testing.expect(@hasDecl(caps, "doeNativeDeviceSubgroupSize"));
}

// ============================================================
// 15. doe_device_caps.zig — Feature query constants
// ============================================================

test "doe_device_caps: feature constants match WebGPU spec values" {
    try std.testing.expectEqual(@as(u32, 0x00000001), types.WGPUFeatureName_CoreFeaturesAndLimits);
    try std.testing.expectEqual(@as(u32, 0x00000002), types.WGPUFeatureName_DepthClipControl);
    try std.testing.expectEqual(@as(u32, 0x00000012), caps.FEATURE_SUBGROUPS);
    try std.testing.expectEqual(@as(u32, 0x00000016), types.WGPUFeatureName_TextureComponentSwizzle);
}

test "doe_device_caps: METAL_SIMD_GROUP_SIZE is 32" {
    try std.testing.expectEqual(@as(u32, 32), caps.METAL_SIMD_GROUP_SIZE);
}

// ============================================================
// 16. doe_device_caps.zig — Feature support queries
// ============================================================

test "doeNativeAdapterHasFeature: shader-f16 is supported" {
    const result = caps.doeNativeAdapterHasFeature(null, types.WGPUFeatureName_ShaderF16);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "doeNativeDeviceHasFeature: shader-f16 is supported" {
    const result = caps.doeNativeDeviceHasFeature(null, types.WGPUFeatureName_ShaderF16);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "doeNativeAdapterHasFeature: unknown feature returns 0" {
    const result = caps.doeNativeAdapterHasFeature(null, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "doeNativeDeviceHasFeature: unknown feature returns 0" {
    const result = caps.doeNativeDeviceHasFeature(null, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "doeNativeAdapterHasFeature: null device handle is safe" {
    // Null queries retain the platform-capability fallback used by diagnostics.
    _ = caps.doeNativeAdapterHasFeature(null, types.WGPUFeatureName_ShaderF16);
    _ = caps.doeNativeAdapterHasFeature(null, 0);
}

test "doeNativeDeviceHasFeature: null device handle is safe" {
    _ = caps.doeNativeDeviceHasFeature(null, types.WGPUFeatureName_ShaderF16);
    _ = caps.doeNativeDeviceHasFeature(null, 0);
}

test "doeNativeDeviceHasFeature reports only enabled features for a live device" {
    var enabled_features = [_]types.WGPUFeatureName{
        types.WGPUFeatureName_DawnInternalUsages,
        types.WGPUFeatureName_ShaderF16,
    };
    var device = native.DoeDevice{
        .enabled_features = enabled_features[0..],
    };
    const raw: ?*anyopaque = @ptrCast(&device);

    try std.testing.expectEqual(@as(u32, 1), caps.doeNativeDeviceHasFeature(raw, types.WGPUFeatureName_DawnInternalUsages));
    try std.testing.expectEqual(@as(u32, 1), caps.doeNativeDeviceHasFeature(raw, types.WGPUFeatureName_ShaderF16));
    try std.testing.expectEqual(@as(u32, 0), caps.doeNativeDeviceHasFeature(raw, types.WGPUFeatureName_Subgroups));
}

test "doeNativeAdapterHasFeature: subgroups is platform-dependent" {
    const result = caps.doeNativeAdapterHasFeature(null, caps.FEATURE_SUBGROUPS);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(@as(u32, 1), result);
    } else {
        try std.testing.expectEqual(@as(u32, 0), result);
    }
}

test "doeNativeAdapterHasFeature: adapter and device agree on all features" {
    const features = [_]u32{
        types.WGPUFeatureName_ShaderF16,
        caps.FEATURE_SUBGROUPS,
        0,
        0xFFFFFFFF,
    };
    for (features) |f| {
        const adapter_result = caps.doeNativeAdapterHasFeature(null, f);
        const device_result = caps.doeNativeDeviceHasFeature(null, f);
        try std.testing.expectEqual(adapter_result, device_result);
    }
}

// ============================================================
// 17. doe_device_caps.zig — Limits queries
// ============================================================

test "doeNativeDeviceGetLimits: returns success and populates limits" {
    var limits = std.mem.zeroes(types.WGPULimits);
    const status = caps.doeNativeDeviceGetLimits(null, &limits);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);

    // Verify non-zero / reasonable values.
    try std.testing.expect(limits.maxTextureDimension1D >= 8192);
    try std.testing.expect(limits.maxTextureDimension2D >= 8192);
    try std.testing.expect(limits.maxTextureDimension3D >= 256);
    try std.testing.expect(limits.maxTextureArrayLayers >= 256);
    try std.testing.expect(limits.maxBindGroups >= 4);
    try std.testing.expect(limits.maxComputeWorkgroupSizeX >= 256);
    try std.testing.expect(limits.maxComputeWorkgroupSizeY >= 256);
    try std.testing.expect(limits.maxComputeWorkgroupSizeZ >= 64);
    try std.testing.expect(limits.maxComputeInvocationsPerWorkgroup >= 256);
    try std.testing.expect(limits.maxComputeWorkgroupsPerDimension >= 65535);
}

test "doeNativeAdapterGetLimits: returns success and populates limits" {
    var limits = std.mem.zeroes(types.WGPULimits);
    const status = caps.doeNativeAdapterGetLimits(null, &limits);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);
    try std.testing.expect(limits.maxTextureDimension1D > 0);
}

test "doeNativeDeviceGetLimits: null limits pointer returns success without crash" {
    const status = caps.doeNativeDeviceGetLimits(null, null);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);
}

test "doeNativeAdapterGetLimits: null limits pointer returns success without crash" {
    const status = caps.doeNativeAdapterGetLimits(null, null);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);
}

test "doeNativeDeviceGetLimits: specific Metal limit values" {
    var limits = std.mem.zeroes(types.WGPULimits);
    _ = caps.doeNativeDeviceGetLimits(null, &limits);

    // Metal-specific: maxTextureDimension1D/2D = 16384
    try std.testing.expectEqual(@as(u32, 16384), limits.maxTextureDimension1D);
    try std.testing.expectEqual(@as(u32, 16384), limits.maxTextureDimension2D);
    try std.testing.expectEqual(@as(u32, 2048), limits.maxTextureDimension3D);
    try std.testing.expectEqual(@as(u32, 2048), limits.maxTextureArrayLayers);

    // Binding limits
    try std.testing.expectEqual(@as(u32, 4), limits.maxBindGroups);
    try std.testing.expectEqual(@as(u32, 1000), limits.maxBindingsPerBindGroup);
    try std.testing.expectEqual(@as(u32, 8), limits.maxDynamicUniformBuffersPerPipelineLayout);
    try std.testing.expectEqual(@as(u32, 4), limits.maxDynamicStorageBuffersPerPipelineLayout);

    // Sampler/texture/storage per shader stage
    try std.testing.expectEqual(@as(u32, 16), limits.maxSampledTexturesPerShaderStage);
    try std.testing.expectEqual(@as(u32, 16), limits.maxSamplersPerShaderStage);
    try std.testing.expectEqual(@as(u32, 8), limits.maxStorageBuffersPerShaderStage);
    try std.testing.expectEqual(@as(u32, 4), limits.maxStorageTexturesPerShaderStage);
    try std.testing.expectEqual(@as(u32, 12), limits.maxUniformBuffersPerShaderStage);

    // Uniform buffer binding size (64 KB Metal limit)
    try std.testing.expectEqual(@as(u64, 65_536), limits.maxUniformBufferBindingSize);

    // Alignment
    try std.testing.expectEqual(@as(u32, 256), limits.minUniformBufferOffsetAlignment);
    try std.testing.expectEqual(@as(u32, 32), limits.minStorageBufferOffsetAlignment);

    // Vertex
    try std.testing.expectEqual(@as(u32, 8), limits.maxVertexBuffers);
    try std.testing.expectEqual(@as(u32, 16), limits.maxVertexAttributes);
    try std.testing.expectEqual(@as(u32, 2048), limits.maxVertexBufferArrayStride);

    // Compute
    try std.testing.expectEqual(@as(u32, 32768), limits.maxComputeWorkgroupStorageSize);
    try std.testing.expectEqual(@as(u32, 1024), limits.maxComputeInvocationsPerWorkgroup);
    try std.testing.expectEqual(@as(u32, 1024), limits.maxComputeWorkgroupSizeX);
    try std.testing.expectEqual(@as(u32, 1024), limits.maxComputeWorkgroupSizeY);
    try std.testing.expectEqual(@as(u32, 64), limits.maxComputeWorkgroupSizeZ);

    // Buffer size (fallback value when no MTLDevice)
    try std.testing.expectEqual(@as(u64, 268_435_456), limits.maxBufferSize);
    try std.testing.expectEqual(@as(u64, 268_435_456), limits.maxStorageBufferBindingSize);

    // Render
    try std.testing.expectEqual(@as(u32, 8), limits.maxColorAttachments);
    try std.testing.expectEqual(@as(u32, 32), limits.maxColorAttachmentBytesPerSample);
    try std.testing.expectEqual(@as(u32, 16), limits.maxInterStageShaderVariables);
}

test "doeNativeDeviceGetLimits: adapter and device return identical fallback limits" {
    var dev_limits = std.mem.zeroes(types.WGPULimits);
    var adapter_limits = std.mem.zeroes(types.WGPULimits);
    _ = caps.doeNativeDeviceGetLimits(null, &dev_limits);
    _ = caps.doeNativeAdapterGetLimits(null, &adapter_limits);

    // When both are called with null device, they should return identical results.
    const dev_bytes = std.mem.asBytes(&dev_limits);
    const adapter_bytes = std.mem.asBytes(&adapter_limits);
    try std.testing.expectEqualSlices(u8, dev_bytes, adapter_bytes);
}

// ============================================================
// 18. doe_device_caps.zig — Subgroup size query
// ============================================================

test "doeNativeDeviceSubgroupSize: null input is safe" {
    const result = caps.doeNativeDeviceSubgroupSize(null);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(@as(u32, 32), result);
    } else {
        try std.testing.expectEqual(@as(u32, 0), result);
    }
}

test "doeNativeDeviceGetLimitsFromMtl: null device returns fallback limits" {
    var limits = std.mem.zeroes(types.WGPULimits);
    const status = caps.doeNativeDeviceGetLimitsFromMtl(null, &limits);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);
    // Without a real MTLDevice, maxBufferSize falls back to 256 MB.
    try std.testing.expectEqual(@as(u64, 268_435_456), limits.maxBufferSize);
}

test "doeNativeDeviceGetLimitsFromMtl: null limits pointer returns success" {
    const status = caps.doeNativeDeviceGetLimitsFromMtl(null, null);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);
}

// ============================================================
// 19. doe_compute_fast.zig — Export existence
// ============================================================

test "doe_compute_fast: doeNativeComputeDispatchFlush export exists" {
    const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");
    try std.testing.expect(@hasDecl(compute_fast, "doeNativeComputeDispatchFlush"));
}

test "doe_compute_fast: command buffer builder exports exist" {
    const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");
    try std.testing.expect(@hasDecl(compute_fast, "doeNativeCreateComputeDispatchCopyCommandBuffer"));
    try std.testing.expect(@hasDecl(compute_fast, "doeNativeCreateComputeDispatchBatchCopyCommandBuffer"));
}

// ============================================================
// 20. doe_compute_fast.zig — Null-safety of dispatch flush
// ============================================================

test "doeNativeComputeDispatchFlush: null queue is safe" {
    const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");
    var bg_ptrs = [_]?*anyopaque{null} ** 4;
    // Null queue → early return via cast().
    compute_fast.doeNativeComputeDispatchFlush(
        null, // q_raw
        null, // pipe_raw
        &bg_ptrs,
        0,
        1,
        1,
        1,
        null,
        0,
        null,
        0,
        0,
    );
}

test "doeNativeComputeDispatchFlush: null pipeline is safe" {
    const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");
    var bg_ptrs = [_]?*anyopaque{null} ** 4;
    // Wrong magic for queue → early return via cast().
    var dev_backing = native.DoeDevice{};
    var fake = native.DoeQueue{ .dev = &dev_backing };
    fake.magic = 0xDEADBEEF;
    compute_fast.doeNativeComputeDispatchFlush(
        @ptrCast(&fake), // q_raw with bad magic
        null, // pipe_raw
        &bg_ptrs,
        0,
        1,
        1,
        1,
        null,
        0,
        null,
        0,
        0,
    );
}

test "doeNativeCreateComputeDispatchCopyCommandBuffer: null inputs return null" {
    const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");
    var bg_ptrs = [_]?*anyopaque{null} ** 4;
    const command_buffer = compute_fast.doeNativeCreateComputeDispatchCopyCommandBuffer(
        null,
        null,
        &bg_ptrs,
        0,
        1,
        1,
        1,
        null,
        0,
        null,
        0,
        0,
    );
    try std.testing.expect(command_buffer == null);
}

test "doeNativeCreateComputeDispatchBatchCopyCommandBuffer: null inputs return null" {
    const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");
    var pipes = [_]?*anyopaque{null};
    var bg_ptrs = [_]?*anyopaque{null} ** 4;
    var bg_counts = [_]u32{0};
    var dispatch_dims = [_]u32{ 1, 1, 1 };
    const command_buffer = compute_fast.doeNativeCreateComputeDispatchBatchCopyCommandBuffer(
        null,
        1,
        &pipes,
        &bg_ptrs,
        &bg_counts,
        &dispatch_dims,
        null,
        0,
        null,
        0,
        0,
    );
    try std.testing.expect(command_buffer == null);
}

// ============================================================
// 21. doe_compute_ext_native.zig — Null-safety via re-exports
// ============================================================

test "doeNativeComputePassSetPipeline: null inputs are safe" {
    native.doeNativeComputePassSetPipeline(null, null);
}

test "doeNativeComputePassSetBindGroup: null inputs are safe" {
    native.doeNativeComputePassSetBindGroup(null, 0, null, 0, null);
}

test "doeNativeComputePassEnd: null input is safe" {
    native.doeNativeComputePassEnd(null);
}

test "doeNativeComputePassRelease: null input is safe" {
    native.doeNativeComputePassRelease(null);
}

test "doeNativeComputePipelineGetBindGroupLayout: null returns null" {
    const result = native.doeNativeComputePipelineGetBindGroupLayout(null, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeComputePassDispatch: null inputs are safe" {
    native.doeNativeComputePassDispatch(null, 1, 1, 1);
}

test "doeNativeComputePassDispatchIndirect: null inputs are safe" {
    native.doeNativeComputePassDispatchIndirect(null, null, 0);
}

// ============================================================
// 22. doe_queue_submit_native.zig — Null-safety via re-exports
// ============================================================

test "doeNativeQueueFlush: null input is safe" {
    native.doeNativeQueueFlush(null);
}

test "doeNativeQueueWriteBuffer: null queue is safe" {
    var data = [_]u8{ 1, 2, 3, 4 };
    native.doeNativeQueueWriteBuffer(null, null, 0, &data, 4);
}

test "doeNativeQueueRelease: null input is safe" {
    native.doeNativeQueueRelease(null);
}

// ============================================================
// 23. doe_wgpu_native.zig — DoeTexture default fields
// ============================================================

test "DoeTexture: default fields" {
    const tex = native.DoeTexture{};
    try std.testing.expectEqual(@as(?*anyopaque, null), tex.mtl);
    try std.testing.expectEqual(@as(u32, 0), tex.format);
    try std.testing.expectEqual(@as(u32, 0), tex.width);
    try std.testing.expectEqual(@as(u32, 0), tex.height);
    try std.testing.expectEqual(@as(u32, 1), tex.depth_or_array_layers);
    try std.testing.expectEqual(@as(u32, 0), tex.dimension);
}

// ============================================================
// 24. doe_wgpu_native.zig — CmdTag enum variants
// ============================================================

test "CmdTag: all expected variants exist" {
    comptime {
        _ = native.CmdTag.dispatch;
        _ = native.CmdTag.dispatch_indirect;
        _ = native.CmdTag.copy_buf;
        _ = native.CmdTag.copy_buffer_to_texture;
        _ = native.CmdTag.copy_texture_to_buffer;
        _ = native.CmdTag.render_pass;
        _ = native.CmdTag.write_timestamp;
        _ = native.CmdTag.resolve_query_set;
    }
}

test "CmdTag: has exactly 10 variants" {
    const fields = @typeInfo(native.CmdTag).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 10), fields.len);
}

// ============================================================
// 25. doe_wgpu_native.zig — toOpaque helper
// ============================================================

test "toOpaque: converts typed pointer to opaque" {
    var buf = native.DoeBuffer{};
    const opaque_ptr = native.toOpaque(&buf);
    try std.testing.expect(opaque_ptr != null);
    // Round-trip: cast back to DoeBuffer should work.
    const back = native.cast(native.DoeBuffer, opaque_ptr);
    try std.testing.expect(back != null);
    try std.testing.expectEqual(&buf, back.?);
}

// ============================================================
// 26. doe_wgpu_native.zig — DeferredCopy and limits
// ============================================================

test "MAX_DEFERRED_COPIES is 16" {
    try std.testing.expectEqual(@as(u32, 16), native.MAX_DEFERRED_COPIES);
}

test "MAX_DEFERRED_RESOLVES is 8" {
    try std.testing.expectEqual(@as(u32, 8), native.MAX_DEFERRED_RESOLVES);
}

test "DeferredCopy: struct fields exist and are correct types" {
    const dc = native.DeferredCopy{
        .src = @as([*]const u8, @ptrFromInt(0x1000)),
        .dst = @as([*]u8, @ptrFromInt(0x2000)),
        .size = 1024,
    };
    try std.testing.expectEqual(@as(usize, 1024), dc.size);
}

// ============================================================
// 27. doe_wgpu_native.zig — BindingInfo fields
// ============================================================

test "BindingInfo: default kind is buffer" {
    const wgsl_compiler = @import("../../src/compiler/wgsl/mod.zig");
    const bi = native.BindingInfo{
        .group = 0,
        .binding = 0,
    };
    try std.testing.expectEqual(@as(u32, @intFromEnum(wgsl_compiler.BindingKind.buffer)), bi.kind);
    try std.testing.expectEqual(@as(u32, 0), bi.addr_space);
    try std.testing.expectEqual(@as(u32, 0), bi.access);
}

test "MAX_SHADER_BINDINGS matches WGSL compiler MAX_BINDINGS" {
    const wgsl_compiler = @import("../../src/compiler/wgsl/mod.zig");
    try std.testing.expectEqual(wgsl_compiler.MAX_BINDINGS, native.MAX_SHADER_BINDINGS);
    try std.testing.expectEqual(@as(usize, 16), native.MAX_SHADER_BINDINGS);
}

// ============================================================
// 28. doe_render_native.zig — Null-safety via re-exports
// ============================================================

test "doeNativeTextureRelease: null input is safe" {
    native.doeNativeTextureRelease(null);
}

test "doeNativeTextureViewRelease: null input is safe" {
    native.doeNativeTextureViewRelease(null);
}

test "doeNativeSamplerRelease: null input is safe" {
    native.doeNativeSamplerRelease(null);
}

test "doeNativeRenderPipelineRelease: null input is safe" {
    native.doeNativeRenderPipelineRelease(null);
}

test "doeNativeRenderPassSetPipeline: null inputs are safe" {
    native.doeNativeRenderPassSetPipeline(null, null);
}

test "doeNativeRenderPassSetBindGroup: null inputs are safe" {
    native.doeNativeRenderPassSetBindGroup(null, 0, null, 0, null);
}

test "doeNativeRenderPassEnd: null input is safe" {
    native.doeNativeRenderPassEnd(null);
}

test "doeNativeRenderPassRelease: null input is safe" {
    native.doeNativeRenderPassRelease(null);
}

test "doeNativeRenderPassDraw: null input is safe" {
    native.doeNativeRenderPassDraw(null, 0, 0, 0, 0);
}

test "doeNativeRenderPassDrawIndexed: null input is safe" {
    native.doeNativeRenderPassDrawIndexed(null, 0, 0, 0, 0, 0);
}

test "doeNativeDeviceCreateTexture: null device returns null" {
    const result = native.doeNativeDeviceCreateTexture(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeTextureCreateView: null texture returns null" {
    const result = native.doeNativeTextureCreateView(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "texture view: default full Metal view can borrow texture handle" {
    var tex = native.DoeTexture{
        .mtl = @ptrFromInt(0x1000),
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .width = 128,
        .height = 128,
        .depth_or_array_layers = 1,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .mip_level_count = 1,
        .sample_count = 1,
        .usage = abi_texture.WGPUTextureUsage_TextureBinding | abi_texture.WGPUTextureUsage_CopyDst,
    };

    try std.testing.expect(texture_sampler.canBorrowMetalTextureForFullView(
        &tex,
        tex.format,
        texture_sampler.default_texture_view_dimension(&tex),
        0,
        tex.mip_level_count,
        0,
        tex.depth_or_array_layers,
        abi_texture.WGPUTextureAspect_All,
        abi_texture.WGPUTextureUsage_TextureBinding,
        abi_texture.WGPUTextureComponentSwizzle_Red,
        abi_texture.WGPUTextureComponentSwizzle_Green,
        abi_texture.WGPUTextureComponentSwizzle_Blue,
        abi_texture.WGPUTextureComponentSwizzle_Alpha,
    ));
}

test "texture view: undefined counts resolve before reaching Metal" {
    var tex = native.DoeTexture{
        .mtl = @ptrFromInt(0x1000),
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .width = 128,
        .height = 128,
        .depth_or_array_layers = 1,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .mip_level_count = 1,
        .sample_count = 1,
        .usage = abi_texture.WGPUTextureUsage_RenderAttachment | abi_texture.WGPUTextureUsage_CopySrc,
    };
    const desc = abi_pipeline.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .format = 0,
        .dimension = 0,
        .baseMipLevel = 0,
        .mipLevelCount = abi_core.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
        .baseArrayLayer = 0,
        .arrayLayerCount = abi_core.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
        .aspect = 0,
        .usage = 0,
    };

    const raw_view = texture_sampler.doeNativeTextureCreateView(@ptrCast(&tex), &desc) orelse return error.TestUnexpectedResult;
    const view = texture_sampler.registeredTextureView(raw_view) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), view.mip_level_count);
    try std.testing.expectEqual(@as(u32, 1), view.array_layer_count);
    try std.testing.expectEqual(tex.mtl, view.handle);
    try std.testing.expectEqual(@as(u32, 2), tex.ref_count);

    texture_sampler.doeNativeTextureViewRelease(raw_view);
    try std.testing.expectEqual(@as(u32, 1), tex.ref_count);
}

test "texture view: invalid subresource ranges fail before retaining texture" {
    var tex = native.DoeTexture{
        .mtl = @ptrFromInt(0x1000),
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .width = 128,
        .height = 128,
        .depth_or_array_layers = 2,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .mip_level_count = 2,
        .sample_count = 1,
        .usage = abi_texture.WGPUTextureUsage_TextureBinding,
    };
    var desc = abi_pipeline.WGPUTextureViewDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .format = 0,
        .dimension = 0,
        .baseMipLevel = 2,
        .mipLevelCount = abi_core.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
        .baseArrayLayer = 0,
        .arrayLayerCount = abi_core.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
        .aspect = 0,
        .usage = 0,
    };

    try std.testing.expect(texture_sampler.doeNativeTextureCreateView(@ptrCast(&tex), &desc) == null);
    try std.testing.expectEqual(@as(u32, 1), tex.ref_count);

    desc.baseMipLevel = 0;
    desc.mipLevelCount = 3;
    try std.testing.expect(texture_sampler.doeNativeTextureCreateView(@ptrCast(&tex), &desc) == null);
    try std.testing.expectEqual(@as(u32, 1), tex.ref_count);

    desc.mipLevelCount = 1;
    desc.baseArrayLayer = 2;
    try std.testing.expect(texture_sampler.doeNativeTextureCreateView(@ptrCast(&tex), &desc) == null);
    try std.testing.expectEqual(@as(u32, 1), tex.ref_count);
}

test "texture view: non-default Metal view cannot borrow texture handle" {
    var tex = native.DoeTexture{
        .mtl = @ptrFromInt(0x1000),
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .width = 128,
        .height = 128,
        .depth_or_array_layers = 4,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .mip_level_count = 2,
        .sample_count = 1,
        .usage = abi_texture.WGPUTextureUsage_TextureBinding | abi_texture.WGPUTextureUsage_CopyDst,
    };

    try std.testing.expect(!texture_sampler.canBorrowMetalTextureForFullView(
        &tex,
        tex.format,
        texture_sampler.default_texture_view_dimension(&tex),
        1,
        1,
        0,
        tex.depth_or_array_layers,
        abi_texture.WGPUTextureAspect_All,
        tex.usage,
        abi_texture.WGPUTextureComponentSwizzle_Red,
        abi_texture.WGPUTextureComponentSwizzle_Green,
        abi_texture.WGPUTextureComponentSwizzle_Blue,
        abi_texture.WGPUTextureComponentSwizzle_Alpha,
    ));
}

test "doeNativeDeviceCreateSampler: null device returns null" {
    const result = native.doeNativeDeviceCreateSampler(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeDeviceCreateRenderPipeline: null device returns null" {
    const result = native.doeNativeDeviceCreateRenderPipeline(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeCommandEncoderBeginRenderPass: null inputs return null" {
    const result = native.doeNativeCommandEncoderBeginRenderPass(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

// ============================================================
// 29. doe_bind_group_native.zig — Null-safety via re-exports
// ============================================================

test "doeNativeDeviceCreateBindGroupLayout: null device returns null" {
    const result = native.doeNativeDeviceCreateBindGroupLayout(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeDeviceCreateBindGroupLayout: missing entries returns null" {
    const descriptor = types.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .entryCount = 1,
        .entries = null,
    };
    const result = native.doeNativeDeviceCreateBindGroupLayout(null, &descriptor);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeBindGroupLayoutRelease: null input is safe" {
    native.doeNativeBindGroupLayoutRelease(null);
}

test "doeNativeDeviceCreatePipelineLayout: null device still allocates" {
    // Current implementation ignores device (stub) and always allocates.
    const result = native.doeNativeDeviceCreatePipelineLayout(null, null);
    try std.testing.expect(result != null);
    // Clean up.
    native.doeNativePipelineLayoutRelease(result);
}

test "doeNativePipelineLayoutRelease: null input is safe" {
    native.doeNativePipelineLayoutRelease(null);
}

test "doeNativeBindGroupRelease: null input is safe" {
    native.doeNativeBindGroupRelease(null);
}

// ============================================================
// 30. doe_shader_native.zig — Null-safety via re-exports
// ============================================================

test "doeNativeShaderModuleRelease: null input is safe" {
    native.doeNativeShaderModuleRelease(null);
}

test "doeNativeComputePipelineRelease: null input is safe" {
    native.doeNativeComputePipelineRelease(null);
}

// ============================================================
// 31. doe_query_native.zig — Null-safety via re-exports
// ============================================================

test "doeNativeQuerySetDestroy: null input is safe" {
    native.doeNativeQuerySetDestroy(null);
}

// ============================================================
// 32. wgpu_types.zig — Type consistency checks
// ============================================================

test "wgpu_types: WGPUStatus_Success is 1" {
    try std.testing.expectEqual(@as(u32, 1), types.WGPUStatus_Success);
}

test "wgpu_types: WGPUMapAsyncStatus_Success is 1" {
    try std.testing.expectEqual(@as(u32, 1), types.WGPUMapAsyncStatus_Success);
}

test "wgpu_types: WGPUFeatureName_ShaderF16 is 0x0B" {
    try std.testing.expectEqual(@as(u32, 0x0000000B), types.WGPUFeatureName_ShaderF16);
}

test "wgpu_types: WGPUBufferUsage flags are distinct powers of two" {
    // Verify non-overlapping usage flags.
    try std.testing.expectEqual(@as(u64, 0x01), types.WGPUBufferUsage_MapRead);
    try std.testing.expectEqual(@as(u64, 0x02), types.WGPUBufferUsage_MapWrite);
    try std.testing.expectEqual(@as(u64, 0x04), types.WGPUBufferUsage_CopySrc);
    try std.testing.expectEqual(@as(u64, 0x08), types.WGPUBufferUsage_CopyDst);
    try std.testing.expectEqual(@as(u64, 0x10), types.WGPUBufferUsage_Index);
    try std.testing.expectEqual(@as(u64, 0x20), types.WGPUBufferUsage_Vertex);
    try std.testing.expectEqual(@as(u64, 0x40), types.WGPUBufferUsage_Uniform);
    try std.testing.expectEqual(@as(u64, 0x80), types.WGPUBufferUsage_Storage);

    // Verify no overlapping bits among all usage flags.
    const all_flags = [_]u64{
        types.WGPUBufferUsage_MapRead,
        types.WGPUBufferUsage_MapWrite,
        types.WGPUBufferUsage_CopySrc,
        types.WGPUBufferUsage_CopyDst,
        types.WGPUBufferUsage_Index,
        types.WGPUBufferUsage_Vertex,
        types.WGPUBufferUsage_Uniform,
        types.WGPUBufferUsage_Storage,
    };
    var combined: u64 = 0;
    for (all_flags) |f| {
        try std.testing.expectEqual(@as(u64, 0), combined & f);
        combined |= f;
    }
}

test "wgpu_types: WGPULimits struct size is stable" {
    // WGPULimits is an extern struct used across the C ABI boundary.
    // Its size must not change unexpectedly.
    const expected_fields = 33; // 32 u32/u64 fields + nextInChain pointer
    const actual_fields = @typeInfo(types.WGPULimits).@"struct".fields.len;
    try std.testing.expectEqual(expected_fields, actual_fields);
}

test "wgpu_types: initLimits returns zeroed limits" {
    const limits = types.initLimits();
    try std.testing.expect(limits.nextInChain == null);
    try std.testing.expectEqual(@as(u32, 0), limits.maxTextureDimension1D);
    try std.testing.expectEqual(@as(u32, 0), limits.maxBindGroups);
    try std.testing.expectEqual(@as(u64, 0), limits.maxBufferSize);
}

// ============================================================
// 33. doe_wgpu_native.zig — DoeRenderPass default fields
// ============================================================

test "DoeRenderPass: bind groups default to null" {
    // Cannot construct DoeRenderPass without a valid enc pointer, so verify
    // the array size matches MAX_RENDER_BIND_GROUPS.
    const info = @typeInfo(native.DoeRenderPass).@"struct";
    comptime {
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "bind_groups")) {
                const arr_info = @typeInfo(f.type).array;
                if (arr_info.len != native.MAX_RENDER_BIND_GROUPS)
                    @compileError("bind_groups length mismatch");
            }
        }
    }
}

// ============================================================
// 34. doe_wgpu_native.zig — DoeComputePass bind groups
// ============================================================

test "DoeComputePass: bind group array has 4 slots" {
    comptime {
        const info = @typeInfo(native.DoeComputePass).@"struct";
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "bind_groups")) {
                const arr_info = @typeInfo(f.type).array;
                if (arr_info.len != 4)
                    @compileError("DoeComputePass bind_groups should have 4 slots");
            }
        }
    }
}

// ============================================================
// 35. Comprehensive comptime symbol import validation
//     Forces the linker to resolve all exports from each module.
// ============================================================

test "comptime: all export fn symbols are resolvable" {
    comptime {
        // doe_wgpu_native.zig direct exports
        _ = native.doeNativeDeviceCreateBuffer;
        _ = native.doeNativeBufferRelease;
        _ = native.doeNativeBufferUnmap;
        _ = native.doeNativeBufferMapAsync;
        _ = native.doeNativeBufferGetConstMappedRange;
        _ = native.doeNativeBufferGetMappedRange;
        _ = native.doeNativeInstanceProcessEvents;

        // Re-exports: instance/device
        _ = native.doeNativeCreateInstance;
        _ = native.doeNativeInstanceRelease;
        _ = native.doeNativeInstanceWaitAny;
        _ = native.doeNativeRequestAdapterFlat;
        _ = native.doeNativeInstanceRequestAdapter;
        _ = native.doeNativeAdapterRequestDevice;
        _ = native.doeNativeAdapterRelease;
        _ = native.doeNativeRequestDeviceFlat;
        _ = native.doeNativeDeviceRelease;
        _ = native.doeNativeDeviceGetQueue;

        // Re-exports: shader
        _ = native.doeNativeDeviceCreateShaderModule;
        _ = native.doeNativeShaderModuleRelease;
        _ = native.doeNativeDeviceCreateComputePipeline;
        _ = native.doeNativeComputePipelineRelease;

        // Re-exports: bind group
        _ = native.doeNativeDeviceCreateBindGroupLayout;
        _ = native.doeNativeBindGroupLayoutRelease;
        _ = native.doeNativeDeviceCreateBindGroup;
        _ = native.doeNativeBindGroupRelease;
        _ = native.doeNativeDeviceCreatePipelineLayout;
        _ = native.doeNativePipelineLayoutRelease;

        // Re-exports: encoder
        _ = native.doeNativeDeviceCreateCommandEncoder;
        _ = native.doeNativeCommandEncoderRelease;
        _ = native.doeNativeCommandEncoderBeginComputePass;
        _ = native.doeNativeCopyBufferToBuffer;
        _ = native.doeNativeCommandEncoderCopyBufferToTexture;
        _ = native.doeNativeCommandEncoderCopyTextureToBuffer;
        _ = native.doeNativeCommandEncoderFinish;
        _ = native.doeNativeCommandBufferRelease;

        // Re-exports: queue
        _ = native.doeNativeQueueSubmit;
        _ = native.doeNativeQueueFlush;
        _ = native.doeNativeQueueWriteBuffer;
        _ = native.doeNativeQueueRelease;
        _ = native.doeNativeQueueOnSubmittedWorkDone;

        // Re-exports: compute pass
        _ = native.doeNativeComputePassSetPipeline;
        _ = native.doeNativeComputePassSetBindGroup;
        _ = native.doeNativeComputePassDispatch;
        _ = native.doeNativeComputePassEnd;
        _ = native.doeNativeComputePassRelease;
        _ = native.doeNativeComputePipelineGetBindGroupLayout;
        _ = native.doeNativeComputePassDispatchIndirect;

        // Re-exports: caps
        _ = native.doeNativeAdapterHasFeature;
        _ = native.doeNativeDeviceHasFeature;
        _ = native.doeNativeDeviceGetLimits;
        _ = native.doeNativeAdapterGetLimits;

        // Re-exports: render
        _ = native.doeNativeDeviceCreateTexture;
        _ = native.doeNativeTextureCreateView;
        _ = native.doeNativeTextureRelease;
        _ = native.doeNativeTextureViewRelease;
        _ = native.doeNativeDeviceCreateSampler;
        _ = native.doeNativeSamplerRelease;
        _ = native.doeNativeDeviceCreateRenderPipeline;
        _ = native.doeNativeRenderPipelineRelease;
        _ = native.doeNativeCommandEncoderBeginRenderPass;
        _ = native.doeNativeRenderPassSetPipeline;
        _ = native.doeNativeRenderPassSetBindGroup;
        _ = native.doeNativeRenderPassSetVertexBuffer;
        _ = native.doeNativeRenderPassSetIndexBuffer;
        _ = native.doeNativeRenderPassDraw;
        _ = native.doeNativeRenderPassDrawIndexed;
        _ = native.doeNativeRenderPassEnd;
        _ = native.doeNativeRenderPassRelease;

        // Re-exports: query
        _ = native.doeNativeDeviceCreateQuerySet;
        _ = native.doeNativeCommandEncoderWriteTimestamp;
        _ = native.doeNativeCommandEncoderResolveQuerySet;
        _ = native.doeNativeQuerySetDestroy;

        // doe_device_caps.zig direct exports
        _ = caps.doeNativeAdapterHasFeature;
        _ = caps.doeNativeDeviceHasFeature;
        _ = caps.doeNativeDeviceGetLimits;
        _ = caps.doeNativeAdapterGetLimits;
        _ = caps.doeNativeDeviceGetLimitsFromMtl;
        _ = caps.doeNativeDeviceSubgroupSize;

        // doe_compute_fast.zig
        _ = @import("../../src/native/compute/doe_compute_fast.zig").doeNativeComputeDispatchFlush;
    }
}
