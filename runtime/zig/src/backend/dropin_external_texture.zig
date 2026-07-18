const metal_bridge_mod = @import("metal/metal_bridge_decls.zig");
const metal_ext_mod = @import("metal/metal_external_texture.zig");

pub const PlaneLayout = metal_ext_mod.PlaneLayout;
pub const inspectIOSurface = metal_ext_mod.inspectIOSurface;
pub const importCVPixelBuffer = metal_ext_mod.importCVPixelBuffer;
pub const importIOSurface = metal_ext_mod.importIOSurface;
pub const importIOSurfaceWithPixelFormat = metal_ext_mod.importIOSurfaceWithPixelFormat;
pub const MTL_PIXEL_FORMAT_RGBA8_UNORM = metal_ext_mod.MTL_PIXEL_FORMAT_RGBA8_UNORM;
pub const MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB = metal_ext_mod.MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB;
pub const MTL_PIXEL_FORMAT_BGRA8_UNORM = metal_ext_mod.MTL_PIXEL_FORMAT_BGRA8_UNORM;
pub const MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB = metal_ext_mod.MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB;
pub const releasePlanes = metal_ext_mod.releasePlanes;
pub const metal_bridge_release = metal_bridge_mod.metal_bridge_release;
