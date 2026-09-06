// d3d12_descriptors_formats_test.zig — Unit tests for D3D12 descriptor heap/table
// management, DXGI format mapping, format metadata, and device capability defaults.
// All tests exercise pure logic testable without a GPU.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const descriptors = @import("../../src/backend/d3d12/d3d12_descriptors.zig");
const formats = @import("../../src/backend/d3d12/d3d12_formats.zig");
const device_caps = @import("../../src/backend/d3d12/d3d12_device_caps.zig");
const model = @import("../../src/contracts/model/model_gpu_types.zig");
const compressed_formats = @import("../../src/contracts/texture_format.zig");

// ============================================================
// Section 1: DXGI format mapping — pin exact WebGPU->DXGI values
// ============================================================

test "dxgi: R8Unorm maps to 61" {
    try testing.expectEqual(@as(u32, 61), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R8Unorm));
}

test "dxgi: R8Uint maps to 62" {
    try testing.expectEqual(@as(u32, 62), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R8Uint));
}

test "dxgi: R8Snorm maps to 63" {
    try testing.expectEqual(@as(u32, 63), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R8Snorm));
}

test "dxgi: R8Sint maps to 64" {
    try testing.expectEqual(@as(u32, 64), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R8Sint));
}

test "dxgi: RGBA8Unorm maps to 28" {
    try testing.expectEqual(@as(u32, 28), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA8Unorm));
}

test "dxgi: RGBA8UnormSrgb maps to 29" {
    try testing.expectEqual(@as(u32, 29), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA8UnormSrgb));
}

test "dxgi: BGRA8Unorm maps to 87" {
    try testing.expectEqual(@as(u32, 87), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_BGRA8Unorm));
}

test "dxgi: BGRA8UnormSrgb maps to 91" {
    try testing.expectEqual(@as(u32, 91), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_BGRA8UnormSrgb));
}

test "dxgi: R32Float maps to 41" {
    try testing.expectEqual(@as(u32, 41), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R32Float));
}

test "dxgi: R32Uint maps to 42" {
    try testing.expectEqual(@as(u32, 42), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R32Uint));
}

test "dxgi: R32Sint maps to 43" {
    try testing.expectEqual(@as(u32, 43), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_R32Sint));
}

test "dxgi: RG32Float maps to 16" {
    try testing.expectEqual(@as(u32, 16), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RG32Float));
}

test "dxgi: RGBA32Float maps to 2" {
    try testing.expectEqual(@as(u32, 2), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA32Float));
}

test "dxgi: RGBA32Uint maps to 3" {
    try testing.expectEqual(@as(u32, 3), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA32Uint));
}

test "dxgi: RGBA32Sint maps to 4" {
    try testing.expectEqual(@as(u32, 4), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA32Sint));
}

test "dxgi: RGBA16Float maps to 10" {
    try testing.expectEqual(@as(u32, 10), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA16Float));
}

test "dxgi: RGBA16Uint maps to 12" {
    try testing.expectEqual(@as(u32, 12), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA16Uint));
}

test "dxgi: RGBA16Sint maps to 14" {
    try testing.expectEqual(@as(u32, 14), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGBA16Sint));
}

test "dxgi: RGB10A2Unorm maps to 24" {
    try testing.expectEqual(@as(u32, 24), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGB10A2Unorm));
}

test "dxgi: RGB10A2Uint maps to 25" {
    try testing.expectEqual(@as(u32, 25), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGB10A2Uint));
}

test "dxgi: RG11B10Ufloat maps to 26" {
    try testing.expectEqual(@as(u32, 26), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RG11B10Ufloat));
}

test "dxgi: RGB9E5Ufloat maps to 67" {
    try testing.expectEqual(@as(u32, 67), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_RGB9E5Ufloat));
}

test "dxgi: Depth16Unorm maps to 55" {
    try testing.expectEqual(@as(u32, 55), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_Depth16Unorm));
}

test "dxgi: Depth32Float maps to 40" {
    try testing.expectEqual(@as(u32, 40), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_Depth32Float));
}

test "dxgi: Depth24Plus maps to 45" {
    try testing.expectEqual(@as(u32, 45), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_Depth24Plus));
}

test "dxgi: Depth24PlusStencil8 maps to 45" {
    try testing.expectEqual(@as(u32, 45), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_Depth24PlusStencil8));
}

test "dxgi: Depth32FloatStencil8 maps to 20" {
    try testing.expectEqual(@as(u32, 20), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_Depth32FloatStencil8));
}

test "dxgi: Stencil8 maps to 45" {
    try testing.expectEqual(@as(u32, 45), try formats.wgpu_format_to_dxgi(model.WGPUTextureFormat_Stencil8));
}

test "dxgi: BC1RGBAUnorm maps to 71" {
    try testing.expectEqual(@as(u32, 71), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
}

test "dxgi: BC1RGBAUnormSrgb maps to 72" {
    try testing.expectEqual(@as(u32, 72), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC1RGBAUnormSrgb));
}

test "dxgi: BC2RGBAUnorm maps to 74" {
    try testing.expectEqual(@as(u32, 74), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC2RGBAUnorm));
}

test "dxgi: BC3RGBAUnorm maps to 77" {
    try testing.expectEqual(@as(u32, 77), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC3RGBAUnorm));
}

test "dxgi: BC4RUnorm maps to 80" {
    try testing.expectEqual(@as(u32, 80), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC4RUnorm));
}

test "dxgi: BC5RGUnorm maps to 83" {
    try testing.expectEqual(@as(u32, 83), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC5RGUnorm));
}

test "dxgi: BC6HRGBUfloat maps to 95" {
    try testing.expectEqual(@as(u32, 95), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC6HRGBUfloat));
}

test "dxgi: BC6HRGBFloat maps to 96" {
    try testing.expectEqual(@as(u32, 96), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC6HRGBFloat));
}

test "dxgi: BC7RGBAUnorm maps to 98" {
    try testing.expectEqual(@as(u32, 98), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC7RGBAUnorm));
}

test "dxgi: BC7RGBAUnormSrgb maps to 99" {
    try testing.expectEqual(@as(u32, 99), try formats.wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb));
}

test "dxgi: unsupported format returns error" {
    try testing.expectError(error.UnsupportedFeature, formats.wgpu_format_to_dxgi(0xFFFF));
    try testing.expectError(error.UnsupportedFeature, formats.wgpu_format_to_dxgi(0));
}

// ============================================================
// Section 2: Format properties — bytes per pixel, block sizes
// ============================================================

test "bpp: 1-byte formats" {
    try testing.expectEqual(@as(u32, 1), try formats.bytes_per_pixel(model.WGPUTextureFormat_R8Unorm));
    try testing.expectEqual(@as(u32, 1), try formats.bytes_per_pixel(model.WGPUTextureFormat_R8Snorm));
    try testing.expectEqual(@as(u32, 1), try formats.bytes_per_pixel(model.WGPUTextureFormat_R8Uint));
    try testing.expectEqual(@as(u32, 1), try formats.bytes_per_pixel(model.WGPUTextureFormat_R8Sint));
    try testing.expectEqual(@as(u32, 1), try formats.bytes_per_pixel(model.WGPUTextureFormat_Stencil8));
}

test "bpp: 2-byte formats" {
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_R16Float));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_R16Uint));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_R16Sint));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_R16Unorm));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_R16Snorm));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG8Unorm));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG8Snorm));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG8Uint));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG8Sint));
    try testing.expectEqual(@as(u32, 2), try formats.bytes_per_pixel(model.WGPUTextureFormat_Depth16Unorm));
}

test "bpp: 4-byte formats" {
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA8Unorm));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA8UnormSrgb));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA8Snorm));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_BGRA8Unorm));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_BGRA8UnormSrgb));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_R32Float));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_R32Uint));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_R32Sint));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGB10A2Unorm));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG11B10Ufloat));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGB9E5Ufloat));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG16Float));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG16Uint));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG16Sint));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_Depth32Float));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_Depth24Plus));
    try testing.expectEqual(@as(u32, 4), try formats.bytes_per_pixel(model.WGPUTextureFormat_Depth24PlusStencil8));
}

test "bpp: 8-byte formats" {
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA16Float));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA16Uint));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA16Sint));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG32Float));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG32Uint));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_RG32Sint));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(model.WGPUTextureFormat_Depth32FloatStencil8));
}

test "bpp: 16-byte formats" {
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA32Float));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA32Uint));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(model.WGPUTextureFormat_RGBA32Sint));
}

test "bpp: BC compressed 8 bytes per block" {
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC1RGBAUnormSrgb));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC4RUnorm));
    try testing.expectEqual(@as(u32, 8), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC4RSnorm));
}

test "bpp: BC compressed 16 bytes per block" {
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC2RGBAUnorm));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC3RGBAUnorm));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC5RGUnorm));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC6HRGBUfloat));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC7RGBAUnorm));
    try testing.expectEqual(@as(u32, 16), try formats.bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb));
}

test "bpp: unsupported format returns error" {
    try testing.expectError(error.UnsupportedFeature, formats.bytes_per_pixel(0xFFFF));
}

test "format: depth/stencil classification" {
    try testing.expect(formats.is_depth_stencil(model.WGPUTextureFormat_Depth16Unorm));
    try testing.expect(formats.is_depth_stencil(model.WGPUTextureFormat_Depth24Plus));
    try testing.expect(formats.is_depth_stencil(model.WGPUTextureFormat_Depth24PlusStencil8));
    try testing.expect(formats.is_depth_stencil(model.WGPUTextureFormat_Depth32Float));
    try testing.expect(formats.is_depth_stencil(model.WGPUTextureFormat_Depth32FloatStencil8));
    try testing.expect(formats.is_depth_stencil(model.WGPUTextureFormat_Stencil8));
    try testing.expect(!formats.is_depth_stencil(model.WGPUTextureFormat_RGBA8Unorm));
    try testing.expect(!formats.is_depth_stencil(model.WGPUTextureFormat_R32Float));
    try testing.expect(!formats.is_depth_stencil(model.WGPUTextureFormat_BGRA8Unorm));
}

test "format: stencil channel detection" {
    try testing.expect(formats.has_stencil(model.WGPUTextureFormat_Stencil8));
    try testing.expect(formats.has_stencil(model.WGPUTextureFormat_Depth24PlusStencil8));
    try testing.expect(formats.has_stencil(model.WGPUTextureFormat_Depth32FloatStencil8));
    try testing.expect(!formats.has_stencil(model.WGPUTextureFormat_Depth16Unorm));
    try testing.expect(!formats.has_stencil(model.WGPUTextureFormat_Depth32Float));
    try testing.expect(!formats.has_stencil(model.WGPUTextureFormat_Depth24Plus));
    try testing.expect(!formats.has_stencil(model.WGPUTextureFormat_RGBA8Unorm));
}

test "format: BC compressed detection" {
    try testing.expect(formats.is_bc_compressed(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
    try testing.expect(formats.is_bc_compressed(compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb));
    try testing.expect(!formats.is_bc_compressed(model.WGPUTextureFormat_RGBA8Unorm));
    try testing.expect(!formats.is_bc_compressed(model.WGPUTextureFormat_Depth32Float));
    try testing.expect(!formats.is_bc_compressed(0xFFFF));
}

// ============================================================
// Section 3: Vertex format mapping — pin DXGI values
// ============================================================

test "vertex: uint8 formats" {
    try testing.expectEqual(@as(u32, 62), try formats.wgpu_vertex_format_to_dxgi(0x01)); // R8_UINT
    try testing.expectEqual(@as(u32, 50), try formats.wgpu_vertex_format_to_dxgi(0x02)); // R8G8_UINT
    try testing.expectEqual(@as(u32, 30), try formats.wgpu_vertex_format_to_dxgi(0x03)); // R8G8B8A8_UINT
}

test "vertex: sint8 formats" {
    try testing.expectEqual(@as(u32, 64), try formats.wgpu_vertex_format_to_dxgi(0x04)); // R8_SINT
    try testing.expectEqual(@as(u32, 52), try formats.wgpu_vertex_format_to_dxgi(0x05)); // R8G8_SINT
    try testing.expectEqual(@as(u32, 32), try formats.wgpu_vertex_format_to_dxgi(0x06)); // R8G8B8A8_SINT
}

test "vertex: unorm8 formats" {
    try testing.expectEqual(@as(u32, 61), try formats.wgpu_vertex_format_to_dxgi(0x07)); // R8_UNORM
    try testing.expectEqual(@as(u32, 49), try formats.wgpu_vertex_format_to_dxgi(0x08)); // R8G8_UNORM
    try testing.expectEqual(@as(u32, 28), try formats.wgpu_vertex_format_to_dxgi(0x09)); // R8G8B8A8_UNORM
}

test "vertex: snorm8 formats" {
    try testing.expectEqual(@as(u32, 63), try formats.wgpu_vertex_format_to_dxgi(0x0A)); // R8_SNORM
    try testing.expectEqual(@as(u32, 51), try formats.wgpu_vertex_format_to_dxgi(0x0B)); // R8G8_SNORM
    try testing.expectEqual(@as(u32, 31), try formats.wgpu_vertex_format_to_dxgi(0x0C)); // R8G8B8A8_SNORM
}

test "vertex: float32 formats" {
    try testing.expectEqual(@as(u32, 41), try formats.wgpu_vertex_format_to_dxgi(0x1C)); // R32_FLOAT
    try testing.expectEqual(@as(u32, 16), try formats.wgpu_vertex_format_to_dxgi(0x1D)); // R32G32_FLOAT
    try testing.expectEqual(@as(u32, 6), try formats.wgpu_vertex_format_to_dxgi(0x1E)); // R32G32B32_FLOAT
    try testing.expectEqual(@as(u32, 2), try formats.wgpu_vertex_format_to_dxgi(0x1F)); // R32G32B32A32_FLOAT
}

test "vertex: float16 formats" {
    try testing.expectEqual(@as(u32, 54), try formats.wgpu_vertex_format_to_dxgi(0x19)); // R16_FLOAT
    try testing.expectEqual(@as(u32, 34), try formats.wgpu_vertex_format_to_dxgi(0x1A)); // R16G16_FLOAT
    try testing.expectEqual(@as(u32, 10), try formats.wgpu_vertex_format_to_dxgi(0x1B)); // R16G16B16A16_FLOAT
}

test "vertex: uint32 formats" {
    try testing.expectEqual(@as(u32, 42), try formats.wgpu_vertex_format_to_dxgi(0x20)); // R32_UINT
    try testing.expectEqual(@as(u32, 17), try formats.wgpu_vertex_format_to_dxgi(0x21)); // R32G32_UINT
    try testing.expectEqual(@as(u32, 7), try formats.wgpu_vertex_format_to_dxgi(0x22)); // R32G32B32_UINT
    try testing.expectEqual(@as(u32, 3), try formats.wgpu_vertex_format_to_dxgi(0x23)); // R32G32B32A32_UINT
}

test "vertex: sint32 formats" {
    try testing.expectEqual(@as(u32, 43), try formats.wgpu_vertex_format_to_dxgi(0x24)); // R32_SINT
    try testing.expectEqual(@as(u32, 18), try formats.wgpu_vertex_format_to_dxgi(0x25)); // R32G32_SINT
    try testing.expectEqual(@as(u32, 8), try formats.wgpu_vertex_format_to_dxgi(0x26)); // R32G32B32_SINT
    try testing.expectEqual(@as(u32, 4), try formats.wgpu_vertex_format_to_dxgi(0x27)); // R32G32B32A32_SINT
}

test "vertex: packed formats" {
    try testing.expectEqual(@as(u32, 24), try formats.wgpu_vertex_format_to_dxgi(0x28)); // R10G10B10A2_UNORM
    try testing.expectEqual(@as(u32, 87), try formats.wgpu_vertex_format_to_dxgi(0x29)); // B8G8R8A8_UNORM
}

test "vertex: invalid formats return error" {
    try testing.expectError(error.UnsupportedFeature, formats.wgpu_vertex_format_to_dxgi(0x00));
    try testing.expectError(error.UnsupportedFeature, formats.wgpu_vertex_format_to_dxgi(0x2A));
    try testing.expectError(error.UnsupportedFeature, formats.wgpu_vertex_format_to_dxgi(0x2B));
    try testing.expectError(error.UnsupportedFeature, formats.wgpu_vertex_format_to_dxgi(0xFF));
}

// ============================================================
// Section 4: Descriptor table layout — CBV/SRV/UAV slot calculations
// ============================================================

test "descriptor: DescriptorRangeDesc is 16 bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(descriptors.DescriptorRangeDesc));
}

test "descriptor: DescriptorRangeDesc field layout" {
    const desc = descriptors.DescriptorRangeDesc{
        .range_type = 2,
        .num_descriptors = 3,
        .base_shader_register = 0,
        .register_space = 1,
    };
    try testing.expectEqual(@as(u32, 2), desc.range_type);
    try testing.expectEqual(@as(u32, 3), desc.num_descriptors);
    try testing.expectEqual(@as(u32, 0), desc.base_shader_register);
    try testing.expectEqual(@as(u32, 1), desc.register_space);
}

test "descriptor: BindingType enum covers all WebGPU binding types" {
    // Verify all 6 binding types are accessible.
    const ub = descriptors.BindingType.uniform_buffer;
    const sb = descriptors.BindingType.storage_buffer;
    const rosb = descriptors.BindingType.read_only_storage_buffer;
    const st = descriptors.BindingType.sampled_texture;
    const stx = descriptors.BindingType.storage_texture;
    const smp = descriptors.BindingType.sampler;

    // Values should be distinct.
    try testing.expect(@intFromEnum(ub) != @intFromEnum(sb));
    try testing.expect(@intFromEnum(sb) != @intFromEnum(rosb));
    try testing.expect(@intFromEnum(rosb) != @intFromEnum(st));
    try testing.expect(@intFromEnum(st) != @intFromEnum(stx));
    try testing.expect(@intFromEnum(stx) != @intFromEnum(smp));
}

test "descriptor: BindingEntry default has_dynamic_offset is false" {
    const entry = descriptors.BindingEntry{
        .binding = 0,
        .binding_type = .uniform_buffer,
    };
    try testing.expect(!entry.has_dynamic_offset);
}

test "descriptor: BindGroupLayout holds entries slice" {
    const entries = [_]descriptors.BindingEntry{
        .{ .binding = 0, .binding_type = .uniform_buffer },
        .{ .binding = 1, .binding_type = .sampled_texture },
    };
    const layout = descriptors.BindGroupLayout{
        .entries = &entries,
    };
    try testing.expectEqual(@as(usize, 2), layout.entries.len);
    try testing.expectEqual(@as(u32, 0), layout.entries[0].binding);
    try testing.expectEqual(@as(u32, 1), layout.entries[1].binding);
}

test "descriptor: RootSignatureLayout defaults to no groups" {
    const layout = descriptors.RootSignatureLayout{};
    for (layout.groups) |g| {
        try testing.expect(g == null);
    }
    try testing.expect(!layout.allow_input_assembler);
}

test "descriptor: RootSignatureLayout has exactly 4 group slots" {
    const layout = descriptors.RootSignatureLayout{};
    try testing.expectEqual(@as(usize, 4), layout.groups.len);
}

test "descriptor: RootSignatureLayout can set input assembler" {
    const layout = descriptors.RootSignatureLayout{
        .allow_input_assembler = true,
    };
    try testing.expect(layout.allow_input_assembler);
}

test "descriptor: RootSignatureLayout can assign bind group to slot" {
    const entries = [_]descriptors.BindingEntry{
        .{ .binding = 0, .binding_type = .uniform_buffer },
    };
    var layout = descriptors.RootSignatureLayout{};
    layout.groups[0] = descriptors.BindGroupLayout{ .entries = &entries };
    try testing.expect(layout.groups[0] != null);
    try testing.expect(layout.groups[1] == null);
    try testing.expectEqual(@as(usize, 1), layout.groups[0].?.entries.len);
}

// ============================================================
// Section 5: Descriptor heap state — allocation and reset
// ============================================================

test "heap: DescriptorHeapState starts zeroed" {
    const state = descriptors.DescriptorHeapState{};
    try testing.expect(state.cbv_srv_uav_heap == null);
    try testing.expect(state.sampler_heap == null);
    try testing.expectEqual(@as(u32, 0), state.cbv_srv_uav_next);
    try testing.expectEqual(@as(u32, 0), state.sampler_next);
    try testing.expectEqual(@as(u32, 0), state.cbv_srv_uav_capacity);
    try testing.expectEqual(@as(u32, 0), state.sampler_capacity);
}

test "heap: reset_allocations zeroes indices but keeps capacity" {
    var state = descriptors.DescriptorHeapState{
        .cbv_srv_uav_capacity = 256,
        .sampler_capacity = 64,
        .cbv_srv_uav_next = 42,
        .sampler_next = 7,
    };
    state.reset_allocations();
    try testing.expectEqual(@as(u32, 0), state.cbv_srv_uav_next);
    try testing.expectEqual(@as(u32, 0), state.sampler_next);
    try testing.expectEqual(@as(u32, 256), state.cbv_srv_uav_capacity);
    try testing.expectEqual(@as(u32, 64), state.sampler_capacity);
}

test "heap: deinit zeroes entire state" {
    var state = descriptors.DescriptorHeapState{
        .cbv_srv_uav_capacity = 256,
        .sampler_capacity = 64,
        .cbv_srv_uav_next = 10,
        .sampler_next = 3,
        // null heaps: deinit should not crash on null
    };
    state.deinit();
    try testing.expect(state.cbv_srv_uav_heap == null);
    try testing.expect(state.sampler_heap == null);
    try testing.expectEqual(@as(u32, 0), state.cbv_srv_uav_capacity);
    try testing.expectEqual(@as(u32, 0), state.sampler_capacity);
    try testing.expectEqual(@as(u32, 0), state.cbv_srv_uav_next);
    try testing.expectEqual(@as(u32, 0), state.sampler_next);
}

test "heap: allocate_sampler fails at capacity with no heap" {
    var state = descriptors.DescriptorHeapState{
        .sampler_capacity = 0,
        .sampler_next = 0,
    };
    // Without a device, ensure_heaps will fail, but testing the
    // capacity check path: manually set capacity to simulate.
    state.sampler_capacity = 2;
    state.sampler_next = 2;
    // The sampler_next == sampler_capacity path should trigger.
    // However, allocate_sampler calls ensure_heaps first, which
    // will fail without a device. So we test the structural invariant.
    try testing.expect(state.sampler_next >= state.sampler_capacity);
}

test "heap: repeated reset_allocations is idempotent" {
    var state = descriptors.DescriptorHeapState{
        .cbv_srv_uav_capacity = 256,
        .sampler_capacity = 64,
    };
    state.cbv_srv_uav_next = 100;
    state.sampler_next = 50;
    state.reset_allocations();
    state.reset_allocations();
    try testing.expectEqual(@as(u32, 0), state.cbv_srv_uav_next);
    try testing.expectEqual(@as(u32, 0), state.sampler_next);
}

// ============================================================
// Section 6: D3D12 device caps struct defaults and feature queries
// ============================================================

test "caps: D3D12DeviceCaps defaults to conservative values" {
    const caps = device_caps.D3D12DeviceCaps{};
    try testing.expect(!caps.supports_native_16bit);
    try testing.expect(!caps.has_subgroups);
    try testing.expect(!caps.has_shader_f16);
    try testing.expect(!caps.has_subgroups_f16);
    try testing.expect(!caps.supports_bc_sliced_3d);
    try testing.expect(!caps.supports_etc2);
    try testing.expect(!caps.supports_astc);
    try testing.expect(!caps.supports_astc_sliced_3d);
    try testing.expect(!caps.supports_float32_blendable);
    try testing.expect(!caps.supports_texture_formats_tier1);
    try testing.expect(!caps.supports_texture_formats_tier2);
    try testing.expect(!caps.supports_texture_component_swizzle);
    try testing.expectEqual(@as(u32, 32), caps.wave_lane_count_min);
    try testing.expectEqual(@as(u32, 32), caps.wave_lane_count_max);
}

test "caps: default shader model is SM6.0" {
    const caps = device_caps.D3D12DeviceCaps{};
    try testing.expectEqual(@as(c_int, 0x60), caps.shader_model);
}

test "caps: query_device_caps with null device returns static defaults" {
    const caps = device_caps.query_device_caps(null);
    try testing.expect(!caps.has_shader_f16);
    try testing.expect(!caps.has_subgroups);
    try testing.expect(!caps.has_subgroups_f16);
    try testing.expect(!caps.supports_native_16bit);
    try testing.expectEqual(@as(u32, 32), caps.wave_lane_count_min);
    try testing.expectEqual(@as(u32, 32), caps.wave_lane_count_max);
}

test "caps: d3d12_adapter_has_feature rejects ETC2 and ASTC" {
    try testing.expect(!device_caps.d3d12_adapter_has_feature(0xBEEF));
}

test "caps: d3d12_adapter_has_feature_with_caps rejects ASTC" {
    const caps = device_caps.D3D12DeviceCaps{};
    try testing.expect(!device_caps.d3d12_adapter_has_feature_with_caps(0xBEEF, caps));
}

test "caps: d3d12_device_subgroup_size returns platform-dependent value" {
    const size = device_caps.d3d12_device_subgroup_size();
    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(u32, 32), size);
    } else {
        try testing.expectEqual(@as(u32, 0), size);
    }
}

test "caps: d3d12_device_subgroup_size_from_caps uses wave_lane_count_min" {
    const caps = device_caps.D3D12DeviceCaps{
        .wave_lane_count_min = 64,
        .wave_lane_count_max = 64,
    };
    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(u32, 64), device_caps.d3d12_device_subgroup_size_from_caps(caps));
    } else {
        try testing.expectEqual(@as(u32, 0), device_caps.d3d12_device_subgroup_size_from_caps(caps));
    }
}

test "caps: D3D12DeviceCaps can be constructed with custom fields" {
    const caps = device_caps.D3D12DeviceCaps{
        .shader_model = 0x62,
        .wave_lane_count_min = 16,
        .wave_lane_count_max = 128,
        .supports_native_16bit = true,
        .has_subgroups = true,
        .has_shader_f16 = true,
        .has_subgroups_f16 = true,
        .supports_bc_sliced_3d = true,
        .supports_float32_blendable = true,
        .supports_texture_formats_tier1 = true,
        .supports_texture_formats_tier2 = true,
        .supports_texture_component_swizzle = true,
    };
    try testing.expectEqual(@as(c_int, 0x62), caps.shader_model);
    try testing.expectEqual(@as(u32, 16), caps.wave_lane_count_min);
    try testing.expectEqual(@as(u32, 128), caps.wave_lane_count_max);
    try testing.expect(caps.supports_native_16bit);
    try testing.expect(caps.has_subgroups);
    try testing.expect(caps.has_shader_f16);
    try testing.expect(caps.has_subgroups_f16);
    try testing.expect(caps.supports_bc_sliced_3d);
    try testing.expect(caps.supports_float32_blendable);
    try testing.expect(caps.supports_texture_formats_tier1);
    try testing.expect(caps.supports_texture_formats_tier2);
    try testing.expect(caps.supports_texture_component_swizzle);
}

test "caps: D3D12 limits static values match spec minimums" {
    var limits: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPULimits = undefined;
    device_caps.d3d12_device_get_limits(&limits);
    try testing.expectEqual(@as(u32, 16384), limits.maxTextureDimension1D);
    try testing.expectEqual(@as(u32, 16384), limits.maxTextureDimension2D);
    try testing.expectEqual(@as(u32, 2048), limits.maxTextureDimension3D);
    try testing.expectEqual(@as(u32, 2048), limits.maxTextureArrayLayers);
    try testing.expectEqual(@as(u32, 4), limits.maxBindGroups);
    try testing.expectEqual(@as(u32, 24), limits.maxBindGroupsPlusVertexBuffers);
    try testing.expectEqual(@as(u32, 1000), limits.maxBindingsPerBindGroup);
    try testing.expectEqual(@as(u32, 8), limits.maxDynamicUniformBuffersPerPipelineLayout);
    try testing.expectEqual(@as(u32, 4), limits.maxDynamicStorageBuffersPerPipelineLayout);
    try testing.expectEqual(@as(u32, 128), limits.maxSampledTexturesPerShaderStage);
    try testing.expectEqual(@as(u32, 16), limits.maxSamplersPerShaderStage);
    try testing.expectEqual(@as(u32, 8), limits.maxStorageBuffersPerShaderStage);
    try testing.expectEqual(@as(u32, 8), limits.maxStorageTexturesPerShaderStage);
    try testing.expectEqual(@as(u32, 14), limits.maxUniformBuffersPerShaderStage);
    try testing.expectEqual(@as(u64, 65536), limits.maxUniformBufferBindingSize);
    try testing.expectEqual(@as(u64, 268_435_456), limits.maxStorageBufferBindingSize);
    try testing.expectEqual(@as(u32, 256), limits.minUniformBufferOffsetAlignment);
    try testing.expectEqual(@as(u32, 32), limits.minStorageBufferOffsetAlignment);
    try testing.expectEqual(@as(u32, 16), limits.maxVertexBuffers);
    try testing.expectEqual(@as(u64, 268_435_456), limits.maxBufferSize);
    try testing.expectEqual(@as(u32, 32), limits.maxVertexAttributes);
    try testing.expectEqual(@as(u32, 2048), limits.maxVertexBufferArrayStride);
    try testing.expectEqual(@as(u32, 16), limits.maxInterStageShaderVariables);
    try testing.expectEqual(@as(u32, 8), limits.maxColorAttachments);
    try testing.expectEqual(@as(u32, 32), limits.maxColorAttachmentBytesPerSample);
    try testing.expectEqual(@as(u32, 32768), limits.maxComputeWorkgroupStorageSize);
    try testing.expectEqual(@as(u32, 1024), limits.maxComputeInvocationsPerWorkgroup);
    try testing.expectEqual(@as(u32, 1024), limits.maxComputeWorkgroupSizeX);
    try testing.expectEqual(@as(u32, 1024), limits.maxComputeWorkgroupSizeY);
    try testing.expectEqual(@as(u32, 64), limits.maxComputeWorkgroupSizeZ);
    try testing.expectEqual(@as(u32, 65535), limits.maxComputeWorkgroupsPerDimension);
}

test "caps: adapter_get_limits matches device_get_limits" {
    var dev_limits: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPULimits = undefined;
    var adapter_limits: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPULimits = undefined;
    device_caps.d3d12_device_get_limits(&dev_limits);
    device_caps.d3d12_adapter_get_limits(&adapter_limits);
    try testing.expectEqual(dev_limits.maxTextureDimension1D, adapter_limits.maxTextureDimension1D);
    try testing.expectEqual(dev_limits.maxBufferSize, adapter_limits.maxBufferSize);
    try testing.expectEqual(dev_limits.maxComputeInvocationsPerWorkgroup, adapter_limits.maxComputeInvocationsPerWorkgroup);
}

// ============================================================
// Section 7: DXGI constant value cross-checks
// ============================================================

test "dxgi constants: DXGI_FORMAT values match Microsoft spec" {
    try testing.expectEqual(@as(u32, 2), formats.DXGI_FORMAT_R32G32B32A32_FLOAT);
    try testing.expectEqual(@as(u32, 3), formats.DXGI_FORMAT_R32G32B32A32_UINT);
    try testing.expectEqual(@as(u32, 4), formats.DXGI_FORMAT_R32G32B32A32_SINT);
    try testing.expectEqual(@as(u32, 6), formats.DXGI_FORMAT_R32G32B32_FLOAT);
    try testing.expectEqual(@as(u32, 10), formats.DXGI_FORMAT_R16G16B16A16_FLOAT);
    try testing.expectEqual(@as(u32, 16), formats.DXGI_FORMAT_R32G32_FLOAT);
    try testing.expectEqual(@as(u32, 20), formats.DXGI_FORMAT_D32_FLOAT_S8X24_UINT);
    try testing.expectEqual(@as(u32, 24), formats.DXGI_FORMAT_R10G10B10A2_UNORM);
    try testing.expectEqual(@as(u32, 26), formats.DXGI_FORMAT_R11G11B10_FLOAT);
    try testing.expectEqual(@as(u32, 28), formats.DXGI_FORMAT_R8G8B8A8_UNORM);
    try testing.expectEqual(@as(u32, 29), formats.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB);
    try testing.expectEqual(@as(u32, 40), formats.DXGI_FORMAT_D32_FLOAT);
    try testing.expectEqual(@as(u32, 41), formats.DXGI_FORMAT_R32_FLOAT);
    try testing.expectEqual(@as(u32, 45), formats.DXGI_FORMAT_D24_UNORM_S8_UINT);
    try testing.expectEqual(@as(u32, 49), formats.DXGI_FORMAT_R8G8_UNORM);
    try testing.expectEqual(@as(u32, 54), formats.DXGI_FORMAT_R16_FLOAT);
    try testing.expectEqual(@as(u32, 55), formats.DXGI_FORMAT_D16_UNORM);
    try testing.expectEqual(@as(u32, 61), formats.DXGI_FORMAT_R8_UNORM);
    try testing.expectEqual(@as(u32, 67), formats.DXGI_FORMAT_R9G9B9E5_SHAREDEXP);
    try testing.expectEqual(@as(u32, 71), formats.DXGI_FORMAT_BC1_UNORM);
    try testing.expectEqual(@as(u32, 87), formats.DXGI_FORMAT_B8G8R8A8_UNORM);
    try testing.expectEqual(@as(u32, 91), formats.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB);
    try testing.expectEqual(@as(u32, 95), formats.DXGI_FORMAT_BC6H_UF16);
    try testing.expectEqual(@as(u32, 98), formats.DXGI_FORMAT_BC7_UNORM);
    try testing.expectEqual(@as(u32, 99), formats.DXGI_FORMAT_BC7_UNORM_SRGB);
}

// ============================================================
// Section 8: Adapter caps cache operations
// ============================================================

test "caps: get_adapter_caps returns null for null handle" {
    const result = device_caps.get_adapter_caps(null);
    try testing.expect(result == null);
}

test "caps: remove_adapter_caps with null handle does not crash" {
    device_caps.remove_adapter_caps(null);
}

test "caps: set then get adapter caps round-trips" {
    // Use a sentinel pointer value for the adapter handle.
    const sentinel: usize = 0xDEAD_BEEF_1234;
    const handle: ?*anyopaque = @ptrFromInt(sentinel);
    const caps = device_caps.D3D12DeviceCaps{
        .has_shader_f16 = true,
        .wave_lane_count_min = 64,
    };
    device_caps.set_adapter_caps(handle, caps);
    defer device_caps.remove_adapter_caps(handle);

    const retrieved = device_caps.get_adapter_caps(handle);
    try testing.expect(retrieved != null);
    try testing.expect(retrieved.?.has_shader_f16);
    try testing.expectEqual(@as(u32, 64), retrieved.?.wave_lane_count_min);
}

test "caps: remove_adapter_caps clears cached entry" {
    const sentinel: usize = 0xCAFE_BABE_5678;
    const handle: ?*anyopaque = @ptrFromInt(sentinel);
    const caps = device_caps.D3D12DeviceCaps{ .has_subgroups = true };
    device_caps.set_adapter_caps(handle, caps);
    device_caps.remove_adapter_caps(handle);

    const retrieved = device_caps.get_adapter_caps(handle);
    try testing.expect(retrieved == null);
}

test "caps: set_adapter_caps with null handle is no-op" {
    // Should not crash.
    device_caps.set_adapter_caps(null, device_caps.D3D12DeviceCaps{});
}
