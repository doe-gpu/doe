// metal_external_texture.zig — Metal-side external texture import for Doe.
//
// Wraps the ObjC bridge functions for importing IOSurface and CVPixelBuffer
// media surfaces as MTLTexture handles. Used by doe_external_texture_native.zig
// when a native platform handle is provided in the descriptor's nextInChain.

const builtin = @import("builtin");
const bridge = @import("metal_bridge_decls.zig");

// MTLPixelFormat constants matching Apple's Metal ABI.
pub const MTL_PIXEL_FORMAT_AUTO: u32 = 0;
pub const MTL_PIXEL_FORMAT_RGBA8_UNORM: u32 = 70;
pub const MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB: u32 = 71;
pub const MTL_PIXEL_FORMAT_BGRA8_UNORM: u32 = 80;
pub const MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB: u32 = 81;
pub const MTL_PIXEL_FORMAT_R8_UNORM: u32 = 10;
pub const MTL_PIXEL_FORMAT_RG8_UNORM: u32 = 25;

pub const IOSurfaceLayout = struct {
    plane_count: u32,
    width: u32,
    height: u32,
};

pub const PlaneLayout = struct {
    plane0: ?*anyopaque,
    plane1: ?*anyopaque,
    is_single_plane: bool,
    width: u32,
    height: u32,
};

pub fn inspectIOSurface(iosurface: ?*anyopaque) ?IOSurfaceLayout {
    if (comptime builtin.os.tag != .macos) return null;
    if (iosurface == null) return null;

    const plane_count = bridge.doe_metal_iosurface_plane_count(iosurface);
    if (plane_count == 0) return null;

    var width: u32 = 0;
    var height: u32 = 0;
    bridge.doe_metal_iosurface_plane_size(iosurface, 0, &width, &height);
    if (width == 0 or height == 0) return null;

    return .{
        .plane_count = plane_count,
        .width = width,
        .height = height,
    };
}

/// Import an IOSurface as one or two MTLTexture planes.
/// Returns PlaneLayout with retained MTLTexture handles (caller must release).
/// Returns null on failure (non-macOS, null device, null iosurface).
pub fn importIOSurface(device: ?*anyopaque, iosurface: ?*anyopaque) ?PlaneLayout {
    return importIOSurfaceWithPixelFormat(device, iosurface, MTL_PIXEL_FORMAT_AUTO);
}

pub fn importIOSurfaceWithPixelFormat(
    device: ?*anyopaque,
    iosurface: ?*anyopaque,
    single_plane_pixel_format: u32,
) ?PlaneLayout {
    if (comptime builtin.os.tag != .macos) return null;
    if (device == null or iosurface == null) return null;

    const layout = inspectIOSurface(iosurface) orelse return null;

    if (layout.plane_count == 1) {
        const plane0 = bridge.doe_metal_import_iosurface(
            device,
            iosurface,
            0,
            layout.width,
            layout.height,
            single_plane_pixel_format,
        );
        if (plane0 == null) return null;

        return .{
            .plane0 = plane0,
            .plane1 = null,
            .is_single_plane = true,
            .width = layout.width,
            .height = layout.height,
        };
    }

    // Multi-plane (NV12): plane 0 = Y (R8Unorm), plane 1 = UV (RG8Unorm).
    var w0: u32 = 0;
    var h0: u32 = 0;
    bridge.doe_metal_iosurface_plane_size(iosurface, 0, &w0, &h0);
    if (w0 == 0 or h0 == 0) return null;

    const p0 = bridge.doe_metal_import_iosurface(
        device,
        iosurface,
        0,
        w0,
        h0,
        MTL_PIXEL_FORMAT_R8_UNORM,
    );
    if (p0 == null) return null;

    var w1: u32 = 0;
    var h1: u32 = 0;
    bridge.doe_metal_iosurface_plane_size(iosurface, 1, &w1, &h1);
    if (w1 == 0 or h1 == 0) {
        bridge.metal_bridge_release(p0);
        return null;
    }

    const p1 = bridge.doe_metal_import_iosurface(
        device,
        iosurface,
        1,
        w1,
        h1,
        MTL_PIXEL_FORMAT_RG8_UNORM,
    );
    if (p1 == null) {
        bridge.metal_bridge_release(p0);
        return null;
    }

    return .{
        .plane0 = p0,
        .plane1 = p1,
        .is_single_plane = false,
        .width = w0,
        .height = h0,
    };
}

/// Import a CVPixelBuffer as one or two MTLTexture planes.
/// Returns PlaneLayout with retained MTLTexture handles (caller must release).
/// Returns null on failure.
pub fn importCVPixelBuffer(device: ?*anyopaque, cvpixelbuffer: ?*anyopaque) ?PlaneLayout {
    if (comptime builtin.os.tag != .macos) return null;
    if (device == null or cvpixelbuffer == null) return null;

    const plane_count = bridge.doe_metal_external_plane_count(cvpixelbuffer);
    if (plane_count == 0) return null;

    // Import plane 0.
    var w0: u32 = 0;
    var h0: u32 = 0;
    bridge.doe_metal_external_plane_size(cvpixelbuffer, 0, &w0, &h0);
    if (w0 == 0 or h0 == 0) return null;

    const p0 = bridge.doe_metal_import_cvpixelbuffer(device, cvpixelbuffer, 0);
    if (p0 == null) return null;

    if (plane_count == 1) {
        return .{
            .plane0 = p0,
            .plane1 = null,
            .is_single_plane = true,
            .width = w0,
            .height = h0,
        };
    }

    // Import plane 1.
    const p1 = bridge.doe_metal_import_cvpixelbuffer(device, cvpixelbuffer, 1);
    if (p1 == null) {
        bridge.metal_bridge_release(p0);
        return null;
    }

    return .{
        .plane0 = p0,
        .plane1 = p1,
        .is_single_plane = false,
        .width = w0,
        .height = h0,
    };
}

/// Release plane textures. Safe to call with null handles.
pub fn releasePlanes(layout: PlaneLayout) void {
    if (comptime builtin.os.tag != .macos) return;
    if (layout.plane0) |p| bridge.metal_bridge_release(p);
    if (layout.plane1) |p| bridge.metal_bridge_release(p);
}
