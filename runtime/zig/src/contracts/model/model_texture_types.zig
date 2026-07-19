const gpu = @import("model_texture_value_types.zig");
const resource = @import("model_resource_types.zig");

pub const TextureWriteCommand = struct {
    texture: resource.CopyTextureResource,
    data: []const u8,
};

pub const TextureQueryCommand = struct {
    handle: u64,
    expected_width: ?u32 = null,
    expected_height: ?u32 = null,
    expected_depth_or_array_layers: ?u32 = null,
    expected_format: ?gpu.WGPUTextureFormat = null,
    expected_dimension: ?u32 = null,
    expected_view_dimension: ?u32 = null,
    expected_sample_count: ?u32 = null,
    expected_usage: ?gpu.WGPUFlags = null,
};

pub const TextureDestroyCommand = struct {
    handle: u64,
};
