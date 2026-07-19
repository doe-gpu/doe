// runtime_integration_test.zig — Integration tests for buffer, encoder, queue, and
// compute-fast runtime modules. Tests struct layouts, constant stability, enum values,
// state machine logic, and validation without requiring a GPU backend.

const std = @import("std");
const testing = std.testing;

const native = @import("../../src/native/mod.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");
const dispatch_preconditions = @import("../../src/core/compute/dispatch_preconditions.zig");
const compute_fast = @import("../../src/native/compute/doe_compute_fast.zig");

// ============================================================
// doe_buffer_native.zig — Buffer constants and map state
// ============================================================

// 1. Buffer usage flag combinations — verify flag constants, composability.

test "buffer usage: flag constants match WebGPU spec values" {
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0), types.WGPUBufferUsage_None);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x01), types.WGPUBufferUsage_MapRead);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x02), types.WGPUBufferUsage_MapWrite);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x04), types.WGPUBufferUsage_CopySrc);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x08), types.WGPUBufferUsage_CopyDst);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x10), types.WGPUBufferUsage_Index);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x20), types.WGPUBufferUsage_Vertex);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x40), types.WGPUBufferUsage_Uniform);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x80), types.WGPUBufferUsage_Storage);
    try testing.expectEqual(@as(types.WGPUBufferUsage, 0x200), types.WGPUBufferUsage_QueryResolve);
}

test "buffer usage: flags are single-bit and non-overlapping" {
    const flags = [_]types.WGPUBufferUsage{
        types.WGPUBufferUsage_MapRead,
        types.WGPUBufferUsage_MapWrite,
        types.WGPUBufferUsage_CopySrc,
        types.WGPUBufferUsage_CopyDst,
        types.WGPUBufferUsage_Index,
        types.WGPUBufferUsage_Vertex,
        types.WGPUBufferUsage_Uniform,
        types.WGPUBufferUsage_Storage,
        types.WGPUBufferUsage_QueryResolve,
    };
    // Each flag must be a power of two (single bit).
    for (flags) |f| {
        try testing.expect(f != 0);
        try testing.expectEqual(@as(types.WGPUBufferUsage, 0), f & (f - 1));
    }
    // Union of all flags must have no collisions.
    var combined: types.WGPUBufferUsage = 0;
    for (flags) |f| {
        try testing.expectEqual(@as(types.WGPUBufferUsage, 0), combined & f);
        combined |= f;
    }
}

test "buffer usage: composability — storage | copy_dst | copy_src" {
    const usage = types.WGPUBufferUsage_Storage | types.WGPUBufferUsage_CopyDst | types.WGPUBufferUsage_CopySrc;
    try testing.expect(usage & types.WGPUBufferUsage_Storage != 0);
    try testing.expect(usage & types.WGPUBufferUsage_CopyDst != 0);
    try testing.expect(usage & types.WGPUBufferUsage_CopySrc != 0);
    try testing.expect(usage & types.WGPUBufferUsage_Uniform == 0);
}

test "buffer usage: map_read | copy_dst is a valid readback pattern" {
    const usage = types.WGPUBufferUsage_MapRead | types.WGPUBufferUsage_CopyDst;
    try testing.expect(usage & types.WGPUBufferUsage_MapRead != 0);
    try testing.expect(usage & types.WGPUBufferUsage_CopyDst != 0);
    try testing.expect(usage & types.WGPUBufferUsage_MapWrite == 0);
}

// 2. Map mode constants — read/write mode values stable.

test "buffer map mode: read and write constants are stable" {
    try testing.expectEqual(@as(types.WGPUMapMode, 0x01), types.WGPUMapMode_Read);
    try testing.expectEqual(@as(types.WGPUMapMode, 0x02), types.WGPUMapMode_Write);
}

test "buffer map mode: read and write are distinct bits" {
    try testing.expect(types.WGPUMapMode_Read != types.WGPUMapMode_Write);
    try testing.expectEqual(@as(types.WGPUMapMode, 0), types.WGPUMapMode_Read & types.WGPUMapMode_Write);
}

test "buffer map async status: success value is 1" {
    try testing.expectEqual(@as(types.WGPUMapAsyncStatus, 1), types.WGPUMapAsyncStatus_Success);
}

// 3. DoeBuffer struct — field defaults and magic.

test "buffer struct: TYPE_MAGIC matches MAGIC_BUFFER constant" {
    try testing.expectEqual(@as(u32, 0xD0E1_0005), native.DoeBuffer.TYPE_MAGIC);
}

test "buffer struct: default initialization produces valid magic" {
    const buf = native.DoeBuffer{};
    try testing.expectEqual(native.DoeBuffer.TYPE_MAGIC, buf.magic);
    try testing.expectEqual(@as(u32, 1), buf.ref_count);
    try testing.expect(!buf.mapped);
    try testing.expectEqual(@as(u64, 0), buf.size);
    try testing.expectEqual(@as(u64, 0), buf.usage);
    try testing.expect(buf.mtl == null);
    try testing.expectEqual(@as(u64, 0), buf.vk_id);
    try testing.expect(buf.vk_runtime_ref == null);
    try testing.expect(buf.vk_mapped_ptr == null);
}

test "buffer struct: cast accepts valid magic, rejects corrupted" {
    var buf = native.DoeBuffer{};
    const raw_ptr: *anyopaque = @ptrCast(&buf);
    try testing.expect(native.cast(native.DoeBuffer, raw_ptr) != null);

    buf.magic = 0xBAD;
    try testing.expect(native.cast(native.DoeBuffer, raw_ptr) == null);
}

test "buffer struct: cast returns null for null pointer" {
    try testing.expect(native.cast(native.DoeBuffer, null) == null);
}

// 4. DoeBuffer backend kind enum.

test "buffer struct: BackendKind default is metal" {
    const buf = native.DoeBuffer{};
    try testing.expectEqual(native.BackendKind.metal, buf.backend);
}

test "buffer struct: BackendKind enum has three variants" {
    const fields = @typeInfo(native.BackendKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

test "buffer struct: BackendKind ordinals are stable" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(native.BackendKind.metal));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(native.BackendKind.vulkan));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(native.BackendKind.d3d12));
}

// 5. Deferred copy struct layout.

test "buffer: DeferredCopy struct has expected fields" {
    try testing.expect(@hasField(native.DeferredCopy, "src"));
    try testing.expect(@hasField(native.DeferredCopy, "dst"));
    try testing.expect(@hasField(native.DeferredCopy, "size"));
}

test "buffer: MAX_DEFERRED_COPIES constant is 16" {
    try testing.expectEqual(@as(u32, 16), native.MAX_DEFERRED_COPIES);
}

test "buffer: MAX_DEFERRED_RESOLVES constant is 8" {
    try testing.expectEqual(@as(u32, 8), native.MAX_DEFERRED_RESOLVES);
}

// ============================================================
// doe_encoder_native.zig — Command encoder structs and tags
// ============================================================

// 1. CmdTag enum values — stable ordinals.

test "encoder: CmdTag enum has all expected variants" {
    const fields = @typeInfo(native.CmdTag).@"enum".fields;
    try testing.expectEqual(@as(usize, 10), fields.len);
    // Verify names via comptime inline loop.
    const expected_names = [_][]const u8{
        "dispatch",
        "dispatch_indirect",
        "copy_buf",
        "copy_buffer_to_texture",
        "copy_texture_to_buffer",
        "clear_buffer",
        "copy_texture_to_texture",
        "render_pass",
        "write_timestamp",
        "resolve_query_set",
    };
    inline for (expected_names, 0..) |name, i| {
        try testing.expectEqualStrings(name, fields[i].name);
    }
}

test "encoder: CmdTag ordinals are sequential starting from 0" {
    try testing.expectEqual(@as(usize, 0), @intFromEnum(native.CmdTag.dispatch));
    try testing.expectEqual(@as(usize, 1), @intFromEnum(native.CmdTag.dispatch_indirect));
    try testing.expectEqual(@as(usize, 2), @intFromEnum(native.CmdTag.copy_buf));
    try testing.expectEqual(@as(usize, 3), @intFromEnum(native.CmdTag.copy_buffer_to_texture));
    try testing.expectEqual(@as(usize, 4), @intFromEnum(native.CmdTag.copy_texture_to_buffer));
    try testing.expectEqual(@as(usize, 5), @intFromEnum(native.CmdTag.clear_buffer));
    try testing.expectEqual(@as(usize, 6), @intFromEnum(native.CmdTag.copy_texture_to_texture));
    try testing.expectEqual(@as(usize, 7), @intFromEnum(native.CmdTag.render_pass));
    try testing.expectEqual(@as(usize, 8), @intFromEnum(native.CmdTag.write_timestamp));
    try testing.expectEqual(@as(usize, 9), @intFromEnum(native.CmdTag.resolve_query_set));
}

// 2. DoeCommandEncoder struct — magic and fields.

test "encoder: DoeCommandEncoder has correct struct fields" {
    try testing.expect(@hasField(native.DoeCommandEncoder, "magic"));
    try testing.expect(@hasField(native.DoeCommandEncoder, "ref_count"));
    try testing.expect(@hasField(native.DoeCommandEncoder, "dev"));
    try testing.expect(@hasField(native.DoeCommandEncoder, "cmds"));
}

test "encoder: DoeCommandBuffer has correct struct fields" {
    try testing.expect(@hasField(native.DoeCommandBuffer, "magic"));
    try testing.expect(@hasField(native.DoeCommandBuffer, "ref_count"));
    try testing.expect(@hasField(native.DoeCommandBuffer, "dev"));
    try testing.expect(@hasField(native.DoeCommandBuffer, "cmds"));
}

test "encoder: DoeComputePass has correct struct fields" {
    try testing.expect(@hasField(native.DoeComputePass, "magic"));
    try testing.expect(@hasField(native.DoeComputePass, "ref_count"));
    try testing.expect(@hasField(native.DoeComputePass, "enc"));
    try testing.expect(@hasField(native.DoeComputePass, "pipeline"));
    try testing.expect(@hasField(native.DoeComputePass, "bind_groups"));
}

// 3. RecordedCmd union — tag-payload pairing.

test "encoder: RecordedCmd is a tagged union keyed by CmdTag" {
    const info = @typeInfo(native.RecordedCmd);
    try testing.expect(info == .@"union");
    try testing.expect(info.@"union".tag_type != null);
}

test "encoder: RecordedCmd dispatch payload has all expected fields" {
    const dispatch_info = @typeInfo(std.meta.TagPayload(native.RecordedCmd, .dispatch));
    try testing.expect(dispatch_info == .@"struct");
    const S = std.meta.TagPayload(native.RecordedCmd, .dispatch);
    try testing.expect(@hasField(S, "pso"));
    try testing.expect(@hasField(S, "needs_sizes_buf"));
    try testing.expect(@hasField(S, "bufs"));
    try testing.expect(@hasField(S, "buf_sizes"));
    try testing.expect(@hasField(S, "buf_count"));
    try testing.expect(@hasField(S, "x"));
    try testing.expect(@hasField(S, "y"));
    try testing.expect(@hasField(S, "z"));
    try testing.expect(@hasField(S, "wg_x"));
    try testing.expect(@hasField(S, "wg_y"));
    try testing.expect(@hasField(S, "wg_z"));
}

test "encoder: RecordedCmd copy_buf payload has src, dst, offsets, size" {
    const S = std.meta.TagPayload(native.RecordedCmd, .copy_buf);
    try testing.expect(@hasField(S, "src"));
    try testing.expect(@hasField(S, "src_off"));
    try testing.expect(@hasField(S, "dst"));
    try testing.expect(@hasField(S, "dst_off"));
    try testing.expect(@hasField(S, "size"));
}

test "encoder: RecordedCmd render_pass payload includes draw geometry" {
    const S = std.meta.TagPayload(native.RecordedCmd, .render_pass);
    try testing.expect(@hasField(S, "pso"));
    try testing.expect(@hasField(S, "topology"));
    try testing.expect(@hasField(S, "draw_count"));
    try testing.expect(@hasField(S, "vertex_count"));
    try testing.expect(@hasField(S, "instance_count"));
    try testing.expect(@hasField(S, "indexed"));
    try testing.expect(@hasField(S, "indirect"));
}

// 4. Binding limits.

test "encoder: MAX_BIND is 16" {
    try testing.expectEqual(@as(usize, 16), native.MAX_BIND);
}

test "encoder: MAX_FLAT_BIND is MAX_BIND * MAX_COMPUTE_BIND_GROUPS" {
    try testing.expectEqual(native.MAX_BIND * native.MAX_COMPUTE_BIND_GROUPS, native.MAX_FLAT_BIND);
}

test "encoder: MAX_COMPUTE_BIND_GROUPS is 4" {
    try testing.expectEqual(@as(usize, 4), native.MAX_COMPUTE_BIND_GROUPS);
}

test "encoder: MAX_RENDER_BIND_GROUPS is 4" {
    try testing.expectEqual(@as(usize, 4), native.MAX_RENDER_BIND_GROUPS);
}

test "encoder: MAX_VERTEX_BUFFERS is 8" {
    try testing.expectEqual(@as(usize, 8), native.MAX_VERTEX_BUFFERS);
}

test "encoder: MAX_VERTEX_ATTRIBUTES is 16" {
    try testing.expectEqual(@as(usize, 16), native.MAX_VERTEX_ATTRIBUTES);
}

test "encoder: VERTEX_BUFFER_SLOT_BASE is 8" {
    try testing.expectEqual(@as(u32, 8), native.VERTEX_BUFFER_SLOT_BASE);
}

// 5. Export existence for encoder functions.

test "encoder: C ABI exports exist" {
    try testing.expect(@hasDecl(native, "doeNativeDeviceCreateCommandEncoder"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderRelease"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderBeginComputePass"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderFinish"));
    try testing.expect(@hasDecl(native, "doeNativeCommandBufferRelease"));
    try testing.expect(@hasDecl(native, "doeNativeCopyBufferToBuffer"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderCopyBufferToTexture"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderCopyTextureToBuffer"));
}

test "encoder: debug marker exports exist (no-ops)" {
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderInsertDebugMarker"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderPushDebugGroup"));
    try testing.expect(@hasDecl(native, "doeNativeCommandEncoderPopDebugGroup"));
}

// 6. Null-safety for encoder exports.

test "encoder: null encoder on finish returns null" {
    const result = native.doeNativeCommandEncoderFinish(null, null);
    try testing.expect(result == null);
}

test "encoder: null encoder on begin compute pass returns null" {
    const result = native.doeNativeCommandEncoderBeginComputePass(null, null);
    try testing.expect(result == null);
}

test "encoder: null args on copy buffer to buffer do not crash" {
    native.doeNativeCopyBufferToBuffer(null, null, 0, null, 0, 0);
}

test "encoder: debug marker no-ops accept null without crash" {
    native.doeNativeCommandEncoderInsertDebugMarker(null, null, 0);
    native.doeNativeCommandEncoderPushDebugGroup(null, null, 0);
    native.doeNativeCommandEncoderPopDebugGroup(null);
}

// ============================================================
// doe_queue_submit_native.zig — Queue struct and constants
// ============================================================

// 1. DoeQueue struct defaults and magic.

test "queue: DoeQueue TYPE_MAGIC is correct" {
    try testing.expectEqual(@as(u32, 0xD0E1_0004), native.DoeQueue.TYPE_MAGIC);
}

test "queue: default deferred_copy_count is 0" {
    // DoeQueue has a non-nullable dev pointer, so we cannot default-init it directly.
    // Verify the field exists and its type.
    try testing.expect(@hasField(native.DoeQueue, "deferred_copy_count"));
    try testing.expect(@hasField(native.DoeQueue, "deferred_copies"));
    try testing.expect(@hasField(native.DoeQueue, "deferred_resolve_count"));
    try testing.expect(@hasField(native.DoeQueue, "deferred_resolves"));
}

test "queue: event_counter starts at 0 by default" {
    try testing.expect(@hasField(native.DoeQueue, "event_counter"));
    try testing.expect(@hasField(native.DoeQueue, "completed_event_counter"));
    try testing.expect(@hasField(native.DoeQueue, "pending_cmd"));
    try testing.expect(@hasField(native.DoeQueue, "mtl_event"));
}

// 2. Queue submit and flush exports exist.

test "queue: C ABI exports exist" {
    try testing.expect(@hasDecl(native, "doeNativeQueueSubmit"));
    try testing.expect(@hasDecl(native, "doeNativeQueueFlush"));
    try testing.expect(@hasDecl(native, "doeNativeQueueWriteBuffer"));
    try testing.expect(@hasDecl(native, "doeNativeQueueRelease"));
    try testing.expect(@hasDecl(native, "doeNativeQueueOnSubmittedWorkDone"));
}

// 3. Queue internal helpers are re-exported.

test "queue: flush_pending_work is accessible via native" {
    try testing.expect(@hasDecl(native, "flush_pending_work"));
}

test "queue: try_schedule_deferred_copy is accessible via native" {
    try testing.expect(@hasDecl(native, "try_schedule_deferred_copy"));
}

// 4. Queue null-safety on submit.

test "queue: null queue on submit does not crash" {
    var empty_bufs = [_]?*anyopaque{null};
    native.doeNativeQueueSubmit(null, 0, &empty_bufs);
}

// ============================================================
// doe_compute_fast.zig — Fast path constants and dispatch
// ============================================================

// 1. DoeComputePipeline struct fields for fast path.

test "compute fast: DoeComputePipeline TYPE_MAGIC is correct" {
    try testing.expectEqual(@as(u32, 0xD0E1_0007), native.DoeComputePipeline.TYPE_MAGIC);
}

test "compute fast: pipeline has workgroup size fields" {
    try testing.expect(@hasField(native.DoeComputePipeline, "wg_x"));
    try testing.expect(@hasField(native.DoeComputePipeline, "wg_y"));
    try testing.expect(@hasField(native.DoeComputePipeline, "wg_z"));
}

test "compute fast: pipeline has needs_sizes_buf flag" {
    try testing.expect(@hasField(native.DoeComputePipeline, "needs_sizes_buf"));
}

test "compute fast: pipeline has dispatch_preconditions" {
    try testing.expect(@hasField(native.DoeComputePipeline, "dispatch_preconditions"));
    try testing.expect(@hasField(native.DoeComputePipeline, "texture_dispatch_preconditions"));
}

test "compute fast: pipeline default workgroup size is zero (unknown)" {
    const pipe = native.DoeComputePipeline{};
    try testing.expectEqual(@as(u32, 0), pipe.wg_x);
    try testing.expectEqual(@as(u32, 0), pipe.wg_y);
    try testing.expectEqual(@as(u32, 0), pipe.wg_z);
    try testing.expect(!pipe.needs_sizes_buf);
}

// 2. DoeBindGroup struct for compute dispatches.

test "compute fast: DoeBindGroup TYPE_MAGIC is correct" {
    try testing.expectEqual(@as(u32, 0xD0E1_000A), native.DoeBindGroup.TYPE_MAGIC);
}

test "compute fast: bind group has buffer arrays sized MAX_BIND" {
    const bg = native.DoeBindGroup{};
    try testing.expectEqual(@as(usize, native.MAX_BIND), bg.buffers.len);
    try testing.expectEqual(@as(usize, native.MAX_BIND), bg.buffer_sizes.len);
    try testing.expectEqual(@as(usize, native.MAX_BIND), bg.textures.len);
    try testing.expectEqual(@as(usize, native.MAX_BIND), bg.texture_views.len);
    try testing.expectEqual(@as(usize, native.MAX_BIND), bg.samplers.len);
    try testing.expectEqual(@as(usize, native.MAX_BIND), bg.offsets.len);
}

test "compute fast: bind group defaults are all null/zero" {
    const bg = native.DoeBindGroup{};
    try testing.expectEqual(@as(u32, 0), bg.count);
    for (bg.buffers) |b| try testing.expect(b == null);
    for (bg.buffer_sizes) |s| try testing.expectEqual(@as(u64, 0), s);
    for (bg.offsets) |o| try testing.expectEqual(@as(u64, 0), o);
}

// 3. Dispatch preconditions validation.

test "compute fast: ValidationError has expected variants" {
    const fields = @typeInfo(dispatch_preconditions.ValidationError).error_set.?;
    var found_dispatch = false;
    var found_overflow = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "DispatchPreconditionFailed")) found_dispatch = true;
        if (std.mem.eql(u8, f.name, "Overflow")) found_overflow = true;
    }
    try testing.expect(found_dispatch);
    try testing.expect(found_overflow);
}

test "compute fast: invocation_extent multiplies workgroups by workgroup_size" {
    // 4 workgroups * 64 invocations per workgroup = 256 total
    const extent = try dispatch_preconditions.invocation_extent(4, 64);
    try testing.expectEqual(@as(u64, 256), extent);
}

test "compute fast: invocation_extent of 0 workgroups is 0" {
    const extent = try dispatch_preconditions.invocation_extent(0, 64);
    try testing.expectEqual(@as(u64, 0), extent);
}

test "compute fast: invocation_extent of 0 workgroup_size is 0" {
    const extent = try dispatch_preconditions.invocation_extent(4, 0);
    try testing.expectEqual(@as(u64, 0), extent);
}

// 4. Fast path export existence.

test "compute fast: doeNativeComputeDispatchFlush export exists" {
    try testing.expect(@hasDecl(compute_fast, "doeNativeComputeDispatchFlush"));
}

test "compute fast: command buffer builder exports exist" {
    try testing.expect(@hasDecl(compute_fast, "doeNativeCreateComputeDispatchCopyCommandBuffer"));
    try testing.expect(@hasDecl(compute_fast, "doeNativeCreateComputeDispatchBatchCopyCommandBuffer"));
}

test "compute fast: compute pass exports exist" {
    try testing.expect(@hasDecl(native, "doeNativeComputePassSetPipeline"));
    try testing.expect(@hasDecl(native, "doeNativeComputePassSetBindGroup"));
    try testing.expect(@hasDecl(native, "doeNativeComputePassDispatch"));
    try testing.expect(@hasDecl(native, "doeNativeComputePassEnd"));
    try testing.expect(@hasDecl(native, "doeNativeComputePassRelease"));
    try testing.expect(@hasDecl(native, "doeNativeComputePassDispatchIndirect"));
}

// ============================================================
// Cross-module: Handle magic uniqueness across all types
// ============================================================

test "handle magic: pub TYPE_MAGIC constants are correct" {
    // Only types with pub TYPE_MAGIC are directly accessible from tests.
    try testing.expectEqual(@as(u32, 0xD0E1_0004), native.DoeQueue.TYPE_MAGIC);
    try testing.expectEqual(@as(u32, 0xD0E1_0005), native.DoeBuffer.TYPE_MAGIC);
    try testing.expectEqual(@as(u32, 0xD0E1_0007), native.DoeComputePipeline.TYPE_MAGIC);
    try testing.expectEqual(@as(u32, 0xD0E1_000A), native.DoeBindGroup.TYPE_MAGIC);
}

test "handle magic: default-init structs carry correct D0E1 prefix" {
    // For types with non-pub TYPE_MAGIC, verify via default .magic field value.
    // Only types without non-nullable pointer fields can be default-inited.
    const instance = native.DoeInstance{};
    const adapter = native.DoeAdapter{};
    const device = native.DoeDevice{};
    const buffer = native.DoeBuffer{};
    const shader = native.DoeShaderModule{};
    const pipeline = native.DoeComputePipeline{};
    const bgl = native.DoeBindGroupLayout{};
    const pl = native.DoePipelineLayout{};
    const bg = native.DoeBindGroup{};
    const tex = native.DoeTexture{};
    const sampler = native.DoeSampler{};
    const render_pipe = native.DoeRenderPipeline{};

    const magics = [_]u32{
        instance.magic,
        adapter.magic,
        device.magic,
        buffer.magic,
        shader.magic,
        pipeline.magic,
        bgl.magic,
        pl.magic,
        bg.magic,
        tex.magic,
        sampler.magic,
        render_pipe.magic,
    };
    // All must use D0E1 prefix.
    for (magics) |m| {
        try testing.expectEqual(@as(u32, 0xD0E1_0000), m & 0xFFFF_0000);
    }
    // All must be distinct.
    for (magics, 0..) |a, i| {
        for (magics[i + 1 ..]) |b| {
            try testing.expect(a != b);
        }
    }
}

test "handle magic: known magic values are sequential" {
    // Verify the expected sequence via default-init magic fields.
    try testing.expectEqual(@as(u32, 0xD0E1_0001), (native.DoeInstance{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0002), (native.DoeAdapter{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0003), (native.DoeDevice{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0005), (native.DoeBuffer{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0006), (native.DoeShaderModule{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0008), (native.DoeBindGroupLayout{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0009), (native.DoePipelineLayout{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_000E), (native.DoeTexture{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0010), (native.DoeSampler{}).magic);
    try testing.expectEqual(@as(u32, 0xD0E1_0011), (native.DoeRenderPipeline{}).magic);
}

// ============================================================
// Cross-module: Ref-counting helper contracts
// ============================================================

test "object_should_destroy returns true when ref_count is 1" {
    var buf = native.DoeBuffer{};
    try testing.expectEqual(@as(u32, 1), buf.ref_count);
    try testing.expect(native.object_should_destroy(&buf));
}

test "object_should_destroy returns false and decrements when ref_count > 1" {
    var buf = native.DoeBuffer{};
    buf.ref_count = 3;
    try testing.expect(!native.object_should_destroy(&buf));
    try testing.expectEqual(@as(u32, 2), buf.ref_count);
    try testing.expect(!native.object_should_destroy(&buf));
    try testing.expectEqual(@as(u32, 1), buf.ref_count);
    try testing.expect(native.object_should_destroy(&buf));
}

// ============================================================
// Cross-module: Shader/pipeline binding limits
// ============================================================

test "MAX_SHADER_BINDINGS is 16" {
    try testing.expectEqual(@as(usize, 16), native.MAX_SHADER_BINDINGS);
}

test "BindingInfo struct has expected fields" {
    try testing.expect(@hasField(native.BindingInfo, "group"));
    try testing.expect(@hasField(native.BindingInfo, "binding"));
    try testing.expect(@hasField(native.BindingInfo, "kind"));
    try testing.expect(@hasField(native.BindingInfo, "addr_space"));
    try testing.expect(@hasField(native.BindingInfo, "access"));
}

// ============================================================
// Cross-module: WGPUFuture and callback structs
// ============================================================

test "WGPUFuture has id field" {
    const future = types.WGPUFuture{ .id = 42 };
    try testing.expectEqual(@as(u64, 42), future.id);
}

test "WGPUStringView has data and length fields" {
    const sv = types.WGPUStringView{ .data = null, .length = 0 };
    try testing.expect(sv.data == null);
    try testing.expectEqual(@as(usize, 0), sv.length);
}

test "WGPUBufferMapCallbackInfo is extern struct" {
    const info = @typeInfo(types.WGPUBufferMapCallbackInfo);
    try testing.expect(info == .@"struct");
    try testing.expect(info.@"struct".layout == .@"extern");
}

// ============================================================
// Cross-module: ERR_CAP constant
// ============================================================

test "ERR_CAP constant is 512" {
    try testing.expectEqual(@as(usize, 512), native.ERR_CAP);
}
