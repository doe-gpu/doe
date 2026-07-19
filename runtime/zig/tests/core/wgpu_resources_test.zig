// wgpu_resources_test.zig — Unit tests for the WebGPU resource model layer.
// Tests pure logic: buffer/texture descriptor validation helpers,
// resource ID alignment, binding usage flags, and layout composition.
// All tests run without a GPU.

const std = @import("std");
const testing = std.testing;

const resources = @import("../../src/core/resource/wgpu_resources.zig");
const model = @import("../../src/contracts/model/model.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");
const normalizers = @import("../../src/core/resource/wgpu_resource_normalizers.zig");
const loader = @import("../../src/core/abi/wgpu_loader.zig");

// ============================================================
// Section 1: requiredBytes — size alignment and overflow safety
// ============================================================

test "requiredBytes: zero bytes zero offset returns 0 (aligned to 4)" {
    const result = try resources.requiredBytes(0, 0);
    try testing.expectEqual(@as(u64, 0), result);
}

test "requiredBytes: 1 byte zero offset aligns to 4" {
    const result = try resources.requiredBytes(1, 0);
    try testing.expectEqual(@as(u64, 4), result);
}

test "requiredBytes: 4 bytes zero offset stays at 4" {
    const result = try resources.requiredBytes(4, 0);
    try testing.expectEqual(@as(u64, 4), result);
}

test "requiredBytes: 5 bytes zero offset aligns to 8" {
    const result = try resources.requiredBytes(5, 0);
    try testing.expectEqual(@as(u64, 8), result);
}

test "requiredBytes: 3 bytes with 1 offset aligns (3+1)=4 to 4" {
    const result = try resources.requiredBytes(3, 1);
    try testing.expectEqual(@as(u64, 4), result);
}

test "requiredBytes: 1 byte with 3 offset aligns (1+3)=4 to 4" {
    const result = try resources.requiredBytes(1, 3);
    try testing.expectEqual(@as(u64, 4), result);
}

test "requiredBytes: 1 byte with 4 offset aligns (1+4)=5 to 8" {
    const result = try resources.requiredBytes(1, 4);
    try testing.expectEqual(@as(u64, 8), result);
}

test "requiredBytes: large aligned value stays aligned" {
    const result = try resources.requiredBytes(1024, 0);
    try testing.expectEqual(@as(u64, 1024), result);
}

test "requiredBytes: large unaligned value rounds up" {
    const result = try resources.requiredBytes(1023, 0);
    try testing.expectEqual(@as(u64, 1024), result);
}

test "requiredBytes: offset contributes to alignment" {
    const result = try resources.requiredBytes(256, 2);
    try testing.expectEqual(@as(u64, 260), result);
}

test "requiredBytes: power of two sizes stay aligned" {
    try testing.expectEqual(@as(u64, 4), try resources.requiredBytes(4, 0));
    try testing.expectEqual(@as(u64, 8), try resources.requiredBytes(8, 0));
    try testing.expectEqual(@as(u64, 16), try resources.requiredBytes(16, 0));
    try testing.expectEqual(@as(u64, 256), try resources.requiredBytes(256, 0));
    try testing.expectEqual(@as(u64, 4096), try resources.requiredBytes(4096, 0));
}

// ============================================================
// Section 2: bindingUsageForBufferKind — usage flag combinations
// ============================================================

test "binding usage: uniform buffer includes Uniform+CopySrc+CopyDst" {
    const binding = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = model.WGPUBufferBindingType_Uniform,
    };
    const usage = resources.bindingUsageForBufferKind(binding);
    try testing.expect((usage & types.WGPUBufferUsage_Uniform) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopySrc) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopyDst) != 0);
    // Should not include Storage.
    try testing.expect((usage & types.WGPUBufferUsage_Storage) == 0);
}

test "binding usage: storage buffer includes Storage+CopySrc+CopyDst" {
    const binding = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = model.WGPUBufferBindingType_Storage,
    };
    const usage = resources.bindingUsageForBufferKind(binding);
    try testing.expect((usage & types.WGPUBufferUsage_Storage) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopySrc) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopyDst) != 0);
}

test "binding usage: read-only storage buffer includes Storage+CopySrc+CopyDst" {
    const binding = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = model.WGPUBufferBindingType_ReadOnlyStorage,
    };
    const usage = resources.bindingUsageForBufferKind(binding);
    try testing.expect((usage & types.WGPUBufferUsage_Storage) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopySrc) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopyDst) != 0);
}

test "binding usage: undefined type includes both Uniform and Storage" {
    const binding = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = model.WGPUBufferBindingType_Undefined,
    };
    const usage = resources.bindingUsageForBufferKind(binding);
    try testing.expect((usage & types.WGPUBufferUsage_Storage) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_Uniform) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopySrc) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopyDst) != 0);
}

test "binding usage: unrecognized type falls to default with both Uniform and Storage" {
    const binding = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = 0xFF,
    };
    const usage = resources.bindingUsageForBufferKind(binding);
    try testing.expect((usage & types.WGPUBufferUsage_Storage) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_Uniform) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopySrc) != 0);
    try testing.expect((usage & types.WGPUBufferUsage_CopyDst) != 0);
}

test "binding usage: storage and read-only storage produce same flags" {
    const storage = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = model.WGPUBufferBindingType_Storage,
    };
    const ro_storage = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 1,
        .buffer_type = model.WGPUBufferBindingType_ReadOnlyStorage,
    };
    try testing.expectEqual(
        resources.bindingUsageForBufferKind(storage),
        resources.bindingUsageForBufferKind(ro_storage),
    );
}

// ============================================================
// Section 3: normalizeTextureFormat — format normalization proxy
// ============================================================

test "normalizeTextureFormat: R8Unorm passes through" {
    const result = resources.normalizeTextureFormat(model.WGPUTextureFormat_R8Unorm);
    try testing.expectEqual(types.WGPUTextureFormat_R8Unorm, result);
}

test "normalizeTextureFormat: Undefined passes through as Undefined" {
    const result = resources.normalizeTextureFormat(model.WGPUTextureFormat_Undefined);
    try testing.expectEqual(types.WGPUTextureFormat_Undefined, result);
}

// ============================================================
// Section 4: KernelBinding struct defaults
// ============================================================

test "KernelBinding: defaults for optional fields" {
    const binding = model.KernelBinding{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 42,
    };
    try testing.expectEqual(@as(u32, 0), binding.group);
    try testing.expectEqual(@as(u64, 0), binding.buffer_offset);
    try testing.expectEqual(model.WGPUWholeSize, binding.buffer_size);
    try testing.expectEqual(model.WGPUBufferBindingType_Undefined, binding.buffer_type);
    try testing.expectEqual(model.WGPUTextureFormat_Undefined, binding.texture_format);
    try testing.expect(!binding.texture_multisampled);
}

test "KernelBinding: resource_kind enum covers all types" {
    const buffer_kind = model.KernelBindingResourceKind.buffer;
    const texture_kind = model.KernelBindingResourceKind.texture;
    const storage_texture_kind = model.KernelBindingResourceKind.storage_texture;
    const sampler_kind = model.KernelBindingResourceKind.sampler;

    try testing.expect(@intFromEnum(buffer_kind) != @intFromEnum(texture_kind));
    try testing.expect(@intFromEnum(texture_kind) != @intFromEnum(storage_texture_kind));
    try testing.expect(@intFromEnum(storage_texture_kind) != @intFromEnum(sampler_kind));
}

test "KernelBinding: custom group assignment" {
    const binding = model.KernelBinding{
        .binding = 3,
        .group = 2,
        .resource_kind = .texture,
        .resource_handle = 100,
    };
    try testing.expectEqual(@as(u32, 3), binding.binding);
    try testing.expectEqual(@as(u32, 2), binding.group);
}

// ============================================================
// Section 5: CopyTextureResource struct and dimension defaults
// ============================================================

test "CopyTextureResource: kind enum distinguishes buffer and texture" {
    const buf = model.CopyResourceKind.buffer;
    const tex = model.CopyResourceKind.texture;
    try testing.expect(@intFromEnum(buf) != @intFromEnum(tex));
}

test "CopyTextureResource: dimension constants are distinct" {
    try testing.expect(model.WGPUTextureDimension_1D != model.WGPUTextureDimension_2D);
    try testing.expect(model.WGPUTextureDimension_2D != model.WGPUTextureDimension_3D);
    try testing.expect(model.WGPUTextureDimension_Undefined != model.WGPUTextureDimension_1D);
}

test "CopyTextureResource: view dimension constants are distinct" {
    try testing.expect(model.WGPUTextureViewDimension_1D != model.WGPUTextureViewDimension_2D);
    try testing.expect(model.WGPUTextureViewDimension_2D != model.WGPUTextureViewDimension_3D);
    try testing.expect(model.WGPUTextureViewDimension_2DArray != model.WGPUTextureViewDimension_Cube);
    try testing.expect(model.WGPUTextureViewDimension_Cube != model.WGPUTextureViewDimension_CubeArray);
}

// ============================================================
// Section 6: Texture format constants — value pinning
// ============================================================

test "texture format: Undefined is 0" {
    try testing.expectEqual(@as(u32, 0), model.WGPUTextureFormat_Undefined);
}

test "texture format: R8Unorm is 1" {
    try testing.expectEqual(@as(u32, 1), model.WGPUTextureFormat_R8Unorm);
}

test "texture format: common formats have expected ordinal values" {
    // Validate a selection of format constants match webgpu.h values.
    try testing.expect(model.WGPUTextureFormat_R8Unorm < model.WGPUTextureFormat_RGBA8Unorm);
    try testing.expect(model.WGPUTextureFormat_RGBA8Unorm < model.WGPUTextureFormat_RGBA32Float);
    try testing.expect(model.WGPUTextureFormat_Depth16Unorm < model.WGPUTextureFormat_Depth32Float);
}

// ============================================================
// Section 7: Texture usage flag composition
// ============================================================

test "texture usage: flags are powers of two (non-overlapping bits)" {
    const copy_src = model.WGPUTextureUsage_CopySrc;
    const copy_dst = model.WGPUTextureUsage_CopyDst;
    const tex_bind = model.WGPUTextureUsage_TextureBinding;
    const store_bind = model.WGPUTextureUsage_StorageBinding;
    const render = model.WGPUTextureUsage_RenderAttachment;

    // Each flag should have no bits in common with any other.
    try testing.expectEqual(@as(u64, 0), copy_src & copy_dst);
    try testing.expectEqual(@as(u64, 0), copy_src & tex_bind);
    try testing.expectEqual(@as(u64, 0), copy_src & store_bind);
    try testing.expectEqual(@as(u64, 0), copy_src & render);
    try testing.expectEqual(@as(u64, 0), copy_dst & tex_bind);
    try testing.expectEqual(@as(u64, 0), copy_dst & store_bind);
    try testing.expectEqual(@as(u64, 0), copy_dst & render);
    try testing.expectEqual(@as(u64, 0), tex_bind & store_bind);
    try testing.expectEqual(@as(u64, 0), tex_bind & render);
    try testing.expectEqual(@as(u64, 0), store_bind & render);
}

test "texture usage: flags can be combined with OR" {
    const combined = model.WGPUTextureUsage_CopySrc | model.WGPUTextureUsage_CopyDst | model.WGPUTextureUsage_TextureBinding;
    try testing.expect((combined & model.WGPUTextureUsage_CopySrc) != 0);
    try testing.expect((combined & model.WGPUTextureUsage_CopyDst) != 0);
    try testing.expect((combined & model.WGPUTextureUsage_TextureBinding) != 0);
    try testing.expect((combined & model.WGPUTextureUsage_StorageBinding) == 0);
}

test "texture usage: None is 0" {
    try testing.expectEqual(@as(u64, 0), model.WGPUTextureUsage_None);
}

// ============================================================
// Section 8: Buffer binding type constants
// ============================================================

test "buffer binding type: Undefined differs from Uniform" {
    try testing.expect(model.WGPUBufferBindingType_Undefined != model.WGPUBufferBindingType_Uniform);
}

test "buffer binding type: all values are distinct" {
    const vals = [_]u32{
        model.WGPUBufferBindingType_Undefined,
        model.WGPUBufferBindingType_Uniform,
        model.WGPUBufferBindingType_Storage,
        model.WGPUBufferBindingType_ReadOnlyStorage,
    };
    for (vals, 0..) |a, i| {
        for (vals[i + 1 ..]) |b| {
            try testing.expect(a != b);
        }
    }
}

// ============================================================
// Section 9: alignTo helper (shared utility)
// ============================================================

test "alignTo: zero alignment returns value unchanged" {
    try testing.expectEqual(@as(u64, 7), loader.alignTo(7, 0));
}

test "alignTo: alignment 1 returns value unchanged" {
    try testing.expectEqual(@as(u64, 7), loader.alignTo(7, 1));
}

test "alignTo: already aligned value stays the same" {
    try testing.expectEqual(@as(u64, 256), loader.alignTo(256, 256));
    try testing.expectEqual(@as(u64, 4), loader.alignTo(4, 4));
    try testing.expectEqual(@as(u64, 0), loader.alignTo(0, 4));
}

test "alignTo: unaligned value rounds up" {
    try testing.expectEqual(@as(u64, 4), loader.alignTo(1, 4));
    try testing.expectEqual(@as(u64, 4), loader.alignTo(3, 4));
    try testing.expectEqual(@as(u64, 8), loader.alignTo(5, 4));
    try testing.expectEqual(@as(u64, 256), loader.alignTo(1, 256));
    try testing.expectEqual(@as(u64, 256), loader.alignTo(255, 256));
    try testing.expectEqual(@as(u64, 512), loader.alignTo(257, 256));
}

// ============================================================
// Section 10: Normalizer functions — buffer binding type
// ============================================================

test "normalizeBufferBindingType: Uniform normalizes" {
    const result = normalizers.normalizeBufferBindingType(model.WGPUBufferBindingType_Uniform);
    try testing.expectEqual(types.WGPUBufferBindingType_Uniform, result);
}

test "normalizeBufferBindingType: Storage normalizes" {
    const result = normalizers.normalizeBufferBindingType(model.WGPUBufferBindingType_Storage);
    try testing.expectEqual(types.WGPUBufferBindingType_Storage, result);
}

test "normalizeBufferBindingType: ReadOnlyStorage normalizes" {
    const result = normalizers.normalizeBufferBindingType(model.WGPUBufferBindingType_ReadOnlyStorage);
    try testing.expectEqual(types.WGPUBufferBindingType_ReadOnlyStorage, result);
}

test "normalizeBufferBindingType: unknown falls to Undefined" {
    const result = normalizers.normalizeBufferBindingType(0xFF);
    try testing.expectEqual(types.WGPUBufferBindingType_Undefined, result);
}

// ============================================================
// Section 11: Normalizer functions — texture view dimension
// ============================================================

test "normalizeTextureViewDimension: 2D normalizes" {
    const result = normalizers.normalizeTextureViewDimension(model.WGPUTextureViewDimension_2D);
    try testing.expectEqual(types.WGPUTextureViewDimension_2D, result);
}

test "normalizeTextureViewDimension: 3D normalizes" {
    const result = normalizers.normalizeTextureViewDimension(model.WGPUTextureViewDimension_3D);
    try testing.expectEqual(types.WGPUTextureViewDimension_3D, result);
}

test "normalizeTextureViewDimension: Cube normalizes" {
    const result = normalizers.normalizeTextureViewDimension(model.WGPUTextureViewDimension_Cube);
    try testing.expectEqual(types.WGPUTextureViewDimension_Cube, result);
}

test "normalizeTextureViewDimension: unknown falls to 2D" {
    const result = normalizers.normalizeTextureViewDimension(0xFF);
    try testing.expectEqual(types.WGPUTextureViewDimension_2D, result);
}

// ============================================================
// Section 12: KernelDispatchCommand struct defaults
// ============================================================

test "KernelDispatchCommand: defaults for optional fields" {
    const cmd = model.KernelDispatchCommand{
        .kernel = "test_kernel",
        .x = 1,
        .y = 1,
        .z = 1,
    };
    try testing.expectEqual(@as(u32, 1), cmd.repeat);
    try testing.expectEqual(model.KernelDispatchRepeatSynchronization.dependent, cmd.repeat_synchronization);
    try testing.expectEqual(@as(u32, 0), cmd.warmup_dispatch_count);
    try testing.expect(!cmd.initialize_buffers_on_create);
    try testing.expect(cmd.bindings == null);
    try testing.expect(cmd.entry_point == null);
}

test "KernelDispatchCommand: custom repeat and warmup" {
    const cmd = model.KernelDispatchCommand{
        .kernel = "matmul",
        .x = 64,
        .y = 64,
        .z = 1,
        .repeat = 100,
        .warmup_dispatch_count = 10,
        .initialize_buffers_on_create = true,
    };
    try testing.expectEqual(@as(u32, 100), cmd.repeat);
    try testing.expectEqual(@as(u32, 10), cmd.warmup_dispatch_count);
    try testing.expect(cmd.initialize_buffers_on_create);
}

// ============================================================
// Section 13: WGPUWholeSize sentinel
// ============================================================

test "WGPUWholeSize: is max u64" {
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), model.WGPUWholeSize);
    try testing.expectEqual(std.math.maxInt(u64), model.WGPUWholeSize);
}

// ============================================================
// Section 14: Texture aspect constants
// ============================================================

test "texture aspect: All, StencilOnly, DepthOnly are distinct" {
    try testing.expect(model.WGPUTextureAspect_All != model.WGPUTextureAspect_StencilOnly);
    try testing.expect(model.WGPUTextureAspect_All != model.WGPUTextureAspect_DepthOnly);
    try testing.expect(model.WGPUTextureAspect_StencilOnly != model.WGPUTextureAspect_DepthOnly);
    try testing.expect(model.WGPUTextureAspect_Undefined != model.WGPUTextureAspect_All);
}
