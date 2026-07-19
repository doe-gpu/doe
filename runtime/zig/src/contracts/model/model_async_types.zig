const gpu = @import("model_texture_value_types.zig");

pub const AsyncDiagnosticsMode = enum {
    pipeline_async,
    capability_introspection,
    resource_table_immediates,
    lifecycle_refcount,
    pixel_local_storage,
    full,
};

pub const AsyncDiagnosticsFeaturePolicy = enum {
    strict,
    emulate_when_unavailable,
};

pub const AsyncDiagnosticsCommand = struct {
    target_format: gpu.WGPUTextureFormat = gpu.WGPUTextureFormat_RGBA8Unorm,
    mode: AsyncDiagnosticsMode = .pipeline_async,
    iterations: u32 = 1,
    feature_policy: AsyncDiagnosticsFeaturePolicy = .strict,
};

pub const MapAsyncMode = enum {
    read,
    write,
};

pub const MapAsyncCommand = struct {
    bytes: usize,
    mode: MapAsyncMode = .write,
};
