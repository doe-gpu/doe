const std = @import("std");
const generated = @import("../../src/core/abi/generated/webgpu_upstream.zig");
const callbacks = @import("../../src/core/abi/wgpu_callback_descriptor_types.zig");
const handles = @import("../../src/core/abi/wgpu_handle_types.zig");
const pipeline = @import("../../src/core/abi/wgpu_pipeline_descriptor_types.zig");
const vertex_formats = @import("../../src/contracts/vertex_format.zig");

test "vertex formats match the pinned WebGPU header across every scalar and vector type" {
    inline for (@typeInfo(vertex_formats.Format).@"enum".fields) |field| {
        const suffix = comptime if (std.mem.eql(u8, field.name, "unorm8x4_bgra")) "Unorm8x4BGRA" else &[_]u8{std.ascii.toUpper(field.name[0])} ++ field.name[1..];
        try std.testing.expectEqual(@as(u32, @field(generated.c, "WGPUVertexFormat_" ++ suffix)), field.value);
    }
}

test "generated WebGPU procedure table and loader metadata cover the symbol contract" {
    try std.testing.expectEqual(generated.proc_names.len, generated.loader_metadata.len);
    try std.testing.expectEqual(
        generated.proc_names.len,
        @typeInfo(generated.ProcTable).@"struct".fields.len,
    );
    try std.testing.expect(generated.proc_names.len > 0);
    for (generated.loader_metadata, 0..) |entry, index| {
        try std.testing.expectEqualStrings(generated.proc_names[index], entry.name);
        if (index > 0) {
            try std.testing.expect(entry.offset > generated.loader_metadata[index - 1].offset);
        }
    }
}

test "generated WebGPU feature inventory is sorted and nonempty" {
    try std.testing.expect(generated.feature_names.len > 0);
    for (generated.feature_names[1..], 1..) |name, index| {
        try std.testing.expect(std.mem.order(u8, generated.feature_names[index - 1], name) == .lt);
    }
}

test "narrow ABI owners use the generated upstream record and callback identities" {
    comptime {
        if (handles.WGPUStringView != generated.WGPUStringView) @compileError("WGPUStringView is not generated");
        if (handles.WGPUBuffer != generated.WGPUBuffer) @compileError("WGPUBuffer is not generated");
        if (callbacks.WGPUBufferMapCallback != generated.WGPUBufferMapCallback) @compileError("WGPUBufferMapCallback is not generated");
        if (pipeline.WGPUBufferDescriptor != generated.WGPUBufferDescriptor) @compileError("WGPUBufferDescriptor is not generated");
        if (pipeline.WGPUShaderSourceSPIRV != generated.WGPUShaderSourceSPIRV) @compileError("WGPUShaderSourceSPIRV is not generated");
    }
    try std.testing.expectEqual(@sizeOf(generated.WGPUStringView), @sizeOf(handles.WGPUStringView));
    try std.testing.expectEqual(@sizeOf(generated.WGPURequestAdapterCallbackInfo), @sizeOf(callbacks.WGPURequestAdapterCallbackInfo));
    try std.testing.expectEqual(@alignOf(generated.WGPUUncapturedErrorCallbackInfo), @alignOf(callbacks.WGPUUncapturedErrorCallbackInfo));
}
