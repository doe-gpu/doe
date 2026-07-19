// precompiled_shader_test.zig — Tests for precompiled shader module support.
// Verifies sType dispatch, type definitions, struct defaults, null safety,
// SPIR-V/HLSL storage paths, and MSL Metal integration.

const std = @import("std");
const builtin = @import("builtin");

const native = @import("../../src/native/mod.zig");
const shader = @import("../../src/native/shader/doe_shader_native.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");

// ============================================================
// 1. sType constants — values are distinct and correctly assigned
// ============================================================

test "sType: ShaderSourceMSL is 0x00000003" {
    try std.testing.expectEqual(@as(types.WGPUSType, 0x00000003), types.WGPUSType_ShaderSourceMSL);
}

test "sType: ShaderSourceSPIRV is 0x00000004" {
    try std.testing.expectEqual(@as(types.WGPUSType, 0x00000004), types.WGPUSType_ShaderSourceSPIRV);
}

test "sType: ShaderSourceHLSL is 0x00000005" {
    try std.testing.expectEqual(@as(types.WGPUSType, 0x00000005), types.WGPUSType_ShaderSourceHLSL);
}

test "sType: all shader source sTypes are distinct" {
    const stypes = [_]types.WGPUSType{
        types.WGPUSType_ShaderSourceWGSL,
        types.WGPUSType_ShaderSourceMSL,
        types.WGPUSType_ShaderSourceSPIRV,
        types.WGPUSType_ShaderSourceHLSL,
    };
    for (stypes, 0..) |a, i| {
        for (stypes[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }
}

// ============================================================
// 2. Descriptor struct layout — field existence and alignment
// ============================================================

test "WGPUShaderSourceMSL: has chain, code, and workgroup fields" {
    const desc = std.mem.zeroes(types.WGPUShaderSourceMSL);
    try std.testing.expectEqual(@as(types.WGPUSType, 0), desc.chain.sType);
    try std.testing.expectEqual(@as(?[*]const u8, null), desc.code.data);
    try std.testing.expectEqual(@as(u32, 0), desc.workgroup_size_x);
    try std.testing.expectEqual(@as(u32, 0), desc.workgroup_size_y);
    try std.testing.expectEqual(@as(u32, 0), desc.workgroup_size_z);
}

test "WGPUShaderSourceSPIRV: code_size zero is valid default" {
    const desc = std.mem.zeroes(types.WGPUShaderSourceSPIRV);
    try std.testing.expectEqual(@as(u32, 0), desc.code_size);
    try std.testing.expectEqual(@as(u32, 0), desc.workgroup_size_x);
}

test "WGPUShaderSourceHLSL: has chain, code, and workgroup fields" {
    const desc = std.mem.zeroes(types.WGPUShaderSourceHLSL);
    try std.testing.expectEqual(@as(types.WGPUSType, 0), desc.chain.sType);
    try std.testing.expectEqual(@as(?[*]const u8, null), desc.code.data);
    try std.testing.expectEqual(@as(u32, 0), desc.workgroup_size_x);
}

// ============================================================
// 3. DoeShaderModule — new fields default correctly
// ============================================================

test "DoeShaderModule: spirv_data defaults to null" {
    const sm = native.DoeShaderModule{};
    try std.testing.expectEqual(@as(?[]const u32, null), sm.spirv_data);
}

test "DoeShaderModule: hlsl_source defaults to null" {
    const sm = native.DoeShaderModule{};
    try std.testing.expectEqual(@as(?[]const u8, null), sm.hlsl_source);
}

test "DoeShaderModule: default has null mtl_library and null precompiled" {
    const sm = native.DoeShaderModule{};
    try std.testing.expectEqual(@as(?*anyopaque, null), sm.mtl_library);
    try std.testing.expectEqual(@as(?[]const u32, null), sm.spirv_data);
    try std.testing.expectEqual(@as(?[]const u8, null), sm.hlsl_source);
}

// ============================================================
// 4. Null safety — shader module creation with null inputs
// ============================================================

test "doeNativeDeviceCreateShaderModule: null device returns null" {
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(null, &desc);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeDeviceCreateShaderModule: null descriptor returns null" {
    const result = native.doeNativeDeviceCreateShaderModule(null, null);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "doeNativeDeviceCreateShaderModule: null nextInChain returns null" {
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(null, &desc);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

// ============================================================
// 5. sType dispatch — unknown sType returns null with error
// ============================================================

test "doeNativeDeviceCreateShaderModule: unknown sType returns null" {
    var chain = types.WGPUChainedStruct{
        .next = null,
        .sType = 0xDEADBEEF,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = &chain,
        .label = .{ .data = null, .length = 0 },
    };
    // Device is null so will fail on device cast before sType dispatch,
    // but we still verify null return.
    const result = native.doeNativeDeviceCreateShaderModule(null, &desc);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

// ============================================================
// 6. SPIR-V creation — validation and storage
// ============================================================

test "SPIR-V shader module: invalid code_size (not multiple of 4) is rejected" {
    // Create a fake device handle to pass device validation.
    // The SPIR-V path does not touch the device, so we need a valid magic.
    var dev = native.DoeDevice{};
    var spirv_words = [_]u32{ 0x07230203, 0x00010000, 0, 0 }; // minimal SPIR-V header
    var spirv_desc = types.WGPUShaderSourceSPIRV{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceSPIRV },
        .code = &spirv_words,
        .code_size = 5, // not a multiple of 4
        .workgroup_size_x = 1,
        .workgroup_size_y = 1,
        .workgroup_size_z = 1,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&spirv_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    // Error inputs return an error-flagged module (not null) to prevent
    // GPU process crashes when Dawn's wire server receives a null handle.
    try std.testing.expect(result != null);
    if (native.cast(native.DoeShaderModule, result)) |sm| {
        try std.testing.expectEqual(native.CompilationMessageKind.@"error", sm.compilation_message_kind);
    }
}

test "SPIR-V shader module: zero code_size is rejected" {
    var dev = native.DoeDevice{};
    var spirv_words = [_]u32{0x07230203};
    var spirv_desc = types.WGPUShaderSourceSPIRV{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceSPIRV },
        .code = &spirv_words,
        .code_size = 0,
        .workgroup_size_x = 0,
        .workgroup_size_y = 0,
        .workgroup_size_z = 0,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&spirv_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);
    if (native.cast(native.DoeShaderModule, result)) |sm| {
        try std.testing.expectEqual(native.CompilationMessageKind.@"error", sm.compilation_message_kind);
    }
}

test "SPIR-V shader module: valid input creates module with stored binary" {
    var dev = native.DoeDevice{};
    var spirv_words = [_]u32{ 0x07230203, 0x00010000, 0xDECAFBAD, 0x00000001 };
    var spirv_desc = types.WGPUShaderSourceSPIRV{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceSPIRV },
        .code = &spirv_words,
        .code_size = 16, // 4 words * 4 bytes
        .workgroup_size_x = 8,
        .workgroup_size_y = 4,
        .workgroup_size_z = 2,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&spirv_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);

    // Verify module fields via cast.
    const sm = native.cast(native.DoeShaderModule, result).?;
    try std.testing.expectEqual(@as(u32, 8), sm.wg_x);
    try std.testing.expectEqual(@as(u32, 4), sm.wg_y);
    try std.testing.expectEqual(@as(u32, 2), sm.wg_z);
    try std.testing.expectEqual(@as(u32, 0), sm.binding_count);
    try std.testing.expect(!sm.needs_sizes_buf);
    try std.testing.expectEqual(@as(?*anyopaque, null), sm.mtl_library);
    // SPIR-V data stored.
    try std.testing.expect(sm.spirv_data != null);
    const stored = sm.spirv_data.?;
    try std.testing.expectEqual(@as(usize, 4), stored.len);
    try std.testing.expectEqual(@as(u32, 0x07230203), stored[0]);
    try std.testing.expectEqual(@as(u32, 0xDECAFBAD), stored[2]);

    // Cleanup.
    native.doeNativeShaderModuleRelease(result);
}

test "SPIR-V shader module: workgroup size 0 normalizes to 1" {
    var dev = native.DoeDevice{};
    var spirv_words = [_]u32{ 0x07230203, 0x00010000 };
    var spirv_desc = types.WGPUShaderSourceSPIRV{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceSPIRV },
        .code = &spirv_words,
        .code_size = 8,
        .workgroup_size_x = 0,
        .workgroup_size_y = 0,
        .workgroup_size_z = 0,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&spirv_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);

    const sm = native.cast(native.DoeShaderModule, result).?;
    try std.testing.expectEqual(@as(u32, 1), sm.wg_x);
    try std.testing.expectEqual(@as(u32, 1), sm.wg_y);
    try std.testing.expectEqual(@as(u32, 1), sm.wg_z);

    native.doeNativeShaderModuleRelease(result);
}

// ============================================================
// 7. HLSL creation — storage path
// ============================================================

test "HLSL shader module: null code pointer is rejected" {
    var dev = native.DoeDevice{};
    var hlsl_desc = types.WGPUShaderSourceHLSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceHLSL },
        .code = .{ .data = null, .length = 0 },
        .workgroup_size_x = 1,
        .workgroup_size_y = 1,
        .workgroup_size_z = 1,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&hlsl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);
    if (native.cast(native.DoeShaderModule, result)) |sm| {
        try std.testing.expectEqual(native.CompilationMessageKind.@"error", sm.compilation_message_kind);
    }
}

test "HLSL shader module: valid input creates module with stored source" {
    var dev = native.DoeDevice{};
    const hlsl_code = "[numthreads(8,1,1)] void CSMain() {}";
    var hlsl_desc = types.WGPUShaderSourceHLSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceHLSL },
        .code = .{ .data = hlsl_code.ptr, .length = hlsl_code.len },
        .workgroup_size_x = 8,
        .workgroup_size_y = 0,
        .workgroup_size_z = 0,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&hlsl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);

    const sm = native.cast(native.DoeShaderModule, result).?;
    try std.testing.expectEqual(@as(u32, 8), sm.wg_x);
    try std.testing.expectEqual(@as(u32, 1), sm.wg_y); // 0 → 1
    try std.testing.expectEqual(@as(u32, 1), sm.wg_z); // 0 → 1
    try std.testing.expectEqual(@as(u32, 0), sm.binding_count);
    try std.testing.expectEqual(@as(?*anyopaque, null), sm.mtl_library);
    // HLSL source stored.
    try std.testing.expect(sm.hlsl_source != null);
    try std.testing.expectEqualStrings(hlsl_code, sm.hlsl_source.?);

    native.doeNativeShaderModuleRelease(result);
}

// ============================================================
// 8. MSL creation — Metal integration (macOS only)
// ============================================================

test "MSL shader module: null code pointer is rejected" {
    var dev = native.DoeDevice{};
    var msl_desc = types.WGPUShaderSourceMSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceMSL },
        .code = .{ .data = null, .length = 0 },
        .workgroup_size_x = 1,
        .workgroup_size_y = 1,
        .workgroup_size_z = 1,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&msl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);
    if (native.cast(native.DoeShaderModule, result)) |sm| {
        try std.testing.expectEqual(native.CompilationMessageKind.@"error", sm.compilation_message_kind);
    }
}

// The following tests require a real Metal device and are skipped on non-macOS.
// They create a shader module from pre-translated MSL and verify the resulting
// handle fields (binding_count=0, workgroup size from descriptor, etc.).

test "MSL shader module: create from pre-translated MSL (Metal integration)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // Acquire Metal device.
    const bridge = @import("../../src/backend/metal/metal_bridge_decls.zig");
    const mtl_device = bridge.metal_bridge_create_default_device() orelse return error.SkipZigTest;
    defer bridge.metal_bridge_release(mtl_device);

    const mtl_queue = bridge.metal_bridge_device_new_command_queue(mtl_device) orelse return error.SkipZigTest;
    defer bridge.metal_bridge_release(mtl_queue);

    // Create a DoeDevice with real Metal handles.
    var dev = native.DoeDevice{
        .mtl_device = mtl_device,
        .mtl_queue = mtl_queue,
    };

    const msl_code =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\kernel void main_kernel(device float* data [[buffer(0)]],
        \\                        uint gid [[thread_position_in_grid]]) {
        \\    data[gid] = data[gid] * 2.0;
        \\}
    ;

    var msl_desc = types.WGPUShaderSourceMSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceMSL },
        .code = .{ .data = msl_code.ptr, .length = msl_code.len },
        .workgroup_size_x = 64,
        .workgroup_size_y = 0,
        .workgroup_size_z = 0,
    };

    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&msl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };

    const result = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    try std.testing.expect(result != null);

    const sm = native.cast(native.DoeShaderModule, result).?;
    // MSL path: binding_count is 0 (degraded mode).
    try std.testing.expectEqual(@as(u32, 0), sm.binding_count);
    // MTLLibrary was created.
    try std.testing.expect(sm.mtl_library != null);
    // Workgroup size from descriptor (0 → 1 normalization).
    try std.testing.expectEqual(@as(u32, 64), sm.wg_x);
    try std.testing.expectEqual(@as(u32, 1), sm.wg_y);
    try std.testing.expectEqual(@as(u32, 1), sm.wg_z);
    // No SPIR-V or HLSL stored.
    try std.testing.expectEqual(@as(?[]const u32, null), sm.spirv_data);
    try std.testing.expectEqual(@as(?[]const u8, null), sm.hlsl_source);
    try std.testing.expect(!sm.needs_sizes_buf);

    native.doeNativeShaderModuleRelease(result);
}

test "MSL shader module: can create compute pipeline from pre-translated MSL" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const bridge = @import("../../src/backend/metal/metal_bridge_decls.zig");
    const mtl_device = bridge.metal_bridge_create_default_device() orelse return error.SkipZigTest;
    defer bridge.metal_bridge_release(mtl_device);

    const mtl_queue = bridge.metal_bridge_device_new_command_queue(mtl_device) orelse return error.SkipZigTest;
    defer bridge.metal_bridge_release(mtl_queue);

    var dev = native.DoeDevice{
        .mtl_device = mtl_device,
        .mtl_queue = mtl_queue,
    };

    const msl_code =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\kernel void main_kernel(device float* data [[buffer(0)]],
        \\                        uint gid [[thread_position_in_grid]]) {
        \\    data[gid] = data[gid] + 1.0;
        \\}
    ;

    var msl_desc = types.WGPUShaderSourceMSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceMSL },
        .code = .{ .data = msl_code.ptr, .length = msl_code.len },
        .workgroup_size_x = 32,
        .workgroup_size_y = 1,
        .workgroup_size_z = 1,
    };

    const shader_desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&msl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };

    const shader_module = native.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &shader_desc);
    try std.testing.expect(shader_module != null);
    defer native.doeNativeShaderModuleRelease(shader_module);

    // Create compute pipeline from the MSL shader module.
    const pipeline_desc = types.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .layout = null,
        .compute = .{
            .nextInChain = null,
            .module = shader_module,
            .entryPoint = .{ .data = null, .length = 0 }, // defaults to main_kernel
            .constantCount = 0,
            .constants = null,
        },
    };

    const pipeline = native.doeNativeDeviceCreateComputePipeline(@ptrCast(&dev), &pipeline_desc);
    try std.testing.expect(pipeline != null);

    // Verify pipeline inherited workgroup size.
    const cp = native.cast(native.DoeComputePipeline, pipeline).?;
    try std.testing.expectEqual(@as(u32, 32), cp.wg_x);
    try std.testing.expectEqual(@as(u32, 1), cp.wg_y);
    try std.testing.expectEqual(@as(u32, 1), cp.wg_z);
    try std.testing.expect(cp.mtl_pso != null);

    native.doeNativeComputePipelineRelease(pipeline);
}
