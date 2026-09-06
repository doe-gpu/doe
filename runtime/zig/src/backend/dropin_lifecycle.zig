const builtin = @import("builtin");
const metal_bridge_mod = @import("metal/metal_bridge_decls.zig");

pub const NativeVulkanRuntime = if (builtin.os.tag == .linux) @import("vulkan/native_runtime.zig").NativeVulkanRuntime else void;
pub const NativeD3D12Runtime = @import("d3d12/d3d12_native_runtime.zig").NativeD3D12Runtime;

pub const metal_bridge_create_default_device = metal_bridge_mod.metal_bridge_create_default_device;
pub const metal_bridge_device_new_command_queue = metal_bridge_mod.metal_bridge_device_new_command_queue;
pub const metal_bridge_device_new_shared_event = metal_bridge_mod.metal_bridge_device_new_shared_event;
pub const metal_bridge_release = metal_bridge_mod.metal_bridge_release;

pub const metal_bridge_retain = metal_bridge_mod.metal_bridge_retain;
