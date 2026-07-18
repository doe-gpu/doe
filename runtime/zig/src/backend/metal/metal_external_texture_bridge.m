// metal_external_texture_bridge.m — IOSurface/CVPixelBuffer import for Doe Metal backend.
//
// Creates MTLTexture objects backed by IOSurface planes, enabling zero-copy
// import of video frames from CoreVideo (AVFoundation, VideoToolbox) and
// cross-process shared surfaces into the WebGPU external texture pipeline.
//
// Each returned MetalHandle is +1 retained; caller owns it and must release
// via metal_bridge_release() (which is CFRelease under ARC bridging).

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#include "metal_external_texture_bridge.h"

// ============================================================
// MTLPixelFormat constants for plane import
// ============================================================

// Single-plane packed color formats.
#define DOE_MTL_PIXEL_FORMAT_RGBA8_UNORM   70
#define DOE_MTL_PIXEL_FORMAT_BGRA8_UNORM   80

// NV12 multi-plane: Y plane = R8Unorm, UV plane = RG8Unorm
#define DOE_MTL_PIXEL_FORMAT_R8_UNORM      10
#define DOE_MTL_PIXEL_FORMAT_RG8_UNORM     25

// ============================================================
// IOSurface import
// ============================================================

MetalHandle doe_metal_import_iosurface(
    MetalHandle device_h,
    void*       iosurface_ptr,
    uint32_t    plane,
    uint32_t    width,
    uint32_t    height,
    uint32_t    pixel_format)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    IOSurfaceRef surface = (IOSurfaceRef)iosurface_ptr;
    if (device == nil || surface == NULL) return NULL;
    if (width == 0 || height == 0) return NULL;

    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2D;
    if (pixel_format == 0) {
        OSType surface_format = IOSurfaceGetPixelFormat(surface);
        if (surface_format == kCVPixelFormatType_32RGBA) {
            pixel_format = DOE_MTL_PIXEL_FORMAT_RGBA8_UNORM;
        } else if (surface_format == kCVPixelFormatType_32BGRA) {
            pixel_format = DOE_MTL_PIXEL_FORMAT_BGRA8_UNORM;
        } else {
            return NULL;
        }
    }
    desc.pixelFormat = (MTLPixelFormat)pixel_format;
    desc.width       = width;
    desc.height      = height;
    desc.depth       = 1;
    desc.mipmapLevelCount = 1;
    desc.sampleCount = 1;
    desc.arrayLength = 1;
    // TextureBinding (sample) + RenderAttachment for potential blit/copy paths.
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> texture = [device newTextureWithDescriptor:desc
                                                    iosurface:surface
                                                        plane:plane];
    if (texture == nil) return NULL;

    return (MetalHandle)CFBridgingRetain(texture);
}

// ============================================================
// CVPixelBuffer import
// ============================================================

MetalHandle doe_metal_import_cvpixelbuffer(
    MetalHandle device_h,
    void*       cvpixelbuffer_ptr,
    uint32_t    plane)
{
    if (device_h == NULL || cvpixelbuffer_ptr == NULL) return NULL;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)cvpixelbuffer_ptr;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (surface == NULL) return NULL;

    // Derive plane dimensions from the CVPixelBuffer.
    uint32_t width  = 0;
    uint32_t height = 0;
    size_t plane_count = CVPixelBufferGetPlaneCount(pixelBuffer);

    if (plane_count == 0) {
        // Non-planar (single plane): use top-level dimensions.
        if (plane != 0) return NULL;
        width  = (uint32_t)CVPixelBufferGetWidth(pixelBuffer);
        height = (uint32_t)CVPixelBufferGetHeight(pixelBuffer);
    } else {
        if (plane >= plane_count) return NULL;
        width  = (uint32_t)CVPixelBufferGetWidthOfPlane(pixelBuffer, plane);
        height = (uint32_t)CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
    }

    // Select pixel format based on plane index and buffer format.
    uint32_t pixel_format;
    OSType cv_format = CVPixelBufferGetPixelFormatType(pixelBuffer);

    if (plane_count <= 1) {
        if (cv_format == kCVPixelFormatType_32RGBA) {
            pixel_format = DOE_MTL_PIXEL_FORMAT_RGBA8_UNORM;
        } else if (cv_format == kCVPixelFormatType_32BGRA) {
            pixel_format = DOE_MTL_PIXEL_FORMAT_BGRA8_UNORM;
        } else {
            return NULL;
        }
    } else {
        // Multi-plane (NV12, 420v, 420f):
        // Plane 0 = luminance (R8Unorm), Plane 1 = chrominance (RG8Unorm).
        pixel_format = (plane == 0) ? DOE_MTL_PIXEL_FORMAT_R8_UNORM
                                    : DOE_MTL_PIXEL_FORMAT_RG8_UNORM;
    }

    return doe_metal_import_iosurface(device_h, surface, plane, width, height, pixel_format);
}

// ============================================================
// CVPixelBuffer plane queries
// ============================================================

uint32_t doe_metal_external_plane_count(void* cvpixelbuffer_ptr) {
    if (cvpixelbuffer_ptr == NULL) return 0;
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)cvpixelbuffer_ptr;

    // CVPixelBufferGetIOSurface returns NULL for non-IOSurface-backed buffers.
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (surface == NULL) return 0;

    size_t count = CVPixelBufferGetPlaneCount(pixelBuffer);
    // Non-planar buffers return 0 from GetPlaneCount; treat as 1 plane.
    return (count == 0) ? 1 : (uint32_t)count;
}

void doe_metal_external_plane_size(
    void*     cvpixelbuffer_ptr,
    uint32_t  plane,
    uint32_t* out_width,
    uint32_t* out_height)
{
    if (cvpixelbuffer_ptr == NULL) {
        if (out_width)  *out_width  = 0;
        if (out_height) *out_height = 0;
        return;
    }

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)cvpixelbuffer_ptr;
    size_t plane_count = CVPixelBufferGetPlaneCount(pixelBuffer);

    uint32_t w = 0;
    uint32_t h = 0;
    if (plane_count == 0) {
        // Non-planar: only plane 0 valid.
        if (plane == 0) {
            w = (uint32_t)CVPixelBufferGetWidth(pixelBuffer);
            h = (uint32_t)CVPixelBufferGetHeight(pixelBuffer);
        }
    } else {
        if (plane < plane_count) {
            w = (uint32_t)CVPixelBufferGetWidthOfPlane(pixelBuffer, plane);
            h = (uint32_t)CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
        }
    }

    if (out_width)  *out_width  = w;
    if (out_height) *out_height = h;
}

// ============================================================
// IOSurface plane queries
// ============================================================

uint32_t doe_metal_iosurface_plane_count(void* iosurface_ptr) {
    if (iosurface_ptr == NULL) return 0;
    IOSurfaceRef surface = (IOSurfaceRef)iosurface_ptr;
    size_t count = IOSurfaceGetPlaneCount(surface);
    // Non-planar IOSurfaces return 0 from GetPlaneCount; treat as 1 plane.
    return (count == 0) ? 1 : (uint32_t)count;
}

void doe_metal_iosurface_plane_size(
    void*     iosurface_ptr,
    uint32_t  plane,
    uint32_t* out_width,
    uint32_t* out_height)
{
    if (iosurface_ptr == NULL) {
        if (out_width)  *out_width  = 0;
        if (out_height) *out_height = 0;
        return;
    }

    IOSurfaceRef surface = (IOSurfaceRef)iosurface_ptr;
    size_t plane_count = IOSurfaceGetPlaneCount(surface);

    uint32_t w = 0;
    uint32_t h = 0;
    if (plane_count == 0) {
        if (plane == 0) {
            w = (uint32_t)IOSurfaceGetWidth(surface);
            h = (uint32_t)IOSurfaceGetHeight(surface);
        }
    } else {
        if (plane < plane_count) {
            w = (uint32_t)IOSurfaceGetWidthOfPlane(surface, plane);
            h = (uint32_t)IOSurfaceGetHeightOfPlane(surface, plane);
        }
    }

    if (out_width)  *out_width  = w;
    if (out_height) *out_height = h;
}
