import { createRequire } from 'node:module';
import { dlopen, FFIType, JSCallback, ptr as bunPtr, toArrayBuffer } from "bun:ffi";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createDoeRuntime, runDawnVsDoeCompare } from "./runtime-cli.js";
import { loadDoeBuildMetadata } from "./build-metadata.js";
import {
    PACKAGE_ROOT,
    WORKSPACE_ROOT,
    libraryBasenamesForPlatform,
    resolvePlatformPackageLibraryPath,
} from "./platform-package.js";
import { globals } from "./webgpu-constants.js";
import {
  UINT32_MAX,
  failValidation,
  describeResourceLabel,
  initResource,
  assertObject,
  assertArray,
  assertBoolean,
  assertNonEmptyString,
  assertIntegerInRange,
  assertOptionalIntegerInRange,
  assertLiveResource,
  destroyResource,
  validatePositiveInteger,
} from "./shared/resource-lifecycle.js";
import {
  KNOWN_FEATURES,
  publishLimits,
  publishFeatures,
} from "./shared/capabilities.js";
import {
  ALL_BUFFER_USAGE_BITS,
  assertBufferDescriptor,
  assertTextureSize,
  assertBindGroupResource as normalizeBindGroupResource,
  normalizeTextureDimension,
  normalizeBindGroupLayoutEntry,
  autoLayoutEntriesFromNativeBindings,
} from "./shared/validation.js";
import {
  setupGlobalsOnTarget,
  requestAdapterFromCreate,
  requestDeviceFromRequestAdapter,
  buildProviderInfo,
  libraryFlavor,
} from "./shared/public-surface.js";
import {
  shaderCheckFailure,
  enrichNativeCompilerError,
  compilerErrorFromMessage,
  pipelineErrorFromError,
  pipelineErrorFromMessage,
} from "./shared/compiler-errors.js";
import {
  createFullSurfaceClasses,
  dispatchDeviceEvent,
  resolveDeviceLost,
  GPUValidationError,
  GPUOutOfMemoryError,
  GPUInternalError,
  GPUDeviceLostInfo,
  GPUUncapturedErrorEvent,
} from "./shared/full-surface.js";
import {
  createEncoderClasses,
} from "./shared/encoder-surface.js";
import {
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
  normalizeOrigin2D,
  normalizeCanvasConfiguration,
  createBrowserSurfaceClasses,
} from "./shared/browser-surface.js";
import {
  createNativeBrowserCanvasBackend,
} from "./shared/browser-native-canvas-backend.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

export { globals };

const WEBGPU_GLOBALS = Object.freeze({
    ...globals,
    GPUValidationError,
    GPUOutOfMemoryError,
    GPUInternalError,
    GPUDeviceLostInfo,
    GPUUncapturedErrorEvent,
});

const CALLBACK_MODE_ALLOW_PROCESS_EVENTS = 2;
const WGPU_STATUS_SUCCESS = 1;
const REQUEST_ADAPTER_STATUS_SUCCESS = 1;
const REQUEST_DEVICE_STATUS_SUCCESS = 1;
const MAP_ASYNC_STATUS_SUCCESS = 1;
const READBACK_BREAKDOWN_FIELD_COUNT = 6;
const READBACK_BREAKDOWN_WAIT_COMPLETED = 0;
const READBACK_BREAKDOWN_DEFERRED_COPY = 1;
const READBACK_BREAKDOWN_DEFERRED_RESOLVE = 2;
const READBACK_BREAKDOWN_MAP = 3;
const READBACK_BREAKDOWN_COPY = 4;
const READBACK_BREAKDOWN_UNMAP = 5;
const DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT = 12;
const DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY = 0;
const DISPATCH_FLUSH_BREAKDOWN_QUEUE_SUBMIT = 1;
const DISPATCH_FLUSH_BREAKDOWN_FLUSH = 2;
const DISPATCH_FLUSH_BREAKDOWN_WAIT_COMPLETED = 3;
const DISPATCH_FLUSH_BREAKDOWN_DEFERRED_COPY = 4;
const DISPATCH_FLUSH_BREAKDOWN_DEFERRED_RESOLVE = 5;
const DISPATCH_FLUSH_BREAKDOWN_COMMAND_BUFFER_END = 6;
const DISPATCH_FLUSH_BREAKDOWN_SYNC_PREPARE = 7;
const DISPATCH_FLUSH_BREAKDOWN_DRIVER_SUBMIT = 8;
const DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_PREPARE = 9;
const DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_RECORD = 10;
const DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_COPY = 11;
const STYPE_SHADER_SOURCE_WGSL = 0x00000002;
const PROCESS_EVENTS_TIMEOUT_NS = 5_000_000_000;
const NS_PER_MS = 1_000_000;
let processEventsTimeoutNs = PROCESS_EVENTS_TIMEOUT_NS;
const BUFFER_MAP_STATE = Object.freeze({
    unmapped: 0,
    pending: 1,
    mapped: 2,
});
const DEVICE_LOST_REASON = Object.freeze({
    unknown: 0,
    destroyed: 1,
    callbackCancelled: 3,
    failedCreation: 4,
});
const ERROR_TYPE = Object.freeze({
    noError: 0x00000001,
    validation: 0x00000002,
    outOfMemory: 0x00000003,
    internal: 0x00000004,
});
const EMPTY_ADAPTER_INFO = Object.freeze({
    vendor: "",
    architecture: "",
    device: "",
    description: "",
    subgroupMinSize: 0,
    subgroupMaxSize: 0,
});
const METAL_WEBGPU_SUBGROUP_MIN_SIZE = 4;
const METAL_WEBGPU_SUBGROUP_MAX_SIZE = 64;
const SAMPLER_BINDING_TYPE = Object.freeze({
    filtering: 2,
    "non-filtering": 3,
    comparison: 4,
});
const TEXTURE_SAMPLE_TYPE = Object.freeze({
    float: 2,
    "unfilterable-float": 3,
    depth: 4,
    sint: 5,
    uint: 6,
});
const TEXTURE_VIEW_DIMENSION = Object.freeze({
    "1d": 1,
    "2d": 2,
    "2d-array": 3,
    cube: 4,
    "cube-array": 5,
    "3d": 6,
});
const TEXTURE_ASPECT_MAP = Object.freeze({
    all: 1,
    "stencil-only": 2,
    "depth-only": 3,
});
const TEXTURE_SWIZZLE_COMPONENT_MAP = Object.freeze({
    "0": 1,
    "1": 2,
    r: 3,
    g: 4,
    b: 5,
    a: 6,
});
const STORAGE_TEXTURE_ACCESS = Object.freeze({
    "write-only": 2,
    "read-only": 3,
    "read-write": 4,
});
const MAX_COMPUTE_BIND_GROUPS = 4;
const MAX_QUEUE_WRITE_BATCH_BYTES = 4 * 1024 * 1024;
const SHADER_SOURCE_BYTES_CACHE_MAX_ENTRIES = 128;
const HOT_U64_CACHE_MAX_ENTRIES = 4096;

function envFlagEnabled(value) {
    return value === "1" || value === "true" || value === "yes" || value === "on";
}

const DOE_WEBGPU_SUBMIT_BREAKDOWN = envFlagEnabled(process.env.DOE_WEBGPU_SUBMIT_BREAKDOWN);
const shaderSourceBytesCache = new Map();
const hotU64Cache = new Map();

function hotU64(value) {
    if (value === null || value === undefined || value === 0 || value === 0n) {
        return 0n;
    }
    if (value === 1) return 1n;
    if (value === 4) return 4n;
    if (value === 16) return 16n;
    if (value === 18) return 18n;
    if (typeof value === "bigint") {
        return value;
    }
    const cached = hotU64Cache.get(value);
    if (cached !== undefined) {
        return cached;
    }
    const converted = BigInt(value);
    if (hotU64Cache.size >= HOT_U64_CACHE_MAX_ENTRIES) {
        hotU64Cache.clear();
    }
    hotU64Cache.set(value, converted);
    return converted;
}

// Struct layout constants for 64-bit platforms (LP64 / LLP64).
const PTR_SIZE = 8;
const SIZE_T_SIZE = 8;
const WGPU_BUFFER_DESCRIPTOR_SIZE = 48;
const WGPU_SHADER_SOURCE_WGSL_SIZE = 32;
const WGPU_SHADER_MODULE_DESCRIPTOR_SIZE = 24;
const WGPU_COMPUTE_PIPELINE_DESCRIPTOR_SIZE = 80;
const WGPU_RENDER_PIPELINE_DESCRIPTOR_SIZE = 168;
const WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_SIZE = 40;
const WGPU_BIND_GROUP_DESCRIPTOR_SIZE = 48;
const WGPU_PIPELINE_LAYOUT_DESCRIPTOR_SIZE = 48;
const WGPU_RENDER_PASS_DESCRIPTOR_SIZE = 72;
const WGPU_LIMITS_SIZE = 152;
const WGPU_QUEUE_DESCRIPTOR_SIZE = 24;
const WGPU_DEVICE_DESCRIPTOR_SIZE = 144;
const WGPU_DEVICE_DEFAULT_QUEUE_LABEL_OFFSET = 56;
const WGPU_RENDER_VERTEX_STATE_SIZE = 64;
const WGPU_RENDER_COLOR_TARGET_STATE_SIZE = 32;
const WGPU_RENDER_FRAGMENT_STATE_SIZE = 64;
const WGPU_VERTEX_ATTRIBUTE_SIZE = 32;
const WGPU_VERTEX_BUFFER_LAYOUT_SIZE = 40;
const WGPU_DEPTH_STENCIL_STATE_SIZE = 72;
const WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_SIZE = 48;

// ---------------------------------------------------------------------------
// Library resolution
// ---------------------------------------------------------------------------

function resolveDoeLibraryPath() {
    const packagedLibraryPath = resolvePlatformPackageLibraryPath({
        requireFn: require,
        workspaceRoot: WORKSPACE_ROOT,
    });
    const libraryNames = libraryBasenamesForPlatform();
    const candidates = [
        process.env.DOE_WEBGPU_LIB,
        process.env.DOE_LIB,
        ...libraryNames.map((name) => resolve(WORKSPACE_ROOT, "runtime", "zig", "zig-out", "lib", name)),
        ...libraryNames.map((name) => resolve(WORKSPACE_ROOT, "zig", "zig-out", "lib", name)),
        packagedLibraryPath,
        ...libraryNames.map((name) => resolve(PACKAGE_ROOT, "prebuilds", `${process.platform}-${process.arch}`, name)),
        ...libraryNames.map((name) => resolve(process.cwd(), "runtime", "zig", "zig-out", "lib", name)),
        ...libraryNames.map((name) => resolve(process.cwd(), "zig", "zig-out", "lib", name)),
    ];
    for (const c of candidates) {
        if (c && existsSync(c)) return c;
    }
    return null;
}

const DOE_LIB_PATH = resolveDoeLibraryPath();
const DOE_LIBRARY_FLAVOR = libraryFlavor(DOE_LIB_PATH);
const DOE_BUILD_METADATA = loadDoeBuildMetadata({
    packageRoot: PACKAGE_ROOT,
    libraryPath: DOE_LIB_PATH ?? "",
});
let wgpu = null;

// ---------------------------------------------------------------------------
// FFI symbol bindings
// ---------------------------------------------------------------------------

function openLibrary(path) {
    const symbols = {
        // Instance
        wgpuCreateInstance:       { args: [FFIType.ptr], returns: FFIType.ptr },
        wgpuInstanceRelease:      { args: [FFIType.ptr], returns: FFIType.void },
        wgpuInstanceWaitAny:      { args: [FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.u64], returns: FFIType.u32 },
        wgpuInstanceProcessEvents: { args: [FFIType.ptr], returns: FFIType.void },

        // Adapter/Device (flat helpers)
        doeRequestAdapterFlat:    { args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.u64 },
        doeRequestDeviceFlat:     { args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.u64 },
        doeNativeAdapterHasFeature: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
        doeNativeAdapterGetLimits:  { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.u32 },
        doeNativeAdapterGetInfo:    { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        doeNativeAdapterFreeInfo:   { args: [FFIType.ptr], returns: FFIType.void },
        doeNativeDeviceHasFeature:  { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
        doeNativeDeviceGetLimits:   { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.u32 },
        doeNativeDevicePushErrorScope: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.void },
        doeNativeDevicePopErrorScopeFlat: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.u64 },
        doeNativeDeviceSetUncapturedErrorCallback: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        doeNativeDeviceRegisterLostCallback: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        wgpuAdapterRelease:       { args: [FFIType.ptr], returns: FFIType.void },
        wgpuAdapterHasFeature:    { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
        wgpuAdapterGetLimits:     { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.u32 },
        wgpuDeviceRelease:        { args: [FFIType.ptr], returns: FFIType.void },
        wgpuDeviceHasFeature:     { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
        wgpuDeviceGetLimits:      { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.u32 },
        wgpuDeviceGetQueue:       { args: [FFIType.ptr], returns: FFIType.ptr },

        // Buffer
        wgpuDeviceCreateBuffer:   { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        doeNativeDeviceCreateBufferFlat: { args: [FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u32], returns: FFIType.ptr },
        wgpuBufferRelease:        { args: [FFIType.ptr], returns: FFIType.void },
        wgpuBufferUnmap:          { args: [FFIType.ptr], returns: FFIType.void },
        wgpuBufferGetConstMappedRange: { args: [FFIType.ptr, FFIType.u64, FFIType.u64], returns: FFIType.ptr },
        wgpuBufferGetMappedRange: { args: [FFIType.ptr, FFIType.u64, FFIType.u64], returns: FFIType.ptr },
        doeNativeBufferGetMapState: { args: [FFIType.ptr], returns: FFIType.u32 },
        doeBufferMapAsyncFlat:    { args: [FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u64, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.u64 },
        doeBufferMapSyncFlat:     { args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u64], returns: FFIType.u32 },
        doeBufferMapReadCopyUnmapFlat: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u64, FFIType.u32, FFIType.ptr, FFIType.ptr], returns: FFIType.u32 },

        // Queue
        wgpuQueueSubmit:          { args: [FFIType.ptr, FFIType.u64, FFIType.ptr], returns: FFIType.void },
        wgpuQueueWriteBuffer:     { args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        doeNativeQueueWriteBuffer: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        doeNativeQueueWriteBufferBatch: { args: [FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        doeNativeQueueWriteBufferBatchDataPtrs: { args: [FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        wgpuQueueRelease:         { args: [FFIType.ptr], returns: FFIType.void },
        doeQueueOnSubmittedWorkDoneFlat: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.u64 },
        doeQueueSubmitOneAndRelease: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.void },

        // Shader
        wgpuDeviceCreateShaderModule: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        doeNativeDeviceCreateShaderModuleWgsl: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.ptr },
        wgpuShaderModuleRelease:  { args: [FFIType.ptr], returns: FFIType.void },
        doeNativeShaderModuleGetBindings: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.u64 },

        // Compute pipeline
        wgpuDeviceCreateComputePipeline: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        doeNativeDeviceCreateComputePipelineMain: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuComputePipelineRelease: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuComputePipelineGetBindGroupLayout: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.ptr },

        // Bind group layout / bind group / pipeline layout
        wgpuDeviceCreateBindGroupLayout: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        doeNativeDeviceCreateBufferBindGroupLayoutFlat4: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.ptr },
        wgpuBindGroupLayoutRelease: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuDeviceCreateBindGroup: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        doeNativeDeviceCreateBufferBindGroupFlat4: {
            args: [
                FFIType.ptr, FFIType.ptr, FFIType.u32,
                FFIType.u32, FFIType.ptr, FFIType.u64,
                FFIType.u32, FFIType.ptr, FFIType.u64,
                FFIType.u32, FFIType.ptr, FFIType.u64,
                FFIType.u32, FFIType.ptr, FFIType.u64,
            ],
            returns: FFIType.ptr,
        },
        wgpuBindGroupRelease:     { args: [FFIType.ptr], returns: FFIType.void },
        wgpuDeviceCreatePipelineLayout: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        doeNativeDeviceCreatePipelineLayoutOne: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32], returns: FFIType.ptr },
        wgpuPipelineLayoutRelease: { args: [FFIType.ptr], returns: FFIType.void },

        // Command encoder
        wgpuDeviceCreateCommandEncoder: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuCommandEncoderRelease: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuCommandEncoderBeginComputePass: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuCommandEncoderCopyBufferToBuffer: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.u64, FFIType.u64], returns: FFIType.void },
        wgpuCommandEncoderCopyTextureToBuffer: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        doeNativeCommandEncoderCopyTextureToBuffer: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.void },
        wgpuCommandEncoderFinish: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuCommandBufferRelease: { args: [FFIType.ptr], returns: FFIType.void },

        // Compute pass
        wgpuComputePassEncoderSetPipeline: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        wgpuComputePassEncoderSetBindGroup: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr], returns: FFIType.void },
        wgpuComputePassEncoderDispatchWorkgroups: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.void },
        doeNativeComputePassDispatchBound: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.void },
        wgpuComputePassEncoderDispatchWorkgroupsIndirect: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuComputePassEncoderEnd: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuComputePassEncoderRelease: { args: [FFIType.ptr], returns: FFIType.void },

        // Texture
        wgpuDeviceCreateTexture:  { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuTextureCreateView:    { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuTextureRelease:       { args: [FFIType.ptr], returns: FFIType.void },
        wgpuTextureViewRelease:   { args: [FFIType.ptr], returns: FFIType.void },

        // Sampler
        wgpuDeviceCreateSampler:  { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuSamplerRelease:       { args: [FFIType.ptr], returns: FFIType.void },

        // Render pipeline
        wgpuDeviceCreateRenderPipeline: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuRenderPipelineRelease: { args: [FFIType.ptr], returns: FFIType.void },

        // Render pass
        wgpuCommandEncoderBeginRenderPass: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuRenderPassEncoderSetPipeline: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        wgpuRenderPassEncoderSetBindGroup: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr], returns: FFIType.void },
        wgpuRenderPassEncoderSetVertexBuffer: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.u64], returns: FFIType.void },
        wgpuRenderPassEncoderSetIndexBuffer: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.u64, FFIType.u64], returns: FFIType.void },
        wgpuRenderPassEncoderDraw: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.void },
        wgpuRenderPassEncoderDrawIndexed: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.i32, FFIType.u32], returns: FFIType.void },
        wgpuRenderPassEncoderSetViewport: { args: [FFIType.ptr, FFIType.f32, FFIType.f32, FFIType.f32, FFIType.f32, FFIType.f32, FFIType.f32], returns: FFIType.void },
        wgpuRenderPassEncoderSetScissorRect: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.void },
        wgpuRenderPassEncoderSetBlendConstant: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        wgpuRenderPassEncoderSetStencilReference: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.void },
        wgpuRenderPassEncoderPushDebugGroup: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuRenderPassEncoderPopDebugGroup: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuRenderPassEncoderInsertDebugMarker: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuCommandEncoderPushDebugGroup: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuCommandEncoderPopDebugGroup: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuCommandEncoderInsertDebugMarker: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuComputePassEncoderPushDebugGroup: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuComputePassEncoderPopDebugGroup: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuComputePassEncoderInsertDebugMarker: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuRenderPassEncoderEnd: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuRenderPassEncoderRelease: { args: [FFIType.ptr], returns: FFIType.void },

        // Render bundle encoder / bundle
        wgpuDeviceCreateRenderBundleEncoder: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuRenderBundleEncoderSetPipeline: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.void },
        wgpuRenderBundleEncoderSetBindGroup: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr], returns: FFIType.void },
        wgpuRenderBundleEncoderSetVertexBuffer: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.u64], returns: FFIType.void },
        wgpuRenderBundleEncoderSetIndexBuffer: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.u64, FFIType.u64], returns: FFIType.void },
        wgpuRenderBundleEncoderDraw: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.u32], returns: FFIType.void },
        wgpuRenderBundleEncoderPushDebugGroup: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuRenderBundleEncoderPopDebugGroup: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuRenderBundleEncoderInsertDebugMarker: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuRenderBundleEncoderDrawIndexed: { args: [FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.i32, FFIType.u32], returns: FFIType.void },
        wgpuRenderBundleEncoderDrawIndirect: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuRenderBundleEncoderDrawIndexedIndirect: { args: [FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.void },
        wgpuRenderBundleEncoderPushDebugGroup: { args: [FFIType.ptr, FFIType.cstring], returns: FFIType.void },
        wgpuRenderBundleEncoderPopDebugGroup: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuRenderBundleEncoderInsertDebugMarker: { args: [FFIType.ptr, FFIType.cstring], returns: FFIType.void },
        wgpuRenderBundleEncoderFinish: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
        wgpuRenderBundleEncoderRelease: { args: [FFIType.ptr], returns: FFIType.void },
        wgpuRenderBundleRelease: { args: [FFIType.ptr], returns: FFIType.void },

        // Render pipeline bind group layout
        wgpuRenderPipelineGetBindGroupLayout: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.ptr },

        // Queue write texture
        wgpuQueueWriteTexture: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    };
        symbols.doeNativeComputePipelineGetBindGroupLayout = {
            args: [FFIType.ptr, FFIType.u32],
            returns: FFIType.ptr,
        };
        symbols.doeNativeCheckShaderSource = {
            args: [FFIType.ptr, FFIType.u64],
            returns: FFIType.u32,
        };
        symbols.doeNativeCopyLastErrorMessage = {
            args: [FFIType.ptr, FFIType.u64],
            returns: FFIType.u64,
        };
        symbols.doeNativeCopyLastErrorStage = {
            args: [FFIType.ptr, FFIType.u64],
            returns: FFIType.u64,
        };
        symbols.doeNativeCopyLastErrorKind = {
            args: [FFIType.ptr, FFIType.u64],
            returns: FFIType.u64,
        };
        symbols.doeNativeGetLastErrorLine = {
            args: [],
            returns: FFIType.u32,
        };
        symbols.doeNativeGetLastErrorColumn = {
            args: [],
            returns: FFIType.u32,
        };
        symbols.doeNativeDeviceCreateQuerySet = {
            args: [FFIType.ptr, FFIType.u32, FFIType.u32],
            returns: FFIType.ptr,
        };
        symbols.doeNativeCommandEncoderWriteTimestamp = {
            args: [FFIType.ptr, FFIType.ptr, FFIType.u32],
            returns: FFIType.void,
        };
        symbols.doeNativeCommandEncoderResolveQuerySet = {
            args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.ptr, FFIType.u64],
            returns: FFIType.void,
        };
        symbols.doeNativeQuerySetDestroy = {
            args: [FFIType.ptr],
            returns: FFIType.void,
        };
        symbols.doeNativeQueueFlush = {
            args: [FFIType.ptr],
            returns: FFIType.void,
        };
        symbols.doeNativeQueueFlushBreakdown = {
            args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr],
            returns: FFIType.void,
        };
        symbols.doeNativeQueueSyncInfo = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueuePipelineCacheInfo = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueuePipelineCacheWarmupCount = {
            args: [FFIType.ptr],
            returns: FFIType.u64,
        };
        symbols.doeNativeQueuePipelineCacheWarmupNs = {
            args: [FFIType.ptr],
            returns: FFIType.u64,
        };
        symbols.doeNativeQueuePipelineCacheFlush = {
            args: [FFIType.ptr],
            returns: FFIType.void,
        };
        symbols.doeNativeQueueFamilyPolicyCode = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueueDeferredSubmissionSyncPolicyCode = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueueFamilyKindCode = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueueFamilyIndex = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueueFamilyQueueCount = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueueFamilyTimestampValidBits = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativeQueueFamilySupportsGraphics = {
            args: [FFIType.ptr],
            returns: FFIType.u32,
        };
        symbols.doeNativePackagePipelineCacheFlush = {
            args: [],
            returns: FFIType.void,
        };
        symbols.doeNativeComputeDispatchFlush = {
            args: [
                FFIType.ptr,  // queue
                FFIType.ptr,  // pipeline
                FFIType.ptr,  // bindGroups (ptr array)
                FFIType.u32,  // bgCount
                FFIType.u32,  // x
                FFIType.u32,  // y
                FFIType.u32,  // z
                FFIType.ptr,  // copySrc
                FFIType.u64,  // copySrcOff
                FFIType.ptr,  // copyDst
                FFIType.u64,  // copyDstOff
                FFIType.u64,  // copySize
            ],
            returns: FFIType.void,
        };
        symbols.doeNativeComputeDispatchFlushOneBindGroup = {
            args: [
                FFIType.ptr,  // queue
                FFIType.ptr,  // pipeline
                FFIType.ptr,  // bindGroup0
                FFIType.u32,  // x
                FFIType.u32,  // y
                FFIType.u32,  // z
                FFIType.ptr,  // copySrc
                FFIType.u64,  // copySrcOff
                FFIType.ptr,  // copyDst
                FFIType.u64,  // copyDstOff
                FFIType.u64,  // copySize
            ],
            returns: FFIType.void,
        };
        symbols.doeNativeComputeDispatchFlushBreakdown = {
            args: [
                FFIType.ptr,  // queue
                FFIType.ptr,  // pipeline
                FFIType.ptr,  // bindGroups (ptr array)
                FFIType.u32,  // bgCount
                FFIType.u32,  // x
                FFIType.u32,  // y
                FFIType.u32,  // z
                FFIType.ptr,  // copySrc
                FFIType.u64,  // copySrcOff
                FFIType.ptr,  // copyDst
                FFIType.u64,  // copyDstOff
                FFIType.u64,  // copySize
                FFIType.ptr,  // u64 breakdown[6]
            ],
            returns: FFIType.void,
        };
        symbols.doeNativeComputeDispatchBatchFlush = {
            args: [
                FFIType.ptr,  // queue
                FFIType.u64,  // dispatchCount
                FFIType.ptr,  // pipelines
                FFIType.ptr,  // bindGroups
                FFIType.ptr,  // bindGroupCounts
                FFIType.ptr,  // dispatchDims
            ],
            returns: FFIType.void,
        };
        symbols.doeNativeComputeDispatchBatchCopyFlush = {
            args: [
                FFIType.ptr,  // queue
                FFIType.u64,  // dispatchCount
                FFIType.ptr,  // pipelines
                FFIType.ptr,  // bindGroups
                FFIType.ptr,  // bindGroupCounts
                FFIType.ptr,  // dispatchDims
                FFIType.ptr,  // copySrc
                FFIType.u64,  // copySrcOff
                FFIType.ptr,  // copyDst
                FFIType.u64,  // copyDstOff
                FFIType.u64,  // copySize
            ],
            returns: FFIType.void,
        };
        symbols.doeNativeComputeDispatchBatchCopyFlushBreakdown = {
            args: [
                FFIType.ptr,  // queue
                FFIType.u64,  // dispatchCount
                FFIType.ptr,  // pipelines
                FFIType.ptr,  // bindGroups
                FFIType.ptr,  // bindGroupCounts
                FFIType.ptr,  // dispatchDims
                FFIType.ptr,  // copySrc
                FFIType.u64,  // copySrcOff
                FFIType.ptr,  // copyDst
                FFIType.u64,  // copyDstOff
                FFIType.u64,  // copySize
                FFIType.ptr,  // u64 breakdown[6]
            ],
            returns: FFIType.void,
        };
        symbols.doeNativeComputePrewarmDispatchBindings = {
            args: [
                FFIType.ptr,  // queue
                FFIType.u64,  // dispatchCount
                FFIType.ptr,  // pipelines
                FFIType.ptr,  // bindGroups
                FFIType.ptr,  // bindGroupCounts
            ],
            returns: FFIType.u32,
        };
    return dlopen(path, symbols);
}

// ---------------------------------------------------------------------------
// Struct marshaling helpers
//
// All layouts assume 64-bit LP64/LLP64: ptr=8, size_t=8, u64=8, u32=4.
// WGPUStringView = { data: ptr@0, length: size_t@8 } = 16 bytes.
// ---------------------------------------------------------------------------

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const LIMIT_OFFSETS = Object.freeze({
    maxTextureDimension1D: 8,
    maxTextureDimension2D: 12,
    maxTextureDimension3D: 16,
    maxTextureArrayLayers: 20,
    maxBindGroups: 24,
    maxBindGroupsPlusVertexBuffers: 28,
    maxBindingsPerBindGroup: 32,
    maxDynamicUniformBuffersPerPipelineLayout: 36,
    maxDynamicStorageBuffersPerPipelineLayout: 40,
    maxSampledTexturesPerShaderStage: 44,
    maxSamplersPerShaderStage: 48,
    maxStorageBuffersPerShaderStage: 52,
    maxStorageTexturesPerShaderStage: 56,
    maxUniformBuffersPerShaderStage: 60,
    maxUniformBufferBindingSize: 64,
    maxStorageBufferBindingSize: 72,
    minUniformBufferOffsetAlignment: 80,
    minStorageBufferOffsetAlignment: 84,
    maxVertexBuffers: 88,
    maxBufferSize: 96,
    maxVertexAttributes: 104,
    maxVertexBufferArrayStride: 108,
    maxInterStageShaderVariables: 112,
    maxColorAttachments: 116,
    maxColorAttachmentBytesPerSample: 120,
    maxComputeWorkgroupStorageSize: 124,
    maxComputeInvocationsPerWorkgroup: 128,
    maxComputeWorkgroupSizeX: 132,
    maxComputeWorkgroupSizeY: 136,
    maxComputeWorkgroupSizeZ: 140,
    maxComputeWorkgroupsPerDimension: 144,
    maxImmediateSize: 148,
});

function copyLastErrorMessage() {
    const fn = wgpu?.symbols?.doeNativeCopyLastErrorMessage;
    if (typeof fn !== "function") return "";
    const buf = new Uint8Array(4096);
    const len = Number(fn(buf, BigInt(buf.length)));
    if (len <= 1) return "";
    return decoder.decode(buf.subarray(0, Math.max(0, len - 1)));
}

function decodeLimits(raw) {
    const view = new DataView(raw);
    const maxStorageBuffersPerShaderStage = view.getUint32(LIMIT_OFFSETS.maxStorageBuffersPerShaderStage, true);
    const maxStorageTexturesPerShaderStage = view.getUint32(LIMIT_OFFSETS.maxStorageTexturesPerShaderStage, true);
    return Object.freeze({
        maxTextureDimension1D: view.getUint32(LIMIT_OFFSETS.maxTextureDimension1D, true),
        maxTextureDimension2D: view.getUint32(LIMIT_OFFSETS.maxTextureDimension2D, true),
        maxTextureDimension3D: view.getUint32(LIMIT_OFFSETS.maxTextureDimension3D, true),
        maxTextureArrayLayers: view.getUint32(LIMIT_OFFSETS.maxTextureArrayLayers, true),
        maxBindGroups: view.getUint32(LIMIT_OFFSETS.maxBindGroups, true),
        maxBindGroupsPlusVertexBuffers: view.getUint32(LIMIT_OFFSETS.maxBindGroupsPlusVertexBuffers, true),
        maxBindingsPerBindGroup: view.getUint32(LIMIT_OFFSETS.maxBindingsPerBindGroup, true),
        maxDynamicUniformBuffersPerPipelineLayout: view.getUint32(LIMIT_OFFSETS.maxDynamicUniformBuffersPerPipelineLayout, true),
        maxDynamicStorageBuffersPerPipelineLayout: view.getUint32(LIMIT_OFFSETS.maxDynamicStorageBuffersPerPipelineLayout, true),
        maxSampledTexturesPerShaderStage: view.getUint32(LIMIT_OFFSETS.maxSampledTexturesPerShaderStage, true),
        maxSamplersPerShaderStage: view.getUint32(LIMIT_OFFSETS.maxSamplersPerShaderStage, true),
        maxStorageBuffersPerShaderStage,
        maxStorageTexturesPerShaderStage,
        maxUniformBuffersPerShaderStage: view.getUint32(LIMIT_OFFSETS.maxUniformBuffersPerShaderStage, true),
        maxUniformBufferBindingSize: Number(view.getBigUint64(LIMIT_OFFSETS.maxUniformBufferBindingSize, true)),
        maxStorageBufferBindingSize: Number(view.getBigUint64(LIMIT_OFFSETS.maxStorageBufferBindingSize, true)),
        minUniformBufferOffsetAlignment: view.getUint32(LIMIT_OFFSETS.minUniformBufferOffsetAlignment, true),
        minStorageBufferOffsetAlignment: view.getUint32(LIMIT_OFFSETS.minStorageBufferOffsetAlignment, true),
        maxVertexBuffers: view.getUint32(LIMIT_OFFSETS.maxVertexBuffers, true),
        maxBufferSize: Number(view.getBigUint64(LIMIT_OFFSETS.maxBufferSize, true)),
        maxVertexAttributes: view.getUint32(LIMIT_OFFSETS.maxVertexAttributes, true),
        maxVertexBufferArrayStride: view.getUint32(LIMIT_OFFSETS.maxVertexBufferArrayStride, true),
        maxInterStageShaderVariables: view.getUint32(LIMIT_OFFSETS.maxInterStageShaderVariables, true),
        maxColorAttachments: view.getUint32(LIMIT_OFFSETS.maxColorAttachments, true),
        maxColorAttachmentBytesPerSample: view.getUint32(LIMIT_OFFSETS.maxColorAttachmentBytesPerSample, true),
        maxComputeWorkgroupStorageSize: view.getUint32(LIMIT_OFFSETS.maxComputeWorkgroupStorageSize, true),
        maxComputeInvocationsPerWorkgroup: view.getUint32(LIMIT_OFFSETS.maxComputeInvocationsPerWorkgroup, true),
        maxComputeWorkgroupSizeX: view.getUint32(LIMIT_OFFSETS.maxComputeWorkgroupSizeX, true),
        maxComputeWorkgroupSizeY: view.getUint32(LIMIT_OFFSETS.maxComputeWorkgroupSizeY, true),
        maxComputeWorkgroupSizeZ: view.getUint32(LIMIT_OFFSETS.maxComputeWorkgroupSizeZ, true),
        maxComputeWorkgroupsPerDimension: view.getUint32(LIMIT_OFFSETS.maxComputeWorkgroupsPerDimension, true),
        maxImmediateSize: view.getUint32(LIMIT_OFFSETS.maxImmediateSize, true),
        maxStorageBuffersInVertexStage: maxStorageBuffersPerShaderStage,
        maxStorageBuffersInFragmentStage: maxStorageBuffersPerShaderStage,
        maxStorageTexturesInVertexStage: maxStorageTexturesPerShaderStage,
        maxStorageTexturesInFragmentStage: maxStorageTexturesPerShaderStage,
    });
}

function queryLimits(handle, fnName) {
    const fn = wgpu?.symbols?.[fnName];
    if (typeof fn !== "function" || !handle) return publishLimits(null);
    const raw = new ArrayBuffer(WGPU_LIMITS_SIZE);
    const status = Number(fn(handle, new Uint8Array(raw)));
    if (status !== WGPU_STATUS_SUCCESS) return publishLimits(null);
    return publishLimits(decodeLimits(raw));
}

function queryLimitsByPreference(handle, fnNames) {
    for (const fnName of fnNames) {
        const fn = wgpu?.symbols?.[fnName];
        if (typeof fn !== "function" || !handle) continue;
        const raw = new ArrayBuffer(WGPU_LIMITS_SIZE);
        const status = Number(fn(handle, new Uint8Array(raw)));
        if (status !== WGPU_STATUS_SUCCESS) continue;
        return publishLimits(decodeLimits(raw));
    }
    return publishLimits(null);
}

function adapterLimits(handle) {
    return queryLimitsByPreference(handle, ["doeNativeAdapterGetLimits", "wgpuAdapterGetLimits"]);
}

function deviceLimits(handle) {
    return queryLimitsByPreference(handle, ["doeNativeDeviceGetLimits", "wgpuDeviceGetLimits"]);
}

function adapterFeatures(handle) {
    const fn = wgpu?.symbols?.doeNativeAdapterHasFeature ?? wgpu?.symbols?.wgpuAdapterHasFeature;
    return publishFeatures(
        typeof fn === "function" && handle
            ? (feature) => Number(fn(handle, feature)) !== 0
            : null,
    );
}

function deviceFeatures(handle) {
    const fn = wgpu?.symbols?.doeNativeDeviceHasFeature ?? wgpu?.symbols?.wgpuDeviceHasFeature;
    return publishFeatures(
        typeof fn === "function" && handle
            ? (feature) => Number(fn(handle, feature)) !== 0
            : null,
    );
}

function copyNativeErrorMeta(symbolName) {
    const fn = wgpu?.symbols?.[symbolName];
    if (typeof fn !== "function") return "";
    const scratch = new Uint8Array(256);
    const len = Number(fn(scratch, scratch.length));
    if (!len) return "";
    return decoder.decode(scratch.subarray(0, Math.min(len, scratch.length - 1)));
}

const fastPathStats = { dispatchFlush: 0, flushAndMap: 0, commandBufferBuild: 0 };
const ZERO_READBACK_BREAKDOWN_NS = Object.freeze({
    readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: 0,
    readbackMapReadCopyUnmapDeferredCopyTotalNs: 0,
    readbackMapReadCopyUnmapDeferredResolveTotalNs: 0,
    readbackMapReadCopyUnmapMapTotalNs: 0,
    readbackMapReadCopyUnmapCopyTotalNs: 0,
    readbackMapReadCopyUnmapUnmapTotalNs: 0,
});
const QUEUE_SYNC_INFO_BACKEND_VULKAN = 1;
const QUEUE_SYNC_INFO_TIMELINE_SEMAPHORE = 2;
const QUEUE_SYNC_INFO_FENCE_POOL = 4;
const QUEUE_SYNC_INFO_DEFERRED_SUBMISSIONS = 8;
const QUEUE_PIPELINE_CACHE_INFO_BACKEND_VULKAN = 1;
const QUEUE_PIPELINE_CACHE_INFO_ACTIVE = 2;
const QUEUE_PIPELINE_CACHE_INFO_DISABLED = 4;
const QUEUE_PIPELINE_CACHE_INFO_SUPPORTED = 8;
const QUEUE_FAMILY_POLICY_NAMES = Object.freeze([
    "prefer_graphics_compute",
    "prefer_compute_only",
    "require_compute_only",
]);
const QUEUE_FAMILY_KIND_NAMES = Object.freeze([
    "graphics_compute",
    "compute_only",
]);
const DEFERRED_SUBMISSION_SYNC_POLICY_NAMES = Object.freeze([
    "prefer_timeline_semaphore",
    "require_fence_pool",
]);

function nativeFastPathInfoFromSymbols() {
    if (!DOE_LIB_PATH) {
        return null;
    }
    try {
        ensureLibrary();
    } catch (_error) {
        return null;
    }
    const symbols = wgpu?.symbols ?? {};
    return {
        appleFastPathCompiled: process.platform === "darwin",
        queueFlush: typeof symbols.doeNativeQueueFlush === "function",
        queueFlushBreakdown: typeof symbols.doeNativeQueueFlushBreakdown === "function",
        queueWriteBufferBatch: typeof symbols.doeNativeQueueWriteBufferBatch === "function",
        queueWriteBufferBatchDataPtrs: typeof symbols.doeNativeQueueWriteBufferBatchDataPtrs === "function",
        computeDispatchFlush: typeof symbols.doeNativeComputeDispatchFlush === "function",
        computeDispatchFlushOneBindGroup: typeof symbols.doeNativeComputeDispatchFlushOneBindGroup === "function",
        computeDispatchFlushBreakdown: typeof symbols.doeNativeComputeDispatchFlushBreakdown === "function",
        computeDispatchBatchFlush: typeof symbols.doeNativeComputeDispatchBatchFlush === "function",
        computeDispatchBatchCopyFlush: typeof symbols.doeNativeComputeDispatchBatchCopyFlush === "function",
        computeDispatchBatchCopyFlushBreakdown: typeof symbols.doeNativeComputeDispatchBatchCopyFlushBreakdown === "function",
        computePrewarmDispatchBindings: typeof symbols.doeNativeComputePrewarmDispatchBindings === "function",
        bufferMapReadCopyUnmap: typeof symbols.doeBufferMapReadCopyUnmapFlat === "function",
    };
}

function decodeQueueSyncInfoBits(bits) {
    return {
        backendVulkan: (bits & QUEUE_SYNC_INFO_BACKEND_VULKAN) !== 0,
        timelineSemaphore: (bits & QUEUE_SYNC_INFO_TIMELINE_SEMAPHORE) !== 0,
        fencePool: (bits & QUEUE_SYNC_INFO_FENCE_POOL) !== 0,
        deferredSubmissions: (bits & QUEUE_SYNC_INFO_DEFERRED_SUBMISSIONS) !== 0,
    };
}

function decodePipelineCacheInfoBits(bits) {
    if ((bits & QUEUE_PIPELINE_CACHE_INFO_BACKEND_VULKAN) === 0) {
        return null;
    }
    const active = (bits & QUEUE_PIPELINE_CACHE_INFO_ACTIVE) !== 0;
    const disabled = (bits & QUEUE_PIPELINE_CACHE_INFO_DISABLED) !== 0;
    const supported = (bits & QUEUE_PIPELINE_CACHE_INFO_SUPPORTED) !== 0;
    return {
        backend: "vulkan",
        state: active ? "enabled" : "disabled",
        reason: !supported
            ? "platform-unsupported"
            : disabled
                ? "cli-flag"
                : active
                    ? "default"
                    : "non-doe-backend",
    };
}

function maybeCallQueueU32(symbolName, queueNative) {
    const fn = wgpu?.symbols?.[symbolName];
    if (typeof fn !== "function") return null;
    const value = Number(fn(queueNative));
    return value === UINT32_MAX ? null : value;
}

function attachQueueFamilyInfo(info, queueNative) {
    const policyCode = maybeCallQueueU32("doeNativeQueueFamilyPolicyCode", queueNative);
    if (policyCode != null && QUEUE_FAMILY_POLICY_NAMES[policyCode]) {
        info.queueFamilyPolicy = QUEUE_FAMILY_POLICY_NAMES[policyCode];
    }
    const syncPolicyCode = maybeCallQueueU32("doeNativeQueueDeferredSubmissionSyncPolicyCode", queueNative);
    if (syncPolicyCode != null && DEFERRED_SUBMISSION_SYNC_POLICY_NAMES[syncPolicyCode]) {
        info.deferredSubmissionSyncPolicy = DEFERRED_SUBMISSION_SYNC_POLICY_NAMES[syncPolicyCode];
    }
    const kindCode = maybeCallQueueU32("doeNativeQueueFamilyKindCode", queueNative);
    if (kindCode != null && QUEUE_FAMILY_KIND_NAMES[kindCode]) {
        info.queueFamilyKind = QUEUE_FAMILY_KIND_NAMES[kindCode];
    }
    const queueFamilyIndex = maybeCallQueueU32("doeNativeQueueFamilyIndex", queueNative);
    if (queueFamilyIndex != null) info.queueFamilyIndex = queueFamilyIndex;
    const queueFamilyQueueCount = maybeCallQueueU32("doeNativeQueueFamilyQueueCount", queueNative);
    if (queueFamilyQueueCount != null) info.queueFamilyQueueCount = queueFamilyQueueCount;
    const queueFamilyTimestampValidBits = maybeCallQueueU32("doeNativeQueueFamilyTimestampValidBits", queueNative);
    if (queueFamilyTimestampValidBits != null) info.queueFamilyTimestampValidBits = queueFamilyTimestampValidBits;
    const queueFamilySupportsGraphics = maybeCallQueueU32("doeNativeQueueFamilySupportsGraphics", queueNative);
    if (queueFamilySupportsGraphics != null) info.queueFamilySupportsGraphics = queueFamilySupportsGraphics !== 0;
    return info;
}

export function nativeQueueSyncInfo(queue) {
    if (!DOE_LIB_PATH) {
        return null;
    }
    try {
        ensureLibrary();
    } catch (_error) {
        return null;
    }
    const fn = wgpu?.symbols?.doeNativeQueueSyncInfo;
    if (typeof fn !== "function" || !queue?._native) {
        return null;
    }
    return attachQueueFamilyInfo(decodeQueueSyncInfoBits(Number(fn(queue._native))), queue._native);
}

export function nativePipelineCacheInfo(queue) {
    if (!DOE_LIB_PATH) {
        return null;
    }
    try {
        ensureLibrary();
    } catch (_error) {
        return null;
    }
    const fn = wgpu?.symbols?.doeNativeQueuePipelineCacheInfo;
    if (typeof fn !== "function" || !queue?._native) {
        return null;
    }
    const info = decodePipelineCacheInfoBits(Number(fn(queue._native)));
    if (!info) {
        return null;
    }
    const warmupCountFn = wgpu?.symbols?.doeNativeQueuePipelineCacheWarmupCount;
    const warmupNsFn = wgpu?.symbols?.doeNativeQueuePipelineCacheWarmupNs;
    return {
        ...info,
        warmupCount: typeof warmupCountFn === "function" ? Math.max(0, Number(warmupCountFn(queue._native)) || 0) : 0,
        warmupNs: typeof warmupNsFn === "function" ? Math.max(0, Number(warmupNsFn(queue._native)) || 0) : 0,
    };
}

export function packagePipelineCacheFlush(queue = null) {
    if (!DOE_LIB_PATH) {
        return false;
    }
    try {
        ensureLibrary();
    } catch (_error) {
        return false;
    }
    if (queue?._native && typeof wgpu?.symbols?.doeNativeQueuePipelineCacheFlush === "function") {
        wgpu.symbols.doeNativeQueuePipelineCacheFlush(queue._native);
    }
    if (typeof wgpu?.symbols?.doeNativePackagePipelineCacheFlush === "function") {
        wgpu.symbols.doeNativePackagePipelineCacheFlush();
    }
    return true;
}

function cachedShaderSourceBytes(code) {
    const cached = shaderSourceBytesCache.get(code);
    if (cached) return cached;
    const encoded = encoder.encode(code);
    if (shaderSourceBytesCache.size >= SHADER_SOURCE_BYTES_CACHE_MAX_ENTRIES) {
        const firstKey = shaderSourceBytesCache.keys().next().value;
        shaderSourceBytesCache.delete(firstKey);
    }
    shaderSourceBytesCache.set(code, encoded);
    return encoded;
}

function elapsedNsSince(startedAtMs) {
    return Math.max(0, Math.round((performance.now() - startedAtMs) * NS_PER_MS));
}

function submitTimingStart() {
    return DOE_WEBGPU_SUBMIT_BREAKDOWN ? performance.now() : 0;
}

function zeroQueueSubmitBreakdown() {
    return {
        submitCommandPrepTotalNs: 0,
        submitAddonCallTotalNs: 0,
        submitAddonCommandReplayTotalNs: 0,
        submitAddonCommandReplayPrepareTotalNs: 0,
        submitAddonCommandReplayRecordTotalNs: 0,
        submitAddonCommandReplayCopyTotalNs: 0,
        submitAddonQueueSubmitTotalNs: 0,
        submitAddonCommandBufferEndTotalNs: 0,
        submitAddonSyncPrepareTotalNs: 0,
        submitAddonDriverSubmitTotalNs: 0,
        submitAddonFlushTotalNs: 0,
        submitPostSubmitBookkeepingTotalNs: 0,
        submitQueueFlushTotalNs: 0,
        submitQueueFlushWaitCompletedTotalNs: 0,
        submitQueueFlushDeferredCopyTotalNs: 0,
        submitQueueFlushDeferredResolveTotalNs: 0,
        submitQueueWaitBookkeepingTotalNs: 0,
    };
}

function accumulateQueueSubmitBreakdown(queue, field, startedAtMs) {
    if (!startedAtMs) return;
    queue._submitBreakdownNs[field] += elapsedNsSince(startedAtMs);
}

function queueDispatchFlushBreakdownScratch(queue) {
    const scratch = queue._dispatchFlushBreakdown ?? new BigUint64Array(DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT);
    queue._dispatchFlushBreakdown = scratch;
    for (let index = 0; index < DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT; index += 1) {
        scratch[index] = 0n;
    }
    return scratch;
}

function accumulateDispatchFlushBreakdown(queue, breakdown) {
    queue._submitBreakdownNs.submitAddonCommandReplayTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY],
    );
    queue._submitBreakdownNs.submitAddonCommandReplayPrepareTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_PREPARE],
    );
    queue._submitBreakdownNs.submitAddonCommandReplayRecordTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_RECORD],
    );
    queue._submitBreakdownNs.submitAddonCommandReplayCopyTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_COPY],
    );
    queue._submitBreakdownNs.submitAddonQueueSubmitTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_QUEUE_SUBMIT],
    );
    queue._submitBreakdownNs.submitAddonCommandBufferEndTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_COMMAND_BUFFER_END],
    );
    queue._submitBreakdownNs.submitAddonSyncPrepareTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_SYNC_PREPARE],
    );
    queue._submitBreakdownNs.submitAddonDriverSubmitTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_DRIVER_SUBMIT],
    );
    queue._submitBreakdownNs.submitAddonFlushTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_FLUSH],
    );
    queue._submitBreakdownNs.submitQueueFlushWaitCompletedTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_WAIT_COMPLETED],
    );
    queue._submitBreakdownNs.submitQueueFlushDeferredCopyTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_DEFERRED_COPY],
    );
    queue._submitBreakdownNs.submitQueueFlushDeferredResolveTotalNs += Number(
        breakdown[DISPATCH_FLUSH_BREAKDOWN_DEFERRED_RESOLVE],
    );
}

function updatePassPipelineState(pass, pipelineNative) {
    if (pass._pipeline === pipelineNative) {
        return false;
    }
    pass._pipeline = pipelineNative;
    return true;
}

function updatePassBindGroupState(pass, index, bindGroupNative) {
    if ((pass._bindGroups[index] ?? null) === bindGroupNative) {
        return false;
    }
    pass._bindGroups[index] = bindGroupNative;
    return true;
}

function initPendingComputeState(pass) {
    pass._pipelineDirty = false;
    pass._bindGroupDirty = [];
}

function markPassPipelineDirty(pass) {
    pass._pipelineDirty = true;
}

function markPassBindGroupDirty(pass, index) {
    pass._bindGroupDirty[index] = true;
}

function clearPendingBoundDispatchState(pass) {
    pass._pipelineDirty = false;
    pass._bindGroupDirty[0] = false;
}

function hasPendingNonZeroBindGroups(pass) {
    for (let index = 1; index < pass._bindGroupDirty.length; index += 1) {
        if (pass._bindGroupDirty[index]) {
            return true;
        }
    }
    return false;
}

function materializeBunPendingComputeState(pass, nativePass) {
    if (pass._pipelineDirty && pass._pipeline != null) {
        wgpu.symbols.wgpuComputePassEncoderSetPipeline(nativePass, pass._pipeline);
        pass._pipelineDirty = false;
    }
    for (let index = 0; index < pass._bindGroupDirty.length; index += 1) {
        if (!pass._bindGroupDirty[index]) {
            continue;
        }
        const bindGroupNative = pass._bindGroups[index] ?? null;
        if (bindGroupNative != null) {
            wgpu.symbols.wgpuComputePassEncoderSetBindGroup(nativePass, index, bindGroupNative, BigInt(0), null);
        }
        pass._bindGroupDirty[index] = false;
    }
}

function immediateBytesEqual(currentData, nextData) {
    if (!currentData || currentData.byteLength !== nextData.byteLength) {
        return false;
    }
    for (let index = 0; index < currentData.byteLength; index += 1) {
        if (currentData[index] !== nextData[index]) {
            return false;
        }
    }
    return true;
}

function updatePassImmediateState(pass, index, data) {
    const currentData = pass._immediates[index];
    if (immediateBytesEqual(currentData, data)) {
        return false;
    }
    pass._immediates[index] = data.slice();
    return true;
}

function updatePassVertexBufferState(pass, slot, bufferNative, offset, size) {
    const current = pass._vertexBuffers[slot];
    if (
        current
        && current.buffer === bufferNative
        && current.offset === offset
        && current.size === size
    ) {
        return false;
    }
    pass._vertexBuffers[slot] = { buffer: bufferNative, offset, size };
    return true;
}

function updatePassIndexBufferState(pass, bufferNative, format, offset, size) {
    const current = pass._indexBuffer;
    if (
        current
        && current.buffer === bufferNative
        && current.format === format
        && current.offset === offset
        && current.size === size
    ) {
        return false;
    }
    pass._indexBuffer = { buffer: bufferNative, format, offset, size };
    return true;
}

function ensureSubmitPtrScratch(queue, count) {
    if (count <= 1) {
        return queue._singleSubmitPtrArray;
    }
    if (!(queue._submitPtrScratch instanceof BigUint64Array) || queue._submitPtrScratch.length < count) {
        queue._submitPtrScratch = new BigUint64Array(count);
    }
    return queue._submitPtrScratch;
}

function ensureBindGroupPtrScratch(queue, count) {
    if (count <= 0) {
        return queue._emptyBindGroupPtrArray;
    }
    if (count <= 1) {
        return queue._singleBindGroupPtrArray;
    }
    if (!(queue._bindGroupPtrScratch instanceof BigUint64Array) || queue._bindGroupPtrScratch.length < count) {
        queue._bindGroupPtrScratch = new BigUint64Array(count);
    }
    return queue._bindGroupPtrScratch;
}

function ensureDispatchBatchScratch(queue, dispatchCount) {
    let scratch = queue._dispatchBatchScratch;
    if (!scratch) {
        scratch = {};
        queue._dispatchBatchScratch = scratch;
    }
    const bindGroupCapacity = dispatchCount * MAX_COMPUTE_BIND_GROUPS;
    if (!(scratch.pipelines instanceof BigUint64Array) || scratch.pipelines.length < dispatchCount) {
        scratch.pipelines = new BigUint64Array(dispatchCount);
    }
    if (!(scratch.bindGroups instanceof BigUint64Array) || scratch.bindGroups.length < bindGroupCapacity) {
        scratch.bindGroups = new BigUint64Array(bindGroupCapacity);
    }
    if (!(scratch.bindGroupCounts instanceof Uint32Array) || scratch.bindGroupCounts.length < dispatchCount) {
        scratch.bindGroupCounts = new Uint32Array(dispatchCount);
    }
    if (!(scratch.dispatchDims instanceof Uint32Array) || scratch.dispatchDims.length < dispatchCount * 3) {
        scratch.dispatchDims = new Uint32Array(dispatchCount * 3);
    }
    return scratch;
}

function fillBunDispatchBatchScratch(scratch, commands, dispatchCount) {
    const { pipelines, bindGroups, bindGroupCounts, dispatchDims } = scratch;
    for (let i = 0; i < dispatchCount; i += 1) {
        const cmd = commands[i];
        if (!cmd || cmd.t !== 0 || (cmd.immediates !== undefined && cmd.immediates.length !== 0)) {
            return false;
        }
        pipelines[i] = hotU64(cmd.p);
        const bindGroupOffset = i * MAX_COMPUTE_BIND_GROUPS;
        const compactBindGroup = cmd.b;
        if (compactBindGroup) {
            bindGroupCounts[i] = 1;
            bindGroups[bindGroupOffset] = hotU64(compactBindGroup);
        } else {
            const commandBindGroups = cmd.bg;
            const bgCount = Array.isArray(commandBindGroups)
                ? Math.min(commandBindGroups.length, MAX_COMPUTE_BIND_GROUPS)
                : 0;
            bindGroupCounts[i] = bgCount;
            for (let j = 0; j < bgCount; j += 1) {
                bindGroups[bindGroupOffset + j] = hotU64(commandBindGroups[j]);
            }
        }
        dispatchDims[(i * 3)] = cmd.x;
        dispatchDims[(i * 3) + 1] = cmd.y;
        dispatchDims[(i * 3) + 2] = cmd.z;
    }
    return true;
}

function ensureQueueWriteBatchScratch(queue, count, byteLength) {
    let scratch = queue._writeBatchScratch;
    if (!scratch) {
        scratch = {};
        queue._writeBatchScratch = scratch;
    }
    if (!(scratch.buffers instanceof BigUint64Array) || scratch.buffers.length < count) {
        scratch.buffers = new BigUint64Array(count);
    }
    if (!(scratch.offsets instanceof BigUint64Array) || scratch.offsets.length < count) {
        scratch.offsets = new BigUint64Array(count);
    }
    if (!(scratch.sizes instanceof Uint32Array) || scratch.sizes.length < count) {
        scratch.sizes = new Uint32Array(count);
    }
    if (!(scratch.dataPtrs instanceof BigUint64Array) || scratch.dataPtrs.length < count) {
        scratch.dataPtrs = new BigUint64Array(count);
    }
    if (!(scratch.data instanceof Uint8Array) || scratch.data.length < byteLength) {
        scratch.data = new Uint8Array(byteLength);
    }
    return scratch;
}

function bunCommandBindGroupCount(cmd) {
    if (cmd?.b) {
        return 1;
    }
    return Math.min(cmd?.bg?.length ?? 0, MAX_COMPUTE_BIND_GROUPS);
}

function bunCommandBindGroupAt(cmd, index) {
    if (index === 0 && cmd?.b) {
        return cmd.b;
    }
    return cmd?.bg?.[index] ?? null;
}

function pushBunLazyDispatchCommand(pass, pipelineNative, x, y, z) {
    const bindGroups = pass._bindGroups;
    if (bindGroups.length > 1) {
        pass._encoder._commands.push({ t: 0, p: pipelineNative, bg: [...bindGroups], x, y, z });
        return;
    }
    const bindGroup = bindGroups[0] ?? null;
    if (bindGroup) {
        pass._encoder._commands.push({ t: 0, p: pipelineNative, b: bindGroup, x, y, z });
    } else {
        pass._encoder._commands.push({ t: 0, p: pipelineNative, x, y, z });
    }
}

function queueFlushBreakdownScratch(queue) {
    if (
        !(queue._flushWaitCompletedNs instanceof BigUint64Array)
        || !(queue._flushDeferredCopyNs instanceof BigUint64Array)
        || !(queue._flushDeferredResolveNs instanceof BigUint64Array)
    ) {
        queue._flushWaitCompletedNs = new BigUint64Array(1);
        queue._flushDeferredCopyNs = new BigUint64Array(1);
        queue._flushDeferredResolveNs = new BigUint64Array(1);
        queue._mapReadCopyUnmapNs = new BigUint64Array(READBACK_BREAKDOWN_FIELD_COUNT);
    }
    queue._flushWaitCompletedNs[0] = 0n;
    queue._flushDeferredCopyNs[0] = 0n;
    queue._flushDeferredResolveNs[0] = 0n;
}

function queueMapReadCopyUnmapScratch(queue) {
    if (!(queue._mapReadCopyUnmapNs instanceof BigUint64Array)) {
        queue._mapReadCopyUnmapNs = new BigUint64Array(READBACK_BREAKDOWN_FIELD_COUNT);
    }
    queue._mapReadCopyUnmapNs.fill(0n);
    return queue._mapReadCopyUnmapNs;
}

/**
 * Read structured error fields (stage, kind, line, column) from the native
 * last-error ABI. Uses `doeNativeGetLastErrorLine` / `doeNativeGetLastErrorColumn`
 * when available; falls back to string copy functions for stage/kind.
 * Returns null when the native symbols are absent (pre-structured-error builds).
 */
function readLastErrorFields() {
    const stageFn = wgpu?.symbols?.doeNativeCopyLastErrorStage;
    const kindFn = wgpu?.symbols?.doeNativeCopyLastErrorKind;
    if (typeof stageFn !== "function" && typeof kindFn !== "function") return null;
    const stage = copyNativeErrorMeta("doeNativeCopyLastErrorStage");
    const kind = copyNativeErrorMeta("doeNativeCopyLastErrorKind");
    const lineFn = wgpu?.symbols?.doeNativeGetLastErrorLine;
    const colFn = wgpu?.symbols?.doeNativeGetLastErrorColumn;
    const line = typeof lineFn === "function" ? Number(lineFn()) : 0;
    const column = typeof colFn === "function" ? Number(colFn()) : 0;
    return {
        stage: stage || undefined,
        kind: kind || undefined,
        line: line > 0 ? line : undefined,
        column: column > 0 ? column : undefined,
    };
}

function preflightShaderSource(code) {
    const fn = wgpu?.symbols?.doeNativeCheckShaderSource;
    if (typeof fn !== "function") {
        return { ok: true, stage: "", kind: "", message: "", reasons: [] };
    }
    const codeBytes = encoder.encode(code);
    const ok = Number(fn(codeBytes, codeBytes.length)) !== 0;
    if (ok) return { ok: true, stage: "", kind: "", message: "", reasons: [] };
    const message = copyNativeErrorMeta("doeNativeCopyLastErrorMessage");
    const lineFn = wgpu?.symbols?.doeNativeGetLastErrorLine;
    const colFn = wgpu?.symbols?.doeNativeGetLastErrorColumn;
    const line = typeof lineFn === "function" ? Number(lineFn()) : 0;
    const column = typeof colFn === "function" ? Number(colFn()) : 0;
    const out = {
        ok: false,
        stage: copyNativeErrorMeta("doeNativeCopyLastErrorStage"),
        kind: copyNativeErrorMeta("doeNativeCopyLastErrorKind"),
        message,
        reasons: message ? [message] : [],
    };
    if (line > 0) out.line = line;
    if (column > 0) out.column = column;
    return out;
}

function writeStringView(view, offset, strBytes) {
    if (strBytes) {
        view.setBigUint64(offset, BigInt(bunPtr(strBytes)), true);
        view.setBigUint64(offset + 8, BigInt(strBytes.length), true);
    } else {
        view.setBigUint64(offset, 0n, true);
        view.setBigUint64(offset + 8, 0n, true);
    }
}

function writePtr(view, offset, ptr) {
    view.setBigUint64(offset, ptr ? BigInt(ptr) : 0n, true);
}

// WGPUBufferDescriptor: { nextInChain:ptr@0, label:sv@8, usage:u64@24, size:u64@32, mappedAtCreation:u32@40 } = 48
function buildBufferDescriptor(descriptor) {
    const buf = new ArrayBuffer(WGPU_BUFFER_DESCRIPTOR_SIZE);
    const v = new DataView(buf);
    // nextInChain = null
    writePtr(v, 0, null);
    // label = empty
    writeStringView(v, 8, null);
    // usage
    v.setBigUint64(24, BigInt(descriptor.usage || 0), true);
    // size
    v.setBigUint64(32, BigInt(descriptor.size || 0), true);
    // mappedAtCreation
    v.setUint32(40, descriptor.mappedAtCreation ? 1 : 0, true);
    return new Uint8Array(buf);
}

// WGPUShaderSourceWGSL: { chain:{next:ptr@0, sType:u32@8, pad@12}, code:sv@16 } = 32
// WGPUShaderModuleDescriptor: { nextInChain:ptr@0, label:sv@8 } = 24
function buildShaderModuleDescriptor(code) {
    const codeBytes = encoder.encode(code);

    const wgslBuf = new ArrayBuffer(WGPU_SHADER_SOURCE_WGSL_SIZE);
    const wgslView = new DataView(wgslBuf);
    writePtr(wgslView, 0, null);
    wgslView.setUint32(8, STYPE_SHADER_SOURCE_WGSL, true);
    writeStringView(wgslView, 16, codeBytes);
    const wgslArr = new Uint8Array(wgslBuf);

    const descBuf = new ArrayBuffer(WGPU_SHADER_MODULE_DESCRIPTOR_SIZE);
    const descView = new DataView(descBuf);
    writePtr(descView, 0, bunPtr(wgslArr));
    writeStringView(descView, 8, null);

    return { desc: new Uint8Array(descBuf), _refs: [codeBytes, wgslArr] };
}

// WGPUComputePipelineDescriptor:
// { nextInChain:ptr@0, label:sv@8, layout:ptr@24, compute:WGPUProgrammableStageDescriptor@32 }
// WGPUProgrammableStageDescriptor: { nextInChain:ptr@0, module:ptr@8, entryPoint:sv@16, constantCount:size_t@32, constants:ptr@40 } = 48
// Total descriptor: 24 + 8 (layout) + 48 (compute) = 80
function buildComputePipelineDescriptor(shaderModulePtr, entryPoint, layoutPtr) {
    const epBytes = encoder.encode(entryPoint);
    const buf = new ArrayBuffer(WGPU_COMPUTE_PIPELINE_DESCRIPTOR_SIZE);
    const v = new DataView(buf);
    // nextInChain
    writePtr(v, 0, null);
    // label
    writeStringView(v, 8, null);
    // layout
    writePtr(v, 24, layoutPtr);
    // compute.nextInChain
    writePtr(v, 32, null);
    // compute.module
    writePtr(v, 40, shaderModulePtr);
    // compute.entryPoint
    writeStringView(v, 48, epBytes);
    // compute.constantCount
    v.setBigUint64(64, 0n, true);
    // compute.constants
    writePtr(v, 72, null);
    return { desc: new Uint8Array(buf), _refs: [epBytes] };
}

function buildRenderPipelineDescriptor(descriptor) {
    const vertexEntryBytes = encoder.encode(descriptor.vertexEntryPoint);
    const fragmentEntryBytes = encoder.encode(descriptor.fragmentEntryPoint);
    const vertexBuffers = descriptor.vertexBuffers ?? [];
    const vertexConstants = buildConstantEntries(descriptor.vertexConstants);
    const fragmentConstants = buildConstantEntries(descriptor.fragmentConstants);
    const fragmentTarget = descriptor.fragmentTarget ?? { format: descriptor.colorFormat };
    let blendStateArr = null;
    if (fragmentTarget.blend) {
        const blendStateBuf = new ArrayBuffer(WGPU_BLEND_STATE_SIZE);
        const blendStateView = new DataView(blendStateBuf);
        const color = fragmentTarget.blend.color ?? {};
        const alpha = fragmentTarget.blend.alpha ?? {};
        blendStateView.setUint32(0, blendOperationCode(color.operation), true);
        blendStateView.setUint32(4, blendFactorCode(color.srcFactor ?? "one"), true);
        blendStateView.setUint32(8, blendFactorCode(color.dstFactor ?? "zero"), true);
        blendStateView.setUint32(12, blendOperationCode(alpha.operation), true);
        blendStateView.setUint32(16, blendFactorCode(alpha.srcFactor ?? "one"), true);
        blendStateView.setUint32(20, blendFactorCode(alpha.dstFactor ?? "zero"), true);
        blendStateArr = new Uint8Array(blendStateBuf);
    }

    const colorTargetBuf = new ArrayBuffer(WGPU_RENDER_COLOR_TARGET_STATE_SIZE);
    const colorTargetView = new DataView(colorTargetBuf);
    writePtr(colorTargetView, 0, null);
    colorTargetView.setUint32(8, TEXTURE_FORMAT_MAP[fragmentTarget.format ?? descriptor.colorFormat] ?? 0x00000016, true);
    writePtr(colorTargetView, 16, blendStateArr ? bunPtr(blendStateArr) : null);
    colorTargetView.setBigUint64(24, BigInt(fragmentTarget.writeMask ?? 0xF), true);
    const colorTargetArr = new Uint8Array(colorTargetBuf);

    const fragmentBuf = new ArrayBuffer(WGPU_RENDER_FRAGMENT_STATE_SIZE);
    const fragmentView = new DataView(fragmentBuf);
    writePtr(fragmentView, 0, null);
    writePtr(fragmentView, 8, descriptor.fragmentModule);
    writeStringView(fragmentView, 16, fragmentEntryBytes);
    fragmentView.setBigUint64(32, BigInt(fragmentConstants.count), true);
    writePtr(fragmentView, 40, fragmentConstants.entries ? bunPtr(fragmentConstants.entries) : null);
    fragmentView.setBigUint64(48, 1n, true);
    writePtr(fragmentView, 56, bunPtr(colorTargetArr));
    const fragmentArr = new Uint8Array(fragmentBuf);

    let vertexAttributeArr = null;
    let vertexBufferArr = null;
    if (vertexBuffers.length > 0) {
        let totalAttributeCount = 0;
        for (const buffer of vertexBuffers) {
            totalAttributeCount += (buffer.attributes ?? []).length;
        }
        vertexAttributeArr = new Uint8Array(totalAttributeCount * WGPU_VERTEX_ATTRIBUTE_SIZE);
        vertexBufferArr = new Uint8Array(vertexBuffers.length * WGPU_VERTEX_BUFFER_LAYOUT_SIZE);
        const attrView = new DataView(vertexAttributeArr.buffer);
        const layoutView = new DataView(vertexBufferArr.buffer);
        let attrIndex = 0;
        for (let bufferIndex = 0; bufferIndex < vertexBuffers.length; bufferIndex += 1) {
            const buffer = vertexBuffers[bufferIndex] ?? {};
            const attributes = buffer.attributes ?? [];
            const layoutOffset = bufferIndex * WGPU_VERTEX_BUFFER_LAYOUT_SIZE;
            writePtr(layoutView, layoutOffset + 0, null);
            layoutView.setUint32(layoutOffset + 8, VERTEX_STEP_MODE_MAP[buffer.stepMode ?? "vertex"] ?? VERTEX_STEP_MODE_MAP.vertex, true);
            layoutView.setBigUint64(layoutOffset + 16, BigInt(buffer.arrayStride ?? 0), true);
            layoutView.setBigUint64(layoutOffset + 24, BigInt(attributes.length), true);
            writePtr(layoutView, layoutOffset + 32, attributes.length > 0 ? bunPtr(vertexAttributeArr) + attrIndex * WGPU_VERTEX_ATTRIBUTE_SIZE : null);
            for (const attribute of attributes) {
                const attrOffset = attrIndex * WGPU_VERTEX_ATTRIBUTE_SIZE;
                writePtr(attrView, attrOffset + 0, null);
                attrView.setUint32(attrOffset + 8, VERTEX_FORMAT_MAP[attribute.format] ?? 0, true);
                attrView.setBigUint64(attrOffset + 16, BigInt(attribute.offset ?? 0), true);
                attrView.setUint32(attrOffset + 24, attribute.shaderLocation ?? 0, true);
                attrIndex += 1;
            }
        }
    }

    let depthStencilArr = null;
    if (descriptor.depthStencil) {
        const stencilFront = descriptor.depthStencil.stencilFront ?? {};
        const stencilBack = descriptor.depthStencil.stencilBack ?? {};
        const depthStencilBuf = new ArrayBuffer(WGPU_DEPTH_STENCIL_STATE_SIZE);
        const depthStencilView = new DataView(depthStencilBuf);
        writePtr(depthStencilView, 0, null);
        depthStencilView.setUint32(8, TEXTURE_FORMAT_MAP[descriptor.depthStencil.format] ?? TEXTURE_FORMAT_MAP.depth32float, true);
        depthStencilView.setUint32(12, descriptor.depthStencil.depthWriteEnabled ? 1 : 0, true);
        depthStencilView.setUint32(16, COMPARE_FUNC_MAP[descriptor.depthStencil.depthCompare ?? "always"] ?? COMPARE_FUNC_MAP.always, true);
        depthStencilView.setUint32(20, COMPARE_FUNC_MAP[stencilFront.compare ?? "always"] ?? COMPARE_FUNC_MAP.always, true);
        depthStencilView.setUint32(24, STENCIL_OPERATION_MAP[stencilFront.failOp ?? "keep"] ?? STENCIL_OPERATION_MAP.keep, true);
        depthStencilView.setUint32(28, STENCIL_OPERATION_MAP[stencilFront.depthFailOp ?? "keep"] ?? STENCIL_OPERATION_MAP.keep, true);
        depthStencilView.setUint32(32, STENCIL_OPERATION_MAP[stencilFront.passOp ?? "keep"] ?? STENCIL_OPERATION_MAP.keep, true);
        depthStencilView.setUint32(36, COMPARE_FUNC_MAP[stencilBack.compare ?? "always"] ?? COMPARE_FUNC_MAP.always, true);
        depthStencilView.setUint32(40, STENCIL_OPERATION_MAP[stencilBack.failOp ?? "keep"] ?? STENCIL_OPERATION_MAP.keep, true);
        depthStencilView.setUint32(44, STENCIL_OPERATION_MAP[stencilBack.depthFailOp ?? "keep"] ?? STENCIL_OPERATION_MAP.keep, true);
        depthStencilView.setUint32(48, STENCIL_OPERATION_MAP[stencilBack.passOp ?? "keep"] ?? STENCIL_OPERATION_MAP.keep, true);
        depthStencilView.setUint32(52, descriptor.depthStencil.stencilReadMask ?? 0xFFFFFFFF, true);
        depthStencilView.setUint32(56, descriptor.depthStencil.stencilWriteMask ?? 0xFFFFFFFF, true);
        depthStencilView.setInt32(60, descriptor.depthStencil.depthBias ?? 0, true);
        depthStencilView.setFloat32(64, descriptor.depthStencil.depthBiasSlopeScale ?? 0, true);
        depthStencilView.setFloat32(68, descriptor.depthStencil.depthBiasClamp ?? 0, true);
        depthStencilArr = new Uint8Array(depthStencilBuf);
    }

    const primitive = descriptor.primitive ?? {};
    const multisample = descriptor.multisample ?? {};
    const buf = new ArrayBuffer(WGPU_RENDER_PIPELINE_DESCRIPTOR_SIZE);
    const view = new DataView(buf);
    writePtr(view, 0, null);
    writeStringView(view, 8, null);
    writePtr(view, 24, descriptor.layout);
    writePtr(view, 32, null);
    writePtr(view, 40, descriptor.vertexModule);
    writeStringView(view, 48, vertexEntryBytes);
    view.setBigUint64(64, BigInt(vertexConstants.count), true);
    writePtr(view, 72, vertexConstants.entries ? bunPtr(vertexConstants.entries) : null);
    view.setBigUint64(80, BigInt(vertexBuffers.length), true);
    writePtr(view, 88, vertexBuffers.length > 0 ? bunPtr(vertexBufferArr) : null);
    writePtr(view, 96, null);
    view.setUint32(104, {
        "point-list": 0x00000001,
        "line-list": 0x00000002,
        "line-strip": 0x00000003,
        "triangle-list": 0x00000004,
        "triangle-strip": 0x00000005,
    }[primitive.topology ?? "triangle-list"] ?? 0x00000004, true);
    view.setUint32(108, 0, true);
    view.setUint32(112, { ccw: 0x00000001, cw: 0x00000002 }[primitive.frontFace ?? "ccw"] ?? 0x00000001, true);
    view.setUint32(116, { none: 0x00000001, front: 0x00000002, back: 0x00000003 }[primitive.cullMode ?? "none"] ?? 0x00000001, true);
    view.setUint32(120, primitive.unclippedDepth ? 1 : 0, true);
    writePtr(view, 128, depthStencilArr ? bunPtr(depthStencilArr) : null);
    writePtr(view, 136, null);
    view.setUint32(144, multisample.count ?? 1, true);
    view.setUint32(148, multisample.mask ?? 0xFFFF_FFFF, true);
    view.setUint32(152, multisample.alphaToCoverageEnabled ? 1 : 0, true);
    writePtr(view, 160, bunPtr(fragmentArr));
    return {
        desc: new Uint8Array(buf),
        _refs: [
            vertexEntryBytes,
            fragmentEntryBytes,
            colorTargetArr,
            blendStateArr,
            fragmentArr,
            vertexAttributeArr,
            vertexBufferArr,
            depthStencilArr,
            ...vertexConstants.refs,
            ...fragmentConstants.refs,
        ].filter(Boolean),
    };
}

// WGPUBindGroupLayoutEntry: { nextInChain:ptr@0, binding:u32@8, visibility:u64@12(actually u32@12 + pad), ...complex }
// The full entry is large. We build a minimal version matching what doe_napi.c marshals.
// For simplicity, we build the entry array matching the C struct layout.
//
// WGPUBindGroupLayoutEntry (simplified layout for buffer-only bindings):
// { nextInChain:ptr@0, binding:u32@8, pad@12, visibility:u64@16,
//   buffer:{nextInChain:ptr@24, type:u32@32, pad@36, hasDynamicOffset:u32@40, pad@44, minBindingSize:u64@48},
//   sampler:{...@56}, texture:{...}, storageTexture:{...} }
// Full size per entry: 128 bytes (varies by ABI — we use a generous allocation)
//
// NOTE: The exact layout is ABI-dependent. We use the wgpu.h canonical layout.
// BindGroupLayoutEntry total = 136 bytes on 64-bit.
const BIND_GROUP_LAYOUT_ENTRY_SIZE = 120;

function buildBindGroupLayoutDescriptor(entries) {
    const entryBufs = new Uint8Array(entries.length * BIND_GROUP_LAYOUT_ENTRY_SIZE);
    const entryView = new DataView(entryBufs.buffer);

    for (let i = 0; i < entries.length; i++) {
        const e = entries[i];
        const off = i * BIND_GROUP_LAYOUT_ENTRY_SIZE;
        // nextInChain: ptr@0
        writePtr(entryView, off + 0, null);
        // binding: u32@8
        entryView.setUint32(off + 8, e.binding, true);
        // visibility: u64@16 (WGPUShaderStageFlags, after 4-byte pad at @12)
        entryView.setBigUint64(off + 16, BigInt(e.visibility || 0), true);
        // bindingArraySize: u32@24
        entryView.setUint32(off + 24, 0, true);
        // buffer sub-struct starts at @32:
        //   buffer.nextInChain: ptr@32
        writePtr(entryView, off + 32, null);
        if (e.buffer) {
            // WGPUBufferBindingType: Undefined=1, Uniform=2, Storage=3, ReadOnlyStorage=4
            const typeMap = { uniform: 2, storage: 3, "read-only-storage": 4 };
            //   buffer.type: u32@40
            entryView.setUint32(off + 40, typeMap[e.buffer.type || "uniform"] || 2, true);
            //   buffer.hasDynamicOffset: u32@44
            entryView.setUint32(off + 44, e.buffer.hasDynamicOffset ? 1 : 0, true);
            //   buffer.minBindingSize: u64@48
            entryView.setBigUint64(off + 48, BigInt(e.buffer.minBindingSize || 0), true);
        }
        if (e.sampler) {
            writePtr(entryView, off + 56, null);
            entryView.setUint32(off + 64, SAMPLER_BINDING_TYPE[e.sampler.type] || 2, true);
        }
        if (e.texture) {
            writePtr(entryView, off + 72, null);
            entryView.setUint32(off + 80, TEXTURE_SAMPLE_TYPE[e.texture.sampleType] || 2, true);
            let tvd = TEXTURE_VIEW_DIMENSION[e.texture.viewDimension] || 2;
            if (e.texture.textureBindingViewDimension) {
                tvd = TEXTURE_VIEW_DIMENSION[e.texture.textureBindingViewDimension] || tvd;
            }
            entryView.setUint32(off + 84, tvd, true);
            entryView.setUint32(off + 88, e.texture.multisampled ? 1 : 0, true);
        }
        if (e.storageTexture) {
            writePtr(entryView, off + 96, null);
            entryView.setUint32(off + 104, STORAGE_TEXTURE_ACCESS[e.storageTexture.access] || 2, true);
            entryView.setUint32(off + 108, TEXTURE_FORMATS[e.storageTexture.format] || 18, true);
            entryView.setUint32(off + 112, TEXTURE_VIEW_DIMENSION[e.storageTexture.viewDimension] || 2, true);
        }
    }

    // WGPUBindGroupLayoutDescriptor: { nextInChain:ptr@0, label:sv@8, entryCount:size_t@24, entries:ptr@32 } = 40
    const descBuf = new ArrayBuffer(WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_SIZE);
    const descView = new DataView(descBuf);
    writePtr(descView, 0, null);
    writeStringView(descView, 8, null);
    descView.setBigUint64(24, BigInt(entries.length), true);
    writePtr(descView, 32, entries.length > 0 ? bunPtr(entryBufs) : null);

    return { desc: new Uint8Array(descBuf), _refs: [entryBufs] };
}

// WGPUBindGroupEntry: { nextInChain:ptr@0, binding:u32@8, pad@12, buffer:ptr@16, offset:u64@24, size:u64@32,
//   sampler:ptr@40, textureView:ptr@48 } = 56
const BIND_GROUP_ENTRY_SIZE = 56;
const WHOLE_SIZE = 0xFFFFFFFFFFFFFFFFn;

function buildBindGroupDescriptor(layoutPtr, entries) {
    const entryBufs = new Uint8Array(entries.length * BIND_GROUP_ENTRY_SIZE);
    const entryView = new DataView(entryBufs.buffer);

    for (let i = 0; i < entries.length; i++) {
        const e = entries[i];
        const off = i * BIND_GROUP_ENTRY_SIZE;
        writePtr(entryView, off + 0, null);
        entryView.setUint32(off + 8, e.binding, true);
        const bufferPtr = e.resource?.buffer ?? null;
        writePtr(entryView, off + 16, bufferPtr);
        entryView.setBigUint64(off + 24, BigInt(e.resource?.offset ?? 0), true);
        entryView.setBigUint64(off + 32, e.resource?.size !== undefined ? BigInt(e.resource.size) : WHOLE_SIZE, true);
        writePtr(entryView, off + 40, e.resource?.sampler ?? null);
        writePtr(entryView, off + 48, e.resource?.textureView ?? null);
    }

    // WGPUBindGroupDescriptor: { nextInChain:ptr@0, label:sv@8, layout:ptr@24, entryCount:size_t@32, entries:ptr@40 } = 48
    const descBuf = new ArrayBuffer(WGPU_BIND_GROUP_DESCRIPTOR_SIZE);
    const descView = new DataView(descBuf);
    writePtr(descView, 0, null);
    writeStringView(descView, 8, null);
    writePtr(descView, 24, layoutPtr);
    descView.setBigUint64(32, BigInt(entries.length), true);
    writePtr(descView, 40, entries.length > 0 ? bunPtr(entryBufs) : null);

    return { desc: new Uint8Array(descBuf), _refs: [entryBufs] };
}

// WGPUPipelineLayoutDescriptor: { nextInChain:ptr@0, label:sv@8, bindGroupLayoutCount:size_t@24,
//   bindGroupLayouts:ptr@32, immediateSize:u32@40, pad@44 } = 48
function buildPipelineLayoutDescriptor(layouts, immediateSize = 0) {
    const ptrs = new BigUint64Array(layouts.length);
    for (let i = 0; i < layouts.length; i++) {
        ptrs[i] = BigInt(layouts[i]);
    }

    const descBuf = new ArrayBuffer(WGPU_PIPELINE_LAYOUT_DESCRIPTOR_SIZE);
    const descView = new DataView(descBuf);
    writePtr(descView, 0, null);
    writeStringView(descView, 8, null);
    descView.setBigUint64(24, BigInt(layouts.length), true);
    writePtr(descView, 32, layouts.length > 0 ? bunPtr(ptrs) : null);
    descView.setUint32(40, immediateSize >>> 0, true);

    return { desc: new Uint8Array(descBuf), _refs: [ptrs] };
}

// WGPUTextureDescriptor: { nextInChain:ptr@0, label:sv@8, usage:u64@24, dimension:u32@32,
//   size:{width:u32@36, height:u32@40, depthOrArrayLayers:u32@44}, format:u32@48,
//   mipLevelCount:u32@52, sampleCount:u32@56, viewFormatCount:size_t@60(pad to 64), viewFormats:ptr@72 }
// Actual: nextInChain@0(8) label@8(16) usage@24(8) dimension@32(4) pad@36(4)
// size@40 {w:u32@40 h:u32@44 d:u32@48} pad@52(4) format@56(4) mipLevelCount@60(4) sampleCount@64(4)
// viewFormatCount@68(8) viewFormats@76(8) = 84 → round to 88
// NOTE: Exact layout depends on struct packing. Let me match the C definition carefully.
// From doe_napi.c:
// { nextInChain:ptr, label:WGPUStringView, usage:u64, dimension:u32, size:WGPUExtent3D, format:u32,
//   mipLevelCount:u32, sampleCount:u32, viewFormatCount:size_t, viewFormats:ptr }
// WGPUExtent3D = { width:u32, height:u32, depthOrArrayLayers:u32 } = 12 bytes
//
// Layout (64-bit, packed):
// nextInChain: ptr@0 (8)
// label.data: ptr@8 (8)
// label.length: size_t@16 (8)
// usage: u64@24 (8)
// dimension: u32@32 (4)
// size.width: u32@36 (4)  ← follows u32, natural alignment
// size.height: u32@40 (4)
// size.depthOrArrayLayers: u32@44 (4)
// format: u32@48 (4)
// mipLevelCount: u32@52 (4)
// sampleCount: u32@56 (4)
// pad: 4@60
// viewFormatCount: size_t@64 (8)
// viewFormats: ptr@72 (8)
// textureBindingViewDimension: u32@80 (4) + pad@84 (4)
// Total: 88
const TEXTURE_DESC_SIZE = 88;

const TEXTURE_FORMAT_MAP = {
    r8unorm: 0x01, r8snorm: 0x02, r8uint: 0x03, r8sint: 0x04,
    r16uint: 0x07, r16sint: 0x08, r16float: 0x09,
    rg8unorm: 0x0A, rg8snorm: 0x0B, rg8uint: 0x0C, rg8sint: 0x0D,
    r32float: 0x0E, r32uint: 0x0F, r32sint: 0x10,
    rg16uint: 0x13, rg16sint: 0x14, rg16float: 0x15,
    rgba8unorm: 0x16, "rgba8unorm-srgb": 0x17, rgba8snorm: 0x18, rgba8uint: 0x19, rgba8sint: 0x1A,
    bgra8unorm: 0x1B, "bgra8unorm-srgb": 0x1C,
    rgb10a2uint: 0x1D, rgb10a2unorm: 0x1E, rg11b10ufloat: 0x1F, rgb9e5ufloat: 0x20,
    rg32float: 0x21, rg32uint: 0x22, rg32sint: 0x23,
    rgba16uint: 0x24, rgba16sint: 0x25, rgba16float: 0x26,
    rgba32float: 0x27, rgba32uint: 0x28, rgba32sint: 0x29,
    stencil8: 0x2C, depth16unorm: 0x2D,
    depth24plus: 0x2E, "depth24plus-stencil8": 0x2F,
    depth32float: 0x30, "depth32float-stencil8": 0x31,
    // BC compressed formats (texture-compression-bc feature)
    "bc1-rgba-unorm": 0x32, "bc1-rgba-unorm-srgb": 0x33,
    "bc2-rgba-unorm": 0x34, "bc2-rgba-unorm-srgb": 0x35,
    "bc3-rgba-unorm": 0x36, "bc3-rgba-unorm-srgb": 0x37,
    "bc4-r-unorm": 0x38, "bc4-r-snorm": 0x39,
    "bc5-rg-unorm": 0x3A, "bc5-rg-snorm": 0x3B,
    "bc6h-rgb-ufloat": 0x3C, "bc6h-rgb-float": 0x3D,
    "bc7-rgba-unorm": 0x3E, "bc7-rgba-unorm-srgb": 0x3F,
    // ETC2/EAC compressed formats (texture-compression-etc2 feature)
    "etc2-rgb8unorm": 0x40, "etc2-rgb8unorm-srgb": 0x41,
    "etc2-rgb8a1unorm": 0x42, "etc2-rgb8a1unorm-srgb": 0x43,
    "etc2-rgba8unorm": 0x44, "etc2-rgba8unorm-srgb": 0x45,
    "eac-r11unorm": 0x46, "eac-r11snorm": 0x47,
    "eac-rg11unorm": 0x48, "eac-rg11snorm": 0x49,
    // ASTC compressed formats (texture-compression-astc feature)
    "astc-4x4-unorm": 0x4A, "astc-4x4-unorm-srgb": 0x4B,
    "astc-5x4-unorm": 0x4C, "astc-5x4-unorm-srgb": 0x4D,
    "astc-5x5-unorm": 0x4E, "astc-5x5-unorm-srgb": 0x4F,
    "astc-6x5-unorm": 0x50, "astc-6x5-unorm-srgb": 0x51,
    "astc-6x6-unorm": 0x52, "astc-6x6-unorm-srgb": 0x53,
    "astc-8x5-unorm": 0x54, "astc-8x5-unorm-srgb": 0x55,
    "astc-8x6-unorm": 0x56, "astc-8x6-unorm-srgb": 0x57,
    "astc-8x8-unorm": 0x58, "astc-8x8-unorm-srgb": 0x59,
    "astc-10x5-unorm": 0x5A, "astc-10x5-unorm-srgb": 0x5B,
    "astc-10x6-unorm": 0x5C, "astc-10x6-unorm-srgb": 0x5D,
    "astc-10x8-unorm": 0x5E, "astc-10x8-unorm-srgb": 0x5F,
    "astc-10x10-unorm": 0x60, "astc-10x10-unorm-srgb": 0x61,
    "astc-12x10-unorm": 0x62, "astc-12x10-unorm-srgb": 0x63,
    "astc-12x12-unorm": 0x64, "astc-12x12-unorm-srgb": 0x65,
};

// Alias used by bind group layout storage texture format lookup
const TEXTURE_FORMATS = TEXTURE_FORMAT_MAP;

const VERTEX_FORMAT_MAP = {
    float32: 0x00000019,
    float32x2: 0x0000001A,
    float32x3: 0x0000001B,
    float32x4: 0x0000001C,
    uint32: 0x00000021,
    uint32x2: 0x00000022,
    uint32x3: 0x00000023,
    uint32x4: 0x00000024,
    sint32: 0x00000025,
    sint32x2: 0x00000026,
    sint32x3: 0x00000027,
    sint32x4: 0x00000028,
};

const VERTEX_STEP_MODE_MAP = {
    vertex: 0x00000001,
    instance: 0x00000002,
};

const COMPARE_FUNC_MAP = {
    never: 0x00000001,
    less: 0x00000002,
    equal: 0x00000003,
    "less-equal": 0x00000004,
    greater: 0x00000005,
    "not-equal": 0x00000006,
    "greater-equal": 0x00000007,
    always: 0x00000008,
};

const STENCIL_OPERATION_MAP = {
    keep: 0x00000001,
    zero: 0x00000002,
    replace: 0x00000003,
    invert: 0x00000004,
    "increment-clamp": 0x00000005,
    "decrement-clamp": 0x00000006,
    "increment-wrap": 0x00000007,
    "decrement-wrap": 0x00000008,
};

const FILTER_MODE_MAP = {
    nearest: 0,
    linear: 1,
};

const ADDRESS_MODE_MAP = {
    repeat: 1,
    "mirror-repeat": 2,
    "clamp-to-edge": 3,
};

const POWER_PREFERENCE_MAP = {
    "low-power": 1,
    "high-performance": 2,
};

const FEATURE_LEVEL_MAP = {
    compatibility: 1,
    core: 2,
};

const INDEX_FORMAT_MAP = {
    uint16: 0x00000001,
    uint32: 0x00000002,
};

const TEXTURE_DIMENSION_MAP = Object.freeze({
    "1d": 1,
    "2d": 2,
    "3d": 3,
});
const TEXTURE_VIEW_DESC_SIZE = 80;
const WGPU_CONSTANT_ENTRY_SIZE = 32;
const WGPU_BLEND_STATE_SIZE = 24;

function blendOperationCode(operation) {
    return {
        add: 1,
        subtract: 2,
        "reverse-subtract": 3,
        min: 4,
        max: 5,
    }[operation ?? "add"] ?? 1;
}

function blendFactorCode(factor) {
    return {
        zero: 1,
        one: 2,
        src: 3,
        "one-minus-src": 4,
        "src-alpha": 5,
        "one-minus-src-alpha": 6,
        dst: 7,
        "one-minus-dst": 8,
        "dst-alpha": 9,
        "one-minus-dst-alpha": 10,
        "src-alpha-saturated": 11,
        constant: 12,
        "one-minus-constant": 13,
        src1: 14,
        "one-minus-src1": 15,
        "src1-alpha": 16,
        "one-minus-src1-alpha": 17,
    }[factor ?? "one"] ?? 2;
}

function buildTextureDescriptor(descriptor) {
    const buf = new ArrayBuffer(TEXTURE_DESC_SIZE);
    const v = new DataView(buf);
    const refs = [];
    writePtr(v, 0, null);
    const labelBytes = descriptor.label ? encoder.encode(descriptor.label) : null;
    if (labelBytes) refs.push(labelBytes);
    writeStringView(v, 8, labelBytes);
    v.setBigUint64(24, BigInt(descriptor.usage || 0), true);
    const dimension = descriptor.dimension ?? "2d";
    v.setUint32(32, typeof dimension === "number" ? dimension : (TEXTURE_DIMENSION_MAP[dimension] ?? 2), true);
    const w = descriptor.size?.[0] ?? descriptor.size?.width ?? descriptor.size ?? 1;
    const h = descriptor.size?.[1] ?? descriptor.size?.height ?? 1;
    const d = descriptor.size?.[2] ?? descriptor.size?.depthOrArrayLayers ?? 1;
    v.setUint32(36, w, true);
    v.setUint32(40, h, true);
    v.setUint32(44, d, true);
    const fmt = descriptor.format || "rgba8unorm";
    v.setUint32(48, TEXTURE_FORMAT_MAP[fmt] ?? 0x16, true);
    v.setUint32(52, descriptor.mipLevelCount || 1, true);
    v.setUint32(56, descriptor.sampleCount || 1, true);
    const viewFormats = Array.isArray(descriptor.viewFormats) ? descriptor.viewFormats : [];
    let viewFormatsArr = null;
    if (viewFormats.length > 0) {
        viewFormatsArr = new Uint32Array(viewFormats.length);
        for (let index = 0; index < viewFormats.length; index += 1) {
            viewFormatsArr[index] = TEXTURE_FORMAT_MAP[viewFormats[index]] ?? 0x16;
        }
        refs.push(viewFormatsArr);
    }
    v.setBigUint64(64, BigInt(viewFormats.length), true);
    writePtr(v, 72, viewFormatsArr ? bunPtr(viewFormatsArr) : null);
    const tbvd = descriptor.textureBindingViewDimension;
    v.setUint32(80, tbvd ? (TEXTURE_VIEW_DIMENSION[tbvd] ?? 0) : 0, true);
    return { desc: new Uint8Array(buf), _refs: refs };
}

function buildTextureViewDescriptor(descriptor) {
    const buf = new ArrayBuffer(TEXTURE_VIEW_DESC_SIZE);
    const v = new DataView(buf);
    const refs = [];
    writePtr(v, 0, null);
    const labelBytes = descriptor.label ? encoder.encode(descriptor.label) : null;
    if (labelBytes) refs.push(labelBytes);
    writeStringView(v, 8, labelBytes);
    const format = descriptor.format;
    v.setUint32(24, format ? (TEXTURE_FORMAT_MAP[format] ?? 0) : 0, true);
    const dimension = descriptor.dimension;
    v.setUint32(28, dimension ? (typeof dimension === "number" ? dimension : (TEXTURE_VIEW_DIMENSION[dimension] ?? 0)) : 0, true);
    v.setUint32(32, descriptor.baseMipLevel ?? 0, true);
    v.setUint32(36, descriptor.mipLevelCount ?? 0, true);
    v.setUint32(40, descriptor.baseArrayLayer ?? 0, true);
    v.setUint32(44, descriptor.arrayLayerCount ?? 0, true);
    const aspect = descriptor.aspect;
    v.setUint32(48, aspect ? (typeof aspect === "number" ? aspect : (TEXTURE_ASPECT_MAP[aspect] ?? 0)) : 0, true);
    v.setBigUint64(56, BigInt(descriptor.usage ?? 0), true);
    const swizzle = typeof descriptor.swizzle === "string" && descriptor.swizzle.length === 4 ? descriptor.swizzle : null;
    v.setUint32(64, swizzle ? (TEXTURE_SWIZZLE_COMPONENT_MAP[swizzle[0]] ?? 0) : 0, true);
    v.setUint32(68, swizzle ? (TEXTURE_SWIZZLE_COMPONENT_MAP[swizzle[1]] ?? 0) : 0, true);
    v.setUint32(72, swizzle ? (TEXTURE_SWIZZLE_COMPONENT_MAP[swizzle[2]] ?? 0) : 0, true);
    v.setUint32(76, swizzle ? (TEXTURE_SWIZZLE_COMPONENT_MAP[swizzle[3]] ?? 0) : 0, true);
    return { desc: new Uint8Array(buf), _refs: refs };
}

function buildConstantEntries(constants) {
    if (!constants || typeof constants !== "object") {
        return { count: 0, entries: null, refs: [] };
    }
    const keys = Object.keys(constants);
    if (keys.length === 0) {
        return { count: 0, entries: null, refs: [] };
    }
    const entries = new Uint8Array(keys.length * WGPU_CONSTANT_ENTRY_SIZE);
    const view = new DataView(entries.buffer);
    const refs = [entries];
    for (let index = 0; index < keys.length; index += 1) {
        const key = keys[index];
        const keyBytes = encoder.encode(String(key));
        refs.push(keyBytes);
        const offset = index * WGPU_CONSTANT_ENTRY_SIZE;
        writePtr(view, offset + 0, null);
        writeStringView(view, offset + 8, keyBytes);
        view.setFloat64(offset + 24, Number(constants[key]), true);
    }
    return { count: keys.length, entries, refs };
}

// WGPUSamplerDescriptor: { nextInChain:ptr@0, label:sv@8, addressModeU:u32@24, V:u32@28, W:u32@32,
//   magFilter:u32@36, minFilter:u32@40, mipmapFilter:u32@44, lodMinClamp:f32@48, lodMaxClamp:f32@52,
//   compare:u32@56, maxAnisotropy:u16@60 } = 64 (with padding)
const SAMPLER_DESC_SIZE = 64;
const REQUEST_ADAPTER_OPTIONS_SIZE = 32;
const PASS_TIMESTAMP_WRITES_SIZE = 24;
const FEATURE_NAME_MAP = new Map(KNOWN_FEATURES);
const LIMIT_U32_FIELDS = Object.freeze([
    ["maxTextureDimension1D", 8],
    ["maxTextureDimension2D", 12],
    ["maxTextureDimension3D", 16],
    ["maxTextureArrayLayers", 20],
    ["maxBindGroups", 24],
    ["maxBindGroupsPlusVertexBuffers", 28],
    ["maxBindingsPerBindGroup", 32],
    ["maxDynamicUniformBuffersPerPipelineLayout", 36],
    ["maxDynamicStorageBuffersPerPipelineLayout", 40],
    ["maxSampledTexturesPerShaderStage", 44],
    ["maxSamplersPerShaderStage", 48],
    ["maxStorageBuffersPerShaderStage", 52],
    ["maxStorageTexturesPerShaderStage", 56],
    ["maxUniformBuffersPerShaderStage", 60],
    ["minUniformBufferOffsetAlignment", 80],
    ["minStorageBufferOffsetAlignment", 84],
    ["maxVertexBuffers", 88],
    ["maxVertexAttributes", 100],
    ["maxVertexBufferArrayStride", 104],
    ["maxInterStageShaderVariables", 108],
    ["maxColorAttachments", 112],
    ["maxColorAttachmentBytesPerSample", 116],
    ["maxComputeWorkgroupStorageSize", 120],
    ["maxComputeInvocationsPerWorkgroup", 124],
    ["maxComputeWorkgroupSizeX", 128],
    ["maxComputeWorkgroupSizeY", 132],
    ["maxComputeWorkgroupSizeZ", 136],
    ["maxComputeWorkgroupsPerDimension", 140],
    ["maxImmediateSize", 144],
]);
const LIMIT_U64_FIELDS = Object.freeze([
    ["maxUniformBufferBindingSize", 64],
    ["maxStorageBufferBindingSize", 72],
    ["maxBufferSize", 92],
]);

function buildSamplerDescriptor(descriptor) {
    const buf = new ArrayBuffer(SAMPLER_DESC_SIZE);
    const v = new DataView(buf);
    const refs = [];
    writePtr(v, 0, null);
    const labelBytes = descriptor.label ? encoder.encode(descriptor.label) : null;
    if (labelBytes) refs.push(labelBytes);
    writeStringView(v, 8, labelBytes);
    v.setUint32(24, ADDRESS_MODE_MAP[descriptor.addressModeU ?? "clamp-to-edge"] ?? ADDRESS_MODE_MAP["clamp-to-edge"], true);
    v.setUint32(28, ADDRESS_MODE_MAP[descriptor.addressModeV ?? "clamp-to-edge"] ?? ADDRESS_MODE_MAP["clamp-to-edge"], true);
    v.setUint32(32, ADDRESS_MODE_MAP[descriptor.addressModeW ?? "clamp-to-edge"] ?? ADDRESS_MODE_MAP["clamp-to-edge"], true);
    v.setUint32(36, FILTER_MODE_MAP[descriptor.magFilter ?? "nearest"] ?? FILTER_MODE_MAP.nearest, true);
    v.setUint32(40, FILTER_MODE_MAP[descriptor.minFilter ?? "nearest"] ?? FILTER_MODE_MAP.nearest, true);
    v.setUint32(44, FILTER_MODE_MAP[descriptor.mipmapFilter ?? "nearest"] ?? FILTER_MODE_MAP.nearest, true);
    v.setFloat32(48, descriptor.lodMinClamp ?? 0.0, true);
    v.setFloat32(52, descriptor.lodMaxClamp ?? 32.0, true);
    v.setUint32(56, descriptor.compare ? (COMPARE_FUNC_MAP[descriptor.compare] ?? 0) : 0, true);
    v.setUint16(60, descriptor.maxAnisotropy ?? 1, true);
    return { desc: new Uint8Array(buf), _refs: refs };
}

function buildRequestAdapterOptions(options) {
    if (!options) return null;
    const buf = new ArrayBuffer(REQUEST_ADAPTER_OPTIONS_SIZE);
    const v = new DataView(buf);
    writePtr(v, 0, null);
    v.setUint32(8, options.featureLevel ? (FEATURE_LEVEL_MAP[options.featureLevel] ?? 0) : 0, true);
    v.setUint32(12, options.powerPreference ? (POWER_PREFERENCE_MAP[options.powerPreference] ?? 0) : 0, true);
    v.setUint32(16, options.forceFallbackAdapter ? 1 : 0, true);
    v.setUint32(20, 0, true); // backendType = undefined
    writePtr(v, 24, null); // compatibleSurface
    return new Uint8Array(buf);
}

function buildRequiredLimits(requiredLimits) {
    if (!requiredLimits || typeof requiredLimits !== "object") {
        return null;
    }
    const buf = new ArrayBuffer(WGPU_LIMITS_SIZE);
    const view = new DataView(buf);
    writePtr(view, 0, null);
    for (const [name, offset] of LIMIT_U32_FIELDS) {
        const value = requiredLimits[name];
        if (value !== undefined) {
            view.setUint32(offset, Number(value), true);
        }
    }
    for (const [name, offset] of LIMIT_U64_FIELDS) {
        const value = requiredLimits[name];
        if (value !== undefined) {
            view.setBigUint64(offset, BigInt(value), true);
        }
    }
    return new Uint8Array(buf);
}

function buildDeviceDescriptor(descriptor) {
    if (!descriptor) {
        return { desc: null, _refs: [] };
    }
    const refs = [];
    const labelBytes = descriptor.label ? encoder.encode(descriptor.label) : null;
    if (labelBytes) refs.push(labelBytes);

    const requiredFeatures = Array.isArray(descriptor.requiredFeatures)
        ? descriptor.requiredFeatures
        : descriptor.requiredFeatures ? Array.from(descriptor.requiredFeatures) : [];
    let featureBytes = null;
    if (requiredFeatures.length > 0) {
        const featureBuf = new ArrayBuffer(requiredFeatures.length * 4);
        const featureView = new DataView(featureBuf);
        for (let index = 0; index < requiredFeatures.length; index += 1) {
            const featureName = requiredFeatures[index];
            const featureCode = FEATURE_NAME_MAP.get(featureName);
            if (featureCode === undefined) {
                throw new Error(`[doe-gpu] requestDevice requiredFeatures contains an unknown feature: ${featureName}`);
            }
            featureView.setUint32(index * 4, featureCode, true);
        }
        featureBytes = new Uint8Array(featureBuf);
        refs.push(featureBytes);
    }

    const limitsBytes = buildRequiredLimits(descriptor.requiredLimits);
    if (limitsBytes) refs.push(limitsBytes);

    const queueLabelBytes = descriptor.defaultQueue?.label ? encoder.encode(descriptor.defaultQueue.label) : null;
    if (queueLabelBytes) refs.push(queueLabelBytes);

    const descBuf = new ArrayBuffer(WGPU_DEVICE_DESCRIPTOR_SIZE);
    const descView = new DataView(descBuf);
    writePtr(descView, 0, null);
    writeStringView(descView, 8, labelBytes);
    descView.setBigUint64(24, BigInt(requiredFeatures.length), true);
    writePtr(descView, 32, featureBytes ? bunPtr(featureBytes) : null);
    writePtr(descView, 40, limitsBytes ? bunPtr(limitsBytes) : null);
    writePtr(descView, WGPU_DEVICE_DEFAULT_QUEUE_LABEL_OFFSET - 8, null);
    writeStringView(descView, WGPU_DEVICE_DEFAULT_QUEUE_LABEL_OFFSET, queueLabelBytes);

    const desc = new Uint8Array(descBuf);
    refs.push(desc);
    return { desc, _refs: refs };
}

function buildPassTimestampWrites(timestampWrites) {
    const buf = new ArrayBuffer(PASS_TIMESTAMP_WRITES_SIZE);
    const v = new DataView(buf);
    writePtr(v, 0, null);
    writePtr(v, 8, timestampWrites.querySet?._native ?? null);
    v.setUint32(16, timestampWrites.beginningOfPassWriteIndex ?? 0xFFFFFFFF, true);
    v.setUint32(20, timestampWrites.endOfPassWriteIndex ?? 0xFFFFFFFF, true);
    return new Uint8Array(buf);
}

// WGPURenderPassColorAttachment:
// { nextInChain:ptr@0, view:ptr@8, depthSlice:u32@16, pad@20, resolveTarget:ptr@24,
//   loadOp:u32@32, storeOp:u32@36, clearValue:{r:f64@40, g:f64@48, b:f64@56, a:f64@64} } = 72
const RENDER_PASS_COLOR_ATTACHMENT_SIZE = 72;
const TEXEL_COPY_TEXTURE_INFO_SIZE = 32;
const TEXEL_COPY_BUFFER_INFO_SIZE = 24;
const EXTENT3D_SIZE = 12;

const DEFAULT_MAX_DRAW_COUNT = 50_000_000;

// WGPURenderPassDescriptor:
// { nextInChain:ptr@0, label:sv@8, colorAttachmentCount:size_t@24, colorAttachments:ptr@32,
//   depthStencilAttachment:ptr@40, occlusionQuerySet:ptr@48, timestampWrites:ptr@56,
//   maxDrawCount:u64@64 } = 72
function buildRenderPassDescriptor(descriptor) {
    const colorAttachments = descriptor.colorAttachments || [];
    const attBuf = new Uint8Array(colorAttachments.length * RENDER_PASS_COLOR_ATTACHMENT_SIZE);
    const attView = new DataView(attBuf.buffer);

    for (let i = 0; i < colorAttachments.length; i++) {
        const a = colorAttachments[i];
        const off = i * RENDER_PASS_COLOR_ATTACHMENT_SIZE;
        writePtr(attView, off + 0, null);
        writePtr(attView, off + 8, a.view._native);
        attView.setUint32(off + 16, 0xFFFFFFFF, true); // depthSlice = WGPU_DEPTH_SLICE_UNDEFINED
        writePtr(attView, off + 24, null); // resolveTarget
        attView.setUint32(off + 32, 1, true); // loadOp = clear (1)
        attView.setUint32(off + 36, 1, true); // storeOp = store (1)
        const cv = a.clearValue || { r: 0, g: 0, b: 0, a: 1 };
        attView.setFloat64(off + 40, cv.r ?? 0, true);
        attView.setFloat64(off + 48, cv.g ?? 0, true);
        attView.setFloat64(off + 56, cv.b ?? 0, true);
        attView.setFloat64(off + 64, cv.a ?? 1, true);
    }

    let depthStencilAttachmentArr = null;
    let timestampWritesArr = null;
    if (descriptor.depthStencilAttachment?.view) {
        const depthBuf = new ArrayBuffer(WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_SIZE);
        const depthView = new DataView(depthBuf);
        writePtr(depthView, 0, descriptor.depthStencilAttachment.view._native);
        depthView.setUint32(8, 1, true); // clear
        depthView.setUint32(12, 1, true); // store
        depthView.setFloat32(16, descriptor.depthStencilAttachment.depthClearValue ?? 1.0, true);
        depthView.setUint32(20, descriptor.depthStencilAttachment.depthReadOnly ? 1 : 0, true);
        depthView.setUint32(24, 1, true); // clear
        depthView.setUint32(28, 1, true); // store
        depthView.setUint32(32, descriptor.depthStencilAttachment.stencilClearValue ?? 0, true);
        depthView.setUint32(36, descriptor.depthStencilAttachment.stencilReadOnly ? 1 : 0, true);
        depthStencilAttachmentArr = new Uint8Array(depthBuf);
    }
    if (descriptor.timestampWrites?.querySet) {
        timestampWritesArr = buildPassTimestampWrites(descriptor.timestampWrites);
    }

    const descBuf = new ArrayBuffer(WGPU_RENDER_PASS_DESCRIPTOR_SIZE);
    const descView = new DataView(descBuf);
    writePtr(descView, 0, null);
    writeStringView(descView, 8, null);
    descView.setBigUint64(24, BigInt(colorAttachments.length), true);
    writePtr(descView, 32, colorAttachments.length > 0 ? bunPtr(attBuf) : null);
    writePtr(descView, 40, depthStencilAttachmentArr ? bunPtr(depthStencilAttachmentArr) : null);
    writePtr(descView, 48, descriptor.occlusionQuerySet?._native ?? null);
    writePtr(descView, 56, timestampWritesArr ? bunPtr(timestampWritesArr) : null);
    descView.setBigUint64(64, BigInt(descriptor.maxDrawCount ?? DEFAULT_MAX_DRAW_COUNT), true);

    return { desc: new Uint8Array(descBuf), _refs: [attBuf, depthStencilAttachmentArr, timestampWritesArr].filter(Boolean) };
}

function buildTexelCopyTextureInfo(source) {
    const buf = new ArrayBuffer(TEXEL_COPY_TEXTURE_INFO_SIZE);
    const view = new DataView(buf);
    writePtr(view, 0, source.texture);
    view.setUint32(8, source.mipLevel ?? 0, true);
    view.setUint32(12, source.origin?.x ?? 0, true);
    view.setUint32(16, source.origin?.y ?? 0, true);
    view.setUint32(20, source.origin?.z ?? 0, true);
    view.setUint32(24, source.aspect ?? 1, true);
    return { desc: new Uint8Array(buf), srcRefs: null };
}

function buildTexelCopyBufferInfo(destination) {
    const buf = new ArrayBuffer(TEXEL_COPY_BUFFER_INFO_SIZE);
    const view = new DataView(buf);
    view.setBigUint64(0, BigInt(destination.offset ?? 0), true);
    view.setUint32(8, destination.bytesPerRow ?? 0, true);
    view.setUint32(12, destination.rowsPerImage ?? 0, true);
    writePtr(view, 16, destination.buffer);
    return { desc: new Uint8Array(buf), dstRefs: null };
}

function buildExtent3D(size) {
    const buf = new ArrayBuffer(EXTENT3D_SIZE);
    const view = new DataView(buf);
    view.setUint32(0, size.width, true);
    view.setUint32(4, size.height, true);
    view.setUint32(8, size.depthOrArrayLayers ?? 1, true);
    return new Uint8Array(buf);
}

// WGPUColor: { double r@0, double g@8, double b@16, double a@24 } = 32
const WGPU_COLOR_SIZE = 32;

function buildColorStruct(r, g, b, a) {
    const buf = new ArrayBuffer(WGPU_COLOR_SIZE);
    const v = new DataView(buf);
    v.setFloat64(0, r, true);
    v.setFloat64(8, g, true);
    v.setFloat64(16, b, true);
    v.setFloat64(24, a, true);
    return new Uint8Array(buf);
}

// WGPUTexelCopyBufferLayout (standalone, for wgpuQueueWriteTexture):
// { uint64_t offset@0, uint32_t bytesPerRow@8, uint32_t rowsPerImage@12 } = 16
const WGPU_TEXEL_COPY_BUFFER_LAYOUT_SIZE = 16;

function buildTexelCopyBufferLayout(layout) {
    const buf = new ArrayBuffer(WGPU_TEXEL_COPY_BUFFER_LAYOUT_SIZE);
    const v = new DataView(buf);
    v.setBigUint64(0, BigInt(layout.offset ?? 0), true);
    v.setUint32(8, layout.bytesPerRow ?? 0, true);
    v.setUint32(12, layout.rowsPerImage ?? 0, true);
    return new Uint8Array(buf);
}

// WGPURenderBundleEncoderDescriptor:
// { ptr nextInChain@0, sv label@8(16), size_t colorFormatCount@24, ptr colorFormats@32,
//   u32 depthStencilFormat@40, u32 sampleCount@44, u32 depthReadOnly@48, u32 stencilReadOnly@52 } = 56
const WGPU_RENDER_BUNDLE_ENCODER_DESCRIPTOR_SIZE = 56;

function buildRenderBundleEncoderDescriptor(descriptor) {
    const colorFormats = descriptor.colorFormats ?? [];
    const formatArr = new Uint32Array(colorFormats.length);
    for (let i = 0; i < colorFormats.length; i++) {
        formatArr[i] = TEXTURE_FORMAT_MAP[colorFormats[i]] ?? 0;
    }
    const buf = new ArrayBuffer(WGPU_RENDER_BUNDLE_ENCODER_DESCRIPTOR_SIZE);
    const v = new DataView(buf);
    writePtr(v, 0, null); // nextInChain
    writeStringView(v, 8, null); // label
    v.setBigUint64(24, BigInt(colorFormats.length), true); // colorFormatCount
    writePtr(v, 32, colorFormats.length > 0 ? bunPtr(formatArr) : null); // colorFormats
    v.setUint32(40, TEXTURE_FORMAT_MAP[descriptor.depthStencilFormat] ?? 0, true); // depthStencilFormat
    v.setUint32(44, descriptor.sampleCount ?? 1, true); // sampleCount
    v.setUint32(48, descriptor.depthReadOnly ? 1 : 0, true); // depthReadOnly
    v.setUint32(52, descriptor.stencilReadOnly ? 1 : 0, true); // stencilReadOnly
    return { desc: new Uint8Array(buf), _refs: [formatArr] };
}

// WGPUStringView for debug group/marker labels (data ptr + length).
// The render pass debug group wgpu API expects WGPUStringView as two separate
// args (ptr, size_t) decomposed at the call site, matching the FFI declaration.
function encodeStringView(label) {
    if (!label) return { bytes: null, len: 0 };
    const bytes = encoder.encode(label);
    return { bytes, len: bytes.length };
}

// ---------------------------------------------------------------------------
// Callback trampolines for async-to-sync bridging
//
// Uses CALLBACK_MODE_ALLOW_PROCESS_EVENTS + wgpuInstanceProcessEvents polling,
// matching the N-API addon strategy. wgpuInstanceWaitAny with timed waits is
// not supported on all backends (e.g. Vulkan/Dawn).
// ---------------------------------------------------------------------------

function processEventsUntilDone(instancePtr, isDone, timeoutNs = processEventsTimeoutNs) {
    const start = Number(process.hrtime.bigint());
    while (!isDone()) {
        wgpu.symbols.wgpuInstanceProcessEvents(instancePtr);
        if (Number(process.hrtime.bigint()) - start >= timeoutNs) {
            throw new Error("[doe-gpu] processEvents timeout");
        }
    }
}

function shaderModuleBindings(shaderModule) {
    const fn = wgpu?.symbols?.doeNativeShaderModuleGetBindings;
    if (typeof fn !== "function" || !shaderModule?._native) return null;
    const count = Number(fn(shaderModule._native, null, 0n));
    if (count <= 0) return [];
    const raw = new ArrayBuffer(count * 20);
    fn(shaderModule._native, new Uint8Array(raw), BigInt(count));
    const view = new DataView(raw);
    const bindings = [];
    for (let index = 0; index < count; index += 1) {
        const offset = index * 20;
        const group = view.getUint32(offset + 0, true);
        const binding = view.getUint32(offset + 4, true);
        const kind = view.getUint32(offset + 8, true);
        const addrSpace = view.getUint32(offset + 12, true);
        const access = view.getUint32(offset + 16, true);
        bindings.push({
            group,
            binding,
            type: ["buffer", "sampler", "texture", "storage_texture"][kind] ?? "unknown",
            space: ["function", "private", "workgroup", "uniform", "storage", "handle"][addrSpace] ?? "unknown",
            access: ["read", "write", "read_write"][access] ?? "unknown",
        });
    }
    return bindings;
}

function requireAutoLayoutEntriesFromNative(shaderModule, visibility, path) {
    const bindings = shaderModuleBindings(shaderModule);
    if (!Array.isArray(bindings)) {
        throw new Error(`${path}: layout: "auto" requires native shader binding metadata on this package surface`);
    }
    return autoLayoutEntriesFromNativeBindings(bindings, visibility);
}

function nativeFailureMessage(prefix) {
    const detail = copyLastErrorMessage();
    return detail ? `${prefix}: ${detail}` : prefix;
}

function decodeStringView(dataPtr, length) {
    if (!dataPtr || !length) return "";
    return decoder.decode(new Uint8Array(toArrayBuffer(dataPtr, 0, Number(length))));
}

function decodeCString(dataPtr, maxBytes = 4096) {
    if (!dataPtr) return "";
    const bytes = new Uint8Array(toArrayBuffer(dataPtr, 0, maxBytes));
    let len = 0;
    while (len < bytes.length && bytes[len] !== 0) {
        len += 1;
    }
    return decoder.decode(bytes.subarray(0, len));
}

function mapBufferMapState(state) {
    switch (Number(state)) {
        case BUFFER_MAP_STATE.pending:
            return "pending";
        case BUFFER_MAP_STATE.mapped:
            return "mapped";
        default:
            return "unmapped";
    }
}

function mapDeviceLostReason(reason) {
    switch (Number(reason)) {
        case DEVICE_LOST_REASON.destroyed:
            return "destroyed";
        case DEVICE_LOST_REASON.callbackCancelled:
            return "callback-cancelled";
        case DEVICE_LOST_REASON.failedCreation:
            return "failed-creation";
        default:
            return "unknown";
    }
}

function mapErrorType(errorType) {
    switch (Number(errorType)) {
        case ERROR_TYPE.noError:
            return "no-error";
        case ERROR_TYPE.validation:
            return "validation";
        case ERROR_TYPE.outOfMemory:
            return "out-of-memory";
        case ERROR_TYPE.internal:
            return "internal";
        default:
            return "unknown";
    }
}

function createGpuError(result) {
    if (!result || result.type === "no-error") {
        return null;
    }
    const message = result.message ?? "";
    let error;
    if (result.type === "validation") {
        error = new GPUValidationError(message);
    } else if (result.type === "out-of-memory") {
        error = new GPUOutOfMemoryError(message);
    } else if (result.type === "internal") {
        error = new GPUInternalError(message);
    } else {
        error = new Error(message);
        error.name = "GPUError";
    }
    error.type = result.type ?? "unknown";
    return error;
}

function unsupportedBunDeviceCapability(name) {
    return new Error(`${name} is not available in this Bun package build`);
}

function dispatchBunDeviceEvent(device, event) {
    if (!event || typeof event !== "object") {
        return;
    }
    if (typeof event.type === "string") {
        dispatchDeviceEvent(device, event.type, event);
    }
    if (event.type === "uncapturederror" && typeof device._onuncapturederror === "function") {
        device._onuncapturederror.call(device, event);
    }
}

function readAdapterInfo(native) {
    const getInfo = wgpu?.symbols?.doeNativeAdapterGetInfo;
    const freeInfo = wgpu?.symbols?.doeNativeAdapterFreeInfo;
    if (typeof getInfo !== "function" || typeof freeInfo !== "function" || !native) {
        return EMPTY_ADAPTER_INFO;
    }
    const vendorOut = new BigUint64Array(1);
    const archOut = new BigUint64Array(1);
    const deviceOut = new BigUint64Array(1);
    const descOut = new BigUint64Array(1);
    const blockOut = new BigUint64Array(1);
    getInfo(native, vendorOut, archOut, deviceOut, descOut, blockOut);
    const block = Number(blockOut[0] ?? 0n);
    try {
        return Object.freeze({
            vendor: decodeCString(Number(vendorOut[0] ?? 0n)),
            architecture: decodeCString(Number(archOut[0] ?? 0n)),
            device: decodeCString(Number(deviceOut[0] ?? 0n)),
            description: decodeCString(Number(descOut[0] ?? 0n)),
            subgroupMinSize: process.platform === "darwin"
                ? METAL_WEBGPU_SUBGROUP_MIN_SIZE
                : 32,
            subgroupMaxSize: process.platform === "darwin"
                ? METAL_WEBGPU_SUBGROUP_MAX_SIZE
                : 32,
        });
    } finally {
        if (block !== 0) {
            freeInfo(block);
        }
    }
}

function ensureBunDeviceLostRegistration(device, native) {
    if (device._lostRegistrationAttempted) {
        return device._lostSupported;
    }
    device._lostRegistrationAttempted = true;
    const registerLost = wgpu?.symbols?.doeNativeDeviceRegisterLostCallback;
    if (typeof registerLost !== "function") {
        device._lostSupported = false;
        return false;
    }
    const callback = new JSCallback(
        (reason, msgPtr, msgLen) => {
            resolveDeviceLost(device, mapDeviceLostReason(reason), decodeStringView(msgPtr, msgLen));
            callback.close();
            if (device._lostCallback === callback) {
                device._lostCallback = null;
            }
        },
        { args: [FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr], returns: FFIType.void },
    );
    try {
        registerLost(native, callback.ptr, null);
    } catch (error) {
        callback.close();
        if (!String(error?.message ?? "").includes("not available")) {
            throw error;
        }
        device._lostSupported = false;
        return false;
    }
    device._lostCallback = callback;
    device._lostSupported = true;
    return true;
}

function setBunDeviceUncapturedErrorHandler(device, native, handler) {
    const setCallback = wgpu?.symbols?.doeNativeDeviceSetUncapturedErrorCallback;
    if (device._uncapturedErrorCallback) {
        device._uncapturedErrorCallback.close();
        device._uncapturedErrorCallback = null;
    }
    if (typeof setCallback !== "function") {
        if (handler) {
            throw unsupportedBunDeviceCapability("GPUDevice.onuncapturederror");
        }
        return;
    }
    setCallback(native, null, null, null);
    if (!handler) {
        return;
    }
    const callback = new JSCallback(
        (errorType, msgPtr, msgLen) => {
            const type = mapErrorType(errorType);
            const message = decodeStringView(msgPtr, msgLen);
            const event = {
                type: "uncapturederror",
                error: createGpuError({ type, message }),
                message,
                errorType: type,
            };
            dispatchBunDeviceEvent(device, event);
        },
        { args: [FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    );
    try {
        setCallback(native, callback.ptr, null, null);
    } catch (error) {
        callback.close();
        if (String(error?.message ?? "").includes("not available")) {
            throw unsupportedBunDeviceCapability("GPUDevice.onuncapturederror");
        }
        throw error;
    }
    device._uncapturedErrorCallback = callback;
}

function popDeviceErrorScope(native) {
    const popErrorScope = wgpu?.symbols?.doeNativeDevicePopErrorScopeFlat;
    if (typeof popErrorScope !== "function") {
        throw unsupportedBunDeviceCapability("GPUDevice.popErrorScope");
    }
    let done = false;
    let result = null;
    const callback = new JSCallback(
        (errorType, msgPtr, msgLen) => {
            done = true;
            const type = mapErrorType(errorType);
            if (type === "no-error") {
                result = null;
                return;
            }
            result = createGpuError({
                type,
                message: decodeStringView(msgPtr, msgLen),
            });
        },
        { args: [FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    );
    try {
        popErrorScope(native, callback.ptr, null, null);
        if (!done) {
            throw new Error("[doe-gpu] popErrorScope: no active error scope");
        }
        return result;
    } finally {
        callback.close();
    }
}

function requestAdapterSync(instancePtr, options) {
    let resolvedAdapter = null;
    let resolvedStatus = null;
    let done = false;
    const optionsBytes = buildRequestAdapterOptions(options);
    const cb = new JSCallback(
        (status, adapter, _msgData, _msgLen, _ud1, _ud2) => {
            resolvedStatus = status;
            resolvedAdapter = adapter;
            done = true;
        },
        { args: [FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    );
    try {
        const futureId = wgpu.symbols.doeRequestAdapterFlat(
            instancePtr, optionsBytes ? bunPtr(optionsBytes) : null, CALLBACK_MODE_ALLOW_PROCESS_EVENTS, cb.ptr, null, null);
        if (futureId === 0 || futureId === 0n) throw new Error("[doe-gpu] requestAdapter future unavailable");
        processEventsUntilDone(instancePtr, () => done);
        if (resolvedStatus !== REQUEST_ADAPTER_STATUS_SUCCESS || !resolvedAdapter) {
            throw new Error(nativeFailureMessage(`[doe-gpu] requestAdapter failed (status=${resolvedStatus})`));
        }
        return resolvedAdapter;
    } finally {
        cb.close();
    }
}

function requestDeviceSync(instancePtr, adapterPtr, descriptor) {
    let resolvedDevice = null;
    let resolvedStatus = null;
    let done = false;
    const descriptorBytes = buildDeviceDescriptor(descriptor);
    const cb = new JSCallback(
        (status, device, _msgData, _msgLen, _ud1, _ud2) => {
            resolvedStatus = status;
            resolvedDevice = device;
            done = true;
        },
        { args: [FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    );
    try {
        const futureId = wgpu.symbols.doeRequestDeviceFlat(
            adapterPtr,
            descriptorBytes.desc ? bunPtr(descriptorBytes.desc) : null,
            CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
            cb.ptr,
            null,
            null,
        );
        if (futureId === 0 || futureId === 0n) throw new Error("[doe-gpu] requestDevice future unavailable");
        processEventsUntilDone(instancePtr, () => done);
        if (resolvedStatus !== REQUEST_DEVICE_STATUS_SUCCESS || !resolvedDevice) {
            throw new Error(nativeFailureMessage(`[doe-gpu] requestDevice failed (status=${resolvedStatus})`));
        }
        return resolvedDevice;
    } finally {
        cb.close();
    }
}

function bufferMapSync(instancePtr, bufferPtr, mode, offset, size) {
    if (wgpu.symbols.doeBufferMapSyncFlat) {
        const status = wgpu.symbols.doeBufferMapSyncFlat(
            instancePtr, bufferPtr, BigInt(mode), BigInt(offset), BigInt(size));
        if (status !== MAP_ASYNC_STATUS_SUCCESS) {
            throw new Error(nativeFailureMessage(`[doe-gpu] bufferMapAsync failed (status=${status})`));
        }
        return;
    }
    let mapStatus = null;
    let done = false;
    const cb = new JSCallback(
        (status, _msgData, _msgLen, _ud1, _ud2) => { mapStatus = status; done = true; },
        { args: [FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    );
    try {
        const futureId = wgpu.symbols.doeBufferMapAsyncFlat(
            bufferPtr, BigInt(mode), BigInt(offset), BigInt(size),
            CALLBACK_MODE_ALLOW_PROCESS_EVENTS, cb.ptr, null, null);
        if (futureId === 0 || futureId === 0n) throw new Error("[doe-gpu] bufferMapAsync future unavailable");
        processEventsUntilDone(instancePtr, () => done);
        if (mapStatus !== MAP_ASYNC_STATUS_SUCCESS) {
            throw new Error(nativeFailureMessage(`[doe-gpu] bufferMapAsync failed (status=${mapStatus})`));
        }
    } finally {
        cb.close();
    }
}

function waitForSubmittedWorkDoneSync(instancePtr, queuePtr) {
    let queueStatus = null;
    let done = false;
    const cb = new JSCallback(
        (status, _msgData, _msgLen, _ud1, _ud2) => {
            queueStatus = status;
            done = true;
        },
        { args: [FFIType.u32, FFIType.ptr, FFIType.u64, FFIType.ptr, FFIType.ptr], returns: FFIType.void },
    );
    try {
        const futureId = wgpu.symbols.doeQueueOnSubmittedWorkDoneFlat(
            queuePtr,
            CALLBACK_MODE_ALLOW_PROCESS_EVENTS,
            cb.ptr,
            null,
            null,
        );
        if (futureId === 0 || futureId === 0n) {
            const error = new Error("[doe-gpu] queue work-done future unavailable");
            error.code = "DOE_QUEUE_UNAVAILABLE";
            throw error;
        }
        processEventsUntilDone(instancePtr, () => done, processEventsTimeoutNs);
        if (queueStatus !== REQUEST_DEVICE_STATUS_SUCCESS) {
            const error = new Error(nativeFailureMessage(`[doe-gpu] queue work-done failed (status=${queueStatus})`));
            if (queueStatus === 0) {
                error.code = "DOE_QUEUE_UNAVAILABLE";
            }
            throw error;
        }
    } finally {
        cb.close();
    }
}

// ---------------------------------------------------------------------------
// WebGPU wrapper classes — matches index.js surface exactly
// ---------------------------------------------------------------------------

function ensureBunCommandEncoderNative(encoder) {
    assertLiveResource(encoder._device, "GPUCommandEncoder", "GPUDevice");
    if (encoder._finished) {
        failValidation("GPUCommandEncoder", "command encoder is already finished");
    }
    if (encoder._native) return;
    encoder._native = wgpu.symbols.wgpuDeviceCreateCommandEncoder(
        assertLiveResource(encoder._device, "GPUCommandEncoder", "GPUDevice"), null);
    for (const cmd of encoder._commands) {
        if (cmd.t === 0) {
            const pass = wgpu.symbols.wgpuCommandEncoderBeginComputePass(encoder._native, null);
            wgpu.symbols.wgpuComputePassEncoderSetPipeline(pass, cmd.p);
            const bgCount = bunCommandBindGroupCount(cmd);
            for (let i = 0; i < bgCount; i += 1) {
                const bindGroup = bunCommandBindGroupAt(cmd, i);
                if (bindGroup) {
                    wgpu.symbols.wgpuComputePassEncoderSetBindGroup(pass, i, bindGroup, BigInt(0), null);
                }
            }
            wgpu.symbols.wgpuComputePassEncoderDispatchWorkgroups(pass, cmd.x, cmd.y, cmd.z);
            wgpu.symbols.wgpuComputePassEncoderEnd(pass);
            wgpu.symbols.wgpuComputePassEncoderRelease(pass);
        } else if (cmd.t === 1) {
            wgpu.symbols.wgpuCommandEncoderCopyBufferToBuffer(
                encoder._native, cmd.s, hotU64(cmd.so), cmd.d, hotU64(cmd.do), hotU64(cmd.sz));
        }
    }
    encoder._commands = [];
}

function assertBunNoActivePass(encoder, path) {
    const activePass = encoder._activePass;
    if (activePass == null) {
        return;
    }
    if (activePass._ended) {
        encoder._activePass = null;
        return;
    }
    failValidation(path, "command encoder has an active pass");
}

function materializeLazyBunComputePass(pass) {
    if (!pass._lazy) {
        return;
    }
    ensureBunCommandEncoderNative(pass._encoder);
    pass._lazy = false;
    pass._native = wgpu.symbols.wgpuCommandEncoderBeginComputePass(pass._encoder._native, null);
    if (pass._pipeline != null) {
        wgpu.symbols.wgpuComputePassEncoderSetPipeline(pass._native, pass._pipeline);
    }
    for (let index = 0; index < pass._bindGroups.length; index += 1) {
        if (pass._bindGroups[index]) {
            wgpu.symbols.wgpuComputePassEncoderSetBindGroup(pass._native, index, pass._bindGroups[index], BigInt(0), null);
        }
    }
}

function readIndirectDispatchCounts(bufferNative, offset) {
    const dataPtr = wgpu.symbols.wgpuBufferGetConstMappedRange(bufferNative, BigInt(offset), BigInt(12));
    if (!dataPtr) {
        throw new Error("[doe-gpu] indirect dispatch buffer is not CPU-readable");
    }
    const countsBytes = new Uint8Array(toArrayBuffer(dataPtr, 0, 12)).slice(0);
    const counts = new DataView(countsBytes.buffer, countsBytes.byteOffset, countsBytes.byteLength);
    return {
        x: counts.getUint32(0, true),
        y: counts.getUint32(4, true),
        z: counts.getUint32(8, true),
    };
}

const bunEncoderBackend = {
    computePassInit(pass, native) {
        pass._native = native;
        pass._lazy = native == null;
        pass._pipeline = null;
        pass._bindGroups = [];
        pass._immediates = [];
        initPendingComputeState(pass);
        pass._ended = false;
    },
    computePassAssertOpen(pass, path) {
        if (pass._ended) failValidation(path, "compute pass is already ended");
        if (pass._encoder._finished) failValidation(path, "command encoder is already finished");
    },
    computePassSetPipeline(pass, pipelineNative) {
        if (!updatePassPipelineState(pass, pipelineNative)) {
            return;
        }
        if (pass._lazy) {
            return;
        }
        markPassPipelineDirty(pass);
    },
    computePassSetBindGroup(pass, index, bindGroupNative) {
        if (!updatePassBindGroupState(pass, index, bindGroupNative)) {
            return;
        }
        if (pass._lazy) {
            return;
        }
        markPassBindGroupDirty(pass, index);
    },
    computePassSetImmediates(pass, index, data) {
        if (!updatePassImmediateState(pass, index, data)) {
            return;
        }
        materializeLazyBunComputePass(pass);
        wgpu.symbols.wgpuComputePassEncoderSetImmediates(
            assertLiveResource(pass, "GPUComputePassEncoder.setImmediates", "GPUComputePassEncoder"),
            index,
            data,
            BigInt(data.byteLength),
        );
    },
    computePassDispatchWorkgroups(pass, x, y, z) {
        if (pass._pipeline == null) {
            failValidation("GPUComputePassEncoder.dispatchWorkgroups", "setPipeline() must be called before dispatch");
        }
        if (pass._lazy) {
            pushBunLazyDispatchCommand(pass, pass._pipeline, x, y, z);
            return;
        }
        const nativePass = assertLiveResource(pass, "GPUComputePassEncoder.dispatchWorkgroups", "GPUComputePassEncoder");
        if (
            typeof wgpu.symbols.doeNativeComputePassDispatchBound === "function"
            && (pass._pipelineDirty || pass._bindGroupDirty[0] === true)
            && !hasPendingNonZeroBindGroups(pass)
        ) {
            wgpu.symbols.doeNativeComputePassDispatchBound(
                nativePass,
                pass._pipeline,
                pass._bindGroups[0] ?? null,
                x,
                y,
                z,
            );
            clearPendingBoundDispatchState(pass);
            return;
        }
        materializeBunPendingComputeState(pass, nativePass);
        wgpu.symbols.wgpuComputePassEncoderDispatchWorkgroups(nativePass, x, y, z);
    },
    computePassDispatchBound(pass, pipelineNative, bindGroupNative, x, y, z) {
        if (pass._lazy) {
            pass._pipeline = pipelineNative;
            pass._bindGroups[0] = bindGroupNative;
            pushBunLazyDispatchCommand(pass, pipelineNative, x, y, z);
            return;
        }
        pass._pipeline = pipelineNative;
        const nativePass = assertLiveResource(pass, "GPUComputePassEncoder._dispatchBound", "GPUComputePassEncoder");
        if (typeof wgpu.symbols.doeNativeComputePassDispatchBound === "function") {
            wgpu.symbols.doeNativeComputePassDispatchBound(
                nativePass,
                pipelineNative,
                bindGroupNative,
                x,
                y,
                z,
            );
            clearPendingBoundDispatchState(pass);
            return;
        }
        wgpu.symbols.wgpuComputePassEncoderSetPipeline(nativePass, pipelineNative);
        wgpu.symbols.wgpuComputePassEncoderSetBindGroup(nativePass, 0, bindGroupNative, BigInt(0), null);
        wgpu.symbols.wgpuComputePassEncoderDispatchWorkgroups(nativePass, x, y, z);
        clearPendingBoundDispatchState(pass);
    },
    computePassDispatchWorkgroupsIndirect(pass, indirectBufferNative, indirectOffset) {
        if (pass._pipeline == null) {
            failValidation("GPUComputePassEncoder.dispatchWorkgroupsIndirect", "setPipeline() must be called before dispatch");
        }
        materializeLazyBunComputePass(pass);
        const nativePass = assertLiveResource(pass, "GPUComputePassEncoder.dispatchWorkgroupsIndirect", "GPUComputePassEncoder");
        materializeBunPendingComputeState(pass, nativePass);
        wgpu.symbols.wgpuComputePassEncoderDispatchWorkgroupsIndirect(
            nativePass,
            indirectBufferNative,
            BigInt(indirectOffset),
        );
    },
    computePassEnd(pass) {
        if (pass._lazy) {
            pass._ended = true;
            if (pass._encoder._activePass === pass) {
                pass._encoder._activePass = null;
            }
            return;
        }
        wgpu.symbols.wgpuComputePassEncoderEnd(
            assertLiveResource(pass, "GPUComputePassEncoder.end", "GPUComputePassEncoder"),
        );
        wgpu.symbols.wgpuComputePassEncoderRelease(pass._native);
        pass._native = null;
        pass._ended = true;
        if (pass._encoder._activePass === pass) {
            pass._encoder._activePass = null;
        }
    },
    renderPassInit(pass, native) {
        pass._native = native;
        pass._pipeline = null;
        pass._bindGroups = [];
        pass._immediates = [];
        pass._vertexBuffers = [];
        pass._indexBuffer = null;
        pass._ended = false;
    },
    renderPassAssertOpen(pass, path) {
        if (pass._ended) failValidation(path, "render pass is already ended");
        if (pass._encoder._finished) failValidation(path, "command encoder is already finished");
    },
    renderPassSetPipeline(pass, pipelineNative) {
        if (!updatePassPipelineState(pass, pipelineNative)) {
            return;
        }
        wgpu.symbols.wgpuRenderPassEncoderSetPipeline(
            assertLiveResource(pass, "GPURenderPassEncoder.setPipeline", "GPURenderPassEncoder"),
            pipelineNative,
        );
    },
    renderPassSetBindGroup(pass, index, bindGroupNative) {
        if (!updatePassBindGroupState(pass, index, bindGroupNative)) {
            return;
        }
        wgpu.symbols.wgpuRenderPassEncoderSetBindGroup(
            assertLiveResource(pass, "GPURenderPassEncoder.setBindGroup", "GPURenderPassEncoder"),
            index,
            bindGroupNative,
            BigInt(0),
            null,
        );
    },
    renderPassSetVertexBuffer(pass, slot, bufferNative, offset, size) {
        if (!updatePassVertexBufferState(pass, slot, bufferNative, offset, size)) {
            return;
        }
        wgpu.symbols.wgpuRenderPassEncoderSetVertexBuffer(
            assertLiveResource(pass, "GPURenderPassEncoder.setVertexBuffer", "GPURenderPassEncoder"),
            slot,
            bufferNative,
            BigInt(offset),
            BigInt(size ?? 0),
        );
    },
    renderPassSetIndexBuffer(pass, bufferNative, format, offset, size) {
        if (!updatePassIndexBufferState(pass, bufferNative, format, offset, size)) {
            return;
        }
        wgpu.symbols.wgpuRenderPassEncoderSetIndexBuffer(
            assertLiveResource(pass, "GPURenderPassEncoder.setIndexBuffer", "GPURenderPassEncoder"),
            bufferNative,
            INDEX_FORMAT_MAP[format] ?? INDEX_FORMAT_MAP.uint16,
            BigInt(offset),
            BigInt(size ?? 0),
        );
    },
    renderPassDraw(pass, vertexCount, instanceCount, firstVertex, firstInstance) {
        wgpu.symbols.wgpuRenderPassEncoderDraw(pass._native, vertexCount, instanceCount, firstVertex, firstInstance);
    },
    renderPassDrawIndexed(pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
        wgpu.symbols.wgpuRenderPassEncoderDrawIndexed(
            assertLiveResource(pass, "GPURenderPassEncoder.drawIndexed", "GPURenderPassEncoder"),
            indexCount,
            instanceCount,
            firstIndex,
            baseVertex,
            firstInstance,
        );
    },
    renderPassSetViewport(pass, x, y, width, height, minDepth, maxDepth) {
        wgpu.symbols.wgpuRenderPassEncoderSetViewport(
            assertLiveResource(pass, "GPURenderPassEncoder.setViewport", "GPURenderPassEncoder"),
            x, y, width, height, minDepth, maxDepth,
        );
    },
    renderPassSetScissorRect(pass, x, y, width, height) {
        wgpu.symbols.wgpuRenderPassEncoderSetScissorRect(
            assertLiveResource(pass, "GPURenderPassEncoder.setScissorRect", "GPURenderPassEncoder"),
            x, y, width, height,
        );
    },
    renderPassSetBlendConstant(pass, r, g, b, a) {
        const colorBytes = buildColorStruct(r, g, b, a);
        wgpu.symbols.wgpuRenderPassEncoderSetBlendConstant(
            assertLiveResource(pass, "GPURenderPassEncoder.setBlendConstant", "GPURenderPassEncoder"),
            colorBytes,
        );
    },
    renderPassSetImmediates(pass, index, data) {
        if (!updatePassImmediateState(pass, index, data)) {
            return;
        }
        wgpu.symbols.wgpuRenderPassEncoderSetImmediates(
            assertLiveResource(pass, "GPURenderPassEncoder.setImmediates", "GPURenderPassEncoder"),
            index,
            data,
            BigInt(data.byteLength),
        );
    },
    renderPassSetStencilReference(pass, ref) {
        wgpu.symbols.wgpuRenderPassEncoderSetStencilReference(
            assertLiveResource(pass, "GPURenderPassEncoder.setStencilReference", "GPURenderPassEncoder"),
            ref,
        );
    },
    renderPassPushDebugGroup(pass, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuRenderPassEncoderPushDebugGroup(
            assertLiveResource(pass, "GPURenderPassEncoder.pushDebugGroup", "GPURenderPassEncoder"),
            bytes,
            BigInt(len),
        );
    },
    renderPassPopDebugGroup(pass) {
        wgpu.symbols.wgpuRenderPassEncoderPopDebugGroup(
            assertLiveResource(pass, "GPURenderPassEncoder.popDebugGroup", "GPURenderPassEncoder"),
        );
    },
    renderPassInsertDebugMarker(pass, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuRenderPassEncoderInsertDebugMarker(
            assertLiveResource(pass, "GPURenderPassEncoder.insertDebugMarker", "GPURenderPassEncoder"),
            bytes,
            BigInt(len),
        );
    },
    computePassPushDebugGroup(pass, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuComputePassEncoderPushDebugGroup(
            assertLiveResource(pass, "GPUComputePassEncoder.pushDebugGroup", "GPUComputePassEncoder"),
            bytes,
            BigInt(len),
        );
    },
    computePassPopDebugGroup(pass) {
        wgpu.symbols.wgpuComputePassEncoderPopDebugGroup(
            assertLiveResource(pass, "GPUComputePassEncoder.popDebugGroup", "GPUComputePassEncoder"),
        );
    },
    computePassInsertDebugMarker(pass, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuComputePassEncoderInsertDebugMarker(
            assertLiveResource(pass, "GPUComputePassEncoder.insertDebugMarker", "GPUComputePassEncoder"),
            bytes,
            BigInt(len),
        );
    },
    renderPassEnd(pass) {
        wgpu.symbols.wgpuRenderPassEncoderEnd(assertLiveResource(pass, "GPURenderPassEncoder.end", "GPURenderPassEncoder"));
        pass._ended = true;
        if (pass._encoder._activePass === pass) {
            pass._encoder._activePass = null;
        }
    },
    renderBundleEncoderInit(encoder, native) {
        encoder._native = native;
        encoder._pipeline = null;
        encoder._bindGroups = [];
        encoder._immediates = [];
        encoder._vertexBuffers = [];
        encoder._indexBuffer = null;
        encoder._finished = false;
    },
    renderBundleEncoderSetPipeline(encoder, pipelineNative) {
        if (!updatePassPipelineState(encoder, pipelineNative)) {
            return;
        }
        wgpu.symbols.wgpuRenderBundleEncoderSetPipeline(
            assertLiveResource(encoder, "GPURenderBundleEncoder.setPipeline", "GPURenderBundleEncoder"),
            pipelineNative,
        );
    },
    renderBundleEncoderSetBindGroup(encoder, index, bindGroupNative) {
        if (!updatePassBindGroupState(encoder, index, bindGroupNative)) {
            return;
        }
        wgpu.symbols.wgpuRenderBundleEncoderSetBindGroup(
            assertLiveResource(encoder, "GPURenderBundleEncoder.setBindGroup", "GPURenderBundleEncoder"),
            index,
            bindGroupNative,
            BigInt(0),
            null,
        );
    },
    renderBundleEncoderSetImmediates(encoder, index, data) {
        if (!updatePassImmediateState(encoder, index, data)) {
            return;
        }
        wgpu.symbols.wgpuRenderBundleEncoderSetImmediates(
            assertLiveResource(encoder, "GPURenderBundleEncoder.setImmediates", "GPURenderBundleEncoder"),
            index,
            data,
            BigInt(data.byteLength),
        );
    },
    renderBundleEncoderSetVertexBuffer(encoder, slot, bufferNative, offset, size) {
        if (!updatePassVertexBufferState(encoder, slot, bufferNative, offset, size)) {
            return;
        }
        wgpu.symbols.wgpuRenderBundleEncoderSetVertexBuffer(
            assertLiveResource(encoder, "GPURenderBundleEncoder.setVertexBuffer", "GPURenderBundleEncoder"),
            slot,
            bufferNative,
            BigInt(offset),
            BigInt(size ?? 0),
        );
    },
    renderBundleEncoderSetIndexBuffer(encoder, bufferNative, format, offset, size) {
        if (!updatePassIndexBufferState(encoder, bufferNative, format, offset, size)) {
            return;
        }
        wgpu.symbols.wgpuRenderBundleEncoderSetIndexBuffer(
            assertLiveResource(encoder, "GPURenderBundleEncoder.setIndexBuffer", "GPURenderBundleEncoder"),
            bufferNative,
            INDEX_FORMAT_MAP[format] ?? INDEX_FORMAT_MAP.uint16,
            BigInt(offset),
            BigInt(size ?? 0),
        );
    },
    renderBundleEncoderDraw(encoder, vertexCount, instanceCount, firstVertex, firstInstance) {
        wgpu.symbols.wgpuRenderBundleEncoderDraw(
            assertLiveResource(encoder, "GPURenderBundleEncoder.draw", "GPURenderBundleEncoder"),
            vertexCount, instanceCount, firstVertex, firstInstance,
        );
    },
    renderBundleEncoderDrawIndexed(encoder, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
        wgpu.symbols.wgpuRenderBundleEncoderDrawIndexed(
            assertLiveResource(encoder, "GPURenderBundleEncoder.drawIndexed", "GPURenderBundleEncoder"),
            indexCount, instanceCount, firstIndex, baseVertex, firstInstance,
        );
    },
    renderBundleEncoderDrawIndirect(encoder, indirectBufferNative, indirectOffset) {
        wgpu.symbols.wgpuRenderBundleEncoderDrawIndirect(
            assertLiveResource(encoder, "GPURenderBundleEncoder.drawIndirect", "GPURenderBundleEncoder"),
            indirectBufferNative,
            BigInt(indirectOffset),
        );
    },
    renderBundleEncoderDrawIndexedIndirect(encoder, indirectBufferNative, indirectOffset) {
        wgpu.symbols.wgpuRenderBundleEncoderDrawIndexedIndirect(
            assertLiveResource(encoder, "GPURenderBundleEncoder.drawIndexedIndirect", "GPURenderBundleEncoder"),
            indirectBufferNative,
            BigInt(indirectOffset),
        );
    },
    renderBundleEncoderPushDebugGroup(encoder, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuRenderBundleEncoderPushDebugGroup(
            assertLiveResource(encoder, "GPURenderBundleEncoder.pushDebugGroup", "GPURenderBundleEncoder"),
            bytes,
            BigInt(len),
        );
    },
    renderBundleEncoderPopDebugGroup(encoder) {
        wgpu.symbols.wgpuRenderBundleEncoderPopDebugGroup(
            assertLiveResource(encoder, "GPURenderBundleEncoder.popDebugGroup", "GPURenderBundleEncoder"),
        );
    },
    renderBundleEncoderInsertDebugMarker(encoder, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuRenderBundleEncoderInsertDebugMarker(
            assertLiveResource(encoder, "GPURenderBundleEncoder.insertDebugMarker", "GPURenderBundleEncoder"),
            bytes,
            BigInt(len),
        );
    },
    renderBundleEncoderFinish(encoder, _descriptor, classes) {
        const native = wgpu.symbols.wgpuRenderBundleEncoderFinish(
            assertLiveResource(encoder, "GPURenderBundleEncoder.finish", "GPURenderBundleEncoder"),
            null,
        );
        wgpu.symbols.wgpuRenderBundleEncoderRelease(encoder._native);
        encoder._native = null;
        return new classes.DoeGPURenderBundle(native, encoder._device);
    },
    renderBundleDestroy(native) {
        wgpu.symbols.wgpuRenderBundleRelease(native);
    },
    commandEncoderInit(encoder) {
        encoder._commands = [];
        encoder._native = null;
        encoder._finished = false;
        encoder._activePass = null;
    },
    commandEncoderAssertOpen(encoder, path) {
        if (encoder._finished) failValidation(path, "command encoder is already finished");
        assertBunNoActivePass(encoder, path);
    },
    commandEncoderBeginComputePass(encoder, _descriptor, classes) {
        const descriptorIsEmpty =
            _descriptor === undefined
            || _descriptor === null
            || (typeof _descriptor === "object" && Object.keys(_descriptor).length === 0);
        if (descriptorIsEmpty && encoder._native == null) {
            const pass = new classes.DoeGPUComputePassEncoder(null, encoder);
            encoder._activePass = pass;
            return pass;
        }
        ensureBunCommandEncoderNative(encoder);
        const native = wgpu.symbols.wgpuCommandEncoderBeginComputePass(encoder._native, null);
        const pass = new classes.DoeGPUComputePassEncoder(native, encoder);
        encoder._activePass = pass;
        return pass;
    },
    commandEncoderBeginRenderPass(encoder, descriptor, classes) {
        ensureBunCommandEncoderNative(encoder);
        const { desc, _refs } = buildRenderPassDescriptor(descriptor);
        const pass = wgpu.symbols.wgpuCommandEncoderBeginRenderPass(encoder._native, desc);
        void _refs;
        const wrapper = new classes.DoeGPURenderPassEncoder(pass, encoder);
        encoder._activePass = wrapper;
        return wrapper;
    },
    commandEncoderCopyBufferToBuffer(encoder, srcNative, srcOffset, dstNative, dstOffset, size) {
        if (encoder._native) {
            wgpu.symbols.wgpuCommandEncoderCopyBufferToBuffer(
                encoder._native, srcNative, BigInt(srcOffset), dstNative, BigInt(dstOffset), BigInt(size));
            return;
        }
        encoder._commands.push({ t: 1, s: srcNative, so: srcOffset, d: dstNative, do: dstOffset, sz: size });
    },
    commandEncoderWriteTimestamp(encoder, querySetNative, queryIndex) {
        ensureBunCommandEncoderNative(encoder);
        if (typeof wgpu.symbols.doeNativeCommandEncoderWriteTimestamp === "function") {
            wgpu.symbols.doeNativeCommandEncoderWriteTimestamp(encoder._native, querySetNative, queryIndex);
        }
    },
    commandEncoderResolveQuerySet(encoder, querySetNative, firstQuery, queryCount, destinationNative, destinationOffset) {
        ensureBunCommandEncoderNative(encoder);
        if (typeof wgpu.symbols.doeNativeCommandEncoderResolveQuerySet === "function") {
            wgpu.symbols.doeNativeCommandEncoderResolveQuerySet(
                encoder._native, querySetNative, firstQuery, queryCount, destinationNative, BigInt(destinationOffset));
        }
    },
    commandEncoderCopyBufferToTexture(encoder, source, destination, copySize) {
        ensureBunCommandEncoderNative(encoder);
        const { desc: srcDesc } = buildTexelCopyBufferInfo({
            ...source,
            buffer: source.buffer,
        });
        const { desc: dstDesc } = buildTexelCopyTextureInfo({
            ...destination,
            texture: destination.texture,
        });
        const extent = buildExtent3D(copySize);
        if (typeof wgpu.symbols.wgpuCommandEncoderCopyBufferToTexture === "function") {
            wgpu.symbols.wgpuCommandEncoderCopyBufferToTexture(encoder._native, srcDesc, dstDesc, extent);
            return;
        }
        if (typeof wgpu.symbols.doeNativeCommandEncoderCopyBufferToTexture === "function") {
            wgpu.symbols.doeNativeCommandEncoderCopyBufferToTexture(
                encoder._native,
                source.buffer,
                BigInt(source.offset ?? 0),
                source.bytesPerRow ?? 0,
                source.rowsPerImage ?? 0,
                destination.texture,
                destination.mipLevel ?? 0,
                copySize.width,
                copySize.height,
                copySize.depthOrArrayLayers ?? 1,
            );
            return;
        }
        throw new Error("[doe-gpu] copyBufferToTexture is unavailable in the loaded library");
    },
    commandEncoderCopyTextureToBuffer(encoder, source, destination, copySize) {
        ensureBunCommandEncoderNative(encoder);
        const { desc: srcDesc } = buildTexelCopyTextureInfo({
            ...source,
            texture: source.texture,
        });
        const { desc: dstDesc } = buildTexelCopyBufferInfo({
            ...destination,
            buffer: destination.buffer,
        });
        const extent = buildExtent3D(copySize);
        if (typeof wgpu.symbols.wgpuCommandEncoderCopyTextureToBuffer === "function") {
            wgpu.symbols.wgpuCommandEncoderCopyTextureToBuffer(encoder._native, srcDesc, dstDesc, extent);
            return;
        }
        if (typeof wgpu.symbols.doeNativeCommandEncoderCopyTextureToBuffer === "function") {
            wgpu.symbols.doeNativeCommandEncoderCopyTextureToBuffer(
                encoder._native,
                source.texture,
                source.mipLevel ?? 0,
                destination.buffer,
                BigInt(destination.offset ?? 0),
                destination.bytesPerRow ?? 0,
                destination.rowsPerImage ?? 0,
                copySize.width,
                copySize.height,
                copySize.depthOrArrayLayers ?? 1,
            );
            return;
        }
        throw new Error("[doe-gpu] copyTextureToBuffer is unavailable in the loaded library");
    },
    commandEncoderFinish(encoder) {
        encoder._finished = true;
        if (encoder._native) {
            const cmd = wgpu.symbols.wgpuCommandEncoderFinish(encoder._native, null);
            encoder._native = null;
            return { _native: cmd, _batched: false };
        }
        const commands = encoder._commands;
        encoder._commands = [];
        return { _commands: commands, _batched: true };
    },
    commandBufferDestroy(native) {
        wgpu.symbols.wgpuCommandBufferRelease(native);
    },
};

const {
    DoeGPUComputePassEncoder,
    DoeGPUCommandEncoder,
    DoeGPURenderPassEncoder,
    DoeGPURenderBundleEncoder,
    DoeGPURenderBundle,
} = createEncoderClasses(bunEncoderBackend);

const fullSurfaceBackend = {
    initBufferState(buffer) {
        buffer._mapMode = 0;
        buffer._mappedWriteRanges = [];
    },
    bufferMarkMappedAtCreation(buffer) {
        buffer._mapMode = 0x0002;
        buffer._mappedWriteRanges = [];
    },
    bufferMapAsync(wrapper, native, mode, offset, size) {
        if (wrapper._queue?.hasPendingSubmissions()) {
            const queueNative = assertLiveResource(wrapper._queue, "GPUBuffer.mapAsync", "GPUQueue");
            if (typeof wgpu.symbols.doeNativeQueueFlush === "function") {
                wgpu.symbols.doeNativeQueueFlush(queueNative);
                fastPathStats.flushAndMap += 1;
            } else {
                waitForSubmittedWorkDoneSync(wrapper._instance, queueNative);
            }
            wrapper._queue.markSubmittedWorkDone();
        }
        bufferMapSync(wrapper._instance, native, mode, offset, size);
        wrapper._mapMode = mode;
    },
    bufferMapReadCopyUnmap(wrapper, native, mode, offset, size) {
        if (mode !== 0x0001) {
            failValidation("GPUBuffer._mapReadCopyUnmap", "only MAP_READ mode is supported");
        }
        if (typeof wgpu.symbols.doeBufferMapReadCopyUnmapFlat === "function") {
            const queue = wrapper._queue ?? null;
            const shouldFlush = queue?.hasPendingSubmissions() ? 1 : 0;
            const queueNative = shouldFlush
                ? assertLiveResource(queue, "GPUBuffer._mapReadCopyUnmap", "GPUQueue")
                : null;
            const breakdown = DOE_WEBGPU_SUBMIT_BREAKDOWN
                ? (queue ? queueMapReadCopyUnmapScratch(queue) : new BigUint64Array(READBACK_BREAKDOWN_FIELD_COUNT))
                : null;
            const copy = new ArrayBuffer(Number(size));
            const status = wgpu.symbols.doeBufferMapReadCopyUnmapFlat(
                queueNative,
                native,
                BigInt(mode),
                BigInt(offset),
                BigInt(size),
                shouldFlush,
                new Uint8Array(copy),
                breakdown,
            );
            if (status !== WGPU_STATUS_SUCCESS) {
                throw new Error(nativeFailureMessage("[doe-gpu] bufferMapReadCopyUnmapFlat failed"));
            }
            if (shouldFlush && queue) {
                queue.markSubmittedWorkDone();
                fastPathStats.flushAndMap += 1;
            }
            if (!DOE_WEBGPU_SUBMIT_BREAKDOWN) {
                wrapper.__doe_readback_breakdown_ns = ZERO_READBACK_BREAKDOWN_NS;
                wrapper._mapMode = 0;
                wrapper._mappedWriteRanges = [];
                return copy;
            }
            const readbackBreakdownNs = {
                readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: Number(
                    breakdown[READBACK_BREAKDOWN_WAIT_COMPLETED],
                ),
                readbackMapReadCopyUnmapDeferredCopyTotalNs: Number(
                    breakdown[READBACK_BREAKDOWN_DEFERRED_COPY],
                ),
                readbackMapReadCopyUnmapDeferredResolveTotalNs: Number(
                    breakdown[READBACK_BREAKDOWN_DEFERRED_RESOLVE],
                ),
                readbackMapReadCopyUnmapMapTotalNs: Number(breakdown[READBACK_BREAKDOWN_MAP]),
                readbackMapReadCopyUnmapCopyTotalNs: Number(breakdown[READBACK_BREAKDOWN_COPY]),
                readbackMapReadCopyUnmapUnmapTotalNs: Number(breakdown[READBACK_BREAKDOWN_UNMAP]),
            };
            wrapper.__doe_readback_breakdown_ns = readbackBreakdownNs;
            wrapper._mapMode = 0;
            wrapper._mappedWriteRanges = [];
            return copy;
        }
        const readbackBreakdownNs = {
            readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: 0,
            readbackMapReadCopyUnmapDeferredCopyTotalNs: 0,
            readbackMapReadCopyUnmapDeferredResolveTotalNs: 0,
            readbackMapReadCopyUnmapMapTotalNs: 0,
            readbackMapReadCopyUnmapCopyTotalNs: 0,
            readbackMapReadCopyUnmapUnmapTotalNs: 0,
        };
        if (wrapper._queue?.hasPendingSubmissions()) {
            const queueNative = assertLiveResource(wrapper._queue, "GPUBuffer._mapReadCopyUnmap", "GPUQueue");
            if (DOE_WEBGPU_SUBMIT_BREAKDOWN && typeof wgpu.symbols.doeNativeQueueFlushBreakdown === "function") {
                queueFlushBreakdownScratch(wrapper._queue);
                const waitCompletedNs = wrapper._queue._flushWaitCompletedNs;
                const deferredCopyNs = wrapper._queue._flushDeferredCopyNs;
                const deferredResolveNs = wrapper._queue._flushDeferredResolveNs;
                wgpu.symbols.doeNativeQueueFlushBreakdown(
                    queueNative,
                    bunPtr(waitCompletedNs),
                    bunPtr(deferredCopyNs),
                    bunPtr(deferredResolveNs),
                );
                readbackBreakdownNs.readbackMapReadCopyUnmapQueueWaitCompletedTotalNs = Number(waitCompletedNs[0]);
                readbackBreakdownNs.readbackMapReadCopyUnmapDeferredCopyTotalNs = Number(deferredCopyNs[0]);
                readbackBreakdownNs.readbackMapReadCopyUnmapDeferredResolveTotalNs = Number(deferredResolveNs[0]);
                fastPathStats.flushAndMap += 1;
            } else if (typeof wgpu.symbols.doeNativeQueueFlush === "function") {
                const flushStartedAt = performance.now();
                wgpu.symbols.doeNativeQueueFlush(queueNative);
                readbackBreakdownNs.readbackMapReadCopyUnmapQueueWaitCompletedTotalNs = elapsedNsSince(flushStartedAt);
                fastPathStats.flushAndMap += 1;
            } else {
                const waitStartedAt = performance.now();
                waitForSubmittedWorkDoneSync(wrapper._instance, queueNative);
                readbackBreakdownNs.readbackMapReadCopyUnmapQueueWaitCompletedTotalNs = elapsedNsSince(waitStartedAt);
            }
            wrapper._queue.markSubmittedWorkDone();
        }
        const mapStartedAt = performance.now();
        bufferMapSync(wrapper._instance, native, mode, offset, size);
        readbackBreakdownNs.readbackMapReadCopyUnmapMapTotalNs = elapsedNsSince(mapStartedAt);
        wrapper._mapMode = mode;
        try {
            const copyStartedAt = performance.now();
            const copied = fullSurfaceBackend.bufferReadCopy(wrapper, native, offset, size);
            readbackBreakdownNs.readbackMapReadCopyUnmapCopyTotalNs = elapsedNsSince(copyStartedAt);
            return copied;
        } finally {
            const unmapStartedAt = performance.now();
            wgpu.symbols.wgpuBufferUnmap(native);
            readbackBreakdownNs.readbackMapReadCopyUnmapUnmapTotalNs = elapsedNsSince(unmapStartedAt);
            wrapper.__doe_readback_breakdown_ns = readbackBreakdownNs;
            wrapper._mapMode = 0;
            wrapper._mappedWriteRanges = [];
        }
    },
    bufferGetMappedRange(wrapper, native, offset, size) {
        const isWrite = (wrapper._mapMode & 0x0002) !== 0;
        if (isWrite) {
            const dataPtr = wgpu.symbols.wgpuBufferGetMappedRange(native, BigInt(offset), BigInt(size));
            if (!dataPtr) throw new Error("[doe-gpu] getMappedRange (write) returned NULL");
            return toArrayBuffer(dataPtr, 0, size);
        }
        const dataPtr = wgpu.symbols.wgpuBufferGetConstMappedRange(native, BigInt(offset), BigInt(size));
        if (!dataPtr) throw new Error("[doe-gpu] getMappedRange returned NULL");
        if (DOE_LIBRARY_FLAVOR === "doe-dropin") {
            return toArrayBuffer(dataPtr, 0, size);
        }
        const nativeView = toArrayBuffer(dataPtr, 0, size);
        const copy = new ArrayBuffer(size);
        new Uint8Array(copy).set(new Uint8Array(nativeView));
        return copy;
    },
    bufferReadCopy(_wrapper, native, offset, size) {
        const dataPtr = wgpu.symbols.wgpuBufferGetConstMappedRange(native, BigInt(offset), BigInt(size));
        if (!dataPtr) throw new Error("[doe-gpu] bufferReadCopy getMappedRange returned NULL");
        const nativeView = toArrayBuffer(dataPtr, 0, size);
        const copy = new ArrayBuffer(size);
        new Uint8Array(copy).set(new Uint8Array(nativeView));
        return copy;
    },
    bufferGetMapState(wrapper, native) {
        if (wrapper?._mapState === "pending") {
            return "pending";
        }
        const fn = wgpu?.symbols?.doeNativeBufferGetMapState;
        if (typeof fn !== "function") {
            return null;
        }
        return mapBufferMapState(fn(native));
    },
    bufferUnmap(native, wrapper) {
        wgpu.symbols.wgpuBufferUnmap(native);
        wrapper._mapMode = 0;
        wrapper._mappedWriteRanges = [];
    },
    bufferDestroy(native) {
        wgpu.symbols.wgpuBufferRelease(native);
    },
    initQueueState(queue) {
        queue._pendingSubmissions = 0;
        queue._submitBreakdownNs = zeroQueueSubmitBreakdown();
        queue._singleSubmitPtrArray = new BigUint64Array(1);
        queue._submitPtrScratch = queue._singleSubmitPtrArray;
        queue._emptyBindGroupPtrArray = new BigUint64Array(0);
        queue._singleBindGroupPtrArray = new BigUint64Array(1);
        queue._bindGroupPtrScratch = queue._singleBindGroupPtrArray;
        queue._dispatchBatchScratch = {};
        queue._writeBatchScratch = {};
        queue._dispatchFlushBreakdown = new BigUint64Array(DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT);
        queue._flushWaitCompletedNs = new BigUint64Array(1);
        queue._flushDeferredCopyNs = new BigUint64Array(1);
        queue._flushDeferredResolveNs = new BigUint64Array(1);
    },
    queueHasPendingSubmissions(queue) {
        return queue._pendingSubmissions > 0;
    },
    queueMarkSubmittedWorkDone(queue) {
        queue._pendingSubmissions = 0;
    },
    queueSubmit(queue, queueNative, buffers) {
        const deviceNative = assertLiveResource(queue._device, "GPUQueue.submit", "GPUDevice");
        queue._pendingSubmissions += 1;
        for (let index = 0; index < buffers.length; index += 1) {
            if (buffers[index]?._submitted) {
                failValidation("GPUQueue.submit", `commandBuffers[${index}] was already submitted`);
            }
        }
        const dispatchFlushBreakdown = DOE_WEBGPU_SUBMIT_BREAKDOWN
            ? wgpu.symbols.doeNativeComputeDispatchFlushBreakdown
            : null;
        const dispatchFlush = wgpu.symbols.doeNativeComputeDispatchFlush ?? dispatchFlushBreakdown;
        const dispatchFlushOneBindGroup = wgpu.symbols.doeNativeComputeDispatchFlushOneBindGroup;
        if (dispatchFlush && buffers.length === 1 && buffers[0]?._batched) {
            const cmds = buffers[0]._commands;
            if (cmds.length >= 1 && cmds.length <= 2 && cmds[0]?.t === 0 && !(cmds[0]?.immediates?.length) && (cmds.length === 1 || cmds[1]?.t === 1)) {
                const prepStartedAt = submitTimingStart();
                const cmd0 = cmds[0];
                const cmd1 = cmds.length === 2 ? cmds[1] : null;
                const compactBindGroup = cmd0.b ?? null;
                const commandBindGroups = compactBindGroup ? null : cmd0.bg;
                const bgCount = compactBindGroup
                    ? 1
                    : (Array.isArray(commandBindGroups) ? Math.min(commandBindGroups.length, MAX_COMPUTE_BIND_GROUPS) : 0);
                let bgPtrs = null;
                if (!compactBindGroup || dispatchFlushBreakdown || typeof dispatchFlushOneBindGroup !== "function") {
                    bgPtrs = ensureBindGroupPtrScratch(queue, bgCount);
                    if (compactBindGroup) {
                        bgPtrs[0] = hotU64(compactBindGroup);
                    } else {
                        for (let i = 0; i < bgCount; i += 1) {
                            bgPtrs[i] = hotU64(commandBindGroups[i]);
                        }
                    }
                }
                accumulateQueueSubmitBreakdown(queue, "submitCommandPrepTotalNs", prepStartedAt);
                const addonStartedAt = submitTimingStart();
                if (compactBindGroup && !dispatchFlushBreakdown && typeof dispatchFlushOneBindGroup === "function") {
                    dispatchFlushOneBindGroup(
                        queueNative, cmd0.p, compactBindGroup,
                        cmd0.x, cmd0.y, cmd0.z,
                        cmd1?.s ?? null, hotU64(cmd1?.so),
                        cmd1?.d ?? null, hotU64(cmd1?.do), hotU64(cmd1?.sz));
                    accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                } else if (dispatchFlushBreakdown) {
                    const breakdown = queueDispatchFlushBreakdownScratch(queue);
                    dispatchFlushBreakdown(
                        queueNative, cmd0.p, bgPtrs, bgCount,
                        cmd0.x, cmd0.y, cmd0.z,
                        cmd1?.s ?? null, hotU64(cmd1?.so),
                        cmd1?.d ?? null, hotU64(cmd1?.do), hotU64(cmd1?.sz),
                        breakdown,
                    );
                    accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                    accumulateDispatchFlushBreakdown(queue, breakdown);
                } else {
                    dispatchFlush(
                        queueNative, cmd0.p, bgPtrs, bgCount,
                        cmd0.x, cmd0.y, cmd0.z,
                        cmd1?.s ?? null, hotU64(cmd1?.so),
                        cmd1?.d ?? null, hotU64(cmd1?.do), hotU64(cmd1?.sz));
                    accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                }
                fastPathStats.dispatchFlush += 1;
                const bookkeepingStartedAt = submitTimingStart();
                for (const commandBuffer of buffers) {
                    commandBuffer._submitted = true;
                    commandBuffer.destroy?.();
                }
                accumulateQueueSubmitBreakdown(queue, "submitPostSubmitBookkeepingTotalNs", bookkeepingStartedAt);
                return;
            }
        }
        let batchedCommands = null;
        if (buffers.length === 1) {
            const commandBuffer = buffers[0];
            if (commandBuffer?._batched && Array.isArray(commandBuffer._commands)) {
                batchedCommands = commandBuffer._commands;
            }
        } else {
            const commands = [];
            let allBatched = true;
            for (const commandBuffer of buffers) {
                if (!commandBuffer?._batched || !Array.isArray(commandBuffer._commands)) {
                    allBatched = false;
                    break;
                }
                commands.push(...commandBuffer._commands);
            }
            if (allBatched) batchedCommands = commands;
        }
        if (batchedCommands !== null) {
            const allCommands = batchedCommands;
            const dispatchBatchCopyFlushBreakdown = DOE_WEBGPU_SUBMIT_BREAKDOWN
                ? wgpu.symbols.doeNativeComputeDispatchBatchCopyFlushBreakdown
                : null;
            const dispatchBatchCopyFlush = dispatchBatchCopyFlushBreakdown
                ?? wgpu.symbols.doeNativeComputeDispatchBatchCopyFlush;
            if (dispatchBatchCopyFlush && allCommands.length >= 2) {
                const copyCmd = allCommands[allCommands.length - 1];
                if (copyCmd?.t === 1) {
                    const prepStartedAt = submitTimingStart();
                    const dispatchCount = allCommands.length - 1;
                    const scratch = ensureDispatchBatchScratch(queue, dispatchCount);
                    const { pipelines, bindGroups, bindGroupCounts, dispatchDims } = scratch;
                    const dispatchThenCopy = fillBunDispatchBatchScratch(scratch, allCommands, dispatchCount);
                    if (dispatchThenCopy) {
                        accumulateQueueSubmitBreakdown(queue, "submitCommandPrepTotalNs", prepStartedAt);
                        const addonStartedAt = submitTimingStart();
                        const dispatchCountU64 = hotU64(dispatchCount);
                        if (dispatchBatchCopyFlushBreakdown) {
                            const breakdown = queueDispatchFlushBreakdownScratch(queue);
                            dispatchBatchCopyFlushBreakdown(
                                queueNative,
                                dispatchCountU64,
                                pipelines,
                                bindGroups,
                                bindGroupCounts,
                                dispatchDims,
                                copyCmd.s,
                                hotU64(copyCmd.so),
                                copyCmd.d,
                                hotU64(copyCmd.do),
                                hotU64(copyCmd.sz),
                                breakdown,
                            );
                            accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                            accumulateDispatchFlushBreakdown(queue, breakdown);
                        } else {
                            dispatchBatchCopyFlush(
                                queueNative,
                                dispatchCountU64,
                                pipelines,
                                bindGroups,
                                bindGroupCounts,
                                dispatchDims,
                                copyCmd.s,
                                hotU64(copyCmd.so),
                                copyCmd.d,
                                hotU64(copyCmd.do),
                                hotU64(copyCmd.sz),
                            );
                            accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                        }
                        const bookkeepingStartedAt = submitTimingStart();
                        fastPathStats.dispatchFlush += 1;
                        for (const commandBuffer of buffers) {
                            commandBuffer._submitted = true;
                            commandBuffer.destroy?.();
                        }
                        accumulateQueueSubmitBreakdown(queue, "submitPostSubmitBookkeepingTotalNs", bookkeepingStartedAt);
                        return;
                    }
                }
            }
            const dispatchBatchFlush = wgpu.symbols.doeNativeComputeDispatchBatchFlush
                ?? dispatchBatchCopyFlushBreakdown;
            if (dispatchBatchFlush && allCommands.length > 0) {
                const prepStartedAt = submitTimingStart();
                const dispatchCount = allCommands.length;
                const scratch = ensureDispatchBatchScratch(queue, dispatchCount);
                const { pipelines, bindGroups, bindGroupCounts, dispatchDims } = scratch;
                const allDispatch = fillBunDispatchBatchScratch(scratch, allCommands, dispatchCount);
                if (allDispatch) {
                    accumulateQueueSubmitBreakdown(queue, "submitCommandPrepTotalNs", prepStartedAt);
                    const addonStartedAt = submitTimingStart();
                    const dispatchCountU64 = hotU64(dispatchCount);
                    if (dispatchBatchCopyFlushBreakdown) {
                        const breakdown = queueDispatchFlushBreakdownScratch(queue);
                        dispatchBatchCopyFlushBreakdown(
                            queueNative,
                            dispatchCountU64,
                            pipelines,
                            bindGroups,
                            bindGroupCounts,
                            dispatchDims,
                            null,
                            0n,
                            null,
                            0n,
                            0n,
                            breakdown,
                        );
                        accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                        accumulateDispatchFlushBreakdown(queue, breakdown);
                    } else {
                        dispatchBatchFlush(
                            queueNative,
                            dispatchCountU64,
                            pipelines,
                            bindGroups,
                            bindGroupCounts,
                            dispatchDims,
                        );
                        accumulateQueueSubmitBreakdown(queue, "submitAddonCallTotalNs", addonStartedAt);
                    }
                    const bookkeepingStartedAt = submitTimingStart();
                    fastPathStats.dispatchFlush += 1;
                    for (const commandBuffer of buffers) {
                        commandBuffer._submitted = true;
                        commandBuffer.destroy?.();
                    }
                    accumulateQueueSubmitBreakdown(queue, "submitPostSubmitBookkeepingTotalNs", bookkeepingStartedAt);
                    return;
                }
            }
            const encoder = wgpu.symbols.wgpuDeviceCreateCommandEncoder(deviceNative, null);
            for (const cmd of allCommands) {
                if (cmd.t === 0) {
                    const pass = wgpu.symbols.wgpuCommandEncoderBeginComputePass(encoder, null);
                    wgpu.symbols.wgpuComputePassEncoderSetPipeline(pass, cmd.p);
                    const bgCount = bunCommandBindGroupCount(cmd);
                    for (let i = 0; i < bgCount; i += 1) {
                        const bindGroup = bunCommandBindGroupAt(cmd, i);
                        if (bindGroup) wgpu.symbols.wgpuComputePassEncoderSetBindGroup(pass, i, bindGroup, BigInt(0), null);
                    }
                    for (const immediate of cmd.immediates ?? []) {
                        wgpu.symbols.wgpuComputePassEncoderSetImmediates(
                            pass,
                            immediate.index,
                            immediate.data,
                            BigInt(immediate.data.byteLength),
                        );
                    }
                    wgpu.symbols.wgpuComputePassEncoderDispatchWorkgroups(pass, cmd.x, cmd.y, cmd.z);
                    wgpu.symbols.wgpuComputePassEncoderEnd(pass);
                    wgpu.symbols.wgpuComputePassEncoderRelease(pass);
                } else if (cmd.t === 1) {
                    wgpu.symbols.wgpuCommandEncoderCopyBufferToBuffer(
                        encoder, cmd.s, hotU64(cmd.so), cmd.d, hotU64(cmd.do), hotU64(cmd.sz));
                }
            }
            const cmdBuf = wgpu.symbols.wgpuCommandEncoderFinish(encoder, null);
            const ptrs = ensureSubmitPtrScratch(queue, 1);
            ptrs[0] = hotU64(cmdBuf);
            wgpu.symbols.wgpuQueueSubmit(queueNative, hotU64(1), ptrs);
            wgpu.symbols.wgpuCommandBufferRelease(cmdBuf);
            wgpu.symbols.wgpuCommandEncoderRelease(encoder);
            for (const commandBuffer of buffers) {
                commandBuffer._submitted = true;
                commandBuffer.destroy?.();
            }
            return;
        }
        if (
            buffers.length === 1
            && buffers[0]?._native
            && !buffers[0]?._batched
            && typeof wgpu.symbols.doeQueueSubmitOneAndRelease === "function"
        ) {
            const commandBuffer = buffers[0];
            const submitStartedAt = submitTimingStart();
            wgpu.symbols.doeQueueSubmitOneAndRelease(queueNative, commandBuffer._native);
            commandBuffer._native = null;
            accumulateQueueSubmitBreakdown(queue, "submitAddonQueueSubmitTotalNs", submitStartedAt);
            const bookkeepingStartedAt = submitTimingStart();
            commandBuffer._submitted = true;
            commandBuffer.destroy?.();
            accumulateQueueSubmitBreakdown(queue, "submitPostSubmitBookkeepingTotalNs", bookkeepingStartedAt);
            return;
        }
        const prepStartedAt = submitTimingStart();
        const ptrs = ensureSubmitPtrScratch(queue, buffers.length);
        for (let index = 0; index < buffers.length; index += 1) {
            ptrs[index] = hotU64(assertLiveResource(buffers[index], "GPUQueue.submit", "GPUCommandBuffer"));
        }
        accumulateQueueSubmitBreakdown(queue, "submitCommandPrepTotalNs", prepStartedAt);
        const submitStartedAt = submitTimingStart();
        wgpu.symbols.wgpuQueueSubmit(queueNative, hotU64(buffers.length), ptrs);
        accumulateQueueSubmitBreakdown(queue, "submitAddonQueueSubmitTotalNs", submitStartedAt);
        const bookkeepingStartedAt = submitTimingStart();
        for (const commandBuffer of buffers) {
            commandBuffer._submitted = true;
            commandBuffer.destroy?.();
        }
        accumulateQueueSubmitBreakdown(queue, "submitPostSubmitBookkeepingTotalNs", bookkeepingStartedAt);
    },
    queueWriteBuffer(_queue, native, bufferNative, bufferOffset, view) {
        const writeBuffer = wgpu.symbols.doeNativeQueueWriteBuffer ?? wgpu.symbols.wgpuQueueWriteBuffer;
        writeBuffer(native, bufferNative, hotU64(bufferOffset), view, hotU64(view.byteLength));
    },
    queueWriteBufferBatch(queue, native, entries) {
        if (!entries.length) {
            return;
        }
        const writeBatchDataPtrs = wgpu.symbols.doeNativeQueueWriteBufferBatchDataPtrs;
        const writeBatch = wgpu.symbols.doeNativeQueueWriteBufferBatch;
        if (typeof writeBatchDataPtrs !== "function" && typeof writeBatch !== "function") {
            for (const entry of entries) {
                fullSurfaceBackend.queueWriteBuffer(queue, native, entry.bufferNative, entry.bufferOffset, entry.view);
            }
            return;
        }
        let byteLength = 0;
        for (const entry of entries) {
            if (entry.view.byteLength > UINT32_MAX) {
                failValidation("GPUQueue.__doeWriteBufferBatch", "entry data is too large for the native compact batch ABI");
            }
            byteLength += entry.view.byteLength;
            if (byteLength > MAX_QUEUE_WRITE_BATCH_BYTES) {
                failValidation("GPUQueue.__doeWriteBufferBatch", "compact batch data exceeds the package batch limit");
            }
        }
        const scratch = ensureQueueWriteBatchScratch(queue, entries.length, byteLength);
        if (typeof writeBatchDataPtrs === "function") {
            for (let index = 0; index < entries.length; index += 1) {
                const entry = entries[index];
                const dataPtr = bunPtr(entry.view);
                if (!dataPtr) {
                    failValidation("GPUQueue.__doeWriteBufferBatch", "entry data pointer is unavailable");
                }
                scratch.buffers[index] = hotU64(entry.bufferNative);
                scratch.offsets[index] = hotU64(entry.bufferOffset);
                scratch.sizes[index] = entry.view.byteLength;
                scratch.dataPtrs[index] = hotU64(dataPtr);
            }
            writeBatchDataPtrs(
                native,
                hotU64(entries.length),
                scratch.buffers,
                scratch.offsets,
                scratch.sizes,
                scratch.dataPtrs,
            );
            return;
        }
        let dataOffset = 0;
        for (let index = 0; index < entries.length; index += 1) {
            const entry = entries[index];
            scratch.buffers[index] = hotU64(entry.bufferNative);
            scratch.offsets[index] = hotU64(entry.bufferOffset);
            scratch.sizes[index] = entry.view.byteLength;
            scratch.data.set(entry.view, dataOffset);
            dataOffset += entry.view.byteLength;
        }
        writeBatch(
            native,
            hotU64(entries.length),
            scratch.buffers,
            scratch.offsets,
            scratch.sizes,
            scratch.data,
        );
    },
    queueWriteTexture(_queue, native, destination, data, dataLayout, size) {
        const { desc: dstDesc, srcRefs: _dstRefs } = buildTexelCopyTextureInfo(destination);
        const layoutBytes = buildTexelCopyBufferLayout(dataLayout);
        const extent = buildExtent3D(size);
        wgpu.symbols.wgpuQueueWriteTexture(
            native,
            dstDesc,
            data,
            BigInt(data.byteLength),
            layoutBytes,
            extent,
        );
    },
    async queueOnSubmittedWorkDone(queue, native) {
        try {
            if (DOE_WEBGPU_SUBMIT_BREAKDOWN && typeof wgpu.symbols.doeNativeQueueFlushBreakdown === "function") {
                queueFlushBreakdownScratch(queue);
                const waitCompletedNs = queue._flushWaitCompletedNs;
                const deferredCopyNs = queue._flushDeferredCopyNs;
                const deferredResolveNs = queue._flushDeferredResolveNs;
                const flushStartedAt = submitTimingStart();
                wgpu.symbols.doeNativeQueueFlushBreakdown(
                    native,
                    bunPtr(waitCompletedNs),
                    bunPtr(deferredCopyNs),
                    bunPtr(deferredResolveNs),
                );
                accumulateQueueSubmitBreakdown(queue, "submitQueueFlushTotalNs", flushStartedAt);
                queue._submitBreakdownNs.submitQueueFlushWaitCompletedTotalNs += Number(waitCompletedNs[0]);
                queue._submitBreakdownNs.submitQueueFlushDeferredCopyTotalNs += Number(deferredCopyNs[0]);
                queue._submitBreakdownNs.submitQueueFlushDeferredResolveTotalNs += Number(deferredResolveNs[0]);
                return;
            }
            if (typeof wgpu.symbols.doeNativeQueueFlush === "function") {
                const flushStartedAt = submitTimingStart();
                wgpu.symbols.doeNativeQueueFlush(native);
                accumulateQueueSubmitBreakdown(queue, "submitQueueFlushTotalNs", flushStartedAt);
                return;
            }
            waitForSubmittedWorkDoneSync(queue._instance, native);
        } catch (error) {
            if (error?.code === "DOE_QUEUE_UNAVAILABLE") {
                return;
            }
            throw error;
        }
    },
    textureCreateView(_texture, native, descriptor) {
        if (!descriptor) {
            return wgpu.symbols.wgpuTextureCreateView(native, null);
        }
        const { desc, _refs } = buildTextureViewDescriptor(descriptor);
        const view = wgpu.symbols.wgpuTextureCreateView(native, desc);
        void _refs;
        return view;
    },
    textureDestroy(native, texture) {
        if (texture?._externallyOwned) {
            return;
        }
        wgpu.symbols.wgpuTextureRelease(native);
    },
    shaderModuleDestroy(native) {
        wgpu.symbols.wgpuShaderModuleRelease(native);
    },
    computePipelineGetBindGroupLayout(pipeline, index, classes) {
        if (pipeline._autoLayoutEntriesByGroup && process.platform === "darwin") {
            const entries = pipeline._autoLayoutEntriesByGroup.get(index) ?? [];
            return pipeline._device.createBindGroupLayout({ entries });
        }
        const native = process.platform === "darwin"
            ? wgpu.symbols.doeNativeComputePipelineGetBindGroupLayout(pipeline._native, index)
            : wgpu.symbols.wgpuComputePipelineGetBindGroupLayout(pipeline._native, index);
        return new classes.DoeGPUBindGroupLayout(native, pipeline._device);
    },
    renderPipelineGetBindGroupLayout(pipeline, index, classes) {
        const native = wgpu.symbols.wgpuRenderPipelineGetBindGroupLayout(pipeline._native, index);
        return new classes.DoeGPUBindGroupLayout(native, pipeline);
    },
    deviceCreateRenderBundleEncoder(device, descriptor, encoderClasses) {
        const { desc, _refs } = buildRenderBundleEncoderDescriptor(descriptor);
        const native = wgpu.symbols.wgpuDeviceCreateRenderBundleEncoder(
            assertLiveResource(device, "GPUDevice.createRenderBundleEncoder", "GPUDevice"),
            desc,
        );
        void _refs;
        if (!native) throw new Error("[doe-gpu] createRenderBundleEncoder failed");
        return new encoderClasses.DoeGPURenderBundleEncoder(native, device);
    },
    deviceLimits,
    deviceFeatures,
    adapterLimits,
    adapterFeatures,
    preflightShaderSource,
    preflightShaderSourceOnCreate: false,
    requireAutoLayoutEntriesFromNative,
    deviceGetQueue(native) {
        return wgpu.symbols.wgpuDeviceGetQueue(native);
    },
    deviceCreateBuffer(device, validated) {
        if (typeof wgpu.symbols.doeNativeDeviceCreateBufferFlat === "function") {
            return wgpu.symbols.doeNativeDeviceCreateBufferFlat(
                assertLiveResource(device, "GPUDevice.createBuffer", "GPUDevice"),
                BigInt(validated.usage || 0),
                BigInt(validated.size || 0),
                validated.mappedAtCreation ? 1 : 0,
            );
        }
        const descBytes = buildBufferDescriptor(validated);
        return wgpu.symbols.wgpuDeviceCreateBuffer(assertLiveResource(device, "GPUDevice.createBuffer", "GPUDevice"), descBytes);
    },
    deviceCreateShaderModule(device, code, _compilationHints) {
        if (typeof wgpu.symbols.doeNativeDeviceCreateShaderModuleWgsl === "function") {
            const codeBytes = cachedShaderSourceBytes(code);
            let mod;
            try {
                mod = wgpu.symbols.doeNativeDeviceCreateShaderModuleWgsl(
                    assertLiveResource(device, "GPUDevice.createShaderModule", "GPUDevice"),
                    codeBytes,
                    BigInt(codeBytes.length),
                );
            } catch (error) {
                throw enrichNativeCompilerError(error, "GPUDevice.createShaderModule", readLastErrorFields());
            }
            if (!mod) {
                throw compilerErrorFromMessage("GPUDevice.createShaderModule", nativeFailureMessage("createShaderModule failed"), readLastErrorFields());
            }
            return mod;
        }
        const { desc, _refs } = buildShaderModuleDescriptor(code);
        let mod;
        try {
            mod = wgpu.symbols.wgpuDeviceCreateShaderModule(assertLiveResource(device, "GPUDevice.createShaderModule", "GPUDevice"), desc);
        } catch (error) {
            throw enrichNativeCompilerError(error, "GPUDevice.createShaderModule", readLastErrorFields());
        }
        void _refs;
        if (!mod) {
            throw compilerErrorFromMessage("GPUDevice.createShaderModule", nativeFailureMessage("createShaderModule failed"), readLastErrorFields());
        }
        return mod;
    },
    deviceCreateComputePipeline(device, shaderNative, entryPoint, layoutNative, _constants, _label) {
        if (
            entryPoint === "main"
            && !_constants
            && typeof wgpu.symbols.doeNativeDeviceCreateComputePipelineMain === "function"
        ) {
            let native;
            try {
                native = wgpu.symbols.doeNativeDeviceCreateComputePipelineMain(
                    assertLiveResource(device, "GPUDevice.createComputePipeline", "GPUDevice"),
                    shaderNative,
                    layoutNative,
                );
            } catch (error) {
                throw pipelineErrorFromError(error, "GPUDevice.createComputePipeline", readLastErrorFields());
            }
            if (!native) {
                throw pipelineErrorFromMessage("GPUDevice.createComputePipeline", nativeFailureMessage("createComputePipeline failed"), readLastErrorFields());
            }
            return native;
        }
        const { desc, _refs } = buildComputePipelineDescriptor(shaderNative, entryPoint, layoutNative);
        let native;
        try {
            native = wgpu.symbols.wgpuDeviceCreateComputePipeline(assertLiveResource(device, "GPUDevice.createComputePipeline", "GPUDevice"), desc);
        } catch (error) {
            throw pipelineErrorFromError(error, "GPUDevice.createComputePipeline", readLastErrorFields());
        }
        void _refs;
        if (!native) {
            throw pipelineErrorFromMessage("GPUDevice.createComputePipeline", nativeFailureMessage("createComputePipeline failed"), readLastErrorFields());
        }
        return native;
    },
    deviceCreateBufferBindGroupLayoutFlat4(device, entryCount, b0, b1, b2, b3, _label) {
        if (typeof wgpu.symbols.doeNativeDeviceCreateBufferBindGroupLayoutFlat4 !== "function") {
            return undefined;
        }
        return wgpu.symbols.doeNativeDeviceCreateBufferBindGroupLayoutFlat4(
            assertLiveResource(device, "GPUDevice.createBindGroupLayout", "GPUDevice"),
            entryCount,
            b0,
            b1,
            b2,
            b3,
        );
    },
    deviceCreateBindGroupLayout(device, entries, _label) {
        if (entries.some((entry) => entry.externalTexture)) {
            failValidation(
                "GPUDevice.createBindGroupLayout",
                "externalTexture bindings require a browser canvas backend provider, not the headless Doe runtime package surface",
            );
        }
        const { desc, _refs } = buildBindGroupLayoutDescriptor(entries);
        const native = wgpu.symbols.wgpuDeviceCreateBindGroupLayout(assertLiveResource(device, "GPUDevice.createBindGroupLayout", "GPUDevice"), desc);
        void _refs;
        return native;
    },
    deviceCreateBufferBindGroupFlat4(
        device,
        layoutNative,
        entryCount,
        b0,
        buffer0,
        offset0,
        b1,
        buffer1,
        offset1,
        b2,
        buffer2,
        offset2,
        b3,
        buffer3,
        offset3,
        _label,
    ) {
        if (typeof wgpu.symbols.doeNativeDeviceCreateBufferBindGroupFlat4 !== "function") {
            return undefined;
        }
        return wgpu.symbols.doeNativeDeviceCreateBufferBindGroupFlat4(
            assertLiveResource(device, "GPUDevice.createBindGroup", "GPUDevice"),
            layoutNative,
            entryCount,
            b0,
            buffer0,
            BigInt(offset0),
            b1,
            buffer1,
            BigInt(offset1),
            b2,
            buffer2,
            BigInt(offset2),
            b3,
            buffer3,
            BigInt(offset3),
        );
    },
    deviceCreateBindGroup(device, layoutNative, entries, _label) {
        if (entries.some((entry) => entry.externalTexture)) {
            failValidation(
                "GPUDevice.createBindGroup",
                "externalTexture resources require a browser canvas backend provider, not the headless Doe runtime package surface",
            );
        }
        const normalizedEntries = entries.map((entry) => ({
            binding: entry.binding,
            resource: entry.buffer
                ? { buffer: entry.buffer, offset: entry.offset ?? 0, size: entry.size }
                : entry.sampler
                    ? { sampler: entry.sampler }
                    : { textureView: entry.textureView },
        }));
        const { desc, _refs } = buildBindGroupDescriptor(layoutNative, normalizedEntries);
        const native = wgpu.symbols.wgpuDeviceCreateBindGroup(assertLiveResource(device, "GPUDevice.createBindGroup", "GPUDevice"), desc);
        void _refs;
        return native;
    },
    deviceCreatePipelineLayout(device, layouts, _label, immediateSize = 0) {
        if (
            typeof wgpu.symbols.doeNativeDeviceCreatePipelineLayoutOne === "function"
            && layouts.length === 1
        ) {
            return wgpu.symbols.doeNativeDeviceCreatePipelineLayoutOne(
                assertLiveResource(device, "GPUDevice.createPipelineLayout", "GPUDevice"),
                layouts[0],
                immediateSize >>> 0,
            );
        }
        const { desc, _refs } = buildPipelineLayoutDescriptor(layouts, immediateSize);
        const native = wgpu.symbols.wgpuDeviceCreatePipelineLayout(assertLiveResource(device, "GPUDevice.createPipelineLayout", "GPUDevice"), desc);
        void _refs;
        return native;
    },
    deviceCreateTexture(device, textureDescriptor, size, usage) {
        const { desc, _refs } = buildTextureDescriptor({
            ...textureDescriptor,
            dimension: normalizeTextureDimension(textureDescriptor.dimension, "GPUDevice.createTexture"),
            usage,
            size,
            mipLevelCount: assertIntegerInRange(textureDescriptor.mipLevelCount ?? 1, "GPUDevice.createTexture", "descriptor.mipLevelCount", { min: 1, max: UINT32_MAX }),
            sampleCount: assertIntegerInRange(textureDescriptor.sampleCount ?? 1, "GPUDevice.createTexture", "descriptor.sampleCount", { min: 1, max: UINT32_MAX }),
            viewFormats: Array.isArray(textureDescriptor.viewFormats) ? textureDescriptor.viewFormats : [],
        });
        const native = wgpu.symbols.wgpuDeviceCreateTexture(assertLiveResource(device, "GPUDevice.createTexture", "GPUDevice"), desc);
        void _refs;
        return native;
    },
    deviceCreateSampler(device, descriptor) {
        const { desc, _refs } = buildSamplerDescriptor(descriptor);
        const native = wgpu.symbols.wgpuDeviceCreateSampler(assertLiveResource(device, "GPUDevice.createSampler", "GPUDevice"), desc);
        void _refs;
        return native;
    },
    deviceCreateRenderPipeline(device, descriptor) {
        const { desc, _refs } = buildRenderPipelineDescriptor({
            layout: descriptor.layout,
            vertexModule: descriptor.vertexModule,
            vertexEntryPoint: descriptor.vertexEntryPoint,
            vertexBuffers: descriptor.vertexBuffers ?? [],
            vertexConstants: descriptor.vertexConstants ?? null,
            fragmentModule: descriptor.fragmentModule,
            fragmentEntryPoint: descriptor.fragmentEntryPoint,
            fragmentConstants: descriptor.fragmentConstants ?? null,
            colorFormat: descriptor.colorFormat,
            fragmentTarget: descriptor.fragmentTarget ?? { format: descriptor.colorFormat },
            primitive: descriptor.primitive ?? null,
            depthStencil: descriptor.depthStencil ?? null,
            multisample: descriptor.multisample ?? null,
        });
        let native;
        try {
            native = wgpu.symbols.wgpuDeviceCreateRenderPipeline(
                assertLiveResource(device, "GPUDevice.createRenderPipeline", "GPUDevice"),
                desc,
            );
        } catch (error) {
            throw pipelineErrorFromError(error, "GPUDevice.createRenderPipeline", readLastErrorFields());
        }
        void _refs;
        if (!native) {
            throw pipelineErrorFromMessage("GPUDevice.createRenderPipeline", nativeFailureMessage("createRenderPipeline failed"), readLastErrorFields());
        }
        return native;
    },
    deviceCreateQuerySet(device, descriptor) {
        const QUERY_TYPE_OCCLUSION = 1;
        const QUERY_TYPE_TIMESTAMP = 2;
        const fn = wgpu.symbols.doeNativeDeviceCreateQuerySet;
        if (typeof fn !== "function") {
            throw new Error("[doe-gpu] doeNativeDeviceCreateQuerySet not available");
        }
        const native = fn(
            assertLiveResource(device, "GPUDevice.createQuerySet", "GPUDevice"),
            descriptor.type === "occlusion" ? QUERY_TYPE_OCCLUSION : QUERY_TYPE_TIMESTAMP,
            descriptor.count,
        );
        if (!native) throw new Error("[doe-gpu] createQuerySet failed");
        return native;
    },
    querySetDestroy(native) {
        if (typeof wgpu.symbols.doeNativeQuerySetDestroy === "function") {
            wgpu.symbols.doeNativeQuerySetDestroy(native);
        }
    },
    commandEncoderPushDebugGroup(encoder, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuCommandEncoderPushDebugGroup(
            assertLiveResource(encoder, "GPUCommandEncoder.pushDebugGroup", "GPUCommandEncoder"),
            bytes,
            BigInt(len),
        );
    },
    commandEncoderPopDebugGroup(encoder) {
        wgpu.symbols.wgpuCommandEncoderPopDebugGroup(
            assertLiveResource(encoder, "GPUCommandEncoder.popDebugGroup", "GPUCommandEncoder"),
        );
    },
    commandEncoderInsertDebugMarker(encoder, label) {
        const { bytes, len } = encodeStringView(label);
        wgpu.symbols.wgpuCommandEncoderInsertDebugMarker(
            assertLiveResource(encoder, "GPUCommandEncoder.insertDebugMarker", "GPUCommandEncoder"),
            bytes,
            BigInt(len),
        );
    },
    deviceCreateCommandEncoder(device) {
        return new DoeGPUCommandEncoder(null, device);
    },
    deviceGetLost(wrapper, native) {
        if (!wrapper._lostRegistrationAttempted) {
            ensureBunDeviceLostRegistration(wrapper, native);
        }
        return wrapper._lost;
    },
    deviceGetAdapterInfo(wrapper, _native) {
        return wrapper._adapterInfo ?? EMPTY_ADAPTER_INFO;
    },
    devicePushErrorScope(_wrapper, native, _filter, encodedFilter) {
        const pushErrorScope = wgpu?.symbols?.doeNativeDevicePushErrorScope;
        if (typeof pushErrorScope !== "function") {
            return;
        }
        pushErrorScope(native, encodedFilter);
    },
    devicePopErrorScope(_wrapper, native) {
        if (typeof wgpu?.symbols?.doeNativeDevicePopErrorScope !== "function") {
            return Promise.resolve(null);
        }
        return Promise.resolve(popDeviceErrorScope(native));
    },
    deviceGetOnUncapturedError(wrapper, _native) {
        return wrapper._onuncapturederror ?? null;
    },
    deviceSetOnUncapturedError(wrapper, native, handler) {
        setBunDeviceUncapturedErrorHandler(wrapper, native, handler);
    },
    deviceDestroy(native) {
        wgpu.symbols.wgpuDeviceRelease(native);
    },
    adapterGetInfo(_adapter, native) {
        return readAdapterInfo(native);
    },
    adapterRequestDevice(adapter, _descriptor, classes) {
        const descriptor = _descriptor ?? undefined;
        const native = requestDeviceSync(
            adapter._instance,
            assertLiveResource(adapter, "GPUAdapter.requestDevice", "GPUAdapter"),
            descriptor,
        );
        const device = new classes.DoeGPUDevice(native, adapter._instance);
        device._adapter = adapter;
        device._lostSupported = false;
        device._lostRegistrationAttempted = false;
        device._lostCallback = null;
        device._errorScopes = [];
        device._uncapturedErrorCallback = null;
        device.label = descriptor?.label ?? "";
        if (device.queue) {
            device.queue.label = descriptor?.defaultQueue?.label ?? "";
        }
        return device;
    },
    adapterDestroy(native) {
        wgpu.symbols.wgpuAdapterRelease(native);
    },
    gpuRequestAdapter(gpu, options, classes) {
        const adapter = requestAdapterSync(gpu._instance, options);
        return new classes.DoeGPUAdapter(adapter, gpu._instance);
    },
};

const {
    DoeGPUBuffer,
    DoeGPUQueue,
    DoeGPUTexture,
    DoeGPUTextureView,
    DoeGPUSampler,
    DoeGPURenderPipeline,
    DoeGPUShaderModule,
    DoeGPUComputePipeline,
    DoeGPUBindGroupLayout,
    DoeGPUBindGroup,
    DoeGPUPipelineLayout,
    DoeGPUDevice,
    DoeGPUAdapter,
    DoeGPU,
} = createFullSurfaceClasses({
    globals,
    backend: fullSurfaceBackend,
    encoderClasses: { DoeGPURenderBundleEncoder, DoeGPURenderBundle },
});

// ---------------------------------------------------------------------------
// Library initialization
// ---------------------------------------------------------------------------

let libraryLoaded = false;

function ensureLibrary() {
    if (libraryLoaded) return;
    if (!DOE_LIB_PATH) {
        throw new Error(
            "doe-gpu: libwebgpu_doe not found. Install the matching doe-gpu optional platform package, or build it with `cd runtime/zig && zig build dropin`, or set DOE_WEBGPU_LIB."
        );
    }
    wgpu = openLibrary(DOE_LIB_PATH);
    if (typeof wgpu.symbols.doeNativePackagePipelineCacheFlush === "function") {
        process.on("exit", () => {
            try {
                wgpu.symbols.doeNativePackagePipelineCacheFlush();
            } catch (_error) {
            }
        });
    }
    libraryLoaded = true;
}

// ---------------------------------------------------------------------------
// Public API — matches index.js exports exactly
// ---------------------------------------------------------------------------

export function create(createArgs = null) {
    ensureLibrary();
    const instance = wgpu.symbols.wgpuCreateInstance(null);
    return new DoeGPU(instance);
}

export function createInstance(createArgs = null) {
    return create(createArgs);
}

export function setupGlobals(target = globalThis, createArgs = null) {
    const gpu = create(createArgs);
    return setupGlobalsOnTarget(target, gpu, WEBGPU_GLOBALS);
}

export async function requestAdapter(adapterOptions = undefined, createArgs = null) {
    return requestAdapterFromCreate(create, adapterOptions, createArgs);
}

export async function requestDevice(options = {}) {
    return requestDeviceFromRequestAdapter(requestAdapter, options);
}

export function providerInfo() {
    const flavor = DOE_LIBRARY_FLAVOR;
    const nativeFastPaths = nativeFastPathInfoFromSymbols();
    return buildProviderInfo({
        loaded: !!DOE_LIB_PATH,
        loadError: !DOE_LIB_PATH ? "libwebgpu_doe not found" : "",
        defaultCreateArgs: [],
        doeNative: flavor === "doe-dropin",
        libraryFlavor: flavor,
        doeLibraryPath: DOE_LIB_PATH ?? "",
        buildMetadataSource: DOE_BUILD_METADATA.source,
        buildMetadataPath: DOE_BUILD_METADATA.path,
        leanVerifiedBuild: DOE_BUILD_METADATA.leanVerifiedBuild,
        proofArtifactSha256: DOE_BUILD_METADATA.proofArtifactSha256,
        nativeFastPaths,
    });
}

export function nativeFastPathInfo() {
    return nativeFastPathInfoFromSymbols();
}

function commandNativePointer(value, path, label) {
    if (value === null || value === undefined || value === 0 || value === 0n) {
        return 0n;
    }
    if (typeof value === "object" || typeof value === "function") {
        return hotU64(assertLiveResource(value, path, label));
    }
    return hotU64(value);
}

export function prewarmPreparedDispatches(queue, dispatchCommands) {
    ensureLibrary();
    const commands = Array.isArray(dispatchCommands) ? dispatchCommands : [];
    const prewarm = wgpu?.symbols?.doeNativeComputePrewarmDispatchBindings;
    if (typeof prewarm !== "function") {
        return { available: false, requestedCount: commands.length, preparedCount: 0 };
    }
    const queueNative = assertLiveResource(queue, "prewarmPreparedDispatches", "GPUQueue");
    if (commands.length === 0) {
        return { available: true, requestedCount: 0, preparedCount: 0 };
    }
    const scratch = ensureDispatchBatchScratch(queue, commands.length);
    const { pipelines, bindGroups, bindGroupCounts } = scratch;
    for (let i = 0; i < commands.length; i += 1) {
        const cmd = commands[i];
        pipelines[i] = cmd?.t === 0
            ? commandNativePointer(cmd.p, "prewarmPreparedDispatches.pipeline", "GPUComputePipeline")
            : 0n;
        const bgCount = cmd?.t === 0 ? bunCommandBindGroupCount(cmd) : 0;
        bindGroupCounts[i] = bgCount;
        for (let j = 0; j < bgCount; j += 1) {
            bindGroups[(i * MAX_COMPUTE_BIND_GROUPS) + j] = commandNativePointer(
                bunCommandBindGroupAt(cmd, j),
                "prewarmPreparedDispatches.bindGroup",
                "GPUBindGroup",
            );
        }
    }
    return {
        available: true,
        requestedCount: commands.length,
        preparedCount: Number(prewarm(
            queueNative,
            hotU64(commands.length),
            pipelines,
            bindGroups,
            bindGroupCounts,
        )) || 0,
    };
}

export { createDoeRuntime, runDawnVsDoeCompare };
export { preflightShaderSource };
export { fastPathStats };
export {
    CANVAS_ALPHA_MODES,
    CANVAS_TONE_MAPPING_MODES,
    CANVAS_COLOR_SPACES,
    normalizeOrigin2D,
    normalizeCanvasConfiguration,
    createBrowserSurfaceClasses,
    createNativeBrowserCanvasBackend,
};

export function setNativeTimeoutMs(timeoutMs) {
    validatePositiveInteger(timeoutMs, 'native timeout');
    processEventsTimeoutNs = timeoutMs * 1_000_000;
}

export default {
    CANVAS_ALPHA_MODES,
    CANVAS_TONE_MAPPING_MODES,
    CANVAS_COLOR_SPACES,
    create,
    createInstance,
    createBrowserSurfaceClasses,
    createNativeBrowserCanvasBackend,
    globals,
    normalizeCanvasConfiguration,
    normalizeOrigin2D,
    setupGlobals,
    requestAdapter,
    requestDevice,
    providerInfo,
    nativeFastPathInfo,
    prewarmPreparedDispatches,
    nativeQueueSyncInfo,
    nativePipelineCacheInfo,
    packagePipelineCacheFlush,
    preflightShaderSource,
    setNativeTimeoutMs,
    createDoeRuntime,
    runDawnVsDoeCompare,
    fastPathStats,
};
