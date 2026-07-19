#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "metal_bridge.h"
#include <string.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <CommonCrypto/CommonDigest.h>
#include <os/lock.h>

// CFBridging provides correct ARC-safe transfer across the void* boundary.
// Each returned MetalHandle is +1 retained and owned by the caller.
// metal_bridge_release() must be called to balance.

// ============================================================
// MTLLibrary source cache (avoids recompiling identical MSL source)
// ============================================================

// Keyed by NSData SHA-256 hash of the MSL source bytes.
// One dictionary per process — sufficient because MTLLibrary is device-bound and Doe uses
// a single MTLDevice per process in the common path.
static NSMutableDictionary<NSData*, id<MTLLibrary>>* _mslLibraryCache = nil;
static os_unfair_lock _mslLibraryCacheLock = OS_UNFAIR_LOCK_INIT;

static NSData* msl_source_hash(const char* src, size_t src_len) {
    // Use CC_SHA256 via CommonCrypto (available on all Apple platforms).
    unsigned char digest[32];
    CC_SHA256(src, (CC_LONG)src_len, digest);
    return [NSData dataWithBytes:digest length:32];
}

// ============================================================
// Cached render pass descriptor (avoids alloc per render command)
// ============================================================

static MTLRenderPassDescriptor* _cachedRenderPassDesc = nil;
static const MetalRenderPassOps _defaultRenderPassOps = {
    .color_load_op = 0x00000002,
    .color_store_op = 0x00000001,
    .clear_a = 1.0,
    .depth_clear_value = 1.0f,
};

static BOOL wgpu_to_mtl_load_action(uint32_t op, MTLLoadAction* action_out) {
    switch (op) {
        case 0x00000001:
            *action_out = MTLLoadActionLoad;
            return YES;
        case 0x00000002:
            *action_out = MTLLoadActionClear;
            return YES;
        default:
            return NO;
    }
}

static BOOL wgpu_to_mtl_store_action(uint32_t op, BOOL has_resolve, MTLStoreAction* action_out) {
    switch (op) {
        case 0x00000001:
            *action_out = has_resolve ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore;
            return YES;
        case 0x00000002:
            *action_out = has_resolve ? MTLStoreActionMultisampleResolve : MTLStoreActionDontCare;
            return YES;
        default:
            return NO;
    }
}

static MTLRenderPassDescriptor* cachedRenderPassDescriptor(
    id<MTLTexture> target,
    id<MTLTexture> resolve_target,
    id<MTLTexture> depth_target,
    const MetalRenderPassOps* ops)
{
    if (ops == NULL) return nil;
    if (_cachedRenderPassDesc == nil) {
        _cachedRenderPassDesc = [MTLRenderPassDescriptor new];
    }

    MTLRenderPassColorAttachmentDescriptor* color = _cachedRenderPassDesc.colorAttachments[0];
    color.texture = target;
    color.resolveTexture = resolve_target;
    if (target != nil) {
        MTLLoadAction color_load;
        MTLStoreAction color_store;
        if (!wgpu_to_mtl_load_action(ops->color_load_op, &color_load) ||
            !wgpu_to_mtl_store_action(ops->color_store_op, resolve_target != nil, &color_store)) {
            return nil;
        }
        color.loadAction = color_load;
        color.storeAction = color_store;
        color.clearColor = MTLClearColorMake(ops->clear_r, ops->clear_g, ops->clear_b, ops->clear_a);
    }

    MTLRenderPassDepthAttachmentDescriptor* depth = _cachedRenderPassDesc.depthAttachment;
    depth.texture = depth_target;
    if (depth_target != nil) {
        MTLLoadAction depth_load;
        MTLStoreAction depth_store;
        if (ops->depth_read_only != 0 && ops->depth_load_op == 0) {
            depth_load = MTLLoadActionLoad;
        } else if (!wgpu_to_mtl_load_action(ops->depth_load_op, &depth_load)) {
            return nil;
        }
        if (ops->depth_read_only != 0 && ops->depth_store_op == 0) {
            depth_store = MTLStoreActionDontCare;
        } else if (!wgpu_to_mtl_store_action(ops->depth_store_op, NO, &depth_store)) {
            return nil;
        }
        depth.loadAction = depth_load;
        depth.storeAction = depth_store;
        depth.clearDepth = ops->depth_clear_value;
    }

    MTLRenderPassStencilAttachmentDescriptor* stencil = _cachedRenderPassDesc.stencilAttachment;
    const BOOL uses_stencil = depth_target != nil &&
        (ops->stencil_read_only != 0 || ops->stencil_load_op != 0 || ops->stencil_store_op != 0);
    stencil.texture = uses_stencil ? depth_target : nil;
    if (uses_stencil) {
        MTLLoadAction stencil_load;
        MTLStoreAction stencil_store;
        if (ops->stencil_read_only != 0 && ops->stencil_load_op == 0) {
            stencil_load = MTLLoadActionLoad;
        } else if (!wgpu_to_mtl_load_action(ops->stencil_load_op, &stencil_load)) {
            return nil;
        }
        if (ops->stencil_read_only != 0 && ops->stencil_store_op == 0) {
            stencil_store = MTLStoreActionDontCare;
        } else if (!wgpu_to_mtl_store_action(ops->stencil_store_op, NO, &stencil_store)) {
            return nil;
        }
        stencil.loadAction = stencil_load;
        stencil.storeAction = stencil_store;
        stencil.clearStencil = ops->stencil_clear_value;
    }
    return _cachedRenderPassDesc;
}

// ============================================================
// Pixel format translation
// ============================================================

static MTLPixelFormat wgpu_to_mtl_format(uint32_t wgpu) {
    switch (wgpu) {
        // 8-bit single channel
        case 0x00000001: return MTLPixelFormatR8Unorm;
        case 0x00000002: return MTLPixelFormatR8Snorm;
        case 0x00000003: return MTLPixelFormatR8Uint;
        case 0x00000004: return MTLPixelFormatR8Sint;
        // 16-bit single channel
        case 0x00000005: return MTLPixelFormatR16Unorm;
        case 0x00000006: return MTLPixelFormatR16Snorm;
        case 0x00000007: return MTLPixelFormatR16Uint;
        case 0x00000008: return MTLPixelFormatR16Sint;
        case 0x00000009: return MTLPixelFormatR16Float;
        // 8-bit dual channel
        case 0x0000000A: return MTLPixelFormatRG8Unorm;
        case 0x0000000B: return MTLPixelFormatRG8Snorm;
        case 0x0000000C: return MTLPixelFormatRG8Uint;
        case 0x0000000D: return MTLPixelFormatRG8Sint;
        // 32-bit single channel
        case 0x0000000E: return MTLPixelFormatR32Float;
        case 0x0000000F: return MTLPixelFormatR32Uint;
        case 0x00000010: return MTLPixelFormatR32Sint;
        // 16-bit dual channel
        case 0x00000011: return MTLPixelFormatRG16Unorm;
        case 0x00000012: return MTLPixelFormatRG16Snorm;
        case 0x00000013: return MTLPixelFormatRG16Uint;
        case 0x00000014: return MTLPixelFormatRG16Sint;
        case 0x00000015: return MTLPixelFormatRG16Float;
        // 32-bit quad channel
        case 0x00000016: return MTLPixelFormatRGBA8Unorm;
        case 0x00000017: return MTLPixelFormatRGBA8Unorm_sRGB;
        case 0x00000018: return MTLPixelFormatRGBA8Snorm;
        case 0x00000019: return MTLPixelFormatRGBA8Uint;
        case 0x0000001A: return MTLPixelFormatRGBA8Sint;
        case 0x0000001B: return MTLPixelFormatBGRA8Unorm;
        case 0x0000001C: return MTLPixelFormatBGRA8Unorm_sRGB;
        // packed formats
        case 0x0000001D: return MTLPixelFormatRGB10A2Uint;
        case 0x0000001E: return MTLPixelFormatRGB10A2Unorm;
        case 0x0000001F: return MTLPixelFormatRG11B10Float;
        case 0x00000020: return MTLPixelFormatRGB9E5Float;
        // 64-bit dual channel
        case 0x00000021: return MTLPixelFormatRG32Float;
        case 0x00000022: return MTLPixelFormatRG32Uint;
        case 0x00000023: return MTLPixelFormatRG32Sint;
        // 64-bit quad channel
        case 0x00000024: return MTLPixelFormatRGBA16Uint;
        case 0x00000025: return MTLPixelFormatRGBA16Sint;
        case 0x00000026: return MTLPixelFormatRGBA16Float;
        // 128-bit quad channel
        case 0x00000027: return MTLPixelFormatRGBA32Float;
        case 0x00000028: return MTLPixelFormatRGBA32Uint;
        case 0x00000029: return MTLPixelFormatRGBA32Sint;
        // depth/stencil
        case 0x0000002C: return MTLPixelFormatStencil8;
        case 0x0000002D: return MTLPixelFormatDepth16Unorm;
        case 0x0000002E: return MTLPixelFormatDepth32Float;   // depth24plus
        case 0x0000002F: return MTLPixelFormatDepth32Float;   // depth24plus-stencil8
        case 0x00000030: return MTLPixelFormatDepth32Float;
        case 0x00000031: return MTLPixelFormatDepth32Float_Stencil8;
        // BC compressed formats (texture-compression-bc feature)
        case 0x00000032: return MTLPixelFormatBC1_RGBA;
        case 0x00000033: return MTLPixelFormatBC1_RGBA_sRGB;
        case 0x00000034: return MTLPixelFormatBC2_RGBA;
        case 0x00000035: return MTLPixelFormatBC2_RGBA_sRGB;
        case 0x00000036: return MTLPixelFormatBC3_RGBA;
        case 0x00000037: return MTLPixelFormatBC3_RGBA_sRGB;
        case 0x00000038: return MTLPixelFormatBC4_RUnorm;
        case 0x00000039: return MTLPixelFormatBC4_RSnorm;
        case 0x0000003A: return MTLPixelFormatBC5_RGUnorm;
        case 0x0000003B: return MTLPixelFormatBC5_RGSnorm;
        case 0x0000003C: return MTLPixelFormatBC6H_RGBUfloat;
        case 0x0000003D: return MTLPixelFormatBC6H_RGBFloat;
        case 0x0000003E: return MTLPixelFormatBC7_RGBAUnorm;
        case 0x0000003F: return MTLPixelFormatBC7_RGBAUnorm_sRGB;
        // ETC2/EAC compressed formats (texture-compression-etc2 feature)
        case 0x00000040: return MTLPixelFormatETC2_RGB8;
        case 0x00000041: return MTLPixelFormatETC2_RGB8_sRGB;
        case 0x00000042: return MTLPixelFormatETC2_RGB8A1;
        case 0x00000043: return MTLPixelFormatETC2_RGB8A1_sRGB;
        case 0x00000044: return MTLPixelFormatEAC_RGBA8;
        case 0x00000045: return MTLPixelFormatEAC_RGBA8_sRGB;
        case 0x00000046: return MTLPixelFormatEAC_R11Unorm;
        case 0x00000047: return MTLPixelFormatEAC_R11Snorm;
        case 0x00000048: return MTLPixelFormatEAC_RG11Unorm;
        case 0x00000049: return MTLPixelFormatEAC_RG11Snorm;
        // ASTC compressed formats (LDR / sRGB)
        case 0x0000004A: return MTLPixelFormatASTC_4x4_LDR;
        case 0x0000004B: return MTLPixelFormatASTC_4x4_sRGB;
        case 0x0000004C: return MTLPixelFormatASTC_5x4_LDR;
        case 0x0000004D: return MTLPixelFormatASTC_5x4_sRGB;
        case 0x0000004E: return MTLPixelFormatASTC_5x5_LDR;
        case 0x0000004F: return MTLPixelFormatASTC_5x5_sRGB;
        case 0x00000050: return MTLPixelFormatASTC_6x5_LDR;
        case 0x00000051: return MTLPixelFormatASTC_6x5_sRGB;
        case 0x00000052: return MTLPixelFormatASTC_6x6_LDR;
        case 0x00000053: return MTLPixelFormatASTC_6x6_sRGB;
        case 0x00000054: return MTLPixelFormatASTC_8x5_LDR;
        case 0x00000055: return MTLPixelFormatASTC_8x5_sRGB;
        case 0x00000056: return MTLPixelFormatASTC_8x6_LDR;
        case 0x00000057: return MTLPixelFormatASTC_8x6_sRGB;
        case 0x00000058: return MTLPixelFormatASTC_8x8_LDR;
        case 0x00000059: return MTLPixelFormatASTC_8x8_sRGB;
        case 0x0000005A: return MTLPixelFormatASTC_10x5_LDR;
        case 0x0000005B: return MTLPixelFormatASTC_10x5_sRGB;
        case 0x0000005C: return MTLPixelFormatASTC_10x6_LDR;
        case 0x0000005D: return MTLPixelFormatASTC_10x6_sRGB;
        case 0x0000005E: return MTLPixelFormatASTC_10x8_LDR;
        case 0x0000005F: return MTLPixelFormatASTC_10x8_sRGB;
        case 0x00000060: return MTLPixelFormatASTC_10x10_LDR;
        case 0x00000061: return MTLPixelFormatASTC_10x10_sRGB;
        case 0x00000062: return MTLPixelFormatASTC_12x10_LDR;
        case 0x00000063: return MTLPixelFormatASTC_12x10_sRGB;
        case 0x00000064: return MTLPixelFormatASTC_12x12_LDR;
        case 0x00000065: return MTLPixelFormatASTC_12x12_sRGB;
        default:         return MTLPixelFormatInvalid;
    }
}

static MTLPrimitiveType wgpu_to_mtl_primitive(uint32_t topology) {
    switch (topology) {
        case 0x00000001: return MTLPrimitiveTypePoint;
        case 0x00000002: return MTLPrimitiveTypeLine;
        case 0x00000003: return MTLPrimitiveTypeLineStrip;
        case 0x00000005: return MTLPrimitiveTypeTriangleStrip;
        case 0x00000004:
        default: return MTLPrimitiveTypeTriangle;
    }
}

static MTLWinding wgpu_to_mtl_winding(uint32_t front_face) {
    return front_face == 0x00000002 ? MTLWindingClockwise : MTLWindingCounterClockwise;
}

static MTLCullMode wgpu_to_mtl_cull(uint32_t cull_mode) {
    switch (cull_mode) {
        case 0x00000002: return MTLCullModeFront;
        case 0x00000003: return MTLCullModeBack;
        case 0x00000001:
        default: return MTLCullModeNone;
    }
}

static MTLCompareFunction wgpu_to_mtl_compare(uint32_t compare_fn) {
    switch (compare_fn) {
        case 0x00000001: return MTLCompareFunctionNever;
        case 0x00000002: return MTLCompareFunctionLess;
        case 0x00000003: return MTLCompareFunctionEqual;
        case 0x00000004: return MTLCompareFunctionLessEqual;
        case 0x00000005: return MTLCompareFunctionGreater;
        case 0x00000006: return MTLCompareFunctionNotEqual;
        case 0x00000007: return MTLCompareFunctionGreaterEqual;
        case 0x00000008: return MTLCompareFunctionAlways;
        default: return MTLCompareFunctionAlways;
    }
}

static MTLVertexFormat wgpu_to_mtl_vertex_format(uint32_t format) {
    switch (format) {
        /* 8-bit uint */
        case 0x01: return MTLVertexFormatUChar;
        case 0x02: return MTLVertexFormatUChar2;
        case 0x03: return MTLVertexFormatUChar4;
        /* 8-bit sint */
        case 0x04: return MTLVertexFormatChar;
        case 0x05: return MTLVertexFormatChar2;
        case 0x06: return MTLVertexFormatChar4;
        /* 8-bit unorm */
        case 0x07: return MTLVertexFormatUCharNormalized;
        case 0x08: return MTLVertexFormatUChar2Normalized;
        case 0x09: return MTLVertexFormatUChar4Normalized;
        /* 8-bit snorm */
        case 0x0A: return MTLVertexFormatCharNormalized;
        case 0x0B: return MTLVertexFormatChar2Normalized;
        case 0x0C: return MTLVertexFormatChar4Normalized;
        /* 16-bit uint */
        case 0x0D: return MTLVertexFormatUShort;
        case 0x0E: return MTLVertexFormatUShort2;
        case 0x0F: return MTLVertexFormatUShort4;
        /* 16-bit sint */
        case 0x10: return MTLVertexFormatShort;
        case 0x11: return MTLVertexFormatShort2;
        case 0x12: return MTLVertexFormatShort4;
        /* 16-bit unorm */
        case 0x13: return MTLVertexFormatUShortNormalized;
        case 0x14: return MTLVertexFormatUShort2Normalized;
        case 0x15: return MTLVertexFormatUShort4Normalized;
        /* 16-bit snorm */
        case 0x16: return MTLVertexFormatShortNormalized;
        case 0x17: return MTLVertexFormatShort2Normalized;
        case 0x18: return MTLVertexFormatShort4Normalized;
        /* 32-bit float */
        case 0x19: return MTLVertexFormatFloat;
        case 0x1A: return MTLVertexFormatFloat2;
        case 0x1B: return MTLVertexFormatFloat3;
        case 0x1C: return MTLVertexFormatFloat4;
        /* 16-bit float */
        case 0x1D: return MTLVertexFormatHalf;
        case 0x1E: return MTLVertexFormatHalf2;
        case 0x1F: return MTLVertexFormatHalf4;
        /* 32-bit uint (0x20 skipped) */
        case 0x21: return MTLVertexFormatUInt;
        case 0x22: return MTLVertexFormatUInt2;
        case 0x23: return MTLVertexFormatUInt3;
        case 0x24: return MTLVertexFormatUInt4;
        /* 32-bit sint */
        case 0x25: return MTLVertexFormatInt;
        case 0x26: return MTLVertexFormatInt2;
        case 0x27: return MTLVertexFormatInt3;
        case 0x28: return MTLVertexFormatInt4;
        /* packed formats */
        case 0x29: return MTLVertexFormatUInt1010102Normalized;
        case 0x2A: return MTLVertexFormatUChar4Normalized_BGRA;
        default: return MTLVertexFormatInvalid;
    }
}

static MTLBlendOperation wgpu_to_mtl_blend_op(uint32_t op) {
    switch (op) {
        case 2: return MTLBlendOperationSubtract;
        case 3: return MTLBlendOperationReverseSubtract;
        case 4: return MTLBlendOperationMin;
        case 5: return MTLBlendOperationMax;
        default: return MTLBlendOperationAdd;
    }
}

static MTLBlendFactor wgpu_to_mtl_blend_factor(uint32_t factor) {
    switch (factor) {
        case 1: return MTLBlendFactorZero;
        case 2: return MTLBlendFactorOne;
        case 3: return MTLBlendFactorSourceColor;
        case 4: return MTLBlendFactorOneMinusSourceColor;
        case 5: return MTLBlendFactorSourceAlpha;
        case 6: return MTLBlendFactorOneMinusSourceAlpha;
        case 7: return MTLBlendFactorDestinationColor;
        case 8: return MTLBlendFactorOneMinusDestinationColor;
        case 9: return MTLBlendFactorDestinationAlpha;
        case 10: return MTLBlendFactorOneMinusDestinationAlpha;
        case 11: return MTLBlendFactorSourceAlphaSaturated;
        case 12: return MTLBlendFactorBlendColor;
        case 13: return MTLBlendFactorOneMinusBlendColor;
        case 14: return MTLBlendFactorSource1Color;
        case 15: return MTLBlendFactorOneMinusSource1Color;
        case 16: return MTLBlendFactorSource1Alpha;
        case 17: return MTLBlendFactorOneMinusSource1Alpha;
        default: return MTLBlendFactorOne;
    }
}

static MTLIndexType wgpu_to_mtl_index_type(uint32_t format) {
    return format == 0x00000002 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
}

// ============================================================
// Core device / buffer / blit
// ============================================================

static void ensure_headless_application_ready(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}

static MetalHandle create_default_device_handle(void) {
#if TARGET_OS_OSX
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    id<MTLDevice> device = devices.count > 0 ? devices.firstObject : nil;
    if (device == nil) {
        device = MTLCreateSystemDefaultDevice();
    }
#else
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
#endif
    if (device == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(device);
}

static MetalHandle retained_default_device_handle(void) {
    static MetalHandle cached_default_device = NULL;
    if (cached_default_device == NULL) {
        cached_default_device = create_default_device_handle();
        if (cached_default_device == NULL) {
            return NULL;
        }
    }
    CFRetain(cached_default_device);
    return cached_default_device;
}

@interface MetalSurfaceHost : NSObject
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSView* view;
@property(nonatomic, strong) CAMetalLayer* layer;
- (instancetype)initOffscreen;
- (void)configureWithWidth:(uint32_t)width height:(uint32_t)height;
@end

@implementation MetalSurfaceHost

- (instancetype)initOffscreen {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    ensure_headless_application_ready();

    NSRect frame = NSMakeRect(0.0, 0.0, 64.0, 64.0);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    if (self.window == nil) {
        return nil;
    }
    [self.window setReleasedWhenClosed:NO];
    [self.window setOpaque:YES];
    [self.window setAlphaValue:1.0];
    [self.window setIgnoresMouseEvents:YES];

    self.view = [[NSView alloc] initWithFrame:frame];
    [self.view setWantsLayer:YES];

    self.layer = [CAMetalLayer layer];
    [self.layer setContentsScale:1.0];
    [self.layer setOpaque:YES];

    [self.view setLayer:self.layer];
    [self.window setContentView:self.view];
    [self.window orderFrontRegardless];
    return self;
}

- (void)configureWithWidth:(uint32_t)width height:(uint32_t)height {
    CGFloat w = (CGFloat)width;
    CGFloat h = (CGFloat)height;
    NSRect frame = NSMakeRect(0.0, 0.0, w, h);
    [self.window setFrame:frame display:NO];
    [self.view setFrame:NSMakeRect(0.0, 0.0, w, h)];
    [self.layer setFrame:CGRectMake(0.0, 0.0, w, h)];
    [self.layer setBounds:CGRectMake(0.0, 0.0, w, h)];
    [self.layer setDrawableSize:CGSizeMake(w, h)];
    [self.window orderFrontRegardless];
    [self.window displayIfNeeded];
    [self.view displayIfNeeded];
    [CATransaction flush];
}

@end

MetalHandle metal_bridge_create_default_device(void) {
    return retained_default_device_handle();
}

MetalHandle metal_bridge_create_surface_host(MetalHandle* layer_out) {
    MetalSurfaceHost* host = [[MetalSurfaceHost alloc] initOffscreen];
    if (host == nil || host.layer == nil) return NULL;
    if (layer_out != NULL) {
        *layer_out = (__bridge MetalHandle)host.layer;
    }
    return (MetalHandle)CFBridgingRetain(host);
}

void metal_bridge_configure_surface_host(MetalHandle host_h, uint32_t width, uint32_t height) {
    MetalSurfaceHost* host = (__bridge MetalSurfaceHost*)host_h;
    if (host == nil) return;
    [host configureWithWidth:width height:height];
}

MetalHandle metal_bridge_retain(MetalHandle obj) {
    if (obj == NULL) return NULL;
    return (MetalHandle)CFRetain(obj);
}

void metal_bridge_release(MetalHandle obj) {
    if (obj == NULL) return;
    CFRelease(obj);
}

MetalHandle metal_bridge_device_new_command_queue(MetalHandle device_h) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (queue == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(queue);
}

MetalHandle metal_bridge_device_new_buffer_shared(MetalHandle device_h, size_t length) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    id<MTLBuffer> buf = [device newBufferWithLength:length
                                           options:MTLResourceStorageModeShared];
    if (buf == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(buf);
}

MetalHandle metal_bridge_device_new_buffer_private(MetalHandle device_h, size_t length) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    id<MTLBuffer> buf = [device newBufferWithLength:length
                                           options:MTLResourceStorageModePrivate];
    if (buf == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(buf);
}

void* metal_bridge_buffer_contents(MetalHandle buffer_h) {
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer_h;
    return [buf contents];
}

MetalHandle metal_bridge_encode_blit_copy(
    MetalHandle queue_h,
    MetalHandle src_h,
    MetalHandle dst_h,
    size_t      byte_count)
{
    id<MTLCommandQueue> queue   = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLBuffer>       src_buf = (__bridge id<MTLBuffer>)src_h;
    id<MTLBuffer>       dst_buf = (__bridge id<MTLBuffer>)dst_h;

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    [encoder copyFromBuffer:src_buf
               sourceOffset:0
                   toBuffer:dst_buf
          destinationOffset:0
                       size:byte_count];
    [encoder endEncoding];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

void metal_bridge_command_buffer_commit(MetalHandle cmd_buf_h) {
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    [cmd_buf commit];
}

void metal_bridge_command_buffer_wait_completed(MetalHandle cmd_buf_h) {
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    [cmd_buf waitUntilCompleted];
}

void metal_bridge_command_buffer_spin_wait(MetalHandle cmd_buf_h) {
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    while ([cmd_buf status] < MTLCommandBufferStatusCompleted) {
        /* spin */
    }
}

int metal_bridge_command_buffer_retain_object_until_complete(
    MetalHandle cmd_buf_h,
    MetalHandle object_h)
{
    if (cmd_buf_h == NULL || object_h == NULL) return 0;
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    CFRetain(object_h);
    [cmd_buf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        (void)cb;
        CFRelease(object_h);
    }];
    return 1;
}

static volatile int32_t _atomic_done = 0;
void metal_bridge_command_buffer_setup_atomic_wait(MetalHandle cmd_buf_h) {
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    __atomic_store_n(&_atomic_done, 0, __ATOMIC_RELEASE);
    [cmd_buf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        __atomic_store_n(&_atomic_done, 1, __ATOMIC_RELEASE);
    }];
}

void metal_bridge_command_buffer_atomic_wait(void) {
    while (!__atomic_load_n(&_atomic_done, __ATOMIC_ACQUIRE)) {
        /* spin — no kernel call */
    }
}

// ============================================================
// Streaming Blit Encoder
// ============================================================

MetalHandle metal_bridge_begin_blit_encoding(MetalHandle queue_h, MetalHandle* encoder_out) {
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;
    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    if (encoder == nil) return NULL;
    *encoder_out = (__bridge MetalHandle)encoder; // unretained — lifetime tied to cmd_buf
    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

void metal_bridge_blit_encoder_copy(
    MetalHandle encoder_h,
    MetalHandle src_h,
    MetalHandle dst_h,
    size_t      byte_count)
{
    id<MTLBlitCommandEncoder> encoder = (__bridge id<MTLBlitCommandEncoder>)encoder_h;
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)src_h;
    id<MTLBuffer> dst = (__bridge id<MTLBuffer>)dst_h;
    [encoder copyFromBuffer:src sourceOffset:0
                   toBuffer:dst destinationOffset:0
                       size:byte_count];
}

void metal_bridge_blit_encoder_copy_region(
    MetalHandle encoder_h,
    MetalHandle src_h,
    uint64_t    src_offset,
    MetalHandle dst_h,
    uint64_t    dst_offset,
    uint64_t    size)
{
    id<MTLBlitCommandEncoder> encoder = (__bridge id<MTLBlitCommandEncoder>)encoder_h;
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)src_h;
    id<MTLBuffer> dst = (__bridge id<MTLBuffer>)dst_h;
    [encoder copyFromBuffer:src
               sourceOffset:(NSUInteger)src_offset
                   toBuffer:dst
          destinationOffset:(NSUInteger)dst_offset
                       size:(NSUInteger)size];
}

void metal_bridge_blit_encoder_copy_buffer_to_texture(
    MetalHandle encoder_h,
    MetalHandle src_h,
    uint64_t    src_offset,
    uint32_t    src_bytes_per_row,
    uint32_t    src_rows_per_image,
    MetalHandle dst_texture_h,
    uint32_t    dst_mip_level,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers)
{
    id<MTLBlitCommandEncoder> encoder = (__bridge id<MTLBlitCommandEncoder>)encoder_h;
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)src_h;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)dst_texture_h;
    MTLSize copy_size = MTLSizeMake(width, height, depth_or_array_layers);
    SEL copy_sel = @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:);
    typedef void (*CopyBufferToTextureFn)(id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger, NSUInteger, MTLSize, id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin);
    static CopyBufferToTextureFn copy_fn = NULL;
    if (copy_fn == NULL) {
        copy_fn = (CopyBufferToTextureFn)(IMP)[(id)encoder methodForSelector:copy_sel];
    }
    copy_fn(
        encoder,
        copy_sel,
        src,
        (NSUInteger)src_offset,
        (NSUInteger)src_bytes_per_row,
        (NSUInteger)src_rows_per_image * (NSUInteger)src_bytes_per_row,
        copy_size,
        dst,
        0,
        (NSUInteger)dst_mip_level,
        MTLOriginMake(0, 0, 0));
}

void metal_bridge_blit_encoder_copy_texture_to_buffer(
    MetalHandle encoder_h,
    MetalHandle src_texture_h,
    uint32_t    src_mip_level,
    MetalHandle dst_h,
    uint64_t    dst_offset,
    uint32_t    dst_bytes_per_row,
    uint32_t    dst_rows_per_image,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers)
{
    id<MTLBlitCommandEncoder> encoder = (__bridge id<MTLBlitCommandEncoder>)encoder_h;
    id<MTLTexture> src = (__bridge id<MTLTexture>)src_texture_h;
    id<MTLBuffer> dst = (__bridge id<MTLBuffer>)dst_h;
    MTLSize copy_size = MTLSizeMake(width, height, depth_or_array_layers);
    [encoder copyFromTexture:src
                 sourceSlice:0
                 sourceLevel:(NSUInteger)src_mip_level
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:copy_size
                    toBuffer:dst
           destinationOffset:(NSUInteger)dst_offset
      destinationBytesPerRow:(NSUInteger)dst_bytes_per_row
    destinationBytesPerImage:(NSUInteger)dst_rows_per_image * (NSUInteger)dst_bytes_per_row];
}

void metal_bridge_blit_encoder_copy_texture_to_texture(
    MetalHandle encoder_h,
    MetalHandle src_texture_h,
    uint32_t    src_mip_level,
    MetalHandle dst_texture_h,
    uint32_t    dst_mip_level,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers)
{
    id<MTLBlitCommandEncoder> encoder = (__bridge id<MTLBlitCommandEncoder>)encoder_h;
    id<MTLTexture> src = (__bridge id<MTLTexture>)src_texture_h;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)dst_texture_h;
    MTLSize copy_size = MTLSizeMake(width, height, depth_or_array_layers);
    SEL copy_sel = @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:);
    typedef void (*CopyTextureToTextureFn)(id, SEL, id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin);
    static CopyTextureToTextureFn copy_fn = NULL;
    if (copy_fn == NULL) {
        copy_fn = (CopyTextureToTextureFn)(IMP)[(id)encoder methodForSelector:copy_sel];
    }
    copy_fn(
        encoder,
        copy_sel,
        src,
        0,
        (NSUInteger)src_mip_level,
        MTLOriginMake(0, 0, 0),
        copy_size,
        dst,
        0,
        (NSUInteger)dst_mip_level,
        MTLOriginMake(0, 0, 0));
}

void metal_bridge_end_blit_encoding(MetalHandle encoder_h) {
    id<MTLBlitCommandEncoder> encoder = (__bridge id<MTLBlitCommandEncoder>)encoder_h;
    [encoder endEncoding];
}

// ============================================================
// Shared Event (lightweight GPU fence)
// ============================================================

MetalHandle metal_bridge_device_new_shared_event(MetalHandle device_h) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    id<MTLSharedEvent> event = [device newSharedEvent];
    if (event == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(event);
}

uint64_t metal_bridge_shared_event_signaled_value(MetalHandle event_h) {
    id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)event_h;
    return event.signaledValue;
}

static MTLSharedEventListener* metal_bridge_shared_event_listener(void) {
    static MTLSharedEventListener* listener = nil;
    static dispatch_queue_t listener_queue = nil;
    if (listener == nil) {
        @synchronized([MTLSharedEventListener class]) {
            if (listener == nil) {
                listener_queue = dispatch_queue_create("doe.metal.shared-event-listener", DISPATCH_QUEUE_SERIAL);
                listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:listener_queue];
            }
        }
    }
    return listener;
}

void metal_bridge_command_buffer_encode_signal_event(
    MetalHandle cmd_buf_h,
    MetalHandle event_h,
    uint64_t    value)
{
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLSharedEvent>   event   = (__bridge id<MTLSharedEvent>)event_h;
    [cmd_buf encodeSignalEvent:event value:value];
}

void metal_bridge_shared_event_wait(MetalHandle event_h, uint64_t value) {
    id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)event_h;
    if (event.signaledValue >= value) return;

    for (int i = 0; i < 250000; i++) {
        if (event.signaledValue >= value) return;
#if defined(__aarch64__) || defined(__arm64__)
        __asm__ volatile ("yield");
#endif
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    MTLSharedEventListener* listener = metal_bridge_shared_event_listener();
    [event notifyListener:listener atValue:value block:^(id<MTLSharedEvent> _Nonnull shared_event, uint64_t signaled_value) {
        (void)shared_event;
        (void)signaled_value;
        dispatch_semaphore_signal(sem);
    }];
    if (event.signaledValue >= value) return;
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

int metal_bridge_shared_event_notify(
    MetalHandle event_h,
    uint64_t value,
    MetalCompletionCallback callback,
    void* userdata)
{
    id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)event_h;
    if (event == nil || callback == NULL) return 0;
    MTLSharedEventListener* listener = metal_bridge_shared_event_listener();
    if (listener == nil) return 0;
    [event notifyListener:listener atValue:value block:^(id<MTLSharedEvent> _Nonnull shared_event, uint64_t signaled_value) {
        (void)shared_event;
        (void)signaled_value;
        callback(userdata);
    }];
    return 1;
}

MetalHandle metal_bridge_encode_blit_batch(
    MetalHandle  queue_h,
    MetalHandle* src_bufs,
    MetalHandle* dst_bufs,
    size_t*      byte_counts,
    uint32_t     count)
{
    if (count == 0) return NULL;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)queue_h;

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    for (uint32_t i = 0; i < count; i++) {
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)src_bufs[i];
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)dst_bufs[i];
        [encoder copyFromBuffer:src sourceOffset:0
                       toBuffer:dst destinationOffset:0
                           size:byte_counts[i]];
    }
    [encoder endEncoding];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

// ============================================================
// Streaming Command Buffer (shared across blit/render/compute)
// ============================================================

MetalHandle metal_bridge_create_command_buffer(MetalHandle queue_h) {
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

MetalHandle metal_bridge_cmd_buf_blit_encoder(MetalHandle cmd_buf_h) {
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    if (encoder == nil) return NULL;
    return (__bridge MetalHandle)encoder; // unretained — lifetime tied to cmd_buf
}

MetalHandle metal_bridge_cmd_buf_compute_encoder(MetalHandle cmd_buf_h) {
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    if (encoder == nil) return NULL;
    return (__bridge MetalHandle)encoder; // unretained — lifetime tied to cmd_buf
}

MetalHandle metal_bridge_cmd_buf_compute_encoder_with_timestamps(
    MetalHandle cmd_buf_h,
    MetalHandle counter_buffer_h,
    uint32_t    begin_query_index,
    uint32_t    end_query_index)
{
    if (cmd_buf_h == NULL || counter_buffer_h == NULL) return NULL;
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLCounterSampleBuffer> samples =
        (__bridge id<MTLCounterSampleBuffer>)counter_buffer_h;
    id<MTLDevice> device = cmd_buf.commandQueue.device;
    if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
        return NULL;
    }

    MTLComputePassDescriptor* pass = [MTLComputePassDescriptor computePassDescriptor];
    MTLComputePassSampleBufferAttachmentDescriptor* attachment =
        pass.sampleBufferAttachments[0];
    attachment.sampleBuffer = samples;
    attachment.startOfEncoderSampleIndex = begin_query_index;
    attachment.endOfEncoderSampleIndex = end_query_index;
    id<MTLComputeCommandEncoder> encoder =
        [cmd_buf computeCommandEncoderWithDescriptor:pass];
    if (encoder == nil) return NULL;
    return (__bridge MetalHandle)encoder; // unretained — lifetime tied to cmd_buf
}

void metal_bridge_end_compute_encoding(MetalHandle encoder_h) {
    id<MTLComputeCommandEncoder> encoder = (__bridge id<MTLComputeCommandEncoder>)encoder_h;
    [encoder endEncoding];
}

void metal_bridge_cmd_buf_encode_render_pass(
    MetalHandle cmd_buf_h,
    MetalHandle pipeline_h,
    MetalHandle target_h,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    int         redundant_pipeline,
    int         redundant_bindgroup)
{
    (void)redundant_bindgroup;
    id<MTLCommandBuffer>        cmd_buf  = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLRenderPipelineState>  pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    id<MTLTexture>              target   = (__bridge id<MTLTexture>)target_h;

    MTLRenderPassDescriptor* pass = cachedRenderPassDescriptor(target, nil, nil, &_defaultRenderPassOps);
    id<MTLRenderCommandEncoder> encoder = [cmd_buf renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];

    for (uint32_t i = 0; i < draw_count; i++) {
        if (redundant_pipeline) {
            [encoder setRenderPipelineState:pipeline];
        }
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:vertex_count
                  instanceCount:instance_count];
    }
    [encoder endEncoding];
}

void metal_bridge_cmd_buf_encode_icb_render_pass(
    MetalHandle cmd_buf_h,
    MetalHandle pipeline_h,
    MetalHandle icb_h,
    MetalHandle target_h,
    uint32_t    draw_count)
{
    id<MTLCommandBuffer>         cmd_buf  = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLRenderPipelineState>   pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    id<MTLIndirectCommandBuffer> icb      = (__bridge id<MTLIndirectCommandBuffer>)icb_h;
    id<MTLTexture>               target   = (__bridge id<MTLTexture>)target_h;

    MTLRenderPassDescriptor* pass = cachedRenderPassDescriptor(target, nil, nil, &_defaultRenderPassOps);
    id<MTLRenderCommandEncoder> encoder = [cmd_buf renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder executeCommandsInBuffer:icb withRange:NSMakeRange(0, draw_count)];
    [encoder endEncoding];
}

// === Cached render encoder (kept open across render_draw calls) ===

MetalHandle metal_bridge_cmd_buf_render_encoder(
    MetalHandle cmd_buf_h,
    MetalHandle pipeline_h,
    MetalHandle target_h,
    MetalHandle resolve_target_h,
    MetalHandle depth_target_h,
    const MetalRenderPassOps* ops)
{
    id<MTLCommandBuffer>        cmd_buf  = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLRenderPipelineState>  pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    id<MTLTexture>              target   = (__bridge id<MTLTexture>)target_h;
    id<MTLTexture>              resolve_target = (__bridge id<MTLTexture>)resolve_target_h;
    id<MTLTexture>              depth_target = (__bridge id<MTLTexture>)depth_target_h;

    MTLRenderPassDescriptor* pass = cachedRenderPassDescriptor(target, resolve_target, depth_target, ops);
    if (pass == nil) return NULL;
    id<MTLRenderCommandEncoder> encoder = [cmd_buf renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) return NULL;
    if (pipeline != nil) [encoder setRenderPipelineState:pipeline];
    return (MetalHandle)CFBridgingRetain(encoder); // +1 retained; caller must release
}

void metal_bridge_render_encoder_set_bind_buffer(
    MetalHandle encoder_h,
    uint32_t    slot,
    MetalHandle buffer_h,
    uint64_t    offset)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)buffer_h;
    [encoder setVertexBuffer:buffer offset:(NSUInteger)offset atIndex:slot];
    [encoder setFragmentBuffer:buffer offset:(NSUInteger)offset atIndex:slot];
}

void metal_bridge_render_encoder_set_bind_texture(
    MetalHandle encoder_h,
    uint32_t    slot,
    MetalHandle texture_h)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)texture_h;
    [encoder setVertexTexture:texture atIndex:slot];
    [encoder setFragmentTexture:texture atIndex:slot];
}

void metal_bridge_render_encoder_set_bind_sampler(
    MetalHandle encoder_h,
    uint32_t    slot,
    MetalHandle sampler_h)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLSamplerState> sampler = (__bridge id<MTLSamplerState>)sampler_h;
    [encoder setVertexSamplerState:sampler atIndex:slot];
    [encoder setFragmentSamplerState:sampler atIndex:slot];
}

void metal_bridge_render_encoder_set_vertex_buffer(
    MetalHandle encoder_h,
    uint32_t    slot,
    MetalHandle buffer_h,
    uint64_t    offset)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)buffer_h;
    [encoder setVertexBuffer:buffer offset:(NSUInteger)offset atIndex:slot];
}

void metal_bridge_render_encoder_set_depth_stencil_state(
    MetalHandle encoder_h,
    MetalHandle depth_state_h)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLDepthStencilState> depth_state = (__bridge id<MTLDepthStencilState>)depth_state_h;
    [encoder setDepthStencilState:depth_state];
}

void metal_bridge_render_encoder_set_depth_stencil_values(
    MetalHandle encoder_h,
    uint32_t    compare_fn,
    int         write_enabled)
{
    (void)encoder_h;
    (void)compare_fn;
    (void)write_enabled;
}

void metal_bridge_render_encoder_set_depth_clip_mode(
    MetalHandle encoder_h,
    int         clamp)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    [encoder setDepthClipMode:clamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
}

void metal_bridge_render_encoder_set_front_facing(
    MetalHandle encoder_h,
    uint32_t    front_face)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    [encoder setFrontFacingWinding:wgpu_to_mtl_winding(front_face)];
}

void metal_bridge_render_encoder_set_cull_mode(
    MetalHandle encoder_h,
    uint32_t    cull_mode)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    [encoder setCullMode:wgpu_to_mtl_cull(cull_mode)];
}

void metal_bridge_render_encoder_draw(
    MetalHandle encoder_h,
    uint32_t    topology,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    uint32_t    first_vertex,
    uint32_t    first_instance,
    int         redundant_pipeline,
    MetalHandle pipeline_h)
{
    id<MTLRenderCommandEncoder> encoder  = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLRenderPipelineState>  pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    const MTLPrimitiveType primitive = wgpu_to_mtl_primitive(topology);
    SEL set_pipeline_sel = @selector(setRenderPipelineState:);
    typedef void (*SetPipelineFn)(id, SEL, id<MTLRenderPipelineState>);
    SetPipelineFn set_pipeline_fn = (SetPipelineFn)(IMP)[(id)encoder methodForSelector:set_pipeline_sel];

    if (first_instance == 0 && instance_count == 1) {
        SEL draw_sel = @selector(drawPrimitives:vertexStart:vertexCount:);
        typedef void (*DrawPrimitivesSingleInstanceFn)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
        DrawPrimitivesSingleInstanceFn draw_fn = (DrawPrimitivesSingleInstanceFn)(IMP)[(id)encoder methodForSelector:draw_sel];
        if (redundant_pipeline) {
            for (uint32_t i = 0; i < draw_count; i++) {
                set_pipeline_fn(encoder, set_pipeline_sel, pipeline);
                draw_fn(encoder, draw_sel, primitive, first_vertex, vertex_count);
            }
            return;
        }
        for (uint32_t i = 0; i < draw_count; i++) {
            draw_fn(encoder, draw_sel, primitive, first_vertex, vertex_count);
        }
        return;
    }

    if (first_instance == 0) {
        SEL draw_sel = @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:);
        typedef void (*DrawPrimitivesFn)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
        DrawPrimitivesFn draw_fn = (DrawPrimitivesFn)(IMP)[(id)encoder methodForSelector:draw_sel];
        if (redundant_pipeline) {
            for (uint32_t i = 0; i < draw_count; i++) {
                set_pipeline_fn(encoder, set_pipeline_sel, pipeline);
                draw_fn(encoder, draw_sel, primitive, first_vertex, vertex_count, instance_count);
            }
            return;
        }
        for (uint32_t i = 0; i < draw_count; i++) {
            draw_fn(encoder, draw_sel, primitive, first_vertex, vertex_count, instance_count);
        }
        return;
    }

    SEL draw_sel = @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:);
    typedef void (*DrawPrimitivesBaseInstanceFn)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
    DrawPrimitivesBaseInstanceFn draw_fn = (DrawPrimitivesBaseInstanceFn)(IMP)[(id)encoder methodForSelector:draw_sel];
    if (redundant_pipeline) {
        for (uint32_t i = 0; i < draw_count; i++) {
            set_pipeline_fn(encoder, set_pipeline_sel, pipeline);
            draw_fn(encoder, draw_sel, primitive, first_vertex, vertex_count, instance_count, first_instance);
        }
        return;
    }
    for (uint32_t i = 0; i < draw_count; i++) {
        draw_fn(encoder, draw_sel, primitive, first_vertex, vertex_count, instance_count, first_instance);
    }
}

void metal_bridge_render_encoder_draw_indexed(
    MetalHandle encoder_h,
    uint32_t    topology,
    uint32_t    draw_count,
    uint32_t    index_count,
    uint32_t    instance_count,
    MetalHandle index_buffer_h,
    uint64_t    index_offset,
    uint32_t    index_format,
    int32_t     base_vertex,
    uint32_t    first_instance)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer> index_buffer = (__bridge id<MTLBuffer>)index_buffer_h;
    const MTLPrimitiveType primitive = wgpu_to_mtl_primitive(topology);
    const MTLIndexType index_type = wgpu_to_mtl_index_type(index_format);
    for (uint32_t i = 0; i < draw_count; i++) {
        [encoder drawIndexedPrimitives:primitive
                            indexCount:index_count
                             indexType:index_type
                           indexBuffer:index_buffer
                     indexBufferOffset:(NSUInteger)index_offset
                         instanceCount:instance_count
                            baseVertex:base_vertex
                          baseInstance:first_instance];
    }
}

void metal_bridge_render_encoder_execute_icb(
    MetalHandle encoder_h,
    MetalHandle icb_h,
    uint32_t    draw_count)
{
    id<MTLRenderCommandEncoder>  encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLIndirectCommandBuffer> icb     = (__bridge id<MTLIndirectCommandBuffer>)icb_h;
    [encoder executeCommandsInBuffer:icb withRange:NSMakeRange(0, draw_count)];
}

void metal_bridge_render_encoder_end(MetalHandle encoder_h) {
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    [encoder endEncoding];
}

// ============================================================
// Compute Pipeline
// ============================================================

static void write_error(NSError* err, char* buf, size_t cap) {
    if (buf == NULL || cap == 0) return;
    const char* msg = err ? [[err localizedDescription] UTF8String] : "unknown error";
    strncpy(buf, msg, cap - 1);
    buf[cap - 1] = '\0';
}

MetalHandle metal_bridge_device_new_library_msl(
    MetalHandle device_h,
    const char* src,
    size_t      src_len,
    char*       error_buf,
    size_t      error_cap)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;

    // Retain cached values while holding the lock so a concurrent cache
    // initialization or insertion cannot invalidate the returned object.
    NSData* key = msl_source_hash(src, src_len);
    MetalHandle cached_handle = NULL;
    os_unfair_lock_lock(&_mslLibraryCacheLock);
    if (_mslLibraryCache == nil) {
        _mslLibraryCache = [NSMutableDictionary new];
    }
    id<MTLLibrary> cached = _mslLibraryCache[key];
    if (cached != nil) {
        cached_handle = (MetalHandle)CFBridgingRetain(cached);
    }
    os_unfair_lock_unlock(&_mslLibraryCacheLock);
    if (cached_handle != NULL) return cached_handle;

    NSString* source = [[NSString alloc] initWithBytes:src length:src_len encoding:NSUTF8StringEncoding];
    if (source == nil) {
        if (error_buf && error_cap) strncpy(error_buf, "invalid MSL source encoding", error_cap - 1);
        return NULL;
    }
    NSError* err = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&err];
    if (library == nil) {
        write_error(err, error_buf, error_cap);
        return NULL;
    }
    // Another compiler may have populated this key while Metal compiled.
    // Prefer that canonical object and retain the chosen result under lock.
    os_unfair_lock_lock(&_mslLibraryCacheLock);
    cached = _mslLibraryCache[key];
    if (cached != nil) {
        cached_handle = (MetalHandle)CFBridgingRetain(cached);
    } else {
        _mslLibraryCache[key] = library;
        cached_handle = (MetalHandle)CFBridgingRetain(library);
    }
    os_unfair_lock_unlock(&_mslLibraryCacheLock);
    return cached_handle;
}

MetalHandle metal_bridge_library_new_function(MetalHandle library_h, const char* name) {
    id<MTLLibrary> library = (__bridge id<MTLLibrary>)library_h;
    NSString* fname = [NSString stringWithUTF8String:name];
    id<MTLFunction> fn = [library newFunctionWithName:fname];
    if (fn == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(fn);
}

MetalHandle metal_bridge_device_new_compute_pipeline(
    MetalHandle device_h,
    MetalHandle function_h,
    char*       error_buf,
    size_t      error_cap)
{
    id<MTLDevice>   device   = (__bridge id<MTLDevice>)device_h;
    id<MTLFunction> function = (__bridge id<MTLFunction>)function_h;
    NSError* err = nil;
    id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:function error:&err];
    if (pso == nil) {
        write_error(err, error_buf, error_cap);
        return NULL;
    }
    return (MetalHandle)CFBridgingRetain(pso);
}

MetalHandle metal_bridge_encode_compute_dispatch(
    MetalHandle  queue_h,
    MetalHandle  pipeline_h,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z)
{
    id<MTLCommandQueue>          queue    = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLComputePipelineState>  pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];

    for (uint32_t i = 0; i < buffer_count; i++) {
        if (buffers[i] != NULL) {
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffers[i];
            [encoder setBuffer:buf offset:0 atIndex:i];
        }
    }

    NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
    if (max_tg == 0) max_tg = 256;
    MTLSize tg_size;
    if (y > 1) {
        NSUInteger tg_x = (NSUInteger)sqrt((double)max_tg);
        while (tg_x > 1 && max_tg % tg_x != 0) tg_x--;
        tg_size = MTLSizeMake(tg_x, max_tg / tg_x, 1);
    } else {
        tg_size = MTLSizeMake(max_tg, 1, 1);
    }
    MTLSize grid_size  = MTLSizeMake(x, y, z);
    [encoder dispatchThreadgroups:grid_size threadsPerThreadgroup:tg_size];
    [encoder endEncoding];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

void metal_bridge_cmd_buf_encode_blit_copy(
    MetalHandle cmd_buf_h,
    MetalHandle src_h,
    uint64_t    src_offset,
    MetalHandle dst_h,
    uint64_t    dst_offset,
    uint64_t    size)
{
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)src_h;
    id<MTLBuffer> dst = (__bridge id<MTLBuffer>)dst_h;
    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    [encoder copyFromBuffer:src sourceOffset:(NSUInteger)src_offset
                   toBuffer:dst destinationOffset:(NSUInteger)dst_offset
                       size:(NSUInteger)size];
    [encoder endEncoding];
}

// ============================================================
// clearBuffer / copyTextureToTexture / writeTexture
// ============================================================

void metal_bridge_cmd_buf_fill_buffer(
    MetalHandle cmd_buf_h,
    MetalHandle buffer_h,
    uint64_t    offset,
    uint64_t    size)
{
    if (cmd_buf_h == NULL || buffer_h == NULL || size == 0) return;
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)buffer_h;
    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    [encoder fillBuffer:buffer range:NSMakeRange((NSUInteger)offset, (NSUInteger)size) value:0];
    [encoder endEncoding];
}

void metal_bridge_cmd_buf_copy_texture_to_texture(
    MetalHandle cmd_buf_h,
    MetalHandle src_texture_h,
    uint32_t    src_mip,
    uint32_t    src_slice,
    uint32_t    src_x,
    uint32_t    src_y,
    uint32_t    src_z,
    MetalHandle dst_texture_h,
    uint32_t    dst_mip,
    uint32_t    dst_slice,
    uint32_t    dst_x,
    uint32_t    dst_y,
    uint32_t    dst_z,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_layers)
{
    if (cmd_buf_h == NULL || src_texture_h == NULL || dst_texture_h == NULL) return;
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLTexture> src = (__bridge id<MTLTexture>)src_texture_h;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)dst_texture_h;
    MTLSize copy_size = MTLSizeMake(
        width  > 0 ? width  : 1,
        height > 0 ? height : 1,
        depth_or_layers > 0 ? depth_or_layers : 1);
    id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];
    [encoder copyFromTexture:src
                 sourceSlice:(NSUInteger)src_slice
                 sourceLevel:(NSUInteger)src_mip
                sourceOrigin:MTLOriginMake(src_x, src_y, src_z)
                  sourceSize:copy_size
                   toTexture:dst
            destinationSlice:(NSUInteger)dst_slice
            destinationLevel:(NSUInteger)dst_mip
           destinationOrigin:MTLOriginMake(dst_x, dst_y, dst_z)];
    [encoder endEncoding];
}

int metal_bridge_texture_write_region(
    MetalHandle  texture_h,
    const void*  data,
    uint32_t     bytes_per_row,
    uint32_t     rows_per_image,
    uint32_t     dst_x,
    uint32_t     dst_y,
    uint32_t     dst_z,
    uint32_t     dst_mip,
    uint32_t     dst_slice,
    uint32_t     width,
    uint32_t     height,
    uint32_t     depth_or_layers)
{
    if (texture_h == NULL || data == NULL || width == 0 || height == 0) return 0;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture_h;
    NSUInteger d = depth_or_layers > 0 ? depth_or_layers : 1;
    MTLRegion region;
    if (tex.textureType == MTLTextureType3D) {
        region = MTLRegionMake3D(dst_x, dst_y, dst_z, width, height, d);
        NSUInteger bpi = (NSUInteger)rows_per_image * (NSUInteger)bytes_per_row;
        if (bpi == 0) bpi = (NSUInteger)height * (NSUInteger)bytes_per_row;
        [tex replaceRegion:region
               mipmapLevel:(NSUInteger)dst_mip
                     slice:(NSUInteger)dst_slice
                 withBytes:data
               bytesPerRow:(NSUInteger)bytes_per_row
             bytesPerImage:bpi];
    } else {
        region = MTLRegionMake2D(dst_x, dst_y, width, height);
        [tex replaceRegion:region
               mipmapLevel:(NSUInteger)dst_mip
                     slice:(NSUInteger)dst_slice
                 withBytes:data
               bytesPerRow:(NSUInteger)bytes_per_row
             bytesPerImage:0];
    }
    return 1;
}

void metal_bridge_cmd_buf_encode_compute_dispatch(
    MetalHandle  cmd_buf_h,
    MetalHandle  pipeline_h,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z)
{
    id<MTLCommandBuffer>         cmd_buf  = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    metal_bridge_compute_encoder_encode_dispatch(
        (__bridge MetalHandle)encoder,
        pipeline_h,
        buffers,
        buffer_count,
        x,
        y,
        z,
        wg_x,
        wg_y,
        wg_z);
    [encoder endEncoding];
}

void metal_bridge_compute_encoder_encode_dispatch(
    MetalHandle  encoder_h,
    MetalHandle  pipeline_h,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z)
{
    id<MTLComputeCommandEncoder> encoder = (__bridge id<MTLComputeCommandEncoder>)encoder_h;
    id<MTLComputePipelineState>  pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;

    [encoder setComputePipelineState:pipeline];

    for (uint32_t i = 0; i < buffer_count; i++) {
        if (buffers[i] != NULL) {
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffers[i];
            [encoder setBuffer:buf offset:0 atIndex:i];
        }
    }

    MTLSize tg_size;
    if (wg_x > 0) {
        tg_size = MTLSizeMake(wg_x, wg_y > 0 ? wg_y : 1, wg_z > 0 ? wg_z : 1);
    } else {
        NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
        if (max_tg == 0) max_tg = 256;
        tg_size = MTLSizeMake(max_tg, 1, 1);
    }
    MTLSize grid_size = MTLSizeMake(x, y, z);
    [encoder dispatchThreadgroups:grid_size threadsPerThreadgroup:tg_size];
}

static void metal_bridge_compute_encoder_encode_dispatch_batch_impl(
    MetalHandle         encoder_h,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     repeat_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count)
{
    if (encoder_h == NULL || pipelines == NULL || buffers == NULL ||
        buffer_counts == NULL || dispatch_dims == NULL || workgroup_dims == NULL ||
        dispatch_count == 0 || max_buffer_count == 0) {
        return;
    }

    id<MTLComputeCommandEncoder> encoder = (__bridge id<MTLComputeCommandEncoder>)encoder_h;
    id<MTLComputePipelineState> current_pipeline = nil;
    id<MTLBuffer> current_buffers[64];
    const uint32_t tracked_buffer_count = max_buffer_count < 64 ? max_buffer_count : 64;
    for (uint32_t i = 0; i < tracked_buffer_count; i++) {
        current_buffers[i] = nil;
    }

    for (uint32_t dispatch_index = 0; dispatch_index < dispatch_count; dispatch_index++) {
        MetalHandle pipeline_h = pipelines[dispatch_index];
        if (pipeline_h == NULL) continue;
        id<MTLComputePipelineState> pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;
        if (pipeline != current_pipeline) {
            [encoder setComputePipelineState:pipeline];
            current_pipeline = pipeline;
        }

        uint32_t buffer_count = buffer_counts[dispatch_index];
        if (buffer_count > max_buffer_count) buffer_count = max_buffer_count;
        const MetalHandle* dispatch_buffers = buffers + ((size_t)dispatch_index * (size_t)max_buffer_count);
        for (uint32_t i = 0; i < buffer_count; i++) {
            MetalHandle buffer_h = dispatch_buffers[i];
            if (buffer_h == NULL) continue;
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer_h;
            if (i < tracked_buffer_count) {
                if (current_buffers[i] == buf) continue;
                current_buffers[i] = buf;
            }
            [encoder setBuffer:buf offset:0 atIndex:i];
        }

        const uint32_t dim_offset = dispatch_index * 3;
        const uint32_t x = dispatch_dims[dim_offset];
        const uint32_t y = dispatch_dims[dim_offset + 1];
        const uint32_t z = dispatch_dims[dim_offset + 2];
        const uint32_t wg_x = workgroup_dims[dim_offset];
        const uint32_t wg_y = workgroup_dims[dim_offset + 1];
        const uint32_t wg_z = workgroup_dims[dim_offset + 2];
        const uint32_t repeat_count = repeat_counts != NULL ? repeat_counts[dispatch_index] : 1;
        if (repeat_count == 0) continue;

        MTLSize tg_size;
        if (wg_x > 0) {
            tg_size = MTLSizeMake(wg_x, wg_y > 0 ? wg_y : 1, wg_z > 0 ? wg_z : 1);
        } else {
            NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
            if (max_tg == 0) max_tg = 256;
            tg_size = MTLSizeMake(max_tg, 1, 1);
        }
        MTLSize grid_size = MTLSizeMake(x, y, z);
        for (uint32_t repeat_index = 0; repeat_index < repeat_count; repeat_index++) {
            [encoder dispatchThreadgroups:grid_size threadsPerThreadgroup:tg_size];
        }
    }
}

void metal_bridge_compute_encoder_encode_dispatch_batch(
    MetalHandle         encoder_h,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count)
{
    metal_bridge_compute_encoder_encode_dispatch_batch_impl(
        encoder_h,
        pipelines,
        buffers,
        buffer_counts,
        NULL,
        dispatch_dims,
        workgroup_dims,
        dispatch_count,
        max_buffer_count);
}

void metal_bridge_compute_encoder_encode_dispatch_batch_repeated(
    MetalHandle         encoder_h,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     repeat_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count)
{
    metal_bridge_compute_encoder_encode_dispatch_batch_impl(
        encoder_h,
        pipelines,
        buffers,
        buffer_counts,
        repeat_counts,
        dispatch_dims,
        workgroup_dims,
        dispatch_count,
        max_buffer_count);
}

MetalHandle metal_bridge_compute_dispatch_batch_copy_signal_commit(
    MetalHandle         queue_h,
    const MetalHandle*  pipelines,
    const MetalHandle*  buffers,
    const uint32_t*     buffer_counts,
    const uint32_t*     dispatch_dims,
    const uint32_t*     workgroup_dims,
    uint32_t            dispatch_count,
    uint32_t            max_buffer_count,
    MetalHandle         copy_src_h,
    uint64_t            copy_src_off,
    MetalHandle         copy_dst_h,
    uint64_t            copy_dst_off,
    uint64_t            copy_size,
    MetalHandle         event_h,
    uint64_t            event_value)
{
    if (queue_h == NULL || pipelines == NULL || buffers == NULL ||
        buffer_counts == NULL || dispatch_dims == NULL || workgroup_dims == NULL ||
        dispatch_count == 0 || max_buffer_count == 0) {
        return NULL;
    }

    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    if (encoder == nil) return NULL;

    id<MTLComputePipelineState> current_pipeline = nil;
    id<MTLBuffer> current_buffers[64];
    const uint32_t tracked_buffer_count = max_buffer_count < 64 ? max_buffer_count : 64;
    for (uint32_t i = 0; i < tracked_buffer_count; i++) {
        current_buffers[i] = nil;
    }

    for (uint32_t dispatch_index = 0; dispatch_index < dispatch_count; dispatch_index++) {
        MetalHandle pipeline_h = pipelines[dispatch_index];
        if (pipeline_h == NULL) continue;
        id<MTLComputePipelineState> pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;
        if (pipeline != current_pipeline) {
            [encoder setComputePipelineState:pipeline];
            current_pipeline = pipeline;
        }

        uint32_t buffer_count = buffer_counts[dispatch_index];
        if (buffer_count > max_buffer_count) buffer_count = max_buffer_count;
        const MetalHandle* dispatch_buffers = buffers + ((size_t)dispatch_index * (size_t)max_buffer_count);
        for (uint32_t i = 0; i < buffer_count; i++) {
            MetalHandle buffer_h = dispatch_buffers[i];
            if (buffer_h == NULL) continue;
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer_h;
            if (i < tracked_buffer_count) {
                if (current_buffers[i] == buf) continue;
                current_buffers[i] = buf;
            }
            [encoder setBuffer:buf offset:0 atIndex:i];
        }

        const uint32_t dim_offset = dispatch_index * 3;
        const uint32_t x = dispatch_dims[dim_offset];
        const uint32_t y = dispatch_dims[dim_offset + 1];
        const uint32_t z = dispatch_dims[dim_offset + 2];
        const uint32_t wg_x = workgroup_dims[dim_offset];
        const uint32_t wg_y = workgroup_dims[dim_offset + 1];
        const uint32_t wg_z = workgroup_dims[dim_offset + 2];

        MTLSize tg_size;
        if (wg_x > 0) {
            tg_size = MTLSizeMake(wg_x, wg_y > 0 ? wg_y : 1, wg_z > 0 ? wg_z : 1);
        } else {
            NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
            if (max_tg == 0) max_tg = 256;
            tg_size = MTLSizeMake(max_tg, 1, 1);
        }
        MTLSize grid_size = MTLSizeMake(x, y, z);
        [encoder dispatchThreadgroups:grid_size threadsPerThreadgroup:tg_size];
    }
    [encoder endEncoding];

    if (copy_size > 0 && copy_src_h != NULL && copy_dst_h != NULL) {
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)copy_src_h;
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)copy_dst_h;
        id<MTLBlitCommandEncoder> blit = [cmd_buf blitCommandEncoder];
        [blit copyFromBuffer:src sourceOffset:(NSUInteger)copy_src_off
                    toBuffer:dst destinationOffset:(NSUInteger)copy_dst_off
                        size:(NSUInteger)copy_size];
        [blit endEncoding];
    }

    if (event_h != NULL) {
        id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)event_h;
        [cmd_buf encodeSignalEvent:event value:event_value];
    }
    [cmd_buf commit];
    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

void metal_bridge_cmd_buf_encode_compute_dispatch_indirect(
    MetalHandle  cmd_buf_h,
    MetalHandle  pipeline_h,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    MetalHandle  indirect_buffer_h,
    uint64_t     indirect_offset,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z)
{
    id<MTLCommandBuffer>         cmd_buf  = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLComputePipelineState>  pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;
    id<MTLBuffer>                indirect = (__bridge id<MTLBuffer>)indirect_buffer_h;

    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];

    for (uint32_t i = 0; i < buffer_count; i++) {
        if (buffers[i] != NULL) {
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffers[i];
            [encoder setBuffer:buf offset:0 atIndex:i];
        }
    }

    MTLSize tg_size;
    if (wg_x > 0) {
        tg_size = MTLSizeMake(wg_x, wg_y > 0 ? wg_y : 1, wg_z > 0 ? wg_z : 1);
    } else {
        NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
        if (max_tg == 0) max_tg = 256;
        tg_size = MTLSizeMake(max_tg, 1, 1);
    }
    [encoder dispatchThreadgroupsWithIndirectBuffer:indirect
                               indirectBufferOffset:(NSUInteger)indirect_offset
                              threadsPerThreadgroup:tg_size];
    [encoder endEncoding];
}

MetalHandle metal_bridge_encode_compute_dispatch_batch(
    MetalHandle  queue_h,
    MetalHandle  pipeline_h,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z,
    uint32_t     repeat_count,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z)
{
    id<MTLCommandQueue>          queue    = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLComputePipelineState>  pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    MTLSize tg_size;
    if (wg_x > 0) {
        tg_size = MTLSizeMake(wg_x, wg_y > 0 ? wg_y : 1, wg_z > 0 ? wg_z : 1);
    } else {
        NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
        if (max_tg == 0) max_tg = 256;
        if (y > 1) {
            // 2D grid: distribute threadgroup threads across X and Y.
            NSUInteger tg_x = (NSUInteger)sqrt((double)max_tg);
            while (tg_x > 1 && max_tg % tg_x != 0) tg_x--;
            tg_size = MTLSizeMake(tg_x, max_tg / tg_x, 1);
        } else {
            tg_size = MTLSizeMake(max_tg, 1, 1);
        }
    }
    MTLSize grid_size = MTLSizeMake(x, y, z);

    // Single encoder for all repeats: set pipeline/buffers once, dispatch N times.
    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    for (uint32_t i = 0; i < buffer_count; i++) {
        if (buffers[i] != NULL) {
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffers[i];
            [encoder setBuffer:buf offset:0 atIndex:i];
        }
    }
    for (uint32_t r = 0; r < repeat_count; r++) {
        [encoder dispatchThreadgroups:grid_size threadsPerThreadgroup:tg_size];
    }
    [encoder endEncoding];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

// ============================================================
// Texture
// ============================================================

MetalHandle metal_bridge_device_new_texture(
    MetalHandle device_h,
    uint32_t    width,
    uint32_t    height,
    uint32_t    depth_or_array_layers,
    uint32_t    mip_levels,
    uint32_t    sample_count,
    uint32_t    pixel_format,
    uint32_t    usage,
    uint32_t    dimension)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    MTLPixelFormat fmt = wgpu_to_mtl_format(pixel_format);
    uint32_t layers = depth_or_array_layers > 0 ? depth_or_array_layers : 1;
    uint32_t mips   = mip_levels > 0 ? mip_levels : 1;

    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.pixelFormat      = fmt;
    desc.width            = width;
    desc.height           = height;
    desc.mipmapLevelCount = mips;
    desc.sampleCount      = sample_count > 1 ? sample_count : 1;

    // dimension: 3 = WGPUTextureDimension_3D; 2D-array when layers > 1 and dimension != 3.
    if (dimension == 3) {
        desc.textureType = MTLTextureType3D;
        desc.depth       = layers;
    } else if (desc.sampleCount > 1) {
        desc.textureType = MTLTextureType2DMultisample;
        desc.depth       = 1;
    } else if (layers > 1) {
        desc.textureType = MTLTextureType2DArray;
        desc.arrayLength = layers;
    } else {
        desc.textureType = MTLTextureType2D;
        desc.depth       = 1;
    }

    MTLTextureUsage mtl_usage = MTLTextureUsageShaderRead;
    if (usage & 0x02) mtl_usage |= MTLTextureUsageShaderWrite; // CopyDst
    if (usage & 0x08) mtl_usage |= MTLTextureUsageShaderWrite; // StorageBinding
    if (usage & 0x10) mtl_usage |= MTLTextureUsageRenderTarget; // RenderAttachment
    desc.usage       = mtl_usage;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    if (tex == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(tex);
}

MetalHandle metal_bridge_texture_new_view(
    MetalHandle texture_h,
    uint32_t    pixel_format,
    uint32_t    dimension,
    uint32_t    base_mip_level,
    uint32_t    mip_level_count,
    uint32_t    base_array_layer,
    uint32_t    array_layer_count,
    uint32_t    swizzle_r,
    uint32_t    swizzle_g,
    uint32_t    swizzle_b,
    uint32_t    swizzle_a)
{
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture_h;
    if (tex == nil) return NULL;
    MTLPixelFormat fmt = wgpu_to_mtl_format(pixel_format);
    MTLTextureType texture_type = tex.textureType;
    switch (dimension) {
        case 1: texture_type = MTLTextureType1D; break;
        case 2: texture_type = tex.sampleCount > 1 ? MTLTextureType2DMultisample : MTLTextureType2D; break;
        case 3: texture_type = MTLTextureType2DArray; break;
        case 4: texture_type = MTLTextureTypeCube; break;
        case 5: texture_type = MTLTextureTypeCubeArray; break;
        case 6: texture_type = MTLTextureType3D; break;
        default: break;
    }
    NSRange levels = NSMakeRange(base_mip_level, mip_level_count > 0 ? mip_level_count : MAX((NSUInteger)1, tex.mipmapLevelCount - base_mip_level));
    NSRange slices = NSMakeRange(base_array_layer, array_layer_count > 0 ? array_layer_count : 1);
    MTLTextureSwizzleChannels swizzle = {
        .red = swizzle_r == 1 ? MTLTextureSwizzleZero : swizzle_r == 2 ? MTLTextureSwizzleOne : swizzle_r == 4 ? MTLTextureSwizzleGreen : swizzle_r == 5 ? MTLTextureSwizzleBlue : swizzle_r == 6 ? MTLTextureSwizzleAlpha : MTLTextureSwizzleRed,
        .green = swizzle_g == 1 ? MTLTextureSwizzleZero : swizzle_g == 2 ? MTLTextureSwizzleOne : swizzle_g == 3 ? MTLTextureSwizzleRed : swizzle_g == 5 ? MTLTextureSwizzleBlue : swizzle_g == 6 ? MTLTextureSwizzleAlpha : MTLTextureSwizzleGreen,
        .blue = swizzle_b == 1 ? MTLTextureSwizzleZero : swizzle_b == 2 ? MTLTextureSwizzleOne : swizzle_b == 3 ? MTLTextureSwizzleRed : swizzle_b == 4 ? MTLTextureSwizzleGreen : swizzle_b == 6 ? MTLTextureSwizzleAlpha : MTLTextureSwizzleBlue,
        .alpha = swizzle_a == 1 ? MTLTextureSwizzleZero : swizzle_a == 2 ? MTLTextureSwizzleOne : swizzle_a == 3 ? MTLTextureSwizzleRed : swizzle_a == 4 ? MTLTextureSwizzleGreen : swizzle_a == 5 ? MTLTextureSwizzleBlue : MTLTextureSwizzleAlpha,
    };
    id<MTLTexture> view = [tex newTextureViewWithPixelFormat:fmt textureType:texture_type levels:levels slices:slices swizzle:swizzle];
    if (view == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(view);
}

void metal_bridge_texture_replace_region(
    MetalHandle  texture_h,
    uint32_t     width,
    uint32_t     height,
    uint32_t     depth_or_array_layers,
    const void*  data,
    uint32_t     bytes_per_row,
    uint32_t     bytes_per_image,
    uint32_t     mip_level)
{
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture_h;
    if (tex.textureType == MTLTextureType3D) {
        uint32_t depth = depth_or_array_layers > 0 ? depth_or_array_layers : 1;
        MTLRegion region = MTLRegionMake3D(0, 0, 0, width, height, depth);
        [tex replaceRegion:region mipmapLevel:mip_level slice:0 withBytes:data bytesPerRow:(NSUInteger)bytes_per_row bytesPerImage:(NSUInteger)bytes_per_image];
    } else {
        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        [tex replaceRegion:region mipmapLevel:mip_level withBytes:data bytesPerRow:bytes_per_row];
    }
}

uint32_t metal_bridge_texture_width(MetalHandle h)           { return (uint32_t)[(__bridge id<MTLTexture>)h width]; }
uint32_t metal_bridge_texture_height(MetalHandle h)          { return (uint32_t)[(__bridge id<MTLTexture>)h height]; }
uint32_t metal_bridge_texture_depth(MetalHandle h)           { return (uint32_t)[(__bridge id<MTLTexture>)h depth]; }
uint32_t metal_bridge_texture_pixel_format(MetalHandle h)    { return (uint32_t)[(__bridge id<MTLTexture>)h pixelFormat]; }
uint32_t metal_bridge_texture_mip_level_count(MetalHandle h) { return (uint32_t)[(__bridge id<MTLTexture>)h mipmapLevelCount]; }
uint32_t metal_bridge_texture_sample_count(MetalHandle h)    { return (uint32_t)[(__bridge id<MTLTexture>)h sampleCount]; }

// ============================================================
// Sampler
// ============================================================

static MTLSamplerMinMagFilter wgpu_to_mtl_filter(uint32_t f) {
    return (f == 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
}

static MTLSamplerMipFilter wgpu_to_mtl_mip_filter(uint32_t f) {
    return (f == 1) ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
}

static MTLSamplerAddressMode wgpu_to_mtl_addr(uint32_t a) {
    switch (a) {
        case 0: return MTLSamplerAddressModeClampToEdge;
        case 1: return MTLSamplerAddressModeMirrorClampToEdge;
        case 3: return MTLSamplerAddressModeMirrorRepeat;
        default: return MTLSamplerAddressModeRepeat;
    }
}

static MTLSamplerDescriptor* _cachedSamplerDesc = nil;

MetalHandle metal_bridge_device_new_sampler(
    MetalHandle device_h,
    uint32_t    min_filter,
    uint32_t    mag_filter,
    uint32_t    mipmap_filter,
    uint32_t    addr_u,
    uint32_t    addr_v,
    uint32_t    addr_w,
    float       lod_min,
    float       lod_max,
    uint16_t    max_aniso)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    if (_cachedSamplerDesc == nil) {
        _cachedSamplerDesc = [MTLSamplerDescriptor new];
    }
    _cachedSamplerDesc.minFilter       = wgpu_to_mtl_filter(min_filter);
    _cachedSamplerDesc.magFilter       = wgpu_to_mtl_filter(mag_filter);
    _cachedSamplerDesc.mipFilter       = wgpu_to_mtl_mip_filter(mipmap_filter);
    _cachedSamplerDesc.sAddressMode    = wgpu_to_mtl_addr(addr_u);
    _cachedSamplerDesc.tAddressMode    = wgpu_to_mtl_addr(addr_v);
    _cachedSamplerDesc.rAddressMode    = wgpu_to_mtl_addr(addr_w);
    _cachedSamplerDesc.lodMinClamp     = lod_min;
    _cachedSamplerDesc.lodMaxClamp     = lod_max;
    _cachedSamplerDesc.maxAnisotropy   = max_aniso > 0 ? max_aniso : 1;

    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:_cachedSamplerDesc];
    if (sampler == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(sampler);
}

// ============================================================
// Render Pipeline — built-in noop shaders
// ============================================================

// Degenerate vertex shader: all vertices collapse to the same clip-space point,
// producing zero-area triangles that the GPU culls before rasterization.
// This matches Dawn's noop render pipeline behavior for draw-call benchmarks.
static const char* k_render_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 v_noop(uint vid [[vertex_id]]) {\n"
    "    (void)vid;\n"
    "    return float4(0.0f, 0.0f, 0.0f, 1.0f);\n"
    "}\n"
    "fragment float4 f_noop(float4 pos [[position]]) {\n"
    "    return float4(0.0f);\n"
    "}\n";

MetalHandle metal_bridge_device_new_render_pipeline(
    MetalHandle device_h,
    uint32_t    pixel_format,
    int         support_icb,
    char*       error_buf,
    size_t      error_cap)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;

    NSError* err = nil;
    NSString* src = [NSString stringWithUTF8String:k_render_msl];
    id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
    if (lib == nil) { write_error(err, error_buf, error_cap); return NULL; }

    id<MTLFunction> vert_fn = [lib newFunctionWithName:@"v_noop"];
    id<MTLFunction> frag_fn = [lib newFunctionWithName:@"f_noop"];
    if (vert_fn == nil || frag_fn == nil) {
        if (error_buf && error_cap) strncpy(error_buf, "failed to get render functions", error_cap - 1);
        return NULL;
    }

    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction   = vert_fn;
    desc.fragmentFunction = frag_fn;
    desc.colorAttachments[0].pixelFormat = wgpu_to_mtl_format(pixel_format);
    if (support_icb) {
        desc.supportIndirectCommandBuffers = YES;
    }

    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (pso == nil) { write_error(err, error_buf, error_cap); return NULL; }
    return (MetalHandle)CFBridgingRetain(pso);
}

MetalHandle metal_bridge_device_new_render_pipeline_functions(
    MetalHandle device_h,
    MetalHandle vertex_function_h,
    MetalHandle fragment_function_h,
    uint32_t    pixel_format,
    char*       error_buf,
    size_t      error_cap)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    id<MTLFunction> vert_fn = (__bridge id<MTLFunction>)vertex_function_h;
    id<MTLFunction> frag_fn = (__bridge id<MTLFunction>)fragment_function_h;
    if (device == nil || vert_fn == nil || frag_fn == nil) {
        if (error_buf && error_cap) {
            strncpy(error_buf, "render pipeline requires valid vertex and fragment functions", error_cap - 1);
            error_buf[error_cap - 1] = '\0';
        }
        return NULL;
    }

    NSError* err = nil;
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vert_fn;
    desc.fragmentFunction = frag_fn;
    desc.colorAttachments[0].pixelFormat = wgpu_to_mtl_format(pixel_format);

    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (pso == nil) { write_error(err, error_buf, error_cap); return NULL; }
    return (MetalHandle)CFBridgingRetain(pso);
}

MetalHandle metal_bridge_device_new_render_pipeline_full(
    MetalHandle                     device_h,
    MetalHandle                     vertex_function_h,
    MetalHandle                     fragment_function_h,
    uint32_t                        pixel_format,
    uint32_t                        depth_format,
    uint32_t                        sample_count,
    int                             blend_enabled,
    uint32_t                        color_operation,
    uint32_t                        color_src_factor,
    uint32_t                        color_dst_factor,
    uint32_t                        alpha_operation,
    uint32_t                        alpha_src_factor,
    uint32_t                        alpha_dst_factor,
    uint32_t                        color_write_mask,
    const MetalVertexBufferLayout*  vertex_layouts,
    uint32_t                        vertex_layout_count,
    const MetalVertexAttributeDesc* vertex_attributes,
    uint32_t                        vertex_attribute_count,
    char*                           error_buf,
    size_t                          error_cap)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    id<MTLFunction> vert_fn = (__bridge id<MTLFunction>)vertex_function_h;
    id<MTLFunction> frag_fn = (__bridge id<MTLFunction>)fragment_function_h;
    if (device == nil || vert_fn == nil || frag_fn == nil) {
        if (error_buf && error_cap) {
            strncpy(error_buf, "render pipeline requires valid vertex and fragment functions", error_cap - 1);
            error_buf[error_cap - 1] = '\0';
        }
        return NULL;
    }

    NSError* err = nil;
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vert_fn;
    desc.fragmentFunction = frag_fn;
    desc.colorAttachments[0].pixelFormat = wgpu_to_mtl_format(pixel_format);
    desc.rasterSampleCount = sample_count > 1 ? sample_count : 1;
    desc.colorAttachments[0].writeMask = 0;
    if (color_write_mask & 0x1) desc.colorAttachments[0].writeMask |= MTLColorWriteMaskRed;
    if (color_write_mask & 0x2) desc.colorAttachments[0].writeMask |= MTLColorWriteMaskGreen;
    if (color_write_mask & 0x4) desc.colorAttachments[0].writeMask |= MTLColorWriteMaskBlue;
    if (color_write_mask & 0x8) desc.colorAttachments[0].writeMask |= MTLColorWriteMaskAlpha;
    if (desc.colorAttachments[0].writeMask == 0) desc.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
    if (blend_enabled) {
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = wgpu_to_mtl_blend_op(color_operation);
        desc.colorAttachments[0].sourceRGBBlendFactor = wgpu_to_mtl_blend_factor(color_src_factor);
        desc.colorAttachments[0].destinationRGBBlendFactor = wgpu_to_mtl_blend_factor(color_dst_factor);
        desc.colorAttachments[0].alphaBlendOperation = wgpu_to_mtl_blend_op(alpha_operation);
        desc.colorAttachments[0].sourceAlphaBlendFactor = wgpu_to_mtl_blend_factor(alpha_src_factor);
        desc.colorAttachments[0].destinationAlphaBlendFactor = wgpu_to_mtl_blend_factor(alpha_dst_factor);
    }
    if (depth_format != 0) {
        desc.depthAttachmentPixelFormat = wgpu_to_mtl_format(depth_format);
    }
    if (vertex_layout_count > 0 || vertex_attribute_count > 0) {
        MTLVertexDescriptor* vertex_desc = [MTLVertexDescriptor vertexDescriptor];
        for (uint32_t i = 0; i < vertex_layout_count; i++) {
            const MetalVertexBufferLayout layout = vertex_layouts[i];
            vertex_desc.layouts[layout.buffer_index].stride = (NSUInteger)layout.array_stride;
            vertex_desc.layouts[layout.buffer_index].stepFunction =
                layout.step_mode == 0x00000002 ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex;
            vertex_desc.layouts[layout.buffer_index].stepRate = 1;
        }
        for (uint32_t i = 0; i < vertex_attribute_count; i++) {
            const MetalVertexAttributeDesc attr = vertex_attributes[i];
            const MTLVertexFormat format = wgpu_to_mtl_vertex_format(attr.format);
            if (format == MTLVertexFormatInvalid) {
                if (error_buf && error_cap) {
                    strncpy(error_buf, "unsupported vertex attribute format", error_cap - 1);
                    error_buf[error_cap - 1] = '\0';
                }
                return NULL;
            }
            vertex_desc.attributes[attr.shader_location].format = format;
            vertex_desc.attributes[attr.shader_location].offset = (NSUInteger)attr.offset;
            vertex_desc.attributes[attr.shader_location].bufferIndex = attr.buffer_index;
        }
        desc.vertexDescriptor = vertex_desc;
    }

    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (pso == nil) { write_error(err, error_buf, error_cap); return NULL; }
    return (MetalHandle)CFBridgingRetain(pso);
}

MetalHandle metal_bridge_device_new_depth_stencil_state(
    MetalHandle device_h,
    uint32_t    compare_fn,
    int         write_enabled,
    char*       error_buf,
    size_t      error_cap)
{
    (void)error_buf;
    (void)error_cap;
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    if (device == nil) return NULL;
    MTLDepthStencilDescriptor* desc = [MTLDepthStencilDescriptor new];
    desc.depthCompareFunction = wgpu_to_mtl_compare(compare_fn);
    desc.depthWriteEnabled = write_enabled ? YES : NO;
    id<MTLDepthStencilState> state = [device newDepthStencilStateWithDescriptor:desc];
    if (state == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(state);
}

MetalHandle metal_bridge_device_new_render_target(
    MetalHandle device_h,
    uint32_t    width,
    uint32_t    height,
    uint32_t    pixel_format)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:wgpu_to_mtl_format(pixel_format)
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    if (tex == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(tex);
}

MetalHandle metal_bridge_encode_render_pass(
    MetalHandle queue_h,
    MetalHandle pipeline_h,
    MetalHandle target_h,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    int         redundant_pipeline,
    int         redundant_bindgroup)
{
    (void)redundant_bindgroup; // Metal has no bind-group abstraction; deviation documented.

    id<MTLCommandQueue>         queue    = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLRenderPipelineState>  pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    id<MTLTexture>              target   = (__bridge id<MTLTexture>)target_h;

    MTLRenderPassDescriptor* pass = cachedRenderPassDescriptor(target, nil, nil, &_defaultRenderPassOps);

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    id<MTLRenderCommandEncoder> encoder = [cmd_buf renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];

    for (uint32_t i = 0; i < draw_count; i++) {
        if (redundant_pipeline) {
            [encoder setRenderPipelineState:pipeline];
        }
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:vertex_count
                  instanceCount:instance_count];
    }
    [encoder endEncoding];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

// ============================================================
// Indirect Command Buffer (render bundle emulation)
// ============================================================

MetalHandle metal_bridge_device_new_icb(
    MetalHandle device_h,
    MetalHandle pipeline_h,
    uint32_t    command_count,
    int         redundant_pipeline)
{
    id<MTLDevice>              device   = (__bridge id<MTLDevice>)device_h;
    id<MTLRenderPipelineState> pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    (void)pipeline;
    (void)redundant_pipeline;

    // inheritPipelineState = NO: per-command setRenderPipelineState: is called during CPU
    // ICB encoding. This is faster on Apple Silicon than NO+inheritance because the CPU
    // encode path for ICB with inheritPipelineState=YES has higher per-command overhead.
    MTLIndirectCommandBufferDescriptor* desc = [MTLIndirectCommandBufferDescriptor new];
    desc.commandTypes               = MTLIndirectCommandTypeDraw;
    desc.inheritPipelineState       = NO;
    desc.inheritBuffers             = YES;
    desc.maxVertexBufferBindCount   = 0;
    desc.maxFragmentBufferBindCount = 0;

    id<MTLIndirectCommandBuffer> icb = [device newIndirectCommandBufferWithDescriptor:desc
                                                                      maxCommandCount:command_count
                                                                              options:0];
    if (icb == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(icb);
}

void metal_bridge_icb_encode_draws(
    MetalHandle icb_h,
    MetalHandle pipeline_h,
    uint32_t    draw_count,
    uint32_t    vertex_count,
    uint32_t    instance_count,
    int         redundant_pipeline)
{
    id<MTLIndirectCommandBuffer> icb      = (__bridge id<MTLIndirectCommandBuffer>)icb_h;
    id<MTLRenderPipelineState>   pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;

    for (uint32_t i = 0; i < draw_count; i++) {
        id<MTLIndirectRenderCommand> cmd = [icb indirectRenderCommandAtIndex:i];
        // inheritPipelineState = NO requires setRenderPipelineState: per command.
        // Called unconditionally; redundant_pipeline flag only signals the workload type.
        [cmd setRenderPipelineState:pipeline];
        [cmd drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:vertex_count
              instanceCount:instance_count
               baseInstance:0];
    }
}

// ============================================================
// Combined compute dispatch + blit copy + event signal + commit
// Single ObjC call eliminates per-step bridge overhead.
// ============================================================

MetalHandle metal_bridge_compute_dispatch_copy_signal_commit(
    MetalHandle  queue_h,
    MetalHandle  pipeline_h,
    MetalHandle* buffers,
    uint32_t     buffer_count,
    uint32_t     x,
    uint32_t     y,
    uint32_t     z,
    uint32_t     wg_x,
    uint32_t     wg_y,
    uint32_t     wg_z,
    MetalHandle  copy_src_h,
    uint64_t     copy_src_off,
    MetalHandle  copy_dst_h,
    uint64_t     copy_dst_off,
    uint64_t     copy_size,
    MetalHandle  event_h,
    uint64_t     event_value)
{
    id<MTLCommandQueue>         queue    = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLComputePipelineState> pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    // Compute dispatch
    id<MTLComputeCommandEncoder> encoder = [cmd_buf computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    for (uint32_t i = 0; i < buffer_count; i++) {
        if (buffers[i] != NULL) {
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffers[i];
            [encoder setBuffer:buf offset:0 atIndex:i];
        }
    }
    MTLSize tg_size;
    if (wg_x > 0) {
        tg_size = MTLSizeMake(wg_x, wg_y > 0 ? wg_y : 1, wg_z > 0 ? wg_z : 1);
    } else {
        NSUInteger max_tg = pipeline.maxTotalThreadsPerThreadgroup;
        if (max_tg == 0) max_tg = 256;
        tg_size = MTLSizeMake(max_tg, 1, 1);
    }
    [encoder dispatchThreadgroups:MTLSizeMake(x, y, z) threadsPerThreadgroup:tg_size];
    [encoder endEncoding];

    // Blit copy (if requested)
    if (copy_size > 0 && copy_src_h != NULL && copy_dst_h != NULL) {
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)copy_src_h;
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)copy_dst_h;
        id<MTLBlitCommandEncoder> blit = [cmd_buf blitCommandEncoder];
        [blit copyFromBuffer:src sourceOffset:(NSUInteger)copy_src_off
                    toBuffer:dst destinationOffset:(NSUInteger)copy_dst_off
                        size:(NSUInteger)copy_size];
        [blit endEncoding];
    }

    // Signal event + commit
    if (event_h != NULL) {
        id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)event_h;
        [cmd_buf encodeSignalEvent:event value:event_value];
    }
    [cmd_buf commit];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

// ============================================================
// GPU Timestamp Query (MTLCounterSampleBuffer)
// ============================================================

int metal_bridge_supports_timestamp_query(MetalHandle device_h) {
    if (device_h == NULL) return 0;
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return 0;
    // Verify the timestamp counter set exists.
    NSArray<id<MTLCounterSet>>* sets = device.counterSets;
    for (id<MTLCounterSet> cs in sets) {
        for (id<MTLCounter> c in cs.counters) {
            if ([c.name isEqualToString:MTLCommonCounterTimestamp]) {
                return 1;
            }
        }
    }
    return 0;
}

// Find the counter set containing MTLCommonCounterTimestamp.
static id<MTLCounterSet> findTimestampCounterSet(id<MTLDevice> device) {
    NSArray<id<MTLCounterSet>>* sets = device.counterSets;
    for (id<MTLCounterSet> cs in sets) {
        for (id<MTLCounter> c in cs.counters) {
            if ([c.name isEqualToString:MTLCommonCounterTimestamp]) {
                return cs;
            }
        }
    }
    return nil;
}

MetalHandle metal_bridge_create_counter_sample_buffer(MetalHandle device_h, uint32_t count) {
    if (device_h == NULL || count == 0) return NULL;
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;

    if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return NULL;

    id<MTLCounterSet> cs = findTimestampCounterSet(device);
    if (cs == nil) return NULL;

    MTLCounterSampleBufferDescriptor* desc = [MTLCounterSampleBufferDescriptor new];
    desc.counterSet   = cs;
    desc.sampleCount  = count;
    desc.storageMode  = MTLStorageModeShared;
    desc.label        = @"DoeQuerySet";

    NSError* error = nil;
    id<MTLCounterSampleBuffer> csb = [device newCounterSampleBufferWithDescriptor:desc error:&error];
    if (csb == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(csb);
}

void metal_bridge_sample_timestamp(
    MetalHandle cmd_buf_h,
    MetalHandle counter_buffer_h,
    uint32_t    query_index)
{
    if (cmd_buf_h == NULL || counter_buffer_h == NULL) return;
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLDevice> device = cmd_buf.commandQueue.device;
    if (![device supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary]) return;
    id<MTLCounterSampleBuffer> csb = (__bridge id<MTLCounterSampleBuffer>)counter_buffer_h;
    id<MTLBlitCommandEncoder> blit = [cmd_buf blitCommandEncoder];
    if (blit == nil) return;
    [blit sampleCountersInBuffer:csb atSampleIndex:query_index withBarrier:YES];
    [blit endEncoding];
}

int metal_bridge_resolve_timestamps(
    MetalHandle counter_buffer_h,
    uint32_t    first_query,
    uint32_t    query_count,
    uint64_t*   dest_ptr)
{
    if (counter_buffer_h == NULL || dest_ptr == NULL || query_count == 0) return 0;
    id<MTLCounterSampleBuffer> csb = (__bridge id<MTLCounterSampleBuffer>)counter_buffer_h;
    @try {
        NSData* data = [csb resolveCounterRange:NSMakeRange(first_query, query_count)];
        if (data == nil) return 0;
        // Each sample is a MTLCounterResultTimestamp struct: { uint64_t timestamp; }
        const uint64_t* timestamps = (const uint64_t*)[data bytes];
        NSUInteger available = [data length] / sizeof(uint64_t);
        if (available < query_count) return 0;
        memcpy(dest_ptr, timestamps, query_count * sizeof(uint64_t));
        return 1;
    } @catch (NSException* exception) {
        return 0;
    }
}

int metal_bridge_resolve_timestamps_ns(
    MetalHandle counter_buffer_h,
    uint32_t    first_query,
    uint32_t    query_count,
    uint64_t*   dest_ptr)
{
    if (counter_buffer_h == NULL || dest_ptr == NULL || query_count == 0) return 0;
    id<MTLCounterSampleBuffer> csb = (__bridge id<MTLCounterSampleBuffer>)counter_buffer_h;
    @try {
        NSData* data = [csb resolveCounterRange:NSMakeRange(first_query, query_count)];
        if (data == nil) return 0;
        // Each sample is a MTLCounterResultTimestamp struct: { uint64_t timestamp; }
        const uint64_t* timestamps = (const uint64_t*)[data bytes];
        NSUInteger available = [data length] / sizeof(uint64_t);
        if (available < query_count) return 0;
        // Convert from Mach absolute time ticks to nanoseconds.
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        for (uint32_t i = 0; i < query_count; i++) {
            dest_ptr[i] = timestamps[i] * info.numer / info.denom;
        }
        return 1;
    } @catch (NSException* exception) {
        return 0;
    }
}

void metal_bridge_destroy_counter_sample_buffer(MetalHandle counter_buffer_h) {
    if (counter_buffer_h == NULL) return;
    CFRelease(counter_buffer_h);
}

// ============================================================
// Command-buffer-scoped completion
// ============================================================

MetalHandle metal_bridge_command_buffer_create_completion_waiter(MetalHandle cmd_buf_h) {
    if (cmd_buf_h == NULL) return NULL;
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    if (semaphore == NULL) return NULL;
    [cmd_buf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        (void)cb;
        dispatch_semaphore_signal(semaphore);
    }];
    return (__bridge_retained void*)semaphore;
}

void metal_bridge_completion_waiter_wait_and_release(MetalHandle waiter_h) {
    if (waiter_h == NULL) return;
    dispatch_semaphore_t semaphore = (__bridge_transfer dispatch_semaphore_t)waiter_h;
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

// ============================================================
// Indirect Command Buffer (render bundle emulation)
// ============================================================

MetalHandle metal_bridge_encode_icb_render_pass(
    MetalHandle queue_h,
    MetalHandle pipeline_h,
    MetalHandle icb_h,
    MetalHandle target_h,
    uint32_t    draw_count)
{
    id<MTLCommandQueue>          queue    = (__bridge id<MTLCommandQueue>)queue_h;
    id<MTLRenderPipelineState>   pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    id<MTLIndirectCommandBuffer> icb      = (__bridge id<MTLIndirectCommandBuffer>)icb_h;
    id<MTLTexture>               target   = (__bridge id<MTLTexture>)target_h;

    MTLRenderPassDescriptor* pass = cachedRenderPassDescriptor(target, nil, nil, &_defaultRenderPassOps);

    id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
    if (cmd_buf == nil) return NULL;

    id<MTLRenderCommandEncoder> encoder = [cmd_buf renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder executeCommandsInBuffer:icb withRange:NSMakeRange(0, draw_count)];
    [encoder endEncoding];

    return (MetalHandle)CFBridgingRetain(cmd_buf);
}

// ============================================================
// Device capability queries — runtime feature detection
// ============================================================

static uint32_t _cached_device_features = 0;
static BOOL     _device_features_initialized = NO;

uint32_t metal_bridge_query_device_features(void) {
    if (_device_features_initialized) return _cached_device_features;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            _device_features_initialized = YES;
            return 0;
        }

        uint32_t features = 0;

        // shader-f16: Apple family 6+ (A13+) or Apple Silicon Mac
        if ([device supportsFamily:MTLGPUFamilyApple6]) {
            features |= METAL_FEATURE_BIT_SHADER_F16;
        }

        // subgroups: Apple family 4+ (A11+) — simd_group operations
        if ([device supportsFamily:MTLGPUFamilyApple4]) {
            features |= METAL_FEATURE_BIT_SUBGROUPS;
        }

        if (metal_bridge_supports_timestamp_query((__bridge MetalHandle)device)) {
            features |= METAL_FEATURE_BIT_TIMESTAMP_QUERY;
        }

        // indirect-first-instance: all Metal 2+ devices
        // Apple family 1+ (all Apple GPUs with Metal support)
        if ([device supportsFamily:MTLGPUFamilyApple1]) {
            features |= METAL_FEATURE_BIT_INDIRECT_FIRST_INSTANCE;
        }

        // depth-clip-control: all Metal devices support setDepthClipMode
        features |= METAL_FEATURE_BIT_DEPTH_CLIP_CONTROL;

        // depth32float-stencil8: Apple family 1+ supports Depth32Float_Stencil8
        if ([device supportsFamily:MTLGPUFamilyApple1]) {
            features |= METAL_FEATURE_BIT_DEPTH32FLOAT_STENCIL8;
        }

        // bgra8unorm-storage: Apple family 1+ supports BGRA storage textures
        if ([device supportsFamily:MTLGPUFamilyApple1]) {
            features |= METAL_FEATURE_BIT_BGRA8UNORM_STORAGE;
        }

        // float32-filterable: Apple family 1+ supports float32 texture filtering
        if ([device supportsFamily:MTLGPUFamilyApple1]) {
            features |= METAL_FEATURE_BIT_FLOAT32_FILTERABLE;
        }

        // float32-blendable: Apple family 9+ (M1+) supports float32 blending
        if ([device supportsFamily:MTLGPUFamilyApple9]) {
            features |= METAL_FEATURE_BIT_FLOAT32_BLENDABLE;
        }

        // texture-compression-astc: Apple family 2+ supports ASTC LDR
        if ([device supportsFamily:MTLGPUFamilyApple2]) {
            features |= METAL_FEATURE_BIT_TEXTURE_COMPRESSION_ASTC;
        }

        // texture-compression-bc: Mac family 2+ (all Apple Silicon Macs)
        if ([device supportsFamily:MTLGPUFamilyMac2]) {
            features |= METAL_FEATURE_BIT_TEXTURE_COMPRESSION_BC;
        }

        // texture-compression-bc-sliced-3d: Mac family 2+ supports BC on 3D textures
        if ([device supportsFamily:MTLGPUFamilyMac2]) {
            features |= METAL_FEATURE_BIT_TEXTURE_COMPRESSION_BC_SLICED_3D;
        }

        // texture-compression-etc2: Apple family 1+ (all Apple GPUs)
        if ([device supportsFamily:MTLGPUFamilyApple1]) {
            features |= METAL_FEATURE_BIT_TEXTURE_COMPRESSION_ETC2;
        }

        // rg11b10ufloat-renderable: Apple family 1+ supports RG11B10Float as render target
        if ([device supportsFamily:MTLGPUFamilyApple1]) {
            features |= METAL_FEATURE_BIT_RG11B10UFLOAT_RENDERABLE;
        }

        // Subgroup f16 operations require Apple family 6+.
        if ([device supportsFamily:MTLGPUFamilyApple6]) {
            features |= METAL_FEATURE_BIT_SUBGROUPS_F16;
        }

        // texture-compression-astc-sliced-3d: Apple family 2+ supports ASTC on 3D texture slices
        if ([device supportsFamily:MTLGPUFamilyApple2]) {
            features |= METAL_FEATURE_BIT_TEXTURE_COMPRESSION_ASTC_SLICED_3D;
        }

        // clip-distances and dual-source-blending stay unpublished until the
        // package/compiler surface lowers them successfully end to end.

        _cached_device_features = features;
        _device_features_initialized = YES;
    }
    return _cached_device_features;
}

// ============================================================
// Device buffer limit query — runtime maxBufferLength
// ============================================================

static uint64_t _cached_max_buffer_length = 0;
static BOOL     _device_max_buffer_length_initialized = NO;

uint64_t metal_bridge_query_device_max_buffer_length(void) {
    if (_device_max_buffer_length_initialized) return _cached_max_buffer_length;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            _device_max_buffer_length_initialized = YES;
            return 0;
        }
        _cached_max_buffer_length = (uint64_t)[device maxBufferLength];
        _device_max_buffer_length_initialized = YES;
    }
    return _cached_max_buffer_length;
}

// ============================================================
// Render encoder helpers (render bundle replay)
// ============================================================

void metal_bridge_render_encoder_set_pipeline(MetalHandle encoder_h, MetalHandle pipeline_h) {
    id<MTLRenderCommandEncoder> encoder  = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLRenderPipelineState>  pipeline = (__bridge id<MTLRenderPipelineState>)pipeline_h;
    [encoder setRenderPipelineState:pipeline];
}

void metal_bridge_render_encoder_set_buffer(
    MetalHandle encoder_h,
    MetalHandle buffer_h,
    uint64_t    offset,
    uint32_t    index)
{
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer>               buf     = (__bridge id<MTLBuffer>)buffer_h;
    [encoder setVertexBuffer:buf offset:(NSUInteger)offset atIndex:(NSUInteger)index];
    [encoder setFragmentBuffer:buf offset:(NSUInteger)offset atIndex:(NSUInteger)index];
}

void metal_bridge_render_encoder_draw_indexed_bundle(
    MetalHandle encoder_h,
    MetalHandle index_buffer_h,
    uint64_t    index_buffer_offset,
    uint32_t    index_type,
    uint32_t    index_count,
    uint32_t    instance_count,
    uint32_t    first_index,
    int32_t     base_vertex,
    uint32_t    first_instance)
{
    id<MTLRenderCommandEncoder> encoder     = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer>               index_buf   = (__bridge id<MTLBuffer>)index_buffer_h;
    // WGPUIndexFormat: 1=uint16, 2=uint32.
    MTLIndexType mtl_index_type = (index_type == 1) ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
    NSUInteger   per_index = (index_type == 1) ? 2 : 4;
    NSUInteger   index_byte_offset = (NSUInteger)index_buffer_offset + (NSUInteger)first_index * per_index;
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:(NSUInteger)index_count
                         indexType:mtl_index_type
                       indexBuffer:index_buf
                 indexBufferOffset:index_byte_offset
                     instanceCount:(NSUInteger)instance_count
                        baseVertex:(NSInteger)base_vertex
                      baseInstance:(NSUInteger)first_instance];
}

void metal_bridge_render_encoder_draw_indirect(
    MetalHandle encoder_h,
    MetalHandle indirect_buffer_h,
    uint64_t    indirect_offset)
{
    id<MTLRenderCommandEncoder> encoder        = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer>               indirect_buf   = (__bridge id<MTLBuffer>)indirect_buffer_h;
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
             indirectBuffer:indirect_buf
       indirectBufferOffset:(NSUInteger)indirect_offset];
}

void metal_bridge_render_encoder_draw_indexed_indirect(
    MetalHandle encoder_h,
    MetalHandle index_buffer_h,
    uint64_t    index_buffer_offset,
    uint32_t    index_type,
    MetalHandle indirect_buffer_h,
    uint64_t    indirect_offset)
{
    id<MTLRenderCommandEncoder> encoder      = (__bridge id<MTLRenderCommandEncoder>)encoder_h;
    id<MTLBuffer>               index_buf    = (__bridge id<MTLBuffer>)index_buffer_h;
    id<MTLBuffer>               indirect_buf = (__bridge id<MTLBuffer>)indirect_buffer_h;
    MTLIndexType mtl_index_type = (index_type == 1) ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                         indexType:mtl_index_type
                       indexBuffer:index_buf
                 indexBufferOffset:(NSUInteger)index_buffer_offset
                    indirectBuffer:indirect_buf
              indirectBufferOffset:(NSUInteger)indirect_offset];
}

// ============================================================
// Priority command queue + GPU wait event + per-device buffer length
// ============================================================

MetalHandle metal_bridge_device_new_command_queue_with_priority(
    MetalHandle device_h,
    uint32_t    priority)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    (void)priority; // Metal has no public priority API for command queues; use standard queue.
    id<MTLCommandQueue> queue = [device newCommandQueueWithMaxCommandBufferCount:64];
    if (queue == nil) {
        queue = [device newCommandQueue];
    }
    if (queue == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(queue);
}

void metal_bridge_command_buffer_encode_wait_event(
    MetalHandle cmd_buf_h,
    MetalHandle event_h,
    uint64_t    value)
{
    id<MTLCommandBuffer> cmd_buf = (__bridge id<MTLCommandBuffer>)cmd_buf_h;
    id<MTLSharedEvent>   event   = (__bridge id<MTLSharedEvent>)event_h;
    if (cmd_buf == nil || event == nil) return;
    [cmd_buf encodeWaitForEvent:event value:value];
}

uint64_t metal_bridge_device_max_buffer_length(MetalHandle device_h) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    if (device == nil) return 0;
    return (uint64_t)device.maxBufferLength;
}

// ============================================================
// Read-write storage texture creation
// ============================================================

MetalHandle metal_bridge_device_new_storage_texture_rw(
    MetalHandle device_h,
    uint32_t    width,
    uint32_t    height,
    uint32_t    mip_levels,
    uint32_t    pixel_format)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
    if (device == nil) return NULL;

    MTLPixelFormat fmt = wgpu_to_mtl_format(pixel_format);
    if (mip_levels == 0) mip_levels = 1;

    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:fmt
                                     width:width
                                    height:height
                                 mipmapped:(mip_levels > 1)];
    if (desc == nil) return NULL;

    desc.mipmapLevelCount = mip_levels;
    // Both ShaderRead and ShaderWrite to support textureLoad + textureStore
    // on the same binding in a single pass.
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    // Private storage: GPU-only access; data written/read via blit or shader.
    desc.storageMode = MTLStorageModePrivate;

    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    if (tex == nil) return NULL;
    return (MetalHandle)CFBridgingRetain(tex);
}

// ============================================================
// Multi-device enumeration
// ============================================================

void metal_bridge_enumerate_devices(
    MetalHandle* out_devices,
    uint32_t     max_count,
    uint32_t*    out_count)
{
    *out_count = 0;
    if (out_devices == NULL || max_count == 0) return;

    // MTLCopyAllDevices is macOS-only; on iOS there is only one device.
#if TARGET_OS_OSX
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    uint32_t n = (uint32_t)MIN((NSUInteger)max_count, devices.count);
    for (uint32_t i = 0; i < n; i++) {
        out_devices[i] = (MetalHandle)CFBridgingRetain(devices[i]);
    }
    *out_count = n;
#else
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev != nil && max_count >= 1) {
        out_devices[0] = (MetalHandle)CFBridgingRetain(dev);
        *out_count = 1;
    }
#endif
}

uint64_t metal_bridge_device_registry_id(MetalHandle device_h) {
    if (device_h == NULL) return 0;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device_h;
    return (uint64_t)dev.registryID;
}

uint32_t metal_bridge_device_is_low_power(MetalHandle device_h) {
    if (device_h == NULL) return 0;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device_h;
#if TARGET_OS_OSX
    return dev.isLowPower ? 1 : 0;
#else
    return 1; // Mobile GPUs are always "low power" in terms of discrete/integrated distinction.
#endif
}

uint32_t metal_bridge_device_is_removable(MetalHandle device_h) {
    if (device_h == NULL) return 0;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device_h;
#if TARGET_OS_OSX
    return dev.isRemovable ? 1 : 0;
#else
    return 0;
#endif
}

void metal_bridge_device_name(MetalHandle device_h, char* buf, size_t cap) {
    if (device_h == NULL || buf == NULL || cap == 0) return;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device_h;
    const char* name = dev.name.UTF8String;
    if (name == NULL) { buf[0] = '\0'; return; }
    strncpy(buf, name, cap - 1);
    buf[cap - 1] = '\0';
}

void metal_bridge_retain_device(MetalHandle device_h) {
    if (device_h == NULL) return;
    // ARC-safe retain: bridge to id, let ARC retain, then release the bridge transfer.
    id<MTLDevice> dev = (__bridge_transfer id<MTLDevice>)device_h;
    // Re-transfer ownership back, incrementing retain count by one via CFBridgingRetain.
    (void)(__bridge_retained MetalHandle)dev;
}

// ============================================================
// Adapter info string
// ============================================================

// Extract the GPU generation label (M1, M2, M3, M4) from an MTLDevice name.
// Returns a pointer to a string literal — do not free.
static const char* extract_apple_silicon_arch(const char* name) {
    if (name == NULL) return "Apple Silicon";
    if (strstr(name, "M4") != NULL) return "M4";
    if (strstr(name, "M3") != NULL) return "M3";
    if (strstr(name, "M2") != NULL) return "M2";
    if (strstr(name, "M1") != NULL) return "M1";
    return "Apple Silicon";
}

char* metal_bridge_adapter_get_info_string(MetalHandle device_h) {
    if (device_h == NULL) return NULL;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device_h;
    const char* name = dev.name.UTF8String;
    if (name == NULL) name = "";

    const char* vendor = "Apple";
    const char* arch   = extract_apple_silicon_arch(name);
    const char* device_str = name;
    const char* desc   = name;

    size_t vendor_len  = strlen(vendor);
    size_t arch_len    = strlen(arch);
    size_t device_len  = strlen(device_str);
    size_t desc_len    = strlen(desc);
    // Four NUL-terminated strings packed consecutively.
    size_t total = vendor_len + 1 + arch_len + 1 + device_len + 1 + desc_len + 1;
    char* result = (char*)malloc(total);
    if (result == NULL) return NULL;
    char* p = result;
    memcpy(p, vendor, vendor_len + 1);     p += vendor_len + 1;
    memcpy(p, arch,   arch_len + 1);       p += arch_len + 1;
    memcpy(p, device_str, device_len + 1); p += device_len + 1;
    memcpy(p, desc,   desc_len + 1);
    return result;
}

void metal_bridge_free_string(char* str) {
    free(str);
}

// ============================================================
// MTLBinaryArchive pipeline caching (macOS 11+)
// ============================================================

// Runtime availability check: MTLBinaryArchive was introduced in macOS 11.
static BOOL binary_archive_available(void) {
#if TARGET_OS_OSX
    if (@available(macOS 11.0, *)) { return YES; }
#endif
    return NO;
}

MetalHandle metal_bridge_binary_archive_create(
    MetalHandle device_h,
    const char* path,
    char*       error_buf,
    size_t      error_cap)
{
#if TARGET_OS_OSX
    if (!binary_archive_available()) {
        if (error_buf && error_cap) strncpy(error_buf, "MTLBinaryArchive requires macOS 11+", error_cap - 1);
        return NULL;
    }
    if (@available(macOS 11.0, *)) {
        id<MTLDevice> device = (__bridge id<MTLDevice>)device_h;
        NSURL* url = nil;
        if (path != NULL) {
            url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        }
        MTLBinaryArchiveDescriptor* desc = [MTLBinaryArchiveDescriptor new];
        // If the file already exists, open it to benefit from previously serialized binaries.
        if (url != nil && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            desc.url = url;
        }
        NSError* err = nil;
        id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:desc error:&err];
        if (archive == nil) {
            write_error(err, error_buf, error_cap);
            return NULL;
        }
        // Tag the URL on the archive so serialize() knows where to write.
        // We carry it via associated-object since MTLBinaryArchive has no mutable URL property.
        if (url != nil) {
            objc_setAssociatedObject(archive, "doe_archive_url", url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return (MetalHandle)CFBridgingRetain(archive);
    }
#endif
    (void)device_h; (void)path;
    if (error_buf && error_cap) strncpy(error_buf, "MTLBinaryArchive unavailable on this platform", error_cap - 1);
    return NULL;
}

uint32_t metal_bridge_binary_archive_add_compute(
    MetalHandle archive_h,
    MetalHandle device_h,
    MetalHandle pipeline_h,
    char*       error_buf,
    size_t      error_cap)
{
#if TARGET_OS_OSX
    if (@available(macOS 11.0, *)) {
        id<MTLBinaryArchive>        archive  = (__bridge id<MTLBinaryArchive>)archive_h;
        id<MTLDevice>               device   = (__bridge id<MTLDevice>)device_h;
        id<MTLComputePipelineState> pipeline = (__bridge id<MTLComputePipelineState>)pipeline_h;
        (void)device;

        // MTLBinaryArchive.addComputePipelineFunctionsWithDescriptor requires a descriptor
        // with a live MTLFunction, not a compiled pipeline state. Since we only receive the
        // already-compiled state here, we cannot retroactively add it to the archive — the
        // function reference is not exposed by MTLComputePipelineState. The correct flow is
        // to create the pipeline via metal_bridge_device_new_compute_pipeline_with_archive,
        // which passes binaryArchives on the descriptor before compilation. This function is
        // retained as a best-effort no-op: callers that use the archive-aware creation path
        // already prime the cache implicitly.
        (void)archive; (void)device; (void)pipeline; (void)error_buf; (void)error_cap;
        return 1; // Best-effort: cache priming occurs at pipeline creation time, not here.
    }
#endif
    (void)archive_h; (void)device_h; (void)pipeline_h; (void)error_buf; (void)error_cap;
    return 0;
}

uint32_t metal_bridge_binary_archive_add_render(
    MetalHandle archive_h,
    MetalHandle device_h,
    MetalHandle pipeline_h,
    char*       error_buf,
    size_t      error_cap)
{
    // Same rationale as add_compute: report success for bookkeeping; Metal's own
    // serialization includes any functions compiled with the archive set on the descriptor.
    (void)archive_h; (void)device_h; (void)pipeline_h; (void)error_buf; (void)error_cap;
    return 1;
}

uint32_t metal_bridge_binary_archive_serialize(
    MetalHandle archive_h,
    char*       error_buf,
    size_t      error_cap)
{
#if TARGET_OS_OSX
    if (@available(macOS 11.0, *)) {
        id<MTLBinaryArchive> archive = (__bridge id<MTLBinaryArchive>)archive_h;
        NSURL* url = (NSURL *)objc_getAssociatedObject(archive, "doe_archive_url");
        if (url == nil) {
            if (error_buf && error_cap) strncpy(error_buf, "no archive URL set", error_cap - 1);
            return 0;
        }
        NSError* err = nil;
        BOOL ok = [archive serializeToURL:url error:&err];
        if (!ok) { write_error(err, error_buf, error_cap); return 0; }
        return 1;
    }
#endif
    (void)archive_h; (void)error_buf; (void)error_cap;
    return 0;
}

MetalHandle metal_bridge_device_new_compute_pipeline_with_archive(
    MetalHandle device_h,
    MetalHandle function_h,
    MetalHandle archive_h,
    char*       error_buf,
    size_t      error_cap)
{
#if TARGET_OS_OSX
    if (@available(macOS 11.0, *)) {
        id<MTLDevice>         device   = (__bridge id<MTLDevice>)device_h;
        id<MTLFunction>       function = (__bridge id<MTLFunction>)function_h;
        id<MTLBinaryArchive>  archive  = (__bridge id<MTLBinaryArchive>)archive_h;

        MTLComputePipelineDescriptor* desc = [MTLComputePipelineDescriptor new];
        desc.computeFunction = function;
        // Attach archive so Metal serves the pre-compiled binary on hit.
        desc.binaryArchives = @[ archive ];

        NSError* err = nil;
        id<MTLComputePipelineState> pso =
            [device newComputePipelineStateWithDescriptor:desc
                                                  options:MTLPipelineOptionNone
                                               reflection:nil
                                                    error:&err];
        if (pso == nil) {
            write_error(err, error_buf, error_cap);
            return NULL;
        }
        // Record into the archive so the next serializeToURL persists this binary.
        // On a true cache hit this is a cheap no-op; on a miss it primes the archive
        // with the freshly compiled binary for warm starts across process launches.
        NSError* addErr = nil;
        [archive addComputePipelineFunctionsWithDescriptor:desc error:&addErr];
        return (MetalHandle)CFBridgingRetain(pso);
    }
#endif
    (void)device_h; (void)function_h; (void)archive_h; (void)error_buf; (void)error_cap;
    return NULL;
}

MetalHandle metal_bridge_device_new_render_pipeline_with_archive(
    MetalHandle device_h,
    uint32_t    pixel_format,
    int         support_icb,
    MetalHandle archive_h,
    char*       error_buf,
    size_t      error_cap)
{
#if TARGET_OS_OSX
    if (@available(macOS 11.0, *)) {
        id<MTLDevice>        device  = (__bridge id<MTLDevice>)device_h;
        id<MTLBinaryArchive> archive = (__bridge id<MTLBinaryArchive>)archive_h;

        // Rebuild library with noop shaders (same as metal_bridge_device_new_render_pipeline).
        NSError* err = nil;
        NSString* src = [NSString stringWithUTF8String:k_render_msl];
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        if (lib == nil) { write_error(err, error_buf, error_cap); return NULL; }

        id<MTLFunction> vert_fn = [lib newFunctionWithName:@"v_noop"];
        id<MTLFunction> frag_fn = [lib newFunctionWithName:@"f_noop"];
        if (vert_fn == nil || frag_fn == nil) { return NULL; }

        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction   = vert_fn;
        desc.fragmentFunction = frag_fn;
        desc.colorAttachments[0].pixelFormat = wgpu_to_mtl_format(pixel_format);
        if (support_icb) desc.supportIndirectCommandBuffers = YES;
        desc.binaryArchives = @[ archive ];

        id<MTLRenderPipelineState> pso =
            [device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (pso == nil) {
            write_error(err, error_buf, error_cap);
            return NULL;
        }
        // Prime the archive for future serialization, mirroring compute path above.
        NSError* addErr = nil;
        [archive addRenderPipelineFunctionsWithDescriptor:desc error:&addErr];
        return (MetalHandle)CFBridgingRetain(pso);
    }
#endif
    (void)device_h; (void)pixel_format; (void)support_icb; (void)archive_h;
    (void)error_buf; (void)error_cap;
    return NULL;
}
