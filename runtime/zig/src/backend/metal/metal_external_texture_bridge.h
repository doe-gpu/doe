#pragma once
#include <stdint.h>

// External texture import bridge for Doe native Metal backend.
// Imports IOSurface and CVPixelBuffer media surfaces as MTLTexture handles
// suitable for use in bind groups and copy operations.
//
// Handles are +1 retained; caller owns and must release via
// metal_bridge_release() (standard CFRelease semantics).

typedef void* MetalHandle;

// ============================================================
// IOSurface import
// ============================================================

// Import a single plane from an IOSurface as a MTLTexture.
// device: retained MTLDevice handle.
// iosurface: IOSurfaceRef (caller retains ownership).
// plane: plane index (0 for single-plane color, 0/1 for NV12).
// width/height: dimensions of this plane.
// pixel_format: MTLPixelFormat value (0=derive from IOSurface, 70=RGBA8Unorm,
// 80=BGRA8Unorm, 10=R8Unorm, 25=RG8Unorm).
// Returns a +1 retained MTLTexture handle or NULL on failure.
MetalHandle doe_metal_import_iosurface(
    MetalHandle device,
    void*       iosurface,
    uint32_t    plane,
    uint32_t    width,
    uint32_t    height,
    uint32_t    pixel_format);

// ============================================================
// CVPixelBuffer import
// ============================================================

// Import a single plane from a CVPixelBuffer as a MTLTexture.
// Extracts the underlying IOSurface and delegates to doe_metal_import_iosurface.
// device: retained MTLDevice handle.
// cvpixelbuffer: CVPixelBufferRef (caller retains ownership).
// plane: plane index.
// Returns a +1 retained MTLTexture handle or NULL on failure.
MetalHandle doe_metal_import_cvpixelbuffer(
    MetalHandle device,
    void*       cvpixelbuffer,
    uint32_t    plane);

// ============================================================
// Plane queries
// ============================================================

// Return the number of planes in a CVPixelBuffer.
// Returns 0 if cvpixelbuffer is NULL or not IOSurface-backed.
uint32_t doe_metal_external_plane_count(void* cvpixelbuffer);

// Query the dimensions of a plane within a CVPixelBuffer.
// Writes width/height into the output pointers.
// Safe to call with NULL outputs (they are simply skipped).
void doe_metal_external_plane_size(
    void*     cvpixelbuffer,
    uint32_t  plane,
    uint32_t* out_width,
    uint32_t* out_height);

// ============================================================
// IOSurface plane queries
// ============================================================

// Return the number of planes in an IOSurface (0 for non-planar).
uint32_t doe_metal_iosurface_plane_count(void* iosurface);

// Query the dimensions of a plane within an IOSurface.
void doe_metal_iosurface_plane_size(
    void*     iosurface,
    uint32_t  plane,
    uint32_t* out_width,
    uint32_t* out_height);
