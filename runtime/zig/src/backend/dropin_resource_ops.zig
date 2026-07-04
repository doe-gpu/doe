const builtin = @import("builtin");

pub const metal_bridge = @import("metal/metal_bridge_decls.zig");
pub const d3d12_constants = @import("d3d12/d3d12_constants.zig");
pub const d3d12_formats = @import("d3d12/d3d12_formats.zig");
pub const vk_constants = if (builtin.os.tag == .linux) @import("vulkan/vk_constants.zig") else struct {};
pub const vk_resources = if (builtin.os.tag == .linux) @import("vulkan/vk_resources.zig") else struct {};
pub const vk_dispatch_indirect = if (builtin.os.tag == .linux) @import("vulkan/vk_dispatch_indirect.zig") else struct {};
