const builtin = @import("builtin");
const has_vulkan = builtin.os.tag == .linux;

const backend_lifecycle = @import("../../backend/dropin_lifecycle.zig");
const abi_binding = @import("../../core/abi/wgpu_binding_base_types.zig");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const wgsl_compiler = @import("../../compiler/wgsl/mod.zig");

pub const BackendKind = enum(u8) {
    metal = 0,
    vulkan = 1,
    d3d12 = 2,
};

pub const NativeVulkanRuntime = if (has_vulkan) backend_lifecycle.NativeVulkanRuntime else void;
pub const NativeD3D12Runtime = backend_lifecycle.NativeD3D12Runtime;

pub const MAX_BIND: usize = 16;
pub const MAX_RENDER_BIND_GROUPS: usize = 4;
pub const MAX_COMPUTE_BIND_GROUPS: usize = 4;
pub const MAX_FLAT_BIND: usize = MAX_BIND * MAX_COMPUTE_BIND_GROUPS;
pub const VULKAN_PREPARED_BINDING_CACHE_CAPACITY: usize = 32;
pub const MAX_VERTEX_BUFFERS: usize = 8;
pub const MAX_VERTEX_ATTRIBUTES: usize = 16;
pub const VERTEX_BUFFER_SLOT_BASE: u32 = 8;
pub const ERR_CAP: usize = 512;

pub const extractWorkgroupSize = @import("../../compiler/wgsl/runtime/shader_info.zig").extractWorkgroupSize;

pub const BindingInfo = struct {
    group: u32,
    binding: u32,
    kind: u32 = @intFromEnum(wgsl_compiler.BindingKind.buffer),
    addr_space: u32 = 0,
    access: u32 = 0,
};

pub const MAX_SHADER_BINDINGS: usize = wgsl_compiler.MAX_BINDINGS;

pub const CompilationMessageKind = enum(u8) {
    none,
    @"error",
    warning,
    info,
};

pub const DoeBindGroupLayoutEntry = struct {
    binding: u32 = 0,
    resource_kind: u32 = 0,
    texture_sample_type: u32 = abi_binding.WGPUTextureSampleType_Undefined,
    texture_view_dimension: u32 = abi_texture.WGPUTextureViewDimension_Undefined,
    texture_multisampled: bool = false,
    binding_array_size: u32 = 0,
};
