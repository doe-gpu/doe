//! Stable cross-layer binding identities and pure binding classifications.

const binding_values = @import("model/model_binding_value_types.zig");

pub const MAX_SHADER_BINDINGS: usize = 16;

/// Shader-reflection kind stored by the compiler/native reflection bridge.
pub const ShaderKind = enum(u32) {
    buffer,
    sampler,
    texture,
    storage_texture,
};

/// Native bind-group layout resource identity. Numeric values are consumed by
/// the recorded-command and Vulkan descriptor bridges and must remain stable.
pub const LayoutResourceKind = enum(u32) {
    none = 0,
    buffer = 1,
    sampler = 2,
    texture = 3,
    storage_texture = 4,
    external_texture = 5,
};

pub fn layoutResourceKindCode(kind: LayoutResourceKind) u32 {
    return @intFromEnum(kind);
}

pub fn storageTextureAccessSupported(access: u32) bool {
    return switch (access) {
        binding_values.WGPUStorageTextureAccess_Undefined,
        binding_values.WGPUStorageTextureAccess_WriteOnly,
        binding_values.WGPUStorageTextureAccess_ReadOnly,
        binding_values.WGPUStorageTextureAccess_ReadWrite,
        => true,
        else => false,
    };
}

test "layout resource kind codes are stable" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 1), layoutResourceKindCode(.buffer));
    try std.testing.expectEqual(@as(u32, 5), layoutResourceKindCode(.external_texture));
    try std.testing.expect(storageTextureAccessSupported(binding_values.WGPUStorageTextureAccess_ReadWrite));
}
