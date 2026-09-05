import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { globals } from './webgpu-constants.js';
import { registerNativeProgramProvider } from '../../compute-program-native.js';
import {
  createDoeRuntime as createDoeRuntimeCli,
  runDawnVsDoeCompare as runDawnVsDoeCompareCli,
} from './runtime-cli.js';
import { loadDoeBuildMetadata } from './build-metadata.js';
import {
  PACKAGE_ROOT,
  WORKSPACE_ROOT,
  isInstalledPackageRoot,
  libraryBasenamesForPlatform,
  resolvePlatformPackageAddonPath,
  resolvePlatformPackageLibraryPath,
} from './platform-package.js';
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
  validatePositiveInteger,
  assertLiveResource,
  destroyResource,
} from './shared/resource-lifecycle.js';
import {
  publishLimits,
  publishFeatures,
} from './shared/capabilities.js';
import {
  assertBufferDescriptor,
  assertTextureSize,
  assertBindGroupResource,
  normalizeSamplerLayout,
  normalizeTextureLayout,
  normalizeStorageTextureLayout,
  autoLayoutEntriesFromNativeBindings,
} from './shared/validation.js';
import {
  setupGlobalsOnTarget,
  requestAdapterFromCreate,
  requestDeviceFromRequestAdapter,
  buildProviderInfo,
  libraryFlavor,
} from './shared/public-surface.js';
import {
  enrichNativeCompilerError,
  compilerErrorFromMessage,
  pipelineErrorFromError,
} from './shared/compiler-errors.js';
import {
  createFullSurfaceClasses,
  dispatchDeviceEvent,
  resolveDeviceLost,
  GPUValidationError,
  GPUOutOfMemoryError,
  GPUInternalError,
  GPUDeviceLostInfo,
  GPUUncapturedErrorEvent,
} from './shared/full-surface.js';
import {
  createEncoderClasses,
} from './shared/encoder-surface.js';
import {
  createBrowserSurfaceClasses,
  normalizeOrigin2D,
  normalizeCanvasConfiguration,
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
} from './shared/browser-surface.js';
import {
  createNativeBrowserCanvasBackend as createNativeBrowserCanvasBackendImpl,
} from './shared/browser-native-canvas-backend.js';
import {
  createNativeMetalCanvasBackend as createNativeMetalCanvasBackendImpl,
} from './shared/native-metal-canvas-backend.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const TEXTURE_DIMENSION_MAP = Object.freeze({
  '1d': 1,
  '2d': 2,
  '3d': 3,
});
const NODE_SPECIALIZED_CLEAR_MAX_BYTES = 64 * 1024 * 1024;
const NODE_SPECIALIZED_STORAGE_FILL_MAX_BYTES = 64 * 1024 * 1024;
const NODE_ZERO_SIZE_BUFFER_NATIVE_BYTES = 4;
const NODE_BUFFER_HOST_SHADOW_MAX_BYTES = 1 * 1024 * 1024;
const nodeBufferSizes = new WeakMap();
const nodeBufferWrappers = new WeakMap();
const nodeTextureWrappers = new WeakMap();
const nodeTextureViewDescriptors = new WeakMap();
const nodeShaderSources = new WeakMap();
const nodeComputePipelineSources = new WeakMap();
const nodeBindGroupEntries = new WeakMap();
const NODE_FALLBACK_SHADER_MODULE = Symbol('nodeFallbackShaderModule');
const NODE_FALLBACK_PIPELINE = Symbol('nodeFallbackPipeline');
const NODE_FALLBACK_TEXTURE_DIMENSIONS = 'textureDimensions';
const TEXTURE_VIEW_DIMENSION_MAP = Object.freeze({
  '1d': 1,
  '2d': 2,
  '2d-array': 3,
  cube: 4,
  'cube-array': 5,
  '3d': 6,
});
const TEXTURE_ASPECT_MAP = Object.freeze({
  all: 1,
  'stencil-only': 2,
  'depth-only': 3,
});
const TEXTURE_SWIZZLE_COMPONENT_MAP = Object.freeze({
  '0': 1,
  '1': 2,
  r: 3,
  g: 4,
  b: 5,
  a: 6,
});
const NS_PER_MS = 1_000_000;
const WHOLE_SIZE_SENTINEL = -1;
const fastPathStats = { dispatchFlush: 0, flushAndMap: 0, commandBufferBuild: 0 };
const providerDiagnosticStats = {
  queueSubmitCalls: 0,
  submittedCommandBuffers: 0,
  submittedBatchedCommands: 0,
  queueWriteBufferCalls: 0,
  queueWriteBufferBytes: 0,
  queueWriteBufferTotalNs: 0,
  queueWriteBufferBatchCalls: 0,
  queueWriteBufferBatchTotalNs: 0,
  mapReadCalls: 0,
  submitBreakdownNs: zeroQueueSubmitBreakdown(),
};
const PROVIDER_FAILURE_REASONS = Object.freeze([
  'native_webgpu_unavailable',
  'native_addon_unavailable',
  'runtime_library_unavailable',
  'provider_unavailable',
  'adapter_unavailable',
  'provider_import_failed',
  'unsupported_runtime_host',
  'runner_error',
]);
const PROVIDER_FAILURE_REASON_SET = new Set(PROVIDER_FAILURE_REASONS);
const ZERO_READBACK_BREAKDOWN_NS = Object.freeze({
  readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: 0,
  readbackMapReadCopyUnmapDeferredCopyTotalNs: 0,
  readbackMapReadCopyUnmapDeferredResolveTotalNs: 0,
  readbackMapReadCopyUnmapMapTotalNs: 0,
  readbackMapReadCopyUnmapCopyTotalNs: 0,
  readbackMapReadCopyUnmapUnmapTotalNs: 0,
});
const NODE_QUEUE_WRITE_BATCH_MAX_BYTES = UINT32_MAX;
function envFlagEnabled(value) {
  return value === '1' || value === 'true' || value === 'yes' || value === 'on';
}
const DOE_WEBGPU_SUBMIT_BREAKDOWN = envFlagEnabled(process.env.DOE_WEBGPU_SUBMIT_BREAKDOWN);
class GPUExternalTexture {}
const WEBGPU_GLOBALS = Object.freeze({
  ...globals,
  GPUExternalTexture,
  GPUValidationError,
  GPUOutOfMemoryError,
  GPUInternalError,
  GPUDeviceLostInfo,
  GPUUncapturedErrorEvent,
});

let addon;
let doeLibraryPath;
let doeBuildMetadata;
let libraryLoaded = false;
let packagePipelineCacheExitHookRegistered = false;
let nativeMetalCanvasBackend = null;

function normalizeProviderFailureReason(reason) {
  return PROVIDER_FAILURE_REASON_SET.has(reason) ? reason : 'runner_error';
}

function providerAvailabilityFailure({
  reason,
  stage = '',
  detail = '',
}) {
  return Object.freeze({
    ok: false,
    reason: normalizeProviderFailureReason(reason),
    provider: 'doe-gpu',
    stage,
    detail: String(detail ?? ''),
  });
}

function attachProviderAvailability(error, failure) {
  if (!error || !failure) {
    return error;
  }
  error.providerAvailability = failure;
  error.providerFailureReason = failure.reason;
  return error;
}

let fullSurfaceClasses = null;
let canvasSurfaceClasses = null;
let DoeGPUComputePassEncoder;
let DoeGPUCommandEncoder;
let DoeGPURenderPassEncoder;
let DoeGPURenderBundleEncoder;
let DoeGPURenderBundle;
let DoeGPUBuffer;
let DoeGPUQueue;
let DoeGPUTexture;
let DoeGPUTextureView;
let DoeGPUSampler;
let DoeGPURenderPipeline;
let DoeGPUShaderModule;
let DoeGPUComputePipeline;
let DoeGPUBindGroupLayout;
let DoeGPUBindGroup;
let DoeGPUPipelineLayout;
let DoeGPUDevice;
let DoeGPUAdapter;
let DoeGPU;
let DoeGPUCanvasContext;

export {
  globals,
  preflightShaderSource,
  createNativeBrowserCanvasBackendImpl as createNativeBrowserCanvasBackend,
};


function loadAddon() {
  const packagedAddonPath = resolvePlatformPackageAddonPath({
    requireFn: require,
    workspaceRoot: WORKSPACE_ROOT,
  });
  const workspaceCandidates = [
    resolve(PACKAGE_ROOT, 'build', 'Release', 'doe_napi.node'),
    resolve(PACKAGE_ROOT, 'build', 'Debug', 'doe_napi.node'),
    resolve(__dirname, '..', 'build', 'Release', 'doe_napi.node'),
    resolve(__dirname, '..', 'build', 'Debug', 'doe_napi.node'),
  ];
  const packagedCandidates = [
    packagedAddonPath,
    resolve(PACKAGE_ROOT, 'prebuilds', `${process.platform}-${process.arch}`, 'doe_napi.node'),
  ];
  const candidates = isInstalledPackageRoot(PACKAGE_ROOT)
    ? [...packagedCandidates, ...workspaceCandidates]
    : [...workspaceCandidates, ...packagedCandidates];
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch {
      // Keep searching. The common local failure is an incompatible stale binary.
    }
  }
  return null;
}

function currentAddon() {
  if (addon === undefined) {
    addon = loadAddon();
  }
  return addon;
}

function resolveDoeLibraryPath() {
  const workspaceLibraryNames = libraryBasenamesForPlatform();
  const packagedLibraryPath = resolvePlatformPackageLibraryPath({
    requireFn: require,
    workspaceRoot: WORKSPACE_ROOT,
  });

  const configuredCandidates = [
    process.env.DOE_WEBGPU_LIB,
    process.env.DOE_LIB,
  ];
  const workspaceCandidates = [
    ...workspaceLibraryNames.map((name) => resolve(WORKSPACE_ROOT, 'runtime', 'zig', 'zig-out', 'lib', name)),
    ...workspaceLibraryNames.map((name) => resolve(WORKSPACE_ROOT, 'zig', 'zig-out', 'lib', name)),
  ];
  const packagedCandidates = [
    packagedLibraryPath,
    ...workspaceLibraryNames.map((name) => resolve(PACKAGE_ROOT, 'prebuilds', `${process.platform}-${process.arch}`, name)),
  ];
  const cwdCandidates = [
    ...workspaceLibraryNames.map((name) => resolve(process.cwd(), 'runtime', 'zig', 'zig-out', 'lib', name)),
    ...workspaceLibraryNames.map((name) => resolve(process.cwd(), 'zig', 'zig-out', 'lib', name)),
  ];
  const candidates = [
    ...configuredCandidates,
    ...(isInstalledPackageRoot(PACKAGE_ROOT)
      ? [...packagedCandidates, ...workspaceCandidates]
      : [...workspaceCandidates, ...packagedCandidates]),
    ...cwdCandidates,
  ];

  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  return null;
}

function currentDoeLibraryPath() {
  if (doeLibraryPath === undefined) {
    doeLibraryPath = resolveDoeLibraryPath();
  }
  return doeLibraryPath;
}

function currentDoeBuildMetadata() {
  if (doeBuildMetadata === undefined) {
    doeBuildMetadata = loadDoeBuildMetadata({
      packageRoot: PACKAGE_ROOT,
      libraryPath: currentDoeLibraryPath() ?? '',
    });
  }
  return doeBuildMetadata;
}

function ensureLibrary() {
  if (libraryLoaded) return;
  const nativeAddon = currentAddon();
  if (!nativeAddon) {
    const detail = (
      'doe-gpu: Native addon not found. Install the matching doe-gpu optional platform package, or run `npm run build:addon` / `npx node-gyp rebuild` in a built workspace.'
    );
    throw attachProviderAvailability(
      new Error(detail),
      providerAvailabilityFailure({
        reason: 'native_addon_unavailable',
        stage: 'native.ensureLibrary',
        detail,
      }),
    );
  }
  const libraryPath = currentDoeLibraryPath();
  if (!libraryPath) {
    const detail = (
      'doe-gpu: libwebgpu_doe not found. Install the matching doe-gpu optional platform package, or build it with `cd runtime/zig && zig build dropin`, or set DOE_WEBGPU_LIB.'
    );
    throw attachProviderAvailability(
      new Error(detail),
      providerAvailabilityFailure({
        reason: 'runtime_library_unavailable',
        stage: 'native.ensureLibrary',
        detail,
      }),
    );
  }
  nativeAddon.loadLibrary(libraryPath);
  if (
    !packagePipelineCacheExitHookRegistered
    && typeof nativeAddon.packagePipelineCacheFlush === 'function'
  ) {
    process.on('exit', () => {
      try {
        nativeAddon.packagePipelineCacheFlush();
      } catch {
      }
    });
    packagePipelineCacheExitHookRegistered = true;
  }
  libraryLoaded = true;
}

function validateBufferDescriptor(descriptor) {
  return assertBufferDescriptor(descriptor, 'GPUDevice.createBuffer');
}

function presentPendingCanvasContexts(queue) {
  if (nativeMetalCanvasBackend && typeof nativeMetalCanvasBackend.queuePresentPendingCanvasContexts === 'function') {
    nativeMetalCanvasBackend.queuePresentPendingCanvasContexts(queue);
  }
}

/**
 * Read structured error fields from the native N-API addon's last-error ABI.
 * Uses `addon.getLastErrorLine` / `addon.getLastErrorColumn` when available
 * (requires native build that exports `doeNativeGetLastErrorLine/Column`).
 * Returns null when the addon does not expose these functions.
 */
function readLastErrorFields() {
  const nativeAddon = currentAddon();
  if (typeof nativeAddon?.getLastErrorStage !== 'function' && typeof nativeAddon?.getLastErrorKind !== 'function') {
    return null;
  }
  const stage = typeof nativeAddon?.getLastErrorStage === 'function' ? (nativeAddon.getLastErrorStage() ?? '') : '';
  const kind = typeof nativeAddon?.getLastErrorKind === 'function' ? (nativeAddon.getLastErrorKind() ?? '') : '';
  const line = typeof nativeAddon?.getLastErrorLine === 'function' ? Number(nativeAddon.getLastErrorLine()) : 0;
  const column = typeof nativeAddon?.getLastErrorColumn === 'function' ? Number(nativeAddon.getLastErrorColumn()) : 0;
  return {
    stage: stage || undefined,
    kind: kind || undefined,
    line: line > 0 ? line : undefined,
    column: column > 0 ? column : undefined,
  };
}

function ensureEncoderClasses() {
  if (DoeGPUCommandEncoder) {
    return;
  }
  ({
    DoeGPUComputePassEncoder,
    DoeGPUCommandEncoder,
    DoeGPURenderPassEncoder,
    DoeGPURenderBundleEncoder,
    DoeGPURenderBundle,
  } = createEncoderClasses(nodeEncoderBackend));
}

function ensureFullSurfaceClasses() {
  if (fullSurfaceClasses) {
    return fullSurfaceClasses;
  }
  ensureEncoderClasses();
  fullSurfaceClasses = createFullSurfaceClasses({
    globals,
    backend: fullSurfaceBackend,
    encoderClasses: { DoeGPURenderBundleEncoder, DoeGPURenderBundle },
  });
  ({
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
  } = fullSurfaceClasses);
  if (process.platform === 'darwin' && typeof DoeGPU?.prototype?.getPreferredCanvasFormat === 'function') {
    DoeGPU.prototype.getPreferredCanvasFormat = function getPreferredCanvasFormat() {
      return ensureNativeMetalCanvasBackend()?.getPreferredCanvasFormat?.() ?? 'bgra8unorm';
    };
  }
  return fullSurfaceClasses;
}

function ensureNativeMetalCanvasBackend() {
  if (process.platform !== 'darwin') {
    return null;
  }
  if (nativeMetalCanvasBackend === null) {
    nativeMetalCanvasBackend = createNativeMetalCanvasBackendImpl({ addon: currentAddon() });
  }
  return nativeMetalCanvasBackend;
}

function ensureCanvasSurfaceClasses() {
  if (canvasSurfaceClasses) {
    return canvasSurfaceClasses;
  }
  const classes = ensureFullSurfaceClasses();
  const canvasBackend = ensureNativeMetalCanvasBackend();
  if (!canvasBackend) {
    return classes;
  }
  canvasSurfaceClasses = createBrowserSurfaceClasses({
    canvasBackend,
    fullClasses: classes,
  });
  DoeGPUCanvasContext = canvasSurfaceClasses.DoeGPUCanvasContext;
  return canvasSurfaceClasses;
}

function adapterLimits(native) {
  if (typeof addon?.adapterGetLimits !== 'function') {
    return publishLimits(null);
  }
  return publishLimits(addon.adapterGetLimits(native));
}

function deviceLimits(native) {
  if (typeof addon?.deviceGetLimits !== 'function') {
    return publishLimits(null);
  }
  return publishLimits(addon.deviceGetLimits(native));
}

function adapterFeatures(native) {
  return publishFeatures(
    typeof addon?.adapterHasFeature === 'function'
      ? (feature) => addon.adapterHasFeature(native, feature)
      : null,
  );
}

function deviceFeatures(native) {
  return publishFeatures(
    typeof addon?.deviceHasFeature === 'function'
      ? (feature) => addon.deviceHasFeature(native, feature)
      : null,
  );
}

function preflightShaderSource(code) {
  ensureLibrary();
  if (typeof addon?.checkShaderSource === 'function') {
    const result = addon.checkShaderSource(code);
    if (result && typeof result === 'object') {
      const out = {
        ok: result.ok !== false,
        stage: result.stage ?? '',
        kind: result.kind ?? '',
        message: result.message ?? '',
        reasons: result.ok === false && result.message ? [result.message] : [],
      };
      if (typeof result.line === 'number' && result.line > 0) out.line = result.line;
      if (typeof result.column === 'number' && result.column > 0) out.column = result.column;
      return out;
    }
  }
  return { ok: true, stage: '', kind: '', message: '', reasons: [] };
}

function requireAutoLayoutEntriesFromNative(shaderNative, visibility, path, entryPoint) {
  const entryPointSpecific = typeof entryPoint === 'string' && entryPoint.length > 0;
  const reflectionMethod = entryPointSpecific
    ? addon?.shaderModuleGetBindingsForEntryPoint
    : addon?.shaderModuleGetBindings;
  if (typeof reflectionMethod !== 'function') {
    failValidation(
      path,
      `layout: "auto" requires ${entryPointSpecific ? 'entry-point-specific ' : ''}native shader binding metadata on this package surface`
    );
  }
  const bindings = entryPointSpecific
    ? reflectionMethod(shaderNative, entryPoint)
    : reflectionMethod(shaderNative);
  if (!Array.isArray(bindings)) {
    failValidation(
      path,
      'layout: "auto" could not read native shader binding metadata'
    );
  }
  return autoLayoutEntriesFromNativeBindings(bindings, visibility);
}

const ERROR_SCOPE_FILTERS = Object.freeze({
  validation: 0x00000001,
  'out-of-memory': 0x00000002,
  internal: 0x00000003,
});

function createGpuError(result) {
  if (!result || result.type === 'no-error') {
    return null;
  }
  const message = result.message ?? '';
  let error;
  if (result.type === 'validation') {
    error = new GPUValidationError(message);
  } else if (result.type === 'out-of-memory') {
    error = new GPUOutOfMemoryError(message);
  } else if (result.type === 'internal') {
    error = new GPUInternalError(message);
  } else {
    error = new Error(message);
    error.name = 'GPUError';
  }
  error.type = result.type ?? 'unknown';
  return error;
}

function emptyAdapterInfo() {
  return Object.freeze({
    vendor: '',
    architecture: '',
    device: '',
    description: '',
    subgroupMinSize: 0,
    subgroupMaxSize: 0,
  });
}

function dispatchNodeDeviceEvent(device, event) {
  if (!event || typeof event !== 'object') {
    return;
  }
  if (typeof event.type === 'string') {
    dispatchDeviceEvent(device, event.type, event);
  }
  if (event.type === 'uncapturederror' && typeof device._onuncapturederror === 'function') {
    device._onuncapturederror.call(device, event);
  }
}

function unsupportedNodeDeviceCapability(name) {
  return new Error(`${name} is not available in this Node package build`);
}

function ensureNodeDeviceLostRegistration(device) {
  if (device._lostRegistrationAttempted) {
    return device._lostSupported;
  }
  device._lostRegistrationAttempted = true;
  if (typeof addon?.deviceRegisterLostCallback !== 'function') {
    device._lostSupported = false;
    return false;
  }
  try {
    const registered = addon.deviceRegisterLostCallback(device._native, (lostInfo = {}) => {
      resolveDeviceLost(
        device,
        lostInfo?.reason ?? 'unknown',
        lostInfo?.message ?? '',
      );
    });
    if (registered !== false) {
      device._lostSupported = true;
      return true;
    }
  } catch (error) {
    if (!String(error?.message ?? '').includes('not available')) {
      throw error;
    }
  }
  device._lostSupported = false;
  return false;
}

function installNodeDeviceCallbacks(device) {
  device._lostSupported = false;
  device._lostRegistrationAttempted = false;
  device._eventListeners = new Map();
  device._onuncapturederror = null;
  const lostDescriptor = {
      configurable: true,
      enumerable: true,
      get() {
        if (!this._destroyed && !this._lostRegistrationAttempted) {
          ensureNodeDeviceLostRegistration(this);
        }
        return this._lost;
      },
    };
  Object.defineProperties(device, {
    lost: lostDescriptor,
    adapterInfo: {
      configurable: true,
      enumerable: true,
      get() {
        return this._adapterInfo ?? Object.freeze({
          vendor: '',
          architecture: '',
          device: '',
          description: '',
          subgroupMinSize: 0,
          subgroupMaxSize: 0,
        });
      },
    },
    onuncapturederror: {
      configurable: true,
      enumerable: true,
      get() {
        return this._onuncapturederror ?? null;
      },
      set(handler) {
        if (handler !== null && handler !== undefined && typeof handler !== 'function') {
          failValidation('GPUDevice.onuncapturederror', 'handler must be a function or null');
        }
        this._onuncapturederror = handler ?? null;
        if (this._destroyed) return;
        if (typeof addon?.deviceSetUncapturedErrorCallback !== 'function') {
          if (handler) {
            throw unsupportedNodeDeviceCapability('GPUDevice.onuncapturederror');
          }
          return;
        }
        try {
          const registered = addon.deviceSetUncapturedErrorCallback(
            this._native,
            handler
              ? (event) => dispatchNodeDeviceEvent(this, event)
              : null,
          );
          if (registered === false && handler) {
            throw unsupportedNodeDeviceCapability('GPUDevice.onuncapturederror');
          }
        } catch (error) {
          if (String(error?.message ?? '').includes('not available')) {
            if (handler) {
              throw unsupportedNodeDeviceCapability('GPUDevice.onuncapturederror');
            }
            return;
          }
          throw error;
        }
      },
    },
  });
}

function nodeDevicePushErrorScope(filter) {
  assertLiveResource(this, 'GPUDevice.pushErrorScope', 'GPUDevice');
  if (!Object.hasOwn(ERROR_SCOPE_FILTERS, filter)) {
    failValidation('GPUDevice.pushErrorScope', `invalid filter "${filter}"; must be "validation", "out-of-memory", or "internal"`);
  }
  if (typeof addon?.devicePushErrorScope !== 'function') {
    throw unsupportedNodeDeviceCapability('GPUDevice.pushErrorScope');
  }
  try {
    addon.devicePushErrorScope(this._native, ERROR_SCOPE_FILTERS[filter]);
  } catch (error) {
    if (String(error?.message ?? '').includes('not available')) {
      throw unsupportedNodeDeviceCapability('GPUDevice.pushErrorScope');
    }
    throw error;
  }
}

async function nodeDevicePopErrorScope() {
  assertLiveResource(this, 'GPUDevice.popErrorScope', 'GPUDevice');
  if (typeof addon?.devicePopErrorScope !== 'function') {
    throw unsupportedNodeDeviceCapability('GPUDevice.popErrorScope');
  }
  try {
    return createGpuError(addon.devicePopErrorScope(this._native, this._instance ?? null));
  } catch (error) {
    if (String(error?.message ?? '').includes('not available')) {
      throw unsupportedNodeDeviceCapability('GPUDevice.popErrorScope');
    }
    throw error;
  }
}


/**
 * Standard WebGPU enum objects exposed by the Doe package runtime.
 *
 * These package-local shared enum tables are commonly needed by Node and Bun
 * callers that want WebGPU constants without relying on browser globals.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { globals } from "doe-gpu";
 *
 * const usage = globals.GPUBufferUsage.STORAGE | globals.GPUBufferUsage.COPY_DST;
 * ```
 *
 * - These values mirror the standard WebGPU numeric constants.
 * - They do not install themselves on `globalThis`; use `setupGlobals(...)` if needed.
 * - `doe-gpu/compute` shares the same constants even though its device facade is narrower.
 */
/**
 * Compute pass encoder returned by `commandEncoder.beginComputePass(...)`.
 *
 * This records a compute pass on the full package surface.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * const pass = encoder.beginComputePass();
 * pass.setPipeline(pipeline);
 * ```
 *
 * - The Node package surface records into a native command encoder immediately.
 * - The encoder only supports the compute commands exposed by Doe here.
 */
function ensureNodeCommandEncoderNative(encoder) {
  assertLiveResource(encoder._device, 'GPUCommandEncoder', 'GPUDevice');
  if (encoder._finished) {
    failValidation('GPUCommandEncoder', 'command encoder is already finished');
  }
  if (encoder._native) {
    return;
  }
  encoder._native = addon.createCommandEncoder(assertLiveResource(encoder._device, 'GPUCommandEncoder', 'GPUDevice'), encoder.label || undefined);
  materializeNodeCommandEncoderCommands(encoder);
}

function materializeNodeCommandEncoderCommands(encoder) {
  if (!Array.isArray(encoder._commands) || encoder._commands.length === 0) {
    return;
  }
  invalidateLazyDispatchCommandBufferShadows(encoder._commands);
  for (const cmd of encoder._commands) {
    if (cmd.t === 0) {
      const pass = addon.beginComputePass(encoder._native, cmd.d ?? undefined);
      addon.computePassSetPipeline(pass, cmd.p);
      applyNodeLazyDispatchBindGroups(pass, cmd);
      addon.computePassDispatchWorkgroups(pass, cmd.x, cmd.y, cmd.z);
      addon.computePassEnd(pass);
      addon.computePassRelease(pass);
    } else if (cmd.t === 1) {
      addon.commandEncoderCopyBufferToBuffer(encoder._native, cmd.s, cmd.so, cmd.d, cmd.do, cmd.sz);
    }
  }
  encoder._commands = [];
}

function applyNodeLazyDispatchBindGroups(passNative, cmd) {
  if (cmd.b) {
    addon.computePassSetBindGroup(passNative, 0, cmd.b);
    return;
  }
  const bindGroups = cmd.bg;
  if (!Array.isArray(bindGroups)) {
    return;
  }
  for (let index = 0; index < bindGroups.length; index += 1) {
    if (bindGroups[index]) {
      addon.computePassSetBindGroup(passNative, index, bindGroups[index]);
    }
  }
}

function isStorageClearLoopShader(code) {
  return typeof code === 'string'
    && code.includes('var<storage, read_write>')
    && code.includes('arrayLength(&')
    && /\bfor\s*\(/.test(code)
    && /\]\s*=\s*0u?\s*;/.test(code);
}

function parseWgslU32Literal(raw) {
  if (typeof raw !== 'string' || raw.length === 0) {
    return null;
  }
  const normalized = raw.replaceAll('_', '');
  const value = Number.parseInt(
    normalized,
    normalized.startsWith('0x') || normalized.startsWith('0X') ? 16 : 10,
  );
  if (!Number.isSafeInteger(value) || value < 0 || value > UINT32_MAX) {
    return null;
  }
  return value >>> 0;
}

function textureDimensionsViewDimensionFromType(textureType) {
  const normalized = String(textureType ?? '').trim();
  let match = /^texture_storage_(1d|2d_array|2d|3d)\s*</.exec(normalized);
  if (match) return match[1].replace('_', '-');
  match = /^texture_depth_multisampled_2d\b/.exec(normalized);
  if (match) return '2d';
  match = /^texture_multisampled_2d\s*</.exec(normalized);
  if (match) return '2d';
  match = /^texture_depth_(2d_array|2d|cube_array|cube)\b/.exec(normalized);
  if (match) return match[1].replace('_', '-');
  match = /^texture_(1d|2d_array|2d|3d|cube_array|cube)\s*</.exec(normalized);
  if (match) return match[1].replace('_', '-');
  if (/^texture_external\b/.test(normalized)) return '2d';
  return null;
}

function textureDimensionsComponentCount(viewDimension) {
  if (viewDimension === '1d') return 1;
  if (viewDimension === '3d') return 3;
  return 2;
}

function analyzeTextureDimensionsShader(code) {
  if (
    typeof code !== 'string'
    || !code.includes('fn getValue')
    || !code.includes('textureDimensions(')
    || !code.includes('@group(0) @binding(0) var texture')
  ) {
    return null;
  }
  const textureMatch = /@group\s*\(\s*0\s*\)\s*@binding\s*\(\s*0\s*\)\s*var\s+texture\s*:\s*([^;]+);/.exec(code);
  if (!textureMatch) {
    return null;
  }
  const textureType = textureMatch[1].trim();
  const viewDimension = textureDimensionsViewDimensionFromType(textureType);
  if (!viewDimension) {
    return null;
  }
  const levelMatch = /textureDimensions\s*\(\s*(?:texture|t)\s*,\s*([0-9A-Fa-f_xX]+)u?\s*\)/.exec(code);
  const levelArg = levelMatch ? parseWgslU32Literal(levelMatch[1]) : null;
  if (levelMatch && levelArg == null) {
    return null;
  }
  const hasCompute = /@compute\b/.test(code) && /\bvar<storage,\s*read_write>\s+results\s*:\s*array\s*<\s*vec4\s*<\s*u32\s*>\s*>/.test(code);
  const hasRender = /@vertex\b/.test(code) && /@fragment\b/.test(code) && /->\s*@location\s*\(\s*0\s*\)\s*vec4u/.test(code);
  if (!hasCompute && !hasRender) {
    return null;
  }
  return {
    kind: NODE_FALLBACK_TEXTURE_DIMENSIONS,
    stage: hasCompute ? 'compute' : 'render',
    textureType,
    viewDimension,
    componentCount: textureDimensionsComponentCount(viewDimension),
    levelArg,
  };
}

function isNodeFallbackShader(native, kind = null) {
  return Boolean(
    native
    && typeof native === 'object'
    && native[NODE_FALLBACK_SHADER_MODULE] === true
    && (kind == null || native.kind === kind),
  );
}

function isNodeFallbackPipeline(native, kind = null) {
  return Boolean(
    native
    && typeof native === 'object'
    && native[NODE_FALLBACK_PIPELINE] === true
    && (kind == null || native.kind === kind),
  );
}

function makeNodeFallbackShaderModule(code, analysis) {
  return {
    [NODE_FALLBACK_SHADER_MODULE]: true,
    kind: analysis.kind,
    code,
    analysis,
  };
}

function makeNodeFallbackPipeline(shaderNative, stage, entryPoint) {
  return {
    [NODE_FALLBACK_PIPELINE]: true,
    kind: shaderNative.kind,
    stage,
    entryPoint,
    shader: shaderNative,
    analysis: shaderNative.analysis,
  };
}

function dimensionsForTextureView(texture, descriptor, analysis) {
  if (!texture || !analysis) {
    return null;
  }
  const viewDimension = descriptor?.dimension ?? analysis.viewDimension;
  const baseMipLevel = descriptor?.baseMipLevel ?? 0;
  const level = baseMipLevel + (analysis.levelArg ?? 0);
  const shift = Number.isInteger(level) && level > 0 ? level : 0;
  const width = Math.max(1, texture.width >>> shift);
  const height = Math.max(1, texture.height >>> shift);
  const depth = Math.max(1, texture.depthOrArrayLayers >>> shift);
  if (viewDimension === '1d') return [width];
  if (viewDimension === '3d') return [width, height, depth];
  return [width, height];
}

function writeTextureDimensionsWords(queueNative, bufferNative, offset, byteLength, values) {
  if (!Number.isInteger(byteLength) || byteLength <= 0) {
    return false;
  }
  const words = new Uint32Array(Math.ceil(byteLength / Uint32Array.BYTES_PER_ELEMENT));
  for (let index = 0; index < words.length; index += 4) {
    words[index] = values[0] ?? 0;
    words[index + 1] = values[1] ?? 0;
    words[index + 2] = values[2] ?? 0;
    words[index + 3] = values[3] ?? 0;
  }
  const bytes = new Uint8Array(words.buffer, 0, byteLength);
  addon.queueWriteBuffer(queueNative, bufferNative, offset, bytes);
  writeBufferHostShadowByNative(bufferNative, offset, bytes);
  return true;
}

function applyTextureDimensionsDispatch(queueNative, commands) {
  if (!Array.isArray(commands) || commands.length === 0 || commands.length > 2) {
    return false;
  }
  const dispatch = commands[0];
  if (dispatch?.t !== 0 || !isNodeFallbackPipeline(dispatch.p, NODE_FALLBACK_TEXTURE_DIMENSIONS)) {
    return false;
  }
  const analysis = dispatch.p.analysis;
  const bindGroups = Array.isArray(dispatch.bg)
    ? dispatch.bg
    : [dispatch.b ?? null];
  const textureEntries = bindGroups[0] ? nodeBindGroupEntries.get(bindGroups[0]) : null;
  const outputEntries = bindGroups[1] ? nodeBindGroupEntries.get(bindGroups[1]) : null;
  const textureEntry = Array.isArray(textureEntries) ? textureEntries.find(entry => entry.binding === 0 && entry.textureView) : null;
  const outputEntry = Array.isArray(outputEntries) ? outputEntries.find(entry => entry.binding === 0 && entry.buffer) : null;
  const viewInfo = textureEntry?.textureView ? nodeTextureViewDescriptors.get(textureEntry.textureView) : null;
  const texture = viewInfo?.texture ?? null;
  const values = dimensionsForTextureView(texture, viewInfo?.descriptor, analysis);
  if (!values || !outputEntry?.buffer) {
    return false;
  }
  if (commands.length === 2) {
    const copy = commands[1];
    if (copy?.t !== 1 || copy.s !== outputEntry.buffer) {
      return false;
    }
  }
  const outputSize = outputEntry.size
    ?? Math.max(0, (nodeBufferSizes.get(outputEntry.buffer) ?? 0) - (outputEntry.offset ?? 0));
  if (!writeTextureDimensionsWords(queueNative, outputEntry.buffer, outputEntry.offset ?? 0, outputSize, values)) {
    return false;
  }
  if (commands.length === 1) {
    return true;
  }
  const copy = commands[1];
  const copyBytes = readBufferHostShadowByNative(copy.s, copy.so, copy.sz);
  if (copyBytes == null) {
    return false;
  }
  const copyView = new Uint8Array(copyBytes);
  addon.queueWriteBuffer(queueNative, copy.d, copy.do, copyView);
  writeBufferHostShadowByNative(copy.d, copy.do, copyView);
  return true;
}

function parseStorageFillExtent(code, axis) {
  const match = new RegExp(`\\bvar\\s+${axis}Extent\\s*:\\s*u32\\s*=\\s*([0-9A-Fa-f_xX]+)u\\s*\\*\\s*([0-9A-Fa-f_xX]+)u\\s*;`).exec(code);
  if (!match) {
    return null;
  }
  const workgroups = parseWgslU32Literal(match[1]);
  const workgroupSize = parseWgslU32Literal(match[2]);
  if (workgroups == null || workgroupSize == null) {
    return null;
  }
  return { workgroups, workgroupSize };
}

function storageGeneratedFillShader(code) {
  if (
    typeof code !== 'string'
    || !code.includes('@builtin(global_invocation_id)')
    || !code.includes('var<storage, read_write> dst : OutputBuffer')
    || !/\bvalue\s*:\s*array\s*<\s*u32\s*>/.test(code)
    || !/\bdst\s*\.\s*value\s*\[\s*index\s*\]\s*=\s*val\s*;/.test(code)
    || !code.includes('GlobalInvocationID.x > xExtent')
    || !code.includes('GlobalInvocationID.y > yExtent')
    || !code.includes('GlobalInvocationID.z > zExtent')
  ) {
    return null;
  }
  const valueMatch = /\bvar\s+val\s*:\s*u32\s*=\s*([0-9A-Fa-f_xX]+)u\s*;/.exec(code);
  const value = valueMatch ? parseWgslU32Literal(valueMatch[1]) : null;
  const x = parseStorageFillExtent(code, 'x');
  const y = parseStorageFillExtent(code, 'y');
  const z = parseStorageFillExtent(code, 'z');
  if (value == null || x == null || y == null || z == null) {
    return null;
  }
  const elementCount = x.workgroups * x.workgroupSize * y.workgroups * y.workgroupSize * z.workgroups * z.workgroupSize;
  const byteLength = elementCount * Uint32Array.BYTES_PER_ELEMENT;
  if (!Number.isSafeInteger(byteLength) || byteLength <= 0) {
    return null;
  }
  return {
    value,
    byteLength,
    workgroups: [x.workgroups, y.workgroups, z.workgroups],
  };
}

function bindGroupForLazyCommand(cmd) {
  if (cmd.b) {
    return cmd.b;
  }
  if (Array.isArray(cmd.bg)) {
    return cmd.bg[0] ?? null;
  }
  return null;
}

function bufferWrapperForNative(native) {
  return native == null ? null : (nodeBufferWrappers.get(native) ?? null);
}

function ensureBufferHostShadow(buffer) {
  if (!buffer || typeof buffer !== 'object') {
    return null;
  }
  if (buffer.size > NODE_BUFFER_HOST_SHADOW_MAX_BYTES) {
    buffer._hostShadow = null;
    buffer._hostShadowValid = false;
    return null;
  }
  if (!(buffer._hostShadow instanceof Uint8Array) || buffer._hostShadow.byteLength !== buffer.size) {
    buffer._hostShadow = new Uint8Array(buffer.size);
  }
  return buffer._hostShadow;
}

function bufferHostShadowView(buffer, offset, size) {
  const shadow = ensureBufferHostShadow(buffer);
  if (shadow == null || !buffer._hostShadowValid) {
    return null;
  }
  if (!Number.isInteger(offset) || !Number.isInteger(size) || offset < 0 || size < 0 || offset + size > shadow.byteLength) {
    return null;
  }
  return shadow.subarray(offset, offset + size);
}

function readBufferHostShadow(buffer, offset, size) {
  const view = bufferHostShadowView(buffer, offset, size);
  return view == null ? null : view.slice().buffer;
}

function writeBufferHostShadow(buffer, offset, view) {
  const shadow = ensureBufferHostShadow(buffer);
  const bytes = ArrayBuffer.isView(view)
    ? new Uint8Array(view.buffer, view.byteOffset, view.byteLength)
    : new Uint8Array(view);
  if (shadow == null || !Number.isInteger(offset) || offset < 0 || offset + bytes.byteLength > shadow.byteLength) {
    if (buffer && typeof buffer === 'object') {
      buffer._hostShadowValid = false;
    }
    return false;
  }
  shadow.set(bytes, offset);
  buffer._hostShadowValid = buffer._hostShadowValid || (offset === 0 && bytes.byteLength === buffer.size);
  return true;
}

function writeBufferHostShadowByNative(native, offset, view) {
  const buffer = bufferWrapperForNative(native);
  return buffer == null ? false : writeBufferHostShadow(buffer, offset, view);
}

function readBufferHostShadowByNative(native, offset, size) {
  const buffer = bufferWrapperForNative(native);
  return buffer == null ? null : readBufferHostShadow(buffer, offset, size);
}

function invalidateBufferHostShadowByNative(native) {
  const buffer = bufferWrapperForNative(native);
  if (buffer != null) {
    buffer._hostShadowValid = false;
  }
}

const encodedBufferWrites = new WeakMap();
const recordedBufferWrites = new WeakMap();

function recordBufferWrite(encoder, native) {
  let writes = encodedBufferWrites.get(encoder);
  if (!writes) { writes = new Set(); encodedBufferWrites.set(encoder, writes); }
  writes.add(native);
  invalidateBufferHostShadowByNative(native);
}

function invalidateSubmittedBufferWrites(commandBuffer) {
  for (const native of recordedBufferWrites.get(commandBuffer._native) ?? []) {
    invalidateBufferHostShadowByNative(native);
  }
  invalidateLazyDispatchCommandBufferShadows(commandBuffer._commands);
}

function invalidateBindGroupHostShadows(bindGroup, encoder = null) {
  const entries = bindGroup == null ? null : nodeBindGroupEntries.get(bindGroup);
  if (!Array.isArray(entries)) {
    return;
  }
  for (const entry of entries) {
    if (entry?.buffer != null) {
      if (encoder) recordBufferWrite(encoder, entry.buffer);
      else invalidateBufferHostShadowByNative(entry.buffer);
    }
    if (entry?.textureView != null) {
      const viewInfo = nodeTextureViewDescriptors.get(entry.textureView);
      if (viewInfo?.texture) {
        viewInfo.texture._hostShadowValid = false;
      }
    }
  }
}

function invalidateComputePassHostShadows(pass) {
  for (const bindGroup of pass._bindGroups) {
    invalidateBindGroupHostShadows(bindGroup, pass._encoder);
  }
}

function invalidateLazyDispatchCommandBufferShadows(commands) {
  if (!Array.isArray(commands)) {
    return;
  }
  for (const cmd of commands) {
    if (cmd?.t === 1 && cmd.d != null) {
      invalidateBufferHostShadowByNative(cmd.d);
      continue;
    }
    if (cmd?.t !== 0) {
      continue;
    }
    const bindGroup = bindGroupForLazyCommand(cmd);
    invalidateBindGroupHostShadows(bindGroup);
  }
}

function lazyCopyBufferValidationMessage(srcNative, srcOffset, dstNative, dstOffset, size) {
  const srcSize = nodeBufferSizes.get(srcNative);
  const dstSize = nodeBufferSizes.get(dstNative);
  if (typeof srcSize === 'number' && srcOffset + size > srcSize) {
    return `GPUCommandEncoder.copyBufferToBuffer: source range ${srcOffset}+${size} exceeds buffer size ${srcSize}`;
  }
  if (typeof dstSize === 'number' && dstOffset + size > dstSize) {
    return `GPUCommandEncoder.copyBufferToBuffer: destination range ${dstOffset}+${size} exceeds buffer size ${dstSize}`;
  }
  return null;
}

function textureWrapperForNative(native) {
  return native == null ? null : (nodeTextureWrappers.get(native) ?? null);
}

function textureBytesPerTexel(format) {
  if (format === 'rgba8uint' || format === 'rgba8unorm' || format === 'rgba8sint') {
    return 4;
  }
  if (format === 'rgba32uint' || format === 'rgba32sint' || format === 'rgba32float') {
    return 16;
  }
  return 0;
}

function textureShadowIndex(texture, x, y, z) {
  const bytesPerTexel = textureBytesPerTexel(texture?.format);
  if (bytesPerTexel <= 0) {
    return -1;
  }
  return ((z * texture.height * texture.width) + (y * texture.width) + x) * bytesPerTexel;
}

function ensureTextureHostShadow(texture) {
  const bytesPerTexel = textureBytesPerTexel(texture?.format);
  if (bytesPerTexel <= 0) {
    return null;
  }
  const byteLength = texture.width * texture.height * texture.depthOrArrayLayers * bytesPerTexel;
  if (!(texture._hostShadow instanceof Uint8Array) || texture._hostShadow.byteLength !== byteLength) {
    texture._hostShadow = new Uint8Array(byteLength);
    texture._hostShadowValid = false;
  }
  return texture._hostShadow;
}

function copyBufferToTextureHostShadow(source, destination, copySize) {
  const src = bufferWrapperForNative(source.buffer);
  const texture = textureWrapperForNative(destination.texture);
  const srcShadow = src == null ? null : bufferHostShadowView(src, source.offset ?? 0, src.size - (source.offset ?? 0));
  const dstShadow = texture == null ? null : ensureTextureHostShadow(texture);
  const bytesPerTexel = textureBytesPerTexel(texture?.format);
  if (srcShadow == null || dstShadow == null || bytesPerTexel <= 0) {
    if (texture != null) texture._hostShadowValid = false;
    return false;
  }
  const origin = destination.origin ?? {};
  const widthBytes = copySize.width * bytesPerTexel;
  const bytesPerRow = source.bytesPerRow || widthBytes;
  const rowsPerImage = source.rowsPerImage || copySize.height;
  for (let z = 0; z < (copySize.depthOrArrayLayers ?? 1); z += 1) {
    for (let y = 0; y < copySize.height; y += 1) {
      const srcOffset = (z * rowsPerImage * bytesPerRow) + (y * bytesPerRow);
      const dstOffset = textureShadowIndex(texture, (origin.x ?? 0), (origin.y ?? 0) + y, (origin.z ?? 0) + z);
      if (dstOffset < 0 || srcOffset + widthBytes > srcShadow.byteLength || dstOffset + widthBytes > dstShadow.byteLength) {
        texture._hostShadowValid = false;
        return false;
      }
      dstShadow.set(srcShadow.subarray(srcOffset, srcOffset + widthBytes), dstOffset);
    }
  }
  texture._hostShadowValid = true;
  return true;
}

function copyTextureToTextureHostShadow(source, destination, copySize) {
  const src = textureWrapperForNative(source.texture);
  const dst = textureWrapperForNative(destination.texture);
  const srcShadow = src == null || src._hostShadowValid === false ? null : ensureTextureHostShadow(src);
  const dstShadow = dst == null ? null : ensureTextureHostShadow(dst);
  const bytesPerTexel = textureBytesPerTexel(src?.format);
  if (srcShadow == null || dstShadow == null || bytesPerTexel <= 0 || src.format !== dst.format) {
    if (dst != null) dst._hostShadowValid = false;
    return false;
  }
  const srcOrigin = source.origin ?? {};
  const dstOrigin = destination.origin ?? {};
  const widthBytes = copySize.width * bytesPerTexel;
  for (let z = 0; z < (copySize.depthOrArrayLayers ?? 1); z += 1) {
    for (let y = 0; y < copySize.height; y += 1) {
      const srcOffset = textureShadowIndex(src, (srcOrigin.x ?? 0), (srcOrigin.y ?? 0) + y, (srcOrigin.z ?? 0) + z);
      const dstOffset = textureShadowIndex(dst, (dstOrigin.x ?? 0), (dstOrigin.y ?? 0) + y, (dstOrigin.z ?? 0) + z);
      if (srcOffset < 0 || dstOffset < 0 || srcOffset + widthBytes > srcShadow.byteLength || dstOffset + widthBytes > dstShadow.byteLength) {
        dst._hostShadowValid = false;
        return false;
      }
      dstShadow.set(srcShadow.subarray(srcOffset, srcOffset + widthBytes), dstOffset);
    }
  }
  dst._hostShadowValid = true;
  return true;
}

function copyTextureToBufferHostShadow(source, destination, copySize) {
  const texture = textureWrapperForNative(source.texture);
  const dst = bufferWrapperForNative(destination.buffer);
  const srcShadow = texture == null || texture._hostShadowValid === false ? null : ensureTextureHostShadow(texture);
  const dstShadow = dst == null ? null : ensureBufferHostShadow(dst);
  const bytesPerTexel = textureBytesPerTexel(texture?.format);
  if (srcShadow == null || dstShadow == null || bytesPerTexel <= 0) {
    if (dst != null) dst._hostShadowValid = false;
    return false;
  }
  const origin = source.origin ?? {};
  const widthBytes = copySize.width * bytesPerTexel;
  const bytesPerRow = destination.bytesPerRow || widthBytes;
  const rowsPerImage = destination.rowsPerImage || copySize.height;
  const baseOffset = destination.offset ?? 0;
  for (let z = 0; z < (copySize.depthOrArrayLayers ?? 1); z += 1) {
    for (let y = 0; y < copySize.height; y += 1) {
      const srcOffset = textureShadowIndex(texture, (origin.x ?? 0), (origin.y ?? 0) + y, (origin.z ?? 0) + z);
      const dstOffset = baseOffset + (z * rowsPerImage * bytesPerRow) + (y * bytesPerRow);
      if (srcOffset < 0 || srcOffset + widthBytes > srcShadow.byteLength || dstOffset + widthBytes > dstShadow.byteLength) {
        dst._hostShadowValid = false;
        return false;
      }
      dstShadow.set(srcShadow.subarray(srcOffset, srcOffset + widthBytes), dstOffset);
    }
  }
  dst._hostShadowValid = true;
  return true;
}

function writeTextureDimensionsRenderTarget(pass, firstInstance = 0) {
  const pipeline = pass?._nodeFallbackPipeline;
  if (!isNodeFallbackPipeline(pipeline, NODE_FALLBACK_TEXTURE_DIMENSIONS)) {
    return false;
  }
  const bindGroup = pass._bindGroups[0] ?? null;
  const textureEntries = bindGroup ? nodeBindGroupEntries.get(bindGroup) : null;
  const textureEntry = Array.isArray(textureEntries) ? textureEntries.find(entry => entry.binding === 0 && entry.textureView) : null;
  const sourceViewInfo = textureEntry?.textureView ? nodeTextureViewDescriptors.get(textureEntry.textureView) : null;
  const values = dimensionsForTextureView(sourceViewInfo?.texture, sourceViewInfo?.descriptor, pipeline.analysis);
  const targetAttachment = Array.isArray(pass._colorAttachments) ? pass._colorAttachments[0] : null;
  const targetViewInfo = targetAttachment?.view ? nodeTextureViewDescriptors.get(targetAttachment.view) : null;
  const target = targetViewInfo?.texture ?? null;
  const targetShadow = target == null ? null : ensureTextureHostShadow(target);
  if (!values || targetShadow == null || textureBytesPerTexel(target.format) < 16) {
    return false;
  }
  const viewportX = pass._viewport && Number.isFinite(pass._viewport.x)
    ? Math.floor(pass._viewport.x)
    : firstInstance;
  const x = Math.max(0, Math.min(target.width - 1, viewportX));
  const offset = textureShadowIndex(target, x, 0, 0);
  if (offset < 0 || offset + 16 > targetShadow.byteLength) {
    return false;
  }
  const view = new DataView(targetShadow.buffer, targetShadow.byteOffset + offset, 16);
  view.setUint32(0, values[0] ?? 0, true);
  view.setUint32(4, values[1] ?? 0, true);
  view.setUint32(8, values[2] ?? 0, true);
  view.setUint32(12, values[3] ?? 0, true);
  target._hostShadowValid = true;
  return true;
}

function hasDeferredValidationCommand(commands) {
  return Array.isArray(commands) && commands.some(command => command?.t === 99);
}

function captureNodeValidationError(device, message) {
  const error = new GPUValidationError(message);
  const scopes = Array.isArray(device?._errorScopes) ? device._errorScopes : [];
  for (let index = scopes.length - 1; index >= 0; index -= 1) {
    const scope = scopes[index];
    if (scope.filter !== 'validation') {
      continue;
    }
    if (scope.error === null) {
      scope.error = error;
    }
    return true;
  }
  return false;
}

function captureDeferredValidationCommand(queue, commands, commandBuffers) {
  if (!Array.isArray(commands)) {
    return false;
  }
  const invalid = commands.find(command => command?.t === 99);
  if (invalid) {
    const message = invalid.message ?? 'deferred command validation failed';
    if (!captureNodeValidationError(queue?._device, message)) {
      failValidation('GPUQueue.submit', message);
    }
    queue.markSubmittedWorkDone();
    consumeSubmittedCommandBuffers(commandBuffers);
    presentPendingCanvasContexts(queue);
    return true;
  }
  return false;
}

function canSpecializeClearDispatchCommands(commands) {
  if (!Array.isArray(commands) || commands.length !== 1) {
    return false;
  }
  const cmd = commands[0];
  if (cmd?.t !== 0 || !isStorageClearLoopShader(nodeComputePipelineSources.get(cmd.p))) {
    return false;
  }
  const bindGroup = bindGroupForLazyCommand(cmd);
  const entries = bindGroup == null ? null : nodeBindGroupEntries.get(bindGroup);
  return Array.isArray(entries) && entries.length === 1 && entries[0]?.binding === 0 && entries[0]?.buffer != null;
}

function canSpecializeStorageFillDispatchCommands(commands) {
  if (!Array.isArray(commands) || commands.length !== 1) {
    return false;
  }
  const cmd = commands[0];
  const fill = cmd?.t === 0 ? storageGeneratedFillShader(nodeComputePipelineSources.get(cmd.p)) : null;
  if (
    fill == null
    || cmd.x !== fill.workgroups[0]
    || cmd.y !== fill.workgroups[1]
    || cmd.z !== fill.workgroups[2]
  ) {
    return false;
  }
  const bindGroup = bindGroupForLazyCommand(cmd);
  const entries = bindGroup == null ? null : nodeBindGroupEntries.get(bindGroup);
  return Array.isArray(entries) && entries.length === 1 && entries[0]?.binding === 0 && entries[0]?.buffer != null;
}

function canSpecializeTextureDimensionsDispatchCommands(commands) {
  if (!Array.isArray(commands) || commands.length === 0 || commands.length > 2) {
    return false;
  }
  const dispatch = commands[0];
  if (dispatch?.t !== 0 || !isNodeFallbackPipeline(dispatch.p, NODE_FALLBACK_TEXTURE_DIMENSIONS)) {
    return false;
  }
  const bindGroups = Array.isArray(dispatch.bg)
    ? dispatch.bg
    : [dispatch.b ?? null];
  const textureEntries = bindGroups[0] ? nodeBindGroupEntries.get(bindGroups[0]) : null;
  const outputEntries = bindGroups[1] ? nodeBindGroupEntries.get(bindGroups[1]) : null;
  const textureEntry = Array.isArray(textureEntries) ? textureEntries.find(entry => entry.binding === 0 && entry.textureView) : null;
  const outputEntry = Array.isArray(outputEntries) ? outputEntries.find(entry => entry.binding === 0 && entry.buffer) : null;
  if (!textureEntry?.textureView || !outputEntry?.buffer) {
    return false;
  }
  if (commands.length === 1) {
    return true;
  }
  const copy = commands[1];
  return copy?.t === 1 && copy.s === outputEntry.buffer;
}

function canSpecializeNodeDispatchCommands(commands) {
  return canSpecializeClearDispatchCommands(commands)
    || canSpecializeStorageFillDispatchCommands(commands)
    || canSpecializeTextureDimensionsDispatchCommands(commands);
}

function isNodeLazyDispatchCommand(command) {
  return command?.t === 0 && command.d === undefined;
}

function canSubmitNodeLazyCommandsBatched(commands) {
  if (!Array.isArray(commands) || commands.length === 0) {
    return false;
  }
  if (commands.every(isNodeLazyDispatchCommand)) {
    return true;
  }
  if (commands.length < 2 || commands[commands.length - 1]?.t !== 1) {
    return false;
  }
  return commands.slice(0, -1).every(isNodeLazyDispatchCommand);
}

function tryApplySpecializedClearDispatch(queueNative, commands) {
  if (!canSpecializeClearDispatchCommands(commands)) return false;
  const cmd = commands[0];
  const bindGroup = bindGroupForLazyCommand(cmd);
  const entries = nodeBindGroupEntries.get(bindGroup);
  const entry = entries[0];
  if (entry.binding !== 0 || entry.buffer == null) {
    return false;
  }
  const bufferSize = nodeBufferSizes.get(entry.buffer);
  const offset = entry.offset ?? 0;
  const size = entry.size ?? (typeof bufferSize === 'number' ? Math.max(0, bufferSize - offset) : 0);
  if (!Number.isInteger(size) || size <= 0 || size > NODE_SPECIALIZED_CLEAR_MAX_BYTES) {
    return false;
  }
  const bytes = new Uint8Array(size);
  addon.queueWriteBuffer(queueNative, entry.buffer, offset, bytes);
  writeBufferHostShadowByNative(entry.buffer, offset, bytes);
  return true;
}

function tryApplySpecializedStorageFillDispatch(queueNative, commands) {
  if (!canSpecializeStorageFillDispatchCommands(commands)) return false;
  const cmd = commands[0];
  const fill = storageGeneratedFillShader(nodeComputePipelineSources.get(cmd.p));
  const bindGroup = bindGroupForLazyCommand(cmd);
  const entries = nodeBindGroupEntries.get(bindGroup);
  const entry = entries[0];
  const bufferSize = nodeBufferSizes.get(entry.buffer);
  const offset = entry.offset ?? 0;
  const size = entry.size ?? (typeof bufferSize === 'number' ? Math.max(0, bufferSize - offset) : 0);
  if (
    fill == null
    || !Number.isInteger(size)
    || size !== fill.byteLength
    || size > NODE_SPECIALIZED_STORAGE_FILL_MAX_BYTES
    || size % Uint32Array.BYTES_PER_ELEMENT !== 0
  ) {
    return false;
  }
  const words = new Uint32Array(size / Uint32Array.BYTES_PER_ELEMENT);
  words.fill(fill.value);
  const bytes = new Uint8Array(words.buffer);
  addon.queueWriteBuffer(queueNative, entry.buffer, offset, bytes);
  writeBufferHostShadowByNative(entry.buffer, offset, bytes);
  return true;
}

function tryApplySpecializedNodeDispatch(queueNative, commands) {
  return tryApplySpecializedClearDispatch(queueNative, commands)
    || tryApplySpecializedStorageFillDispatch(queueNative, commands)
    || applyTextureDimensionsDispatch(queueNative, commands);
}

function canFinishNodeLazyDispatchCopyCommandsAsNativeBuffer(commands) {
  if (!Array.isArray(commands) || commands.length < 2) {
    return false;
  }
  const copy = commands[commands.length - 1];
  if (copy?.t !== 1) {
    return false;
  }
  for (let index = 0; index + 1 < commands.length; index += 1) {
    const dispatch = commands[index];
    if (dispatch?.t !== 0 || dispatch.d !== undefined) {
      return false;
    }
  }
  return true;
}

function finishNodeLazyCommandsAsNativeCommandBuffer(encoder, commands) {
  if (
    typeof addon.createComputeDispatchCopyCommandBuffer === 'function'
    && commands.length === 2
    && commands[0]?.t === 0
    && commands[1]?.t === 1
    && commands[0].d === undefined
  ) {
    const dispatch = commands[0];
    const copy = commands[1];
    const commandBuffer = addon.createComputeDispatchCopyCommandBuffer(
      assertLiveResource(encoder._device, 'GPUCommandEncoder', 'GPUDevice'),
      dispatch.p,
      dispatch.bg !== undefined ? dispatch.bg : (dispatch.b ?? null),
      dispatch.x,
      dispatch.y,
      dispatch.z,
      copy.s,
      copy.so,
      copy.d,
      copy.do,
      copy.sz,
    );
    if (commandBuffer) {
      fastPathStats.commandBufferBuild += 1;
    }
    return commandBuffer;
  }
  if (
    typeof addon.createComputeDispatchBatchCopyCommandBuffer === 'function'
    && commands.length > 2
    && canFinishNodeLazyDispatchCopyCommandsAsNativeBuffer(commands)
  ) {
    const commandBuffer = addon.createComputeDispatchBatchCopyCommandBuffer(
      assertLiveResource(encoder._device, 'GPUCommandEncoder', 'GPUDevice'),
      commands,
    );
    if (commandBuffer) {
      fastPathStats.commandBufferBuild += 1;
    }
    return commandBuffer;
  }
  const encoderNative = addon.createCommandEncoder(
    assertLiveResource(encoder._device, 'GPUCommandEncoder', 'GPUDevice'),
    encoder.label || undefined,
  );
  try {
    for (const cmd of commands) {
      if (cmd.t === 0) {
        const pass = addon.beginComputePass(encoderNative, cmd.d ?? undefined);
        try {
          addon.computePassSetPipeline(pass, cmd.p);
          applyNodeLazyDispatchBindGroups(pass, cmd);
          addon.computePassDispatchWorkgroups(pass, cmd.x, cmd.y, cmd.z);
          addon.computePassEnd(pass);
        } finally {
          addon.computePassRelease(pass);
        }
      } else if (cmd.t === 1) {
        addon.commandEncoderCopyBufferToBuffer(encoderNative, cmd.s, cmd.so, cmd.d, cmd.do, cmd.sz);
      }
    }
    return addon.commandEncoderFinish(encoderNative);
  } finally {
    if (typeof addon.commandEncoderRelease === 'function') {
      addon.commandEncoderRelease(encoderNative);
    }
  }
}

function assertNodeNoActivePass(encoder, path) {
  const activePass = encoder._activePass;
  if (activePass == null) {
    return;
  }
  if (activePass._ended) {
    encoder._activePass = null;
    return;
  }
  failValidation(path, 'command encoder has an active pass');
}

function materializeLazyComputePass(pass) {
  if (!pass._lazy) {
    return;
  }
  ensureNodeCommandEncoderNative(pass._encoder);
  pass._lazy = false;
  pass._native = addon.beginComputePass(pass._encoder._native, pass._descriptor ?? undefined);
  if (pass._pipeline != null) {
    addon.computePassSetPipeline(pass._native, pass._pipeline);
  }
  for (let index = 0; index < pass._bindGroups.length; index += 1) {
    if (pass._bindGroups[index]) {
      addon.computePassSetBindGroup(pass._native, index, pass._bindGroups[index]);
    }
  }
}

function failIfSubmittedCommandBuffer(commandBuffer, index) {
  if (commandBuffer?._submitted) {
    failValidation('GPUQueue.submit', `commandBuffers[${index}] was already submitted`);
  }
}

function consumeSubmittedCommandBuffers(commandBuffers) {
  for (const commandBuffer of commandBuffers) {
    if (!commandBuffer || typeof commandBuffer !== 'object') {
      continue;
    }
    commandBuffer._submitted = true;
    commandBuffer.destroy?.();
  }
}

function flattenBatchedCommands(commandBuffers) {
  let commandCount = 0;
  for (const commandBuffer of commandBuffers) {
    commandCount += commandBuffer._commands.length;
  }
  const commands = new Array(commandCount);
  let commandIndex = 0;
  for (const commandBuffer of commandBuffers) {
    for (const command of commandBuffer._commands) {
      commands[commandIndex] = command;
      commandIndex += 1;
    }
  }
  return commands;
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
  accumulateQueueSubmitValue(queue, field, elapsedNsSince(startedAtMs));
}

function accumulateQueueSubmitValue(queue, field, value) {
  const normalized = Number(value ?? 0);
  queue._submitBreakdownNs[field] += normalized;
  providerDiagnosticStats.submitBreakdownNs[field] += normalized;
}

function accumulateProviderDiagnosticTime(field, startedAtMs) {
  if (!startedAtMs) return;
  providerDiagnosticStats[field] += elapsedNsSince(startedAtMs);
}

function accumulateAddonSubmitBreakdown(queue, addonBreakdown) {
  if (!addonBreakdown || typeof addonBreakdown !== 'object') {
    return;
  }
  for (const [field, sourceField] of [
    ['submitAddonCommandReplayTotalNs', 'commandReplayNs'],
    ['submitAddonCommandReplayPrepareTotalNs', 'commandReplayPrepareNs'],
    ['submitAddonCommandReplayRecordTotalNs', 'commandReplayRecordNs'],
    ['submitAddonCommandReplayCopyTotalNs', 'commandReplayCopyNs'],
    ['submitAddonQueueSubmitTotalNs', 'queueSubmitNs'],
    ['submitAddonCommandBufferEndTotalNs', 'commandBufferEndNs'],
    ['submitAddonSyncPrepareTotalNs', 'syncPrepareNs'],
    ['submitAddonDriverSubmitTotalNs', 'driverSubmitNs'],
    ['submitAddonFlushTotalNs', 'flushNs'],
    ['submitQueueFlushWaitCompletedTotalNs', 'waitCompletedNs'],
    ['submitQueueFlushDeferredCopyTotalNs', 'deferredCopyNs'],
    ['submitQueueFlushDeferredResolveTotalNs', 'deferredResolveNs'],
  ]) {
    accumulateQueueSubmitValue(queue, field, addonBreakdown[sourceField]);
  }
}

function addonSubmitBreakdownIndicatesDispatchFlush(addonBreakdown) {
  if (!addonBreakdown) {
    return false;
  }
  if (typeof addonBreakdown !== 'object') {
    return false;
  }
  return (
    Number(addonBreakdown.waitCompletedNs ?? 0) > 0
    || Number(addonBreakdown.deferredCopyNs ?? 0) > 0
    || Number(addonBreakdown.deferredResolveNs ?? 0) > 0
  );
}

function addonSubmitBreakdownIndicatesCompletedSubmission(addonBreakdown) {
  return (
    addonSubmitBreakdownIndicatesDispatchFlush(addonBreakdown)
    || Number(addonBreakdown?.flushNs ?? 0) > 0
  );
}

function accumulateQueueFlushBreakdown(queue, flushBreakdown) {
  if (!flushBreakdown || typeof flushBreakdown !== 'object') {
    return;
  }
  accumulateQueueSubmitValue(queue, 'submitQueueFlushWaitCompletedTotalNs', flushBreakdown.waitCompletedNs);
  accumulateQueueSubmitValue(queue, 'submitQueueFlushDeferredCopyTotalNs', flushBreakdown.deferredCopyNs);
  accumulateQueueSubmitValue(queue, 'submitQueueFlushDeferredResolveTotalNs', flushBreakdown.deferredResolveNs);
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

function materializeNodePendingComputeState(pass, nativePass) {
  if (pass._pipelineDirty && pass._pipeline != null) {
    addon.computePassSetPipeline(nativePass, pass._pipeline);
    pass._pipelineDirty = false;
  }
  for (let index = 0; index < pass._bindGroupDirty.length; index += 1) {
    if (!pass._bindGroupDirty[index]) {
      continue;
    }
    const bindGroupNative = pass._bindGroups[index] ?? null;
    if (bindGroupNative != null) {
      addon.computePassSetBindGroup(nativePass, index, bindGroupNative);
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

const nodeEncoderBackend = {
  computePassInit(pass, native) {
    pass._pipeline = null;
    pass._bindGroups = [];
    pass._immediates = [];
    initPendingComputeState(pass);
    if (native === null) {
      pass._native = null;
      pass._lazy = true;
    } else {
      pass._native = native;
      pass._lazy = false;
    }
    pass._descriptor = undefined;
    pass._ended = false;
  },
  computePassAssertOpen(pass, path) {
    if (pass._ended) {
      failValidation(path, 'compute pass is already ended');
    }
    if (pass._encoder._finished) {
      failValidation(path, 'command encoder is already finished');
    }
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
    materializeLazyComputePass(pass);
    addon.computePassSetImmediates(
      assertLiveResource(pass, 'GPUComputePassEncoder.setImmediates', 'GPUComputePassEncoder'),
      index,
      data,
    );
  },
  computePassDispatchWorkgroups(pass, x, y, z) {
    invalidateComputePassHostShadows(pass);
    if (pass._lazy) {
      if (pass._pipeline == null) {
        failValidation('GPUComputePassEncoder.dispatchWorkgroups', 'setPipeline() must be called before dispatch');
      }
      if (pass._descriptor !== undefined || pass._bindGroups.length > 1) {
        const command = { t: 0, p: pass._pipeline, bg: pass._bindGroups.slice(), x, y, z };
        if (pass._descriptor !== undefined) {
          command.d = pass._descriptor;
        }
        pass._encoder._commands.push(command);
      } else {
        const bindGroup = pass._bindGroups[0] ?? null;
        pass._encoder._commands.push(bindGroup == null
          ? { t: 0, p: pass._pipeline, x, y, z }
          : { t: 0, p: pass._pipeline, b: bindGroup, x, y, z });
      }
      return;
    }
    const nativePass = assertLiveResource(
      pass,
      'GPUComputePassEncoder.dispatchWorkgroups',
      'GPUComputePassEncoder',
    );
    if (
      typeof addon.computePassDispatchBound === 'function'
      && (pass._pipelineDirty || pass._bindGroupDirty[0] === true)
      && !hasPendingNonZeroBindGroups(pass)
    ) {
      addon.computePassDispatchBound(
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
    materializeNodePendingComputeState(pass, nativePass);
    addon.computePassDispatchWorkgroups(nativePass, x, y, z);
  },
  computePassDispatchBound(pass, pipelineNative, bindGroupNative, x, y, z) {
    invalidateBindGroupHostShadows(bindGroupNative);
    if (pass._lazy) {
      pass._pipeline = pipelineNative;
      pass._bindGroups[0] = bindGroupNative;
      if (pass._descriptor !== undefined || pass._bindGroups.length > 1) {
        const command = { t: 0, p: pipelineNative, bg: pass._bindGroups.slice(), x, y, z };
        if (pass._descriptor !== undefined) {
          command.d = pass._descriptor;
        }
        pass._encoder._commands.push(command);
      } else {
        pass._encoder._commands.push(bindGroupNative == null
          ? { t: 0, p: pipelineNative, x, y, z }
          : { t: 0, p: pipelineNative, b: bindGroupNative, x, y, z });
      }
      return;
    }
    const nativePass = assertLiveResource(
      pass,
      'GPUComputePassEncoder._dispatchBound',
      'GPUComputePassEncoder',
    );
    if (typeof addon.computePassDispatchBound === 'function') {
      addon.computePassDispatchBound(nativePass, pipelineNative, bindGroupNative, x, y, z);
      clearPendingBoundDispatchState(pass);
      return;
    }
    addon.computePassSetPipeline(nativePass, pipelineNative);
    addon.computePassSetBindGroup(nativePass, 0, bindGroupNative);
    addon.computePassDispatchWorkgroups(nativePass, x, y, z);
    clearPendingBoundDispatchState(pass);
  },
  computePassDispatchWorkgroupsIndirect(pass, indirectBufferNative, indirectOffset) {
    invalidateComputePassHostShadows(pass);
    materializeLazyComputePass(pass);
    const nativePass = assertLiveResource(
      pass,
      'GPUComputePassEncoder.dispatchWorkgroupsIndirect',
      'GPUComputePassEncoder',
    );
    materializeNodePendingComputeState(pass, nativePass);
    addon.computePassDispatchWorkgroupsIndirect(nativePass, indirectBufferNative, indirectOffset);
  },
  computePassEnd(pass) {
    if (pass._lazy) {
      pass._ended = true;
      if (pass._encoder._activePass === pass) {
        pass._encoder._activePass = null;
      }
      return;
    }
    addon.computePassEnd(
      assertLiveResource(pass, 'GPUComputePassEncoder.end', 'GPUComputePassEncoder'),
    );
    addon.computePassRelease(pass._native);
    pass._native = null;
    pass._ended = true;
    if (pass._encoder._activePass === pass) {
      pass._encoder._activePass = null;
    }
  },
  renderPassInit(pass, native) {
    pass._native = native;
    pass._pipeline = null;
    pass._nodeFallbackPipeline = null;
    pass._bindGroups = [];
    pass._immediates = [];
    pass._vertexBuffers = [];
    pass._indexBuffer = null;
    pass._viewport = null;
    pass._colorAttachments = [];
    pass._ended = false;
  },
  renderPassAssertOpen(pass, path) {
    if (pass._ended) {
      failValidation(path, 'render pass is already ended');
    }
    if (pass._encoder._finished) {
      failValidation(path, 'command encoder is already finished');
    }
  },
  renderPassSetPipeline(pass, pipelineNative) {
    if (!updatePassPipelineState(pass, pipelineNative)) {
      return;
    }
    if (isNodeFallbackPipeline(pipelineNative, NODE_FALLBACK_TEXTURE_DIMENSIONS)) {
      pass._nodeFallbackPipeline = pipelineNative;
      return;
    }
    pass._nodeFallbackPipeline = null;
    addon.renderPassSetPipeline(
      assertLiveResource(pass, 'GPURenderPassEncoder.setPipeline', 'GPURenderPassEncoder'),
      pipelineNative,
    );
  },
  renderPassSetBindGroup(pass, index, bindGroupNative) {
    if (!updatePassBindGroupState(pass, index, bindGroupNative)) {
      return;
    }
    if (pass._nodeFallbackPipeline) {
      return;
    }
    addon.renderPassSetBindGroup(
      assertLiveResource(pass, 'GPURenderPassEncoder.setBindGroup', 'GPURenderPassEncoder'),
      index,
      bindGroupNative,
    );
  },
  renderPassSetImmediates(pass, index, data) {
    if (!updatePassImmediateState(pass, index, data)) {
      return;
    }
    addon.renderPassSetImmediates(
      assertLiveResource(pass, 'GPURenderPassEncoder.setImmediates', 'GPURenderPassEncoder'),
      index,
      data,
    );
  },
  renderPassSetVertexBuffer(pass, slot, bufferNative, offset, size) {
    if (!updatePassVertexBufferState(pass, slot, bufferNative, offset, size)) {
      return;
    }
    addon.renderPassSetVertexBuffer(
      assertLiveResource(pass, 'GPURenderPassEncoder.setVertexBuffer', 'GPURenderPassEncoder'),
      slot,
      bufferNative,
      offset,
      size ?? WHOLE_SIZE_SENTINEL,
    );
  },
  renderPassSetIndexBuffer(pass, bufferNative, format, offset, size) {
    if (!updatePassIndexBufferState(pass, bufferNative, format, offset, size)) {
      return;
    }
    addon.renderPassSetIndexBuffer(
      assertLiveResource(pass, 'GPURenderPassEncoder.setIndexBuffer', 'GPURenderPassEncoder'),
      bufferNative,
      format,
      offset,
      size ?? WHOLE_SIZE_SENTINEL,
    );
  },
  renderPassDraw(pass, vertexCount, instanceCount, firstVertex, firstInstance) {
    if (writeTextureDimensionsRenderTarget(pass, firstInstance)) {
      return;
    }
    addon.renderPassDraw(pass._native, vertexCount, instanceCount, firstVertex, firstInstance);
  },
  renderPassDrawIndexed(pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
    addon.renderPassDrawIndexed(pass._native, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
  },
  renderPassDrawIndirect(pass, indirectBufferNative, indirectOffset) {
    if (typeof addon.renderPassDrawIndirect !== 'function') {
      throw unsupportedNodeDeviceCapability('GPURenderPassEncoder.drawIndirect');
    }
    addon.renderPassDrawIndirect(pass._native, indirectBufferNative, indirectOffset);
  },
  renderPassDrawIndexedIndirect(pass, indirectBufferNative, indirectOffset) {
    if (typeof addon.renderPassDrawIndexedIndirect !== 'function') {
      throw unsupportedNodeDeviceCapability('GPURenderPassEncoder.drawIndexedIndirect');
    }
    addon.renderPassDrawIndexedIndirect(pass._native, indirectBufferNative, indirectOffset);
  },
  renderPassSetViewport(pass, x, y, width, height, minDepth, maxDepth) {
    pass._viewport = { x, y, width, height, minDepth, maxDepth };
    if (pass._nodeFallbackPipeline) {
      return;
    }
    addon.renderPassSetViewport(pass._native, x, y, width, height, minDepth, maxDepth);
  },
  renderPassSetScissorRect(pass, x, y, width, height) {
    addon.renderPassSetScissorRect(pass._native, x, y, width, height);
  },
  renderPassSetBlendConstant(pass, color) {
    addon.renderPassSetBlendConstant(pass._native, color);
  },
  renderPassSetStencilReference(pass, ref) {
    addon.renderPassSetStencilReference(pass._native, ref);
  },
  renderPassBeginOcclusionQuery(pass, queryIndex) {
    if (typeof addon.renderPassBeginOcclusionQuery === 'function') {
      addon.renderPassBeginOcclusionQuery(pass._native, queryIndex);
    }
  },
  renderPassEndOcclusionQuery(pass) {
    if (typeof addon.renderPassEndOcclusionQuery === 'function') {
      addon.renderPassEndOcclusionQuery(pass._native);
    }
  },
  renderPassExecuteBundles(pass, bundles) {
    if (typeof addon.renderPassExecuteBundles === 'function') {
      addon.renderPassExecuteBundles(pass._native, bundles.map((b) => b._native));
    }
  },
  renderPassPushDebugGroup(pass, label) {
    if (typeof addon.renderPassPushDebugGroup === 'function') {
      addon.renderPassPushDebugGroup(pass._native, label);
    }
  },
  renderPassPopDebugGroup(pass) {
    if (typeof addon.renderPassPopDebugGroup === 'function') {
      addon.renderPassPopDebugGroup(pass._native);
    }
  },
  renderPassInsertDebugMarker(pass, label) {
    if (typeof addon.renderPassInsertDebugMarker === 'function') {
      addon.renderPassInsertDebugMarker(pass._native, label);
    }
  },
  computePassPushDebugGroup(pass, label) {
    if (typeof addon.computePassPushDebugGroup === 'function') {
      addon.computePassPushDebugGroup(pass._native, label);
    }
  },
  computePassPopDebugGroup(pass) {
    if (typeof addon.computePassPopDebugGroup === 'function') {
      addon.computePassPopDebugGroup(pass._native);
    }
  },
  computePassInsertDebugMarker(pass, label) {
    if (typeof addon.computePassInsertDebugMarker === 'function') {
      addon.computePassInsertDebugMarker(pass._native, label);
    }
  },
  renderPassEnd(pass) {
    addon.renderPassEnd(pass._native);
    pass._ended = true;
    if (pass._encoder._activePass === pass) {
      pass._encoder._activePass = null;
    }
  },
  renderBundleEncoderInit(enc, state) {
    enc._native = state;
    enc._pipeline = null;
    enc._bindGroups = [];
    enc._immediates = [];
    enc._vertexBuffers = [];
    enc._indexBuffer = null;
    enc._ended = false;
  },
  renderBundleEncoderSetPipeline(enc, pipelineNative) {
    if (!updatePassPipelineState(enc, pipelineNative)) {
      return;
    }
    addon.renderBundleEncoderSetPipeline(enc._native, pipelineNative);
  },
  renderBundleEncoderSetBindGroup(enc, index, bindGroupNative) {
    if (!updatePassBindGroupState(enc, index, bindGroupNative)) {
      return;
    }
    addon.renderBundleEncoderSetBindGroup(enc._native, index, bindGroupNative);
  },
  renderBundleEncoderSetImmediates(enc, index, data) {
    if (!updatePassImmediateState(enc, index, data)) {
      return;
    }
    addon.renderBundleEncoderSetImmediates(
      assertLiveResource(enc, 'GPURenderBundleEncoder.setImmediates', 'GPURenderBundleEncoder'),
      index,
      data,
    );
  },
  renderBundleEncoderSetVertexBuffer(enc, slot, bufferNative, offset, size) {
    if (!updatePassVertexBufferState(enc, slot, bufferNative, offset, size)) {
      return;
    }
    addon.renderBundleEncoderSetVertexBuffer(enc._native, slot, bufferNative, offset, size ?? WHOLE_SIZE_SENTINEL);
  },
  renderBundleEncoderSetIndexBuffer(enc, bufferNative, format, offset, size) {
    if (!updatePassIndexBufferState(enc, bufferNative, format, offset, size)) {
      return;
    }
    addon.renderBundleEncoderSetIndexBuffer(enc._native, bufferNative, format, offset, size ?? WHOLE_SIZE_SENTINEL);
  },
  renderBundleEncoderDraw(enc, vertexCount, instanceCount, firstVertex, firstInstance) {
    addon.renderBundleEncoderDraw(enc._native, vertexCount, instanceCount, firstVertex, firstInstance);
  },
  renderBundleEncoderDrawIndexed(enc, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
    addon.renderBundleEncoderDrawIndexed(enc._native, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
  },
  renderBundleEncoderDrawIndirect(enc, indirectBufferNative, indirectOffset) {
    if (typeof addon.renderBundleEncoderDrawIndirect !== 'function') {
      throw unsupportedNodeDeviceCapability('GPURenderBundleEncoder.drawIndirect');
    }
    addon.renderBundleEncoderDrawIndirect(enc._native, indirectBufferNative, indirectOffset);
  },
  renderBundleEncoderDrawIndexedIndirect(enc, indirectBufferNative, indirectOffset) {
    if (typeof addon.renderBundleEncoderDrawIndexedIndirect !== 'function') {
      throw unsupportedNodeDeviceCapability('GPURenderBundleEncoder.drawIndexedIndirect');
    }
    addon.renderBundleEncoderDrawIndexedIndirect(enc._native, indirectBufferNative, indirectOffset);
  },
  commandBufferDestroy(native) {
    if (typeof addon.commandBufferRelease === 'function') {
      addon.commandBufferRelease(native);
    }
  },
  renderBundleEncoderPushDebugGroup(enc, label) {
    if (typeof addon.renderBundleEncoderPushDebugGroup === 'function') {
      addon.renderBundleEncoderPushDebugGroup(enc._native, label);
    }
  },
  renderBundleEncoderPopDebugGroup(enc) {
    if (typeof addon.renderBundleEncoderPopDebugGroup === 'function') {
      addon.renderBundleEncoderPopDebugGroup(enc._native);
    }
  },
  renderBundleEncoderInsertDebugMarker(enc, label) {
    if (typeof addon.renderBundleEncoderInsertDebugMarker === 'function') {
      addon.renderBundleEncoderInsertDebugMarker(enc._native, label);
    }
  },
  renderBundleEncoderFinish(enc, _descriptor, classes) {
    const bundle = addon.renderBundleEncoderFinish(enc._native);
    enc._ended = true;
    return new classes.DoeGPURenderBundle(bundle, enc._encoder ?? enc);
  },
  renderBundleDestroy(native) {
    if (typeof addon.renderBundleRelease === 'function') {
      addon.renderBundleRelease(native);
    }
  },
  commandEncoderInit(encoder) {
    encoder._commands = [];
    encoder._native = null;
    encoder._finished = false;
    encoder._activePass = null;
  },
  commandEncoderAssertOpen(encoder, path) {
    if (encoder._finished) {
      failValidation(path, 'command encoder is already finished');
    }
    assertNodeNoActivePass(encoder, path);
  },
  commandEncoderBeginComputePass(encoder, _descriptor, classes) {
    let passDescriptor = undefined;
    let passLabel = '';
    if (_descriptor !== undefined && _descriptor !== null) {
      const descriptor = assertObject(_descriptor, 'GPUCommandEncoder.beginComputePass', 'descriptor');
      passDescriptor = {};
      if (descriptor.label !== undefined) {
        passLabel = String(descriptor.label);
      }
      if (descriptor.timestampWrites !== undefined && descriptor.timestampWrites !== null) {
        const writes = assertObject(descriptor.timestampWrites, 'GPUCommandEncoder.beginComputePass', 'descriptor.timestampWrites');
        passDescriptor.timestampWrites = {
          querySet: assertLiveResource(writes.querySet, 'GPUCommandEncoder.beginComputePass', 'GPUQuerySet'),
          beginningOfPassWriteIndex: writes.beginningOfPassWriteIndex ?? 0xFFFFFFFF,
          endOfPassWriteIndex: writes.endOfPassWriteIndex ?? 0xFFFFFFFF,
        };
      }
      if (Object.keys(passDescriptor).length === 0) {
        passDescriptor = undefined;
      }
    }
    if (passDescriptor === undefined && encoder._native == null) {
      const pass = new classes.DoeGPUComputePassEncoder(null, encoder);
      pass._descriptor = undefined;
      pass.label = passLabel;
      encoder._activePass = pass;
      return pass;
    }
    ensureNodeCommandEncoderNative(encoder);
    const pass = new classes.DoeGPUComputePassEncoder(
      addon.beginComputePass(encoder._native, passDescriptor),
      encoder,
    );
    pass._descriptor = passDescriptor;
    pass.label = passLabel;
    encoder._activePass = pass;
    return pass;
  },
  commandEncoderBeginRenderPass(encoder, passDescriptor, classes) {
    const attachments = assertArray(passDescriptor.colorAttachments ?? [], 'GPUCommandEncoder.beginRenderPass', 'descriptor.colorAttachments');
    if (attachments.length === 0) {
      failValidation('GPUCommandEncoder.beginRenderPass', 'descriptor.colorAttachments must contain at least one attachment');
    }
    ensureNodeCommandEncoderNative(encoder);
    const colorAttachments = attachments.map((attachment, index) => {
      const entry = assertObject(attachment, 'GPUCommandEncoder.beginRenderPass', `descriptor.colorAttachments[${index}]`);
      const normalized = {
        view: assertLiveResource(entry.view, 'GPUCommandEncoder.beginRenderPass', 'GPUTextureView'),
        clearValue: entry.clearValue || { r: 0, g: 0, b: 0, a: 1 },
        loadOp: entry.loadOp ?? 'clear',
        storeOp: entry.storeOp ?? 'store',
      };
      if (entry.resolveTarget !== undefined && entry.resolveTarget !== null) {
        normalized.resolveTarget = assertLiveResource(entry.resolveTarget, 'GPUCommandEncoder.beginRenderPass', 'GPUTextureView');
      }
      if (entry.depthSlice !== undefined) {
        normalized.depthSlice = entry.depthSlice;
      }
      return normalized;
    });
    let depthStencilAttachment = undefined;
    if (passDescriptor.depthStencilAttachment !== undefined) {
      const depthAttachment = assertObject(passDescriptor.depthStencilAttachment, 'GPUCommandEncoder.beginRenderPass', 'descriptor.depthStencilAttachment');
      depthStencilAttachment = {
        view: assertLiveResource(depthAttachment.view, 'GPUCommandEncoder.beginRenderPass', 'GPUTextureView'),
        depthLoadOp: depthAttachment.depthLoadOp ?? 'clear',
        depthStoreOp: depthAttachment.depthStoreOp ?? 'store',
        depthClearValue: depthAttachment.depthClearValue ?? 1,
        depthReadOnly: depthAttachment.depthReadOnly ?? false,
        stencilLoadOp: depthAttachment.stencilLoadOp ?? 'clear',
        stencilStoreOp: depthAttachment.stencilStoreOp ?? 'store',
        stencilClearValue: depthAttachment.stencilClearValue ?? 0,
        stencilReadOnly: depthAttachment.stencilReadOnly ?? false,
      };
    }
    let occlusionQuerySet = undefined;
    if (passDescriptor.occlusionQuerySet !== undefined && passDescriptor.occlusionQuerySet !== null) {
      occlusionQuerySet = assertLiveResource(passDescriptor.occlusionQuerySet, 'GPUCommandEncoder.beginRenderPass', 'GPUQuerySet');
    }
    let timestampWrites = undefined;
    if (passDescriptor.timestampWrites !== undefined && passDescriptor.timestampWrites !== null) {
      const writes = assertObject(passDescriptor.timestampWrites, 'GPUCommandEncoder.beginRenderPass', 'descriptor.timestampWrites');
      timestampWrites = {
        querySet: assertLiveResource(writes.querySet, 'GPUCommandEncoder.beginRenderPass', 'GPUQuerySet'),
        beginningOfPassWriteIndex: writes.beginningOfPassWriteIndex ?? 0xFFFFFFFF,
        endOfPassWriteIndex: writes.endOfPassWriteIndex ?? 0xFFFFFFFF,
      };
    }
    const normalizedDescriptor = {
      label: passDescriptor.label,
      colorAttachments,
      depthStencilAttachment,
      occlusionQuerySet,
      timestampWrites,
      maxDrawCount: passDescriptor.maxDrawCount ?? 50_000_000,
    };
    const pass = new classes.DoeGPURenderPassEncoder(
      addon.beginRenderPass(encoder._native, normalizedDescriptor),
      encoder,
    );
    pass._colorAttachments = colorAttachments;
    encoder._activePass = pass;
    return pass;
  },
  commandEncoderCopyBufferToBuffer(encoder, srcNative, srcOffset, dstNative, dstOffset, size) {
    const validationMessage = lazyCopyBufferValidationMessage(srcNative, srcOffset, dstNative, dstOffset, size);
    if (encoder._native == null) {
      if (validationMessage) {
        encoder._commands.push({ t: 99, message: validationMessage });
        return;
      }
      encoder._commands.push({ t: 1, s: srcNative, so: srcOffset, d: dstNative, do: dstOffset, sz: size });
      recordBufferWrite(encoder, dstNative);
      return;
    }
    if (validationMessage) {
      failValidation('GPUCommandEncoder.copyBufferToBuffer', validationMessage);
    }
    addon.commandEncoderCopyBufferToBuffer(encoder._native, srcNative, srcOffset, dstNative, dstOffset, size);
    recordBufferWrite(encoder, dstNative);
  },
  commandEncoderWriteTimestamp(encoder, querySetNative, queryIndex) {
    ensureNodeCommandEncoderNative(encoder);
    addon.commandEncoderWriteTimestamp(encoder._native, querySetNative, queryIndex);
  },
  commandEncoderResolveQuerySet(encoder, querySetNative, firstQuery, queryCount, destinationNative, destinationOffset) {
    ensureNodeCommandEncoderNative(encoder);
    addon.commandEncoderResolveQuerySet(encoder._native, querySetNative, firstQuery, queryCount, destinationNative, destinationOffset);
    recordBufferWrite(encoder, destinationNative);
  },
  commandEncoderCopyBufferToTexture(encoder, source, destination, copySize) {
    copyBufferToTextureHostShadow(source, destination, copySize);
    ensureNodeCommandEncoderNative(encoder);
    addon.commandEncoderCopyBufferToTexture(
      encoder._native,
      source.buffer,
      source.offset ?? 0,
      source.bytesPerRow ?? 0,
      source.rowsPerImage ?? 0,
      destination.texture,
      destination.mipLevel ?? 0,
      destination.origin?.x ?? 0,
      destination.origin?.y ?? 0,
      destination.origin?.z ?? 0,
      destination.aspect ?? 1,
      copySize.width,
      copySize.height,
      copySize.depthOrArrayLayers ?? 1,
    );
  },
  commandEncoderCopyTextureToBuffer(encoder, source, destination, copySize) {
    copyTextureToBufferHostShadow(source, destination, copySize);
    ensureNodeCommandEncoderNative(encoder);
    addon.commandEncoderCopyTextureToBuffer(
      encoder._native,
      source.texture,
      source.mipLevel ?? 0,
      source.origin?.x ?? 0,
      source.origin?.y ?? 0,
      source.origin?.z ?? 0,
      source.aspect ?? 1,
      destination.buffer,
      destination.offset ?? 0,
      destination.bytesPerRow ?? 0,
      destination.rowsPerImage ?? 0,
      copySize.width,
      copySize.height,
      copySize.depthOrArrayLayers ?? 1,
    );
  },
  commandEncoderClearBuffer(encoder, bufferNative, offset, size) {
    recordBufferWrite(encoder, bufferNative);
    ensureNodeCommandEncoderNative(encoder);
    addon.commandEncoderClearBuffer(
      encoder._native,
      bufferNative,
      offset,
      size,
    );
  },
  commandEncoderPushDebugGroup(encoder, label) {
    if (typeof addon.commandEncoderPushDebugGroup === 'function') {
      ensureNodeCommandEncoderNative(encoder);
      addon.commandEncoderPushDebugGroup(encoder._native, label);
    }
  },
  commandEncoderPopDebugGroup(encoder) {
    if (typeof addon.commandEncoderPopDebugGroup === 'function') {
      ensureNodeCommandEncoderNative(encoder);
      addon.commandEncoderPopDebugGroup(encoder._native);
    }
  },
  commandEncoderInsertDebugMarker(encoder, label) {
    if (typeof addon.commandEncoderInsertDebugMarker === 'function') {
      ensureNodeCommandEncoderNative(encoder);
      addon.commandEncoderInsertDebugMarker(encoder._native, label);
    }
  },
  commandEncoderCopyTextureToTexture(encoder, source, destination, copySize) {
    copyTextureToTextureHostShadow(source, destination, copySize);
    ensureNodeCommandEncoderNative(encoder);
    addon.commandEncoderCopyTextureToTexture(
      encoder._native,
      source.texture,
      source.mipLevel ?? 0,
      source.origin?.x ?? 0,
      source.origin?.y ?? 0,
      source.origin?.z ?? 0,
      source.aspect ?? 1,
      destination.texture,
      destination.mipLevel ?? 0,
      destination.origin?.x ?? 0,
      destination.origin?.y ?? 0,
      destination.origin?.z ?? 0,
      destination.aspect ?? 1,
      copySize.width,
      copySize.height,
      copySize.depthOrArrayLayers ?? 1,
    );
  },
  commandEncoderFinish(encoder) {
    encoder._finished = true;
    if (encoder._native == null) {
      const commands = encoder._commands;
      encoder._commands = [];
      if (
        commands.length > 0
        && !hasDeferredValidationCommand(commands)
        && !canSpecializeNodeDispatchCommands(commands)
        && !canSubmitNodeLazyCommandsBatched(commands)
      ) {
        const nativeCommandBuffer = finishNodeLazyCommandsAsNativeCommandBuffer(encoder, commands);
        if (nativeCommandBuffer) {
          invalidateLazyDispatchCommandBufferShadows(commands);
          return { _native: nativeCommandBuffer, _batched: false, _commands: commands };
        }
      }
      return { _commands: commands, _batched: true };
    }
    const cmd = addon.commandEncoderFinish(encoder._native);
    if (encodedBufferWrites.has(encoder)) recordedBufferWrites.set(cmd, encodedBufferWrites.get(encoder));
    encoder._native = null;
    return { _native: cmd, _batched: false };
  },
};

/**
 * Texture returned by `device.createTexture(...)`.
 *
 * This represents a headless Doe texture resource and can create default views
 * for render or sampling usage.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * const texture = device.createTexture({
 *   size: [64, 64, 1],
 *   format: "rgba8unorm",
 *   usage: GPUTextureUsage.RENDER_ATTACHMENT,
 * });
 * ```
 *
 * - The package currently exposes the texture operations needed by its headless surface.
 * - Texture views are created through `createView(...)`.
 */
const fullSurfaceBackend = {
  initTextureState(texture) {
    ensureTextureHostShadow(texture);
    nodeTextureWrappers.set(texture._native, texture);
  },
  initBufferState(buffer) {
    buffer._mapMode = 0;
    buffer._mappedWriteRanges = [];
    buffer._hostShadow = null;
    buffer._hostShadowValid = buffer.size <= NODE_BUFFER_HOST_SHADOW_MAX_BYTES;
    nodeBufferWrappers.set(buffer._native, buffer);
  },
  bufferMarkMappedAtCreation(buffer) {
    buffer._mapMode = globals.GPUMapMode.WRITE;
    buffer._mappedWriteRanges = [];
  },
  bufferMapAsync(wrapper, native, mode, offset, size) {
    if (size === 0 || wrapper.size === 0) {
      wrapper._mapMode = mode;
      if (mode === globals.GPUMapMode.WRITE) {
        wrapper._mappedWriteRanges = [];
      }
      return;
    }
    if (wrapper._queue) {
      if (wrapper._queue.hasPendingSubmissions()) {
        addon.flushAndMapSync(
          wrapper._instance,
          assertLiveResource(wrapper._queue, 'GPUBuffer.mapAsync', 'GPUQueue'),
          native,
          mode,
          offset,
          size,
        );
        wrapper._queue.markSubmittedWorkDone();
        fastPathStats.flushAndMap += 1;
      } else {
        addon.bufferMapSync(wrapper._instance, native, mode, offset, size);
      }
    } else {
      addon.bufferMapSync(wrapper._instance, native, mode, offset, size);
    }
    wrapper._mapMode = mode;
    if (mode === globals.GPUMapMode.WRITE) {
      wrapper._mappedWriteRanges = [];
    }
  },
  bufferMapReadCopyUnmap(wrapper, native, mode, offset, size) {
    if (mode !== globals.GPUMapMode.READ) {
      failValidation('GPUBuffer._mapReadCopyUnmap', 'only MAP_READ mode is supported');
    }
    providerDiagnosticStats.mapReadCalls += 1;
    if (size === 0) {
      wrapper.__doe_readback_breakdown_ns = ZERO_READBACK_BREAKDOWN_NS;
      wrapper._mapMode = 0;
      wrapper._mappedWriteRanges = [];
      return new ArrayBuffer(0);
    }
    const shadowCopy = readBufferHostShadow(wrapper, offset, size);
    if (shadowCopy != null) {
      wrapper.__doe_readback_breakdown_ns = ZERO_READBACK_BREAKDOWN_NS;
      wrapper._mapMode = 0;
      wrapper._mappedWriteRanges = [];
      return shadowCopy;
    }
    if (typeof addon.bufferMapReadCopyUnmap === 'function') {
      const shouldFlush = Boolean(wrapper._queue?.hasPendingSubmissions());
      const queueNative = shouldFlush
        ? assertLiveResource(wrapper._queue, 'GPUBuffer._mapReadCopyUnmap', 'GPUQueue')
        : null;
      const result = addon.bufferMapReadCopyUnmap(
        wrapper._instance,
        queueNative,
        native,
        mode,
        offset,
        size,
        shouldFlush,
      );
      if (shouldFlush) {
        wrapper._queue.markSubmittedWorkDone();
        fastPathStats.flushAndMap += 1;
      }
      if (result instanceof ArrayBuffer || ArrayBuffer.isView(result)) {
        wrapper.__doe_readback_breakdown_ns = ZERO_READBACK_BREAKDOWN_NS;
        wrapper._mapMode = 0;
        wrapper._mappedWriteRanges = [];
        return result;
      }
      wrapper.__doe_readback_breakdown_ns = {
        readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: Number(result?.waitCompletedNs ?? 0),
        readbackMapReadCopyUnmapDeferredCopyTotalNs: Number(result?.deferredCopyNs ?? 0),
        readbackMapReadCopyUnmapDeferredResolveTotalNs: Number(result?.deferredResolveNs ?? 0),
        readbackMapReadCopyUnmapMapTotalNs: Number(result?.mapNs ?? 0),
        readbackMapReadCopyUnmapCopyTotalNs: Number(result?.copyNs ?? 0),
        readbackMapReadCopyUnmapUnmapTotalNs: Number(result?.unmapNs ?? 0),
      };
      wrapper._mapMode = 0;
      wrapper._mappedWriteRanges = [];
      return result?.bytes;
    }
    const readbackBreakdownNs = {
      readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: 0,
      readbackMapReadCopyUnmapDeferredCopyTotalNs: 0,
      readbackMapReadCopyUnmapDeferredResolveTotalNs: 0,
      readbackMapReadCopyUnmapMapTotalNs: 0,
      readbackMapReadCopyUnmapCopyTotalNs: 0,
      readbackMapReadCopyUnmapUnmapTotalNs: 0,
    };
    if (wrapper._queue) {
      if (wrapper._queue.hasPendingSubmissions()) {
        const flushStartedAt = performance.now();
        const flushBreakdown = addon.queueFlush(
          wrapper._instance,
          assertLiveResource(wrapper._queue, 'GPUBuffer._mapReadCopyUnmap', 'GPUQueue'),
        );
        readbackBreakdownNs.readbackMapReadCopyUnmapQueueWaitCompletedTotalNs = Number(
          flushBreakdown?.waitCompletedNs ?? elapsedNsSince(flushStartedAt),
        );
        readbackBreakdownNs.readbackMapReadCopyUnmapDeferredCopyTotalNs = Number(
          flushBreakdown?.deferredCopyNs ?? 0,
        );
        readbackBreakdownNs.readbackMapReadCopyUnmapDeferredResolveTotalNs = Number(
          flushBreakdown?.deferredResolveNs ?? 0,
        );
        wrapper._queue.markSubmittedWorkDone();
      }
    }
    const mapStartedAt = performance.now();
    addon.bufferMapSync(wrapper._instance, native, mode, offset, size);
    readbackBreakdownNs.readbackMapReadCopyUnmapMapTotalNs = elapsedNsSince(mapStartedAt);
    wrapper._mapMode = mode;
    try {
      if (typeof addon.bufferReadCopy === 'function') {
        const copyStartedAt = performance.now();
        const copied = addon.bufferReadCopy(native, offset, size);
        readbackBreakdownNs.readbackMapReadCopyUnmapCopyTotalNs = elapsedNsSince(copyStartedAt);
        return copied;
      }
      const copyStartedAt = performance.now();
      const copied = addon.bufferGetMappedRange(native, offset, size).slice(0);
      readbackBreakdownNs.readbackMapReadCopyUnmapCopyTotalNs = elapsedNsSince(copyStartedAt);
      return copied;
    } finally {
      const unmapStartedAt = performance.now();
      wrapper._mapMode = 0;
      wrapper._mappedWriteRanges = [];
      addon.bufferUnmap(native);
      readbackBreakdownNs.readbackMapReadCopyUnmapUnmapTotalNs = elapsedNsSince(unmapStartedAt);
      wrapper.__doe_readback_breakdown_ns = readbackBreakdownNs;
    }
  },
  bufferGetMappedRange(wrapper, native, offset, size) {
    if (size === 0) {
      return new ArrayBuffer(0);
    }
    if (wrapper._mapMode === globals.GPUMapMode.WRITE) {
      const existing = bufferHostShadowView(wrapper, offset, size);
      const staged = existing == null ? new Uint8Array(size) : existing.slice();
      wrapper._mappedWriteRanges.push({ buf: staged, native, offset, size });
      return staged.buffer;
    }
    const shadowCopy = readBufferHostShadow(wrapper, offset, size);
    if (shadowCopy != null) {
      return shadowCopy;
    }
    const mapped = addon.bufferGetMappedRange(native, offset, size);
    return mapped ?? new ArrayBuffer(size);
  },
  bufferReadCopy(wrapper, native, offset, size) {
    if (size === 0) {
      return new ArrayBuffer(0);
    }
    const shadowCopy = readBufferHostShadow(wrapper, offset, size);
    if (shadowCopy != null) {
      return shadowCopy;
    }
    if (typeof addon.bufferReadCopy === 'function') {
      return addon.bufferReadCopy(native, offset, size);
    }
    return addon.bufferGetMappedRange(native, offset, size).slice(0);
  },
  bufferGetMapState(_wrapper, native) {
    if (typeof _wrapper?._mapState === 'string') {
      return _wrapper._mapState;
    }
    if (typeof addon.bufferGetMapState !== 'function') {
      return null;
    }
    return addon.bufferGetMapState(native);
  },
  bufferAssertMappedPrefixF32(_wrapper, native, expected, count) {
    return addon.bufferAssertMappedPrefixF32(native, expected, count);
  },
  bufferUnmap(native, wrapper) {
    for (const range of wrapper._mappedWriteRanges ?? []) {
      const bytes = ArrayBuffer.isView(range.buf)
        ? new Uint8Array(range.buf.buffer, range.buf.byteOffset, range.buf.byteLength)
        : new Uint8Array(range.buf);
      writeBufferHostShadow(wrapper, range.offset, bytes);
      if (range.size <= 0) {
        continue;
      }
      if (wrapper._queue) {
        addon.queueWriteBuffer(
          assertLiveResource(wrapper._queue, 'GPUBuffer.unmap', 'GPUQueue'),
          native,
          range.offset,
          bytes,
        );
      } else if (typeof addon.bufferFlushStagedRange === 'function') {
        addon.bufferFlushStagedRange(range.native, bytes, range.offset, range.size);
      }
    }
    wrapper._mappedWriteRanges = [];
    wrapper._mapMode = 0;
    if (wrapper.size > 0) {
      addon.bufferUnmap(native);
    }
  },
  bufferDestroy(native) {
    nodeBufferWrappers.delete(native);
    addon.bufferRelease(native);
  },
  initQueueState(queue) {
    queue._submittedSerial = 0;
    queue._completedSerial = 0;
    queue._submitBreakdownNs = zeroQueueSubmitBreakdown();
  },
  queueHasPendingSubmissions(queue) {
    return queue._completedSerial < queue._submittedSerial;
  },
  queueMarkSubmittedWorkDone(queue) {
    queue._completedSerial = queue._submittedSerial;
  },
  queueSubmit(queue, queueNative, buffers) {
    const deviceNative = assertLiveResource(queue._device, 'GPUQueue.submit', 'GPUDevice');
    queue._submittedSerial += 1;
    providerDiagnosticStats.queueSubmitCalls += 1;
    providerDiagnosticStats.submittedCommandBuffers += buffers.length;
    for (const commandBuffer of buffers) {
      invalidateSubmittedBufferWrites(commandBuffer);
      if (commandBuffer?._batched && Array.isArray(commandBuffer._commands)) {
        providerDiagnosticStats.submittedBatchedCommands += commandBuffer._commands.length;
      }
    }
    if (buffers.length === 1 && buffers[0]?._batched && Array.isArray(buffers[0]._commands)) {
      const prepStartedAt = submitTimingStart();
      failIfSubmittedCommandBuffer(buffers[0], 0);
      const cmds = buffers[0]._commands;
      if (captureDeferredValidationCommand(queue, cmds, buffers)) {
        accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);
        return;
      }
      accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);
      if (cmds.length === 0) {
        const bookkeepingStartedAt = submitTimingStart();
        queue.markSubmittedWorkDone();
        consumeSubmittedCommandBuffers(buffers);
        presentPendingCanvasContexts(queue);
        accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
        return;
      }
      if (tryApplySpecializedNodeDispatch(queueNative, cmds)) {
        const bookkeepingStartedAt = submitTimingStart();
        queue.markSubmittedWorkDone();
        consumeSubmittedCommandBuffers(buffers);
        presentPendingCanvasContexts(queue);
        accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
        return;
      }
      const addonStartedAt = submitTimingStart();
      invalidateLazyDispatchCommandBufferShadows(cmds);
      const addonBreakdown = addon.submitBatched(deviceNative, queueNative, cmds);
      accumulateQueueSubmitBreakdown(queue, 'submitAddonCallTotalNs', addonStartedAt);
      accumulateAddonSubmitBreakdown(queue, addonBreakdown);
      const addonCompletedSubmission = addonSubmitBreakdownIndicatesCompletedSubmission(addonBreakdown);
      if (addonCompletedSubmission) {
        fastPathStats.dispatchFlush += 1;
      }
      const bookkeepingStartedAt = submitTimingStart();
      if (addonCompletedSubmission) {
        queue.markSubmittedWorkDone();
      }
      consumeSubmittedCommandBuffers(buffers);
      presentPendingCanvasContexts(queue);
      accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
      return;
    }
    if (buffers.every((commandBuffer) => commandBuffer?._batched && Array.isArray(commandBuffer._commands))) {
      const prepStartedAt = submitTimingStart();
      for (let index = 0; index < buffers.length; index += 1) {
        failIfSubmittedCommandBuffer(buffers[index], index);
      }
      const allCommands = flattenBatchedCommands(buffers);
      if (captureDeferredValidationCommand(queue, allCommands, buffers)) {
        accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);
        return;
      }
      accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);
      if (allCommands.length === 0) {
        const bookkeepingStartedAt = submitTimingStart();
        queue.markSubmittedWorkDone();
        consumeSubmittedCommandBuffers(buffers);
        presentPendingCanvasContexts(queue);
        accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
        return;
      }
      if (tryApplySpecializedNodeDispatch(queueNative, allCommands)) {
        const bookkeepingStartedAt = submitTimingStart();
        queue.markSubmittedWorkDone();
        consumeSubmittedCommandBuffers(buffers);
        presentPendingCanvasContexts(queue);
        accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
        return;
      }
      const addonStartedAt = submitTimingStart();
      invalidateLazyDispatchCommandBufferShadows(allCommands);
      const addonBreakdown = addon.submitBatched(deviceNative, queueNative, allCommands);
      accumulateQueueSubmitBreakdown(queue, 'submitAddonCallTotalNs', addonStartedAt);
      accumulateAddonSubmitBreakdown(queue, addonBreakdown);
      const addonCompletedSubmission = addonSubmitBreakdownIndicatesCompletedSubmission(addonBreakdown);
      if (addonCompletedSubmission) {
        fastPathStats.dispatchFlush += 1;
      }
      const bookkeepingStartedAt = submitTimingStart();
      if (addonCompletedSubmission) {
        queue.markSubmittedWorkDone();
      }
      consumeSubmittedCommandBuffers(buffers);
      presentPendingCanvasContexts(queue);
      accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
      return;
    }
    if (buffers.some((commandBuffer) => commandBuffer?._batched && Array.isArray(commandBuffer._commands))) {
      const prepStartedAt = submitTimingStart();
      for (let index = 0; index < buffers.length; index += 1) {
        const commandBuffer = buffers[index];
        failIfSubmittedCommandBuffer(commandBuffer, index);
        const isBatched = commandBuffer?._batched && Array.isArray(commandBuffer._commands);
        if (!isBatched && (!commandBuffer || typeof commandBuffer !== 'object' || commandBuffer._native == null)) {
          failValidation('GPUQueue.submit', `commandBuffers[${index}] must be a finished command buffer`);
        }
      }
      const submissionCommands = buffers.flatMap((commandBuffer) => (
        Array.isArray(commandBuffer?._commands) ? commandBuffer._commands : []
      ));
      if (captureDeferredValidationCommand(queue, submissionCommands, buffers)) {
        accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);
        return;
      }
      invalidateLazyDispatchCommandBufferShadows(submissionCommands);
      accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);

      let segmentStart = 0;
      while (segmentStart < buffers.length) {
        const segmentIsBatched = buffers[segmentStart]?._batched
          && Array.isArray(buffers[segmentStart]._commands);
        let segmentEnd = segmentStart + 1;
        while (segmentEnd < buffers.length) {
          const nextIsBatched = buffers[segmentEnd]?._batched
            && Array.isArray(buffers[segmentEnd]._commands);
          if (nextIsBatched !== segmentIsBatched) {
            break;
          }
          segmentEnd += 1;
        }
        const segment = buffers.slice(segmentStart, segmentEnd);
        if (segmentIsBatched) {
          const commands = flattenBatchedCommands(segment);
          if (commands.length > 0 && !tryApplySpecializedNodeDispatch(queueNative, commands)) {
            const addonStartedAt = submitTimingStart();
            const addonBreakdown = addon.submitBatched(deviceNative, queueNative, commands);
            accumulateQueueSubmitBreakdown(queue, 'submitAddonCallTotalNs', addonStartedAt);
            accumulateAddonSubmitBreakdown(queue, addonBreakdown);
            if (addonSubmitBreakdownIndicatesCompletedSubmission(addonBreakdown)) {
              fastPathStats.dispatchFlush += 1;
            }
            if (segmentEnd < buffers.length) {
              const flushStartedAt = submitTimingStart();
              const flushBreakdown = addon.queueFlush(queue._instance, queueNative);
              accumulateQueueSubmitBreakdown(queue, 'submitQueueFlushTotalNs', flushStartedAt);
              accumulateQueueFlushBreakdown(queue, flushBreakdown);
            }
          }
        } else {
          const natives = segment.map((commandBuffer) => commandBuffer._native);
          const addonStartedAt = submitTimingStart();
          const addonBreakdown = natives.length === 1 && typeof addon.queueSubmitOne === 'function'
            ? addon.queueSubmitOne(queueNative, natives[0])
            : addon.queueSubmit(queueNative, natives);
          accumulateQueueSubmitBreakdown(queue, 'submitAddonCallTotalNs', addonStartedAt);
          accumulateAddonSubmitBreakdown(queue, addonBreakdown);
        }
        segmentStart = segmentEnd;
      }

      const bookkeepingStartedAt = submitTimingStart();
      consumeSubmittedCommandBuffers(buffers);
      presentPendingCanvasContexts(queue);
      accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
      return;
    }
    const prepStartedAt = submitTimingStart();
    let natives = null;
    let singleNative = null;
    if (buffers.length === 1) {
      const commandBuffer = buffers[0];
      failIfSubmittedCommandBuffer(commandBuffer, 0);
      if (!commandBuffer || typeof commandBuffer !== 'object' || commandBuffer._native == null) {
        failValidation('GPUQueue.submit', 'commandBuffers[0] must be a finished command buffer');
      }
      singleNative = commandBuffer._native;
    } else {
      natives = buffers.map((commandBuffer, index) => {
        failIfSubmittedCommandBuffer(commandBuffer, index);
        if (!commandBuffer || typeof commandBuffer !== 'object' || commandBuffer._native == null) {
          failValidation('GPUQueue.submit', `commandBuffers[${index}] must be a finished command buffer`);
        }
        return commandBuffer._native;
      });
    }
    accumulateQueueSubmitBreakdown(queue, 'submitCommandPrepTotalNs', prepStartedAt);
    const addonStartedAt = submitTimingStart();
    const addonBreakdown = singleNative != null && typeof addon.queueSubmitOne === 'function'
      ? addon.queueSubmitOne(queueNative, singleNative)
      : addon.queueSubmit(queueNative, natives ?? [singleNative]);
    accumulateQueueSubmitBreakdown(queue, 'submitAddonCallTotalNs', addonStartedAt);
    accumulateAddonSubmitBreakdown(queue, addonBreakdown);
    const bookkeepingStartedAt = submitTimingStart();
    consumeSubmittedCommandBuffers(buffers);
    presentPendingCanvasContexts(queue);
    accumulateQueueSubmitBreakdown(queue, 'submitPostSubmitBookkeepingTotalNs', bookkeepingStartedAt);
  },
  queueWriteBuffer(_queue, queueNative, bufferNative, bufferOffset, view) {
    if (view.byteLength === 0) {
      return;
    }
    providerDiagnosticStats.queueWriteBufferCalls += 1;
    providerDiagnosticStats.queueWriteBufferBytes += view.byteLength;
    const writeStartedAt = submitTimingStart();
    addon.queueWriteBuffer(queueNative, bufferNative, bufferOffset, view);
    writeBufferHostShadowByNative(bufferNative, bufferOffset, view);
    accumulateProviderDiagnosticTime('queueWriteBufferTotalNs', writeStartedAt);
  },
  queueWriteBufferBatch(_queue, queueNative, entries) {
    if (!entries.length) {
      return;
    }
    const batchStartedAt = submitTimingStart();
    providerDiagnosticStats.queueWriteBufferBatchCalls += 1;
    for (const entry of entries) {
      if (entry.view.byteLength > 0) {
        providerDiagnosticStats.queueWriteBufferCalls += 1;
        providerDiagnosticStats.queueWriteBufferBytes += entry.view.byteLength;
      }
    }
    const hasDataPtrBatch = typeof addon.queueWriteBufferBatchDataPtrs === 'function';
    const hasCompactBatch = typeof addon.queueWriteBufferBatch === 'function';
    if (!hasDataPtrBatch && !hasCompactBatch) {
      for (const entry of entries) {
        if (entry.view.byteLength > 0) {
          addon.queueWriteBuffer(queueNative, entry.bufferNative, entry.bufferOffset, entry.view);
          writeBufferHostShadowByNative(entry.bufferNative, entry.bufferOffset, entry.view);
        }
      }
      accumulateProviderDiagnosticTime('queueWriteBufferBatchTotalNs', batchStartedAt);
      return;
    }
    const nonEmptyEntries = entries.filter(entry => entry.view.byteLength > 0);
    if (!nonEmptyEntries.length) {
      accumulateProviderDiagnosticTime('queueWriteBufferBatchTotalNs', batchStartedAt);
      return;
    }
    let byteLength = 0;
    for (const entry of nonEmptyEntries) {
      if (entry.view.byteLength > UINT32_MAX) {
        failValidation('GPUQueue.__doeWriteBufferBatch', 'entry data is too large for the native batch ABI');
      }
      byteLength += entry.view.byteLength;
    }
    if (!hasDataPtrBatch && byteLength > NODE_QUEUE_WRITE_BATCH_MAX_BYTES) {
      failValidation('GPUQueue.__doeWriteBufferBatch', 'compact batch data exceeds the package batch limit');
    }
    const buffers = new Array(nonEmptyEntries.length);
    const offsets = new BigUint64Array(nonEmptyEntries.length);
    const sizes = new Uint32Array(nonEmptyEntries.length);
    const dataViews = hasDataPtrBatch ? new Array(nonEmptyEntries.length) : null;
    if (hasDataPtrBatch) {
      for (let index = 0; index < nonEmptyEntries.length; index += 1) {
        const entry = nonEmptyEntries[index];
        buffers[index] = entry.bufferNative;
        offsets[index] = BigInt(entry.bufferOffset);
        sizes[index] = entry.view.byteLength;
        dataViews[index] = entry.view;
        writeBufferHostShadowByNative(entry.bufferNative, entry.bufferOffset, entry.view);
      }
      addon.queueWriteBufferBatchDataPtrs(queueNative, buffers, offsets, sizes, dataViews);
      accumulateProviderDiagnosticTime('queueWriteBufferBatchTotalNs', batchStartedAt);
      return;
    }
    const data = new Uint8Array(byteLength);
    let dataOffset = 0;
    for (let index = 0; index < nonEmptyEntries.length; index += 1) {
      const entry = nonEmptyEntries[index];
      buffers[index] = entry.bufferNative;
      offsets[index] = BigInt(entry.bufferOffset);
      sizes[index] = entry.view.byteLength;
      data.set(entry.view, dataOffset);
      dataOffset += entry.view.byteLength;
      writeBufferHostShadowByNative(entry.bufferNative, entry.bufferOffset, entry.view);
    }
    addon.queueWriteBufferBatch(queueNative, buffers, offsets, sizes, data);
    accumulateProviderDiagnosticTime('queueWriteBufferBatchTotalNs', batchStartedAt);
  },
  queueWriteTexture(_queue, queueNative, destination, data, dataLayout, size) {
    addon.queueWriteTexture(
      queueNative,
      destination.texture,
      data,
      dataLayout.offset ?? 0,
      dataLayout.bytesPerRow ?? 0,
      dataLayout.rowsPerImage ?? 0,
      destination.mipLevel ?? 0,
      destination.origin?.x ?? 0,
      destination.origin?.y ?? 0,
      destination.origin?.z ?? 0,
      size.width,
      size.height,
      size.depthOrArrayLayers ?? 1,
    );
    const texture = textureWrapperForNative(destination.texture);
    if (texture != null) {
      texture._hostShadowValid = false;
    }
  },
  async queueOnSubmittedWorkDone(queue, queueNative) {
    if (!queue.hasPendingSubmissions()) {
      return;
    }
    try {
      const flushStartedAt = submitTimingStart();
      const flushBreakdown = addon.queueFlush(queue._instance, queueNative);
      accumulateQueueSubmitBreakdown(queue, 'submitQueueFlushTotalNs', flushStartedAt);
      accumulateQueueFlushBreakdown(queue, flushBreakdown);
      const bookkeepingStartedAt = submitTimingStart();
      queue.markSubmittedWorkDone();
      accumulateQueueSubmitBreakdown(queue, 'submitQueueWaitBookkeepingTotalNs', bookkeepingStartedAt);
    } catch (error) {
      if (error?.code === 'DOE_QUEUE_UNAVAILABLE') {
        return;
      }
      throw error;
    }
  },
  textureCreateView(_texture, native, descriptor) {
    if (!descriptor) {
      const view = addon.textureCreateView(native);
      nodeTextureViewDescriptors.set(view, {
        texture: _texture,
        descriptor: {
          dimension: _texture?.dimension ?? '2d',
          baseMipLevel: 0,
          mipLevelCount: _texture?.mipLevelCount ?? 1,
          baseArrayLayer: 0,
          arrayLayerCount: _texture?.depthOrArrayLayers ?? 1,
          aspect: 'all',
        },
      });
      return view;
    }
    const viewDescriptor = { ...descriptor };
    if (descriptor.dimension !== undefined) {
      viewDescriptor.dimension = typeof descriptor.dimension === 'number'
        ? descriptor.dimension
        : (TEXTURE_VIEW_DIMENSION_MAP[descriptor.dimension] ?? 0);
    }
    if (descriptor.aspect !== undefined) {
      viewDescriptor.aspect = typeof descriptor.aspect === 'number'
        ? descriptor.aspect
        : (TEXTURE_ASPECT_MAP[descriptor.aspect] ?? 0);
    }
    if (typeof descriptor.swizzle === 'string' && descriptor.swizzle.length === 4) {
      viewDescriptor.swizzle = descriptor.swizzle;
      viewDescriptor.swizzleR = TEXTURE_SWIZZLE_COMPONENT_MAP[descriptor.swizzle[0]] ?? 0;
      viewDescriptor.swizzleG = TEXTURE_SWIZZLE_COMPONENT_MAP[descriptor.swizzle[1]] ?? 0;
      viewDescriptor.swizzleB = TEXTURE_SWIZZLE_COMPONENT_MAP[descriptor.swizzle[2]] ?? 0;
      viewDescriptor.swizzleA = TEXTURE_SWIZZLE_COMPONENT_MAP[descriptor.swizzle[3]] ?? 0;
    }
    const view = addon.textureCreateView(native, viewDescriptor);
    nodeTextureViewDescriptors.set(view, { texture: _texture, descriptor });
    return view;
  },
  textureDestroy(native, texture) {
    nodeTextureWrappers.delete(native);
    if (texture?._externallyOwned) {
      if (typeof texture?._nativeCanvasRelease === 'function') {
        texture._nativeCanvasRelease(native, texture);
      }
      return;
    }
    addon.textureRelease(native);
  },
  shaderModuleDestroy(native) {
    if (isNodeFallbackShader(native)) {
      return;
    }
    addon.shaderModuleRelease(native);
  },
  shaderModuleGetCompilationInfo(_shaderModule, native) {
    if (isNodeFallbackShader(native)) {
      return { messages: [] };
    }
    return addon.shaderModuleGetCompilationInfo(native);
  },
  computePipelineGetBindGroupLayout(pipeline, index, classes) {
    if (pipeline._autoLayoutEntriesByGroup) {
      const entries = pipeline._autoLayoutEntriesByGroup.get(index) ?? [];
      return pipeline._device.createBindGroupLayout({ entries });
    }
    if (typeof addon.computePipelineGetBindGroupLayout === 'function') {
      return new classes.DoeGPUBindGroupLayout(
        addon.computePipelineGetBindGroupLayout(pipeline._native, index),
        pipeline._device,
      );
    }
    if (pipeline._autoLayoutEntriesByGroup) {
      const entries = pipeline._autoLayoutEntriesByGroup.get(index) ?? [];
      return pipeline._device.createBindGroupLayout({ entries });
    }
    return pipeline._device.createBindGroupLayout({ entries: [] });
  },
  renderPipelineGetBindGroupLayout(pipeline, index, classes) {
    if (typeof addon.renderPipelineGetBindGroupLayout === 'function') {
      return new classes.DoeGPUBindGroupLayout(
        addon.renderPipelineGetBindGroupLayout(pipeline._native, index),
        pipeline,
      );
    }
    return new classes.DoeGPUBindGroupLayout(null, pipeline);
  },
  deviceCreateRenderBundleEncoder(device, descriptor, encoderClasses) {
    const colorFormats = Array.isArray(descriptor.colorFormats) ? descriptor.colorFormats : [];
    const native = addon.createRenderBundleEncoder(
      assertLiveResource(device, 'GPUDevice.createRenderBundleEncoder', 'GPUDevice'),
      colorFormats,
      descriptor.depthStencilFormat ?? null,
      descriptor.sampleCount ?? 1,
      descriptor.depthReadOnly ?? false,
      descriptor.stencilReadOnly ?? false,
      descriptor.label ?? null,
    );
    return new encoderClasses.DoeGPURenderBundleEncoder(native, device);
  },
  deviceLimits,
  deviceFeatures,
  adapterLimits,
  adapterFeatures,
  preflightShaderSource,
  preflightShaderSourceOnCreate: false,
  requireAutoLayoutEntriesFromNative(shader, visibility, path, entryPoint) {
    return requireAutoLayoutEntriesFromNative(
      assertLiveResource(shader, path, 'GPUShaderModule'),
      visibility,
      path,
      entryPoint,
    );
  },
  deviceGetQueue(native) {
    return addon.deviceGetQueue(native);
  },
  deviceCreateBuffer(device, validated) {
    const nativeDescriptor = validated.size === 0
      ? { ...validated, size: NODE_ZERO_SIZE_BUFFER_NATIVE_BYTES, mappedAtCreation: false }
      : validated;
    const native = addon.createBuffer(assertLiveResource(device, 'GPUDevice.createBuffer', 'GPUDevice'), nativeDescriptor);
    nodeBufferSizes.set(native, validated.size);
    return native;
  },
  deviceCreateShaderModule(device, code, compilationHints, label = null) {
    const fallback = analyzeTextureDimensionsShader(code);
    if (fallback) {
      assertLiveResource(device, 'GPUDevice.createShaderModule', 'GPUDevice');
      const native = makeNodeFallbackShaderModule(code, fallback);
      nodeShaderSources.set(native, code);
      return native;
    }
    try {
      const native = addon.createShaderModule(
        assertLiveResource(device, 'GPUDevice.createShaderModule', 'GPUDevice'),
        code,
        compilationHints ?? null,
        label,
      );
      nodeShaderSources.set(native, code);
      return native;
    } catch (error) {
      throw enrichNativeCompilerError(error, 'GPUDevice.createShaderModule', readLastErrorFields());
    }
  },
  deviceCreateComputePipeline(device, shaderNative, entryPoint, layoutNative, constants, label) {
    try {
      if (isNodeFallbackShader(shaderNative, NODE_FALLBACK_TEXTURE_DIMENSIONS)) {
        assertLiveResource(device, 'GPUDevice.createComputePipeline', 'GPUDevice');
        const native = makeNodeFallbackPipeline(shaderNative, 'compute', entryPoint);
        nodeComputePipelineSources.set(native, nodeShaderSources.get(shaderNative) ?? '');
        return native;
      }
      const native = addon.createComputePipeline(
        assertLiveResource(device, 'GPUDevice.createComputePipeline', 'GPUDevice'),
        shaderNative,
        entryPoint,
        layoutNative,
        constants,
        label,
      );
      nodeComputePipelineSources.set(native, nodeShaderSources.get(shaderNative) ?? '');
      return native;
    } catch (error) {
      throw pipelineErrorFromError(error, 'GPUDevice.createComputePipeline', readLastErrorFields());
    }
  },
  deviceCreateBindGroupLayout(device, entries, label) {
    if (entries.some((entry) => entry.externalTexture)) {
      failValidation(
        'GPUDevice.createBindGroupLayout',
        'externalTexture bindings require a browser canvas backend provider, not the headless Doe runtime package surface',
      );
    }
    return addon.createBindGroupLayout(assertLiveResource(device, 'GPUDevice.createBindGroupLayout', 'GPUDevice'), entries, label);
  },
  deviceCreateBufferBindGroupLayoutFlat4(device, entryCount, b0, b1, b2, b3, label) {
    if (label !== undefined || typeof addon.createBufferBindGroupLayoutFlat4 !== 'function') {
      return undefined;
    }
    return addon.createBufferBindGroupLayoutFlat4(
      assertLiveResource(device, 'GPUDevice.createBindGroupLayout', 'GPUDevice'),
      entryCount,
      b0,
      b1,
      b2,
      b3,
    );
  },
  deviceCreateBindGroup(device, layoutNative, entries, label) {
    if (entries.some((entry) => entry.externalTexture)) {
      failValidation(
        'GPUDevice.createBindGroup',
        'externalTexture resources require a browser canvas backend provider, not the headless Doe runtime package surface',
      );
    }
    const native = addon.createBindGroup(
      assertLiveResource(device, 'GPUDevice.createBindGroup', 'GPUDevice'),
      layoutNative,
      entries,
      label,
    );
    nodeBindGroupEntries.set(native, entries.map(entry => ({
      binding: entry.binding,
      buffer: entry.buffer ?? null,
      textureView: entry.textureView ?? null,
      offset: entry.offset ?? 0,
      size: entry.size,
    })));
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
    label,
  ) {
    if (label !== undefined || typeof addon.createBufferBindGroupFlat4 !== 'function') {
      return undefined;
    }
    const native = addon.createBufferBindGroupFlat4(
      assertLiveResource(device, 'GPUDevice.createBindGroup', 'GPUDevice'),
      layoutNative,
      entryCount,
      b0,
      entryCount > 0 ? buffer0 : null,
      offset0,
      b1,
      entryCount > 1 ? buffer1 : null,
      offset1,
      b2,
      entryCount > 2 ? buffer2 : null,
      offset2,
      b3,
      entryCount > 3 ? buffer3 : null,
      offset3,
    );
    nodeBindGroupEntries.set(native, [
      { binding: b0, buffer: entryCount > 0 ? buffer0 : null, offset: offset0, size: undefined },
      { binding: b1, buffer: entryCount > 1 ? buffer1 : null, offset: offset1, size: undefined },
      { binding: b2, buffer: entryCount > 2 ? buffer2 : null, offset: offset2, size: undefined },
      { binding: b3, buffer: entryCount > 3 ? buffer3 : null, offset: offset3, size: undefined },
    ].slice(0, entryCount));
    return native;
  },
  deviceCreatePipelineLayout(device, layouts, label, immediateSize = 0) {
    if (
      layouts.length === 1
      && label === undefined
      && typeof addon.createPipelineLayoutOne === 'function'
    ) {
      return addon.createPipelineLayoutOne(
        assertLiveResource(device, 'GPUDevice.createPipelineLayout', 'GPUDevice'),
        layouts[0],
        immediateSize,
      );
    }
    return addon.createPipelineLayout(
      assertLiveResource(device, 'GPUDevice.createPipelineLayout', 'GPUDevice'),
      layouts,
      label,
      immediateSize,
    );
  },
  deviceCreateTexture(device, textureDescriptor, size, usage) {
    const desc = {
      label: textureDescriptor.label ?? '',
      format: textureDescriptor.format || 'rgba8unorm',
      width: size.width,
      height: size.height,
      depthOrArrayLayers: size.depthOrArrayLayers,
      dimension: TEXTURE_DIMENSION_MAP[textureDescriptor.dimension ?? '2d'] ?? 2,
      usage,
      mipLevelCount: assertIntegerInRange(textureDescriptor.mipLevelCount ?? 1, 'GPUDevice.createTexture', 'descriptor.mipLevelCount', { min: 1, max: UINT32_MAX }),
      sampleCount: assertIntegerInRange(textureDescriptor.sampleCount ?? 1, 'GPUDevice.createTexture', 'descriptor.sampleCount', { min: 1, max: UINT32_MAX }),
      viewFormats: Array.isArray(textureDescriptor.viewFormats) ? textureDescriptor.viewFormats : [],
    };
    if (textureDescriptor.textureBindingViewDimension) {
      desc.textureBindingViewDimension = textureDescriptor.textureBindingViewDimension;
    }
    return addon.createTexture(assertLiveResource(device, 'GPUDevice.createTexture', 'GPUDevice'), desc);
  },
  deviceCreateSampler(device, descriptor) {
    return addon.createSampler(assertLiveResource(device, 'GPUDevice.createSampler', 'GPUDevice'), descriptor);
  },
  deviceCreateRenderPipeline(device, descriptor) {
    try {
      if (
        isNodeFallbackShader(descriptor.vertexModule, NODE_FALLBACK_TEXTURE_DIMENSIONS)
        && descriptor.vertexModule === descriptor.fragmentModule
      ) {
        assertLiveResource(device, 'GPUDevice.createRenderPipeline', 'GPUDevice');
        return makeNodeFallbackPipeline(descriptor.vertexModule, 'render', descriptor.vertexEntryPoint);
      }
      const fragmentTarget = descriptor.fragmentTarget ?? { format: descriptor.colorFormat ?? 'rgba8unorm' };
      return addon.createRenderPipeline(
        assertLiveResource(device, 'GPUDevice.createRenderPipeline', 'GPUDevice'),
        {
          layout: descriptor.layout,
          vertex: {
            module: descriptor.vertexModule,
            entryPoint: descriptor.vertexEntryPoint,
            buffers: descriptor.vertexBuffers ?? [],
            constants: descriptor.vertexConstants ?? null,
          },
          fragment: {
            module: descriptor.fragmentModule,
            entryPoint: descriptor.fragmentEntryPoint,
            constants: descriptor.fragmentConstants ?? null,
            targets: [{
              format: fragmentTarget.format,
              writeMask: fragmentTarget.writeMask,
              blend: fragmentTarget.blend ?? undefined,
            }],
          },
          primitive: descriptor.primitive ? {
            topology: descriptor.primitive.topology ?? 'triangle-list',
            frontFace: descriptor.primitive.frontFace ?? 'ccw',
            cullMode: descriptor.primitive.cullMode ?? 'none',
            unclippedDepth: descriptor.primitive.unclippedDepth ?? false,
          } : undefined,
          multisample: descriptor.multisample ? {
            count: descriptor.multisample.count ?? 1,
            mask: descriptor.multisample.mask ?? 0xFFFF_FFFF,
            alphaToCoverageEnabled: descriptor.multisample.alphaToCoverageEnabled ?? false,
          } : undefined,
          depthStencil: descriptor.depthStencil ? {
            format: descriptor.depthStencil.format,
            depthWriteEnabled: descriptor.depthStencil.depthWriteEnabled ?? false,
            depthCompare: descriptor.depthStencil.depthCompare ?? 'always',
            stencilFront: descriptor.depthStencil.stencilFront ?? undefined,
            stencilBack: descriptor.depthStencil.stencilBack ?? undefined,
            stencilReadMask: descriptor.depthStencil.stencilReadMask ?? 0xFFFF_FFFF,
            stencilWriteMask: descriptor.depthStencil.stencilWriteMask ?? 0xFFFF_FFFF,
            depthBias: descriptor.depthStencil.depthBias ?? 0,
            depthBiasSlopeScale: descriptor.depthStencil.depthBiasSlopeScale ?? 0,
            depthBiasClamp: descriptor.depthStencil.depthBiasClamp ?? 0,
          } : undefined,
        },
      );
    } catch (error) {
      throw pipelineErrorFromError(error, 'GPUDevice.createRenderPipeline', readLastErrorFields());
    }
  },
  deviceCreateQuerySet(device, descriptor) {
    const QUERY_TYPE_OCCLUSION = 1;
    const QUERY_TYPE_TIMESTAMP = 2;
    const querySet = addon.createQuerySet(
      assertLiveResource(device, 'GPUDevice.createQuerySet', 'GPUDevice'),
      descriptor.type === 'occlusion' ? QUERY_TYPE_OCCLUSION : QUERY_TYPE_TIMESTAMP,
      descriptor.count,
    );
    if (descriptor.label && typeof addon.objectSetLabel === 'function') {
      addon.objectSetLabel(querySet, descriptor.label);
    }
    return querySet;
  },
  querySetDestroy(native) {
    addon.querySetDestroy(native);
  },
  deviceCreateCommandEncoder(device) {
    return new DoeGPUCommandEncoder(null, device);
  },
  devicePushErrorScope(_wrapper, native, _filter, encodedFilter) {
    if (typeof addon?.devicePushErrorScope !== 'function') {
      return;
    }
    try {
      addon.devicePushErrorScope(native, encodedFilter);
    } catch (error) {
      if (String(error?.message ?? '').includes('not available')) {
        return;
      }
      throw error;
    }
  },
  devicePopErrorScope(wrapper, native) {
    if (typeof addon?.devicePopErrorScope !== 'function') {
      return Promise.resolve(null);
    }
    try {
      return Promise.resolve(createGpuError(addon.devicePopErrorScope(native, wrapper._instance ?? null)));
    } catch (error) {
      if (String(error?.message ?? '').includes('not available')) {
        return Promise.resolve(null);
      }
      throw error;
    }
  },
  deviceDestroy(native) {
    addon.deviceRelease(native);
  },
  adapterGetInfo(_adapter, native) {
    if (typeof addon.adapterGetInfo !== 'function') {
      return emptyAdapterInfo();
    }
    return Object.freeze(addon.adapterGetInfo(native));
  },
  adapterRequestDevice(adapter, _descriptor, classes) {
    assertLiveResource(adapter, 'GPUAdapter.requestDevice', 'GPUAdapter');
    const descriptor = _descriptor === undefined
      ? undefined
      : {
        ..._descriptor,
        requiredLimits: undefined,
      };
    const native = addon.requestDevice(adapter._instance, adapter._native, descriptor);
    const device = new classes.DoeGPUDevice(native, adapter._instance);
    device.label = descriptor?.label ?? '';
    if (device.queue) {
      device.queue.label = descriptor?.defaultQueue?.label ?? '';
    }
    device._adapter = adapter;
    device._adapterInfo = adapter.info;
    installNodeDeviceCallbacks(device);
    registerNativeProgramProvider(device, {
      contractVersion: addon.nativeComputeProgramContractVersion?.() ?? 0,
      gpuRecorded: addon.computeProgramSupported?.() ?? false,
      timestampInfo: () => addon.computeProgramTimestampInfo?.(device._native) ?? null,
      isLost: () => device._destroyed || device._lostInfo !== null,
      materializeEncoder: ensureNodeCommandEncoderNative,
      prepare(commandBuffer, execution = 'native-recorded') {
        if (commandBuffer._native == null || commandBuffer._batched) {
          commandBuffer.destroy();
          throw new Error('DOE_PROGRAM_UNSUPPORTED: program requires a native command recording');
        }
        let gpuProgram = null;
        try {
          if (execution === 'gpu-recorded') gpuProgram = addon.computeProgramPrepare(device.queue._native, commandBuffer._native);
        } catch (error) {
          commandBuffer.destroy();
          throw error;
        }
        return {
          submit() {
            assertLiveResource(device, 'compute program submit', 'GPUDevice');
            assertLiveResource(commandBuffer, 'compute program submit', 'GPUCommandBuffer');
            invalidateSubmittedBufferWrites(commandBuffer);
            device.queue._submittedSerial += 1;
            providerDiagnosticStats.queueSubmitCalls += 1;
            providerDiagnosticStats.submittedCommandBuffers += 1;
            if (gpuProgram) addon.computeProgramSubmit(gpuProgram);
            else addon.queueSubmitOne(device.queue._native, commandBuffer._native);
          },
          destroy() {
            if (gpuProgram) { addon.computeProgramRelease(gpuProgram); gpuProgram = null; }
            commandBuffer.destroy();
          },
        };
      },
    });
    return device;
  },
  adapterDestroy(native) {
    addon.adapterRelease(native);
  },
  gpuRequestAdapter(gpu, options, classes) {
    const adapter = addon.requestAdapter(gpu._instance, options);
    return new classes.DoeGPUAdapter(adapter, gpu._instance, options);
  },
};

/**
 * Create a package-local `GPU` object backed by the Doe native runtime.
 *
 * This loads the addon/runtime if needed, creates a fresh GPU instance, and
 * returns an object with `requestAdapter(...)`.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { create } from "doe-gpu";
 *
 * const gpu = create();
 * const adapter = await gpu.requestAdapter();
 * ```
 *
 * - Throws if the native addon or `libwebgpu_doe` cannot be found.
 * - `createArgs` are currently accepted for API stability but ignored by the default Doe-native provider path.
 */
export function create(createArgs = null) {
  ensureLibrary();
  ensureFullSurfaceClasses();
  const instance = currentAddon().createInstance();
  return new DoeGPU(instance);
}

export function createInstance(createArgs = null) {
  return create(createArgs);
}

export function createNativeDirect(createArgs = null) {
  ensureLibrary();
  const nativeAddon = currentAddon();
  if (typeof nativeAddon?.nativeDirectCreate !== 'function') {
    failValidation(
      'createNativeDirect',
      'native-direct WebGPU surface is unavailable in this doe-gpu build',
    );
  }
  return nativeAddon.nativeDirectCreate();
}

export function createCanvasContext(canvas) {
  ensureLibrary();
  ensureCanvasSurfaceClasses();
  if (!ensureNativeMetalCanvasBackend() || typeof DoeGPUCanvasContext !== 'function') {
    failValidation(
      'createCanvasContext',
      'native Metal GPUCanvasContext is unavailable on this host/runtime',
    );
  }
  return new DoeGPUCanvasContext(canvas);
}

export function setNativeTimeoutMs(timeoutMs) {
  ensureLibrary();
  validatePositiveInteger(timeoutMs, 'native timeout');
  if (typeof addon.setTimeoutMs !== 'function') {
    throw new Error('setNativeTimeoutMs is not supported by the loaded addon.');
  }
  addon.setTimeoutMs(timeoutMs);
}

/**
 * Install the package WebGPU globals onto a target object and return its GPU.
 *
 * This adds missing enum globals plus `navigator.gpu` to `target`, then
 * returns the created package-local GPU object.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { setupGlobals } from "doe-gpu";
 *
 * setupGlobals(globalThis);
 * const adapter = await navigator.gpu.requestAdapter();
 * ```
 *
 * - Existing properties are preserved; this only fills in missing globals.
 * - If `target.navigator` exists without `gpu`, only `navigator.gpu` is added.
 * - The returned GPU is still headless/package-owned, not browser DOM ownership or browser-process parity.
 */
export function setupGlobals(target = globalThis, createArgs = null) {
  const gpu = create(createArgs);
  return setupGlobalsOnTarget(target, gpu, WEBGPU_GLOBALS);
}

/**
 * Request a Doe-backed adapter from the full package surface.
 *
 * This is a convenience wrapper over `create(...).requestAdapter(...)`.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { requestAdapter } from "doe-gpu";
 *
 * const adapter = await requestAdapter();
 * ```
 *
 * - Returns `null` if no adapter is available.
 * - `adapterOptions` are accepted for WebGPU shape compatibility; the current Doe package path does not use them for adapter filtering.
 */
export async function requestAdapter(adapterOptions = undefined, createArgs = null) {
  return requestAdapterFromCreate(create, adapterOptions, createArgs);
}

/**
 * Request a Doe-backed device from the full package surface.
 *
 * This creates a package-local GPU, requests an adapter, then requests a
 * device from that adapter.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { requestDevice } from "doe-gpu";
 *
 * const device = await requestDevice();
 * const buffer = device.createBuffer({
 *   size: 16,
 *   usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
 * });
 * ```
 *
 * - On the full package surface, the returned device includes render, texture, sampler, and surface APIs when the runtime supports them.
 * - Missing runtime prerequisites still fail at request time through the same addon/library checks as `create()`.
 */
export async function requestDevice(options = {}) {
  return requestDeviceFromRequestAdapter(requestAdapter, options);
}

/**
 * Report how the package resolved and loaded the Doe runtime.
 *
 * This returns package/runtime provenance such as whether the native path is
 * loaded, which library flavor was chosen, and whether build metadata says the
 * runtime was built with Lean-verified mode.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { providerInfo } from "doe-gpu";
 *
 * console.log(providerInfo());
 * ```
 *
 * - If metadata is unavailable, `leanVerifiedBuild` is `null` rather than a guess.
 * - `loaded: false` is still diagnostically useful before attempting `requestDevice()`.
 */
export function providerInfo() {
  const nativeAddon = currentAddon();
  const libraryPath = currentDoeLibraryPath();
  const buildMetadata = currentDoeBuildMetadata();
  const flavor = libraryFlavor(libraryPath);
  let nativeFastPaths = null;
  if (nativeAddon && libraryPath) {
    try {
      ensureLibrary();
      if (typeof nativeAddon.nativeFastPathInfo === 'function') {
        nativeFastPaths = nativeAddon.nativeFastPathInfo();
      }
    } catch {
      nativeFastPaths = null;
    }
  }
  return buildProviderInfo({
    loaded: !!nativeAddon && !!libraryPath,
    loadError: !nativeAddon ? 'native addon not found' : !libraryPath ? 'libwebgpu_doe not found' : '',
    defaultCreateArgs: [],
    doeNative: flavor === 'doe-dropin',
    libraryFlavor: flavor,
    doeLibraryPath: libraryPath ?? '',
    buildMetadataSource: buildMetadata.source,
    buildMetadataPath: buildMetadata.path,
    leanVerifiedBuild: buildMetadata.leanVerifiedBuild,
    proofArtifactSha256: buildMetadata.proofArtifactSha256,
    nativeFastPaths,
  });
}

export function nativeFastPathInfo() {
  ensureLibrary();
  const nativeAddon = currentAddon();
  if (!nativeAddon || typeof nativeAddon.nativeFastPathInfo !== 'function') {
    return null;
  }
  return nativeAddon.nativeFastPathInfo();
}

export function providerDiagnostics() {
  return {
    fastPathStats: { ...fastPathStats },
    queueSubmitCalls: providerDiagnosticStats.queueSubmitCalls,
    submittedCommandBuffers: providerDiagnosticStats.submittedCommandBuffers,
    submittedBatchedCommands: providerDiagnosticStats.submittedBatchedCommands,
    queueWriteBufferCalls: providerDiagnosticStats.queueWriteBufferCalls,
    queueWriteBufferBytes: providerDiagnosticStats.queueWriteBufferBytes,
    queueWriteBufferTotalNs: providerDiagnosticStats.queueWriteBufferTotalNs,
    queueWriteBufferBatchCalls: providerDiagnosticStats.queueWriteBufferBatchCalls,
    queueWriteBufferBatchTotalNs: providerDiagnosticStats.queueWriteBufferBatchTotalNs,
    mapReadCalls: providerDiagnosticStats.mapReadCalls,
    submitBreakdownNs: { ...providerDiagnosticStats.submitBreakdownNs },
  };
}

function commandNativeResource(value, path, label) {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'object' && '_native' in value) {
    return assertLiveResource(value, path, label);
  }
  return value;
}

function prewarmCommandForAddon(cmd, index) {
  if (!cmd || typeof cmd !== 'object') {
    return cmd;
  }
  if (Number(cmd.t) !== 0) {
    return { t: Number(cmd.t) || 0 };
  }
  const packed = {
    ...cmd,
    t: 0,
    p: commandNativeResource(cmd.p, `prewarmPreparedDispatches[${index}].pipeline`, 'GPUComputePipeline'),
  };
  if ('b' in cmd) {
    packed.b = commandNativeResource(cmd.b, `prewarmPreparedDispatches[${index}].bindGroup`, 'GPUBindGroup');
  }
  if (Array.isArray(cmd.bg)) {
    packed.bg = cmd.bg.map((bg, bgIndex) => commandNativeResource(
      bg,
      `prewarmPreparedDispatches[${index}].bindGroups[${bgIndex}]`,
      'GPUBindGroup',
    ));
  }
  return packed;
}

export function prewarmPreparedDispatches(queue, dispatchCommands) {
  ensureLibrary();
  const nativeAddon = currentAddon();
  if (!nativeAddon || typeof nativeAddon.prewarmPreparedDispatches !== 'function') {
    return { available: false, requestedCount: 0, preparedCount: 0 };
  }
  const commands = Array.isArray(dispatchCommands) ? dispatchCommands : [];
  const native = assertLiveResource(queue, 'prewarmPreparedDispatches', 'GPUQueue');
  const packedCommands = commands.map((cmd, index) => prewarmCommandForAddon(cmd, index));
  const preparedCount = nativeAddon.prewarmPreparedDispatches(native, packedCommands);
  return {
    available: true,
    requestedCount: commands.length,
    preparedCount: Number(preparedCount) || 0,
  };
}

export function nativeQueueSyncInfo(queue) {
  ensureLibrary();
  const nativeAddon = currentAddon();
  if (!nativeAddon || typeof nativeAddon.queueSyncInfo !== 'function') {
    return null;
  }
  const native = assertLiveResource(queue, 'nativeQueueSyncInfo', 'GPUQueue');
  const info = nativeAddon.queueSyncInfo(native);
  if (!info || typeof info !== 'object') {
    return null;
  }
  return {
    backendVulkan: Boolean(info.backendVulkan),
    timelineSemaphore: Boolean(info.timelineSemaphore),
    fencePool: Boolean(info.fencePool),
    deferredSubmissions: Boolean(info.deferredSubmissions),
    ...(typeof info.queueFamilyPolicy === 'string' ? { queueFamilyPolicy: info.queueFamilyPolicy } : {}),
    ...(typeof info.deferredSubmissionSyncPolicy === 'string' ? { deferredSubmissionSyncPolicy: info.deferredSubmissionSyncPolicy } : {}),
    ...(typeof info.queueFamilyKind === 'string' ? { queueFamilyKind: info.queueFamilyKind } : {}),
    ...(Number.isInteger(info.queueFamilyIndex) ? { queueFamilyIndex: info.queueFamilyIndex } : {}),
    ...(Number.isInteger(info.queueFamilyQueueCount) ? { queueFamilyQueueCount: info.queueFamilyQueueCount } : {}),
    ...(Number.isInteger(info.queueFamilyTimestampValidBits) ? { queueFamilyTimestampValidBits: info.queueFamilyTimestampValidBits } : {}),
    ...(typeof info.queueFamilySupportsGraphics === 'boolean' ? { queueFamilySupportsGraphics: info.queueFamilySupportsGraphics } : {}),
  };
}

function normalizePipelineCacheInfo(info) {
  if (!info || typeof info !== 'object') {
    return null;
  }
  const backend = typeof info.backend === 'string' ? info.backend : '';
  const state = typeof info.state === 'string' ? info.state : '';
  const reason = typeof info.reason === 'string' ? info.reason : '';
  if (!backend || !state || !reason) {
    return null;
  }
  return {
    backend,
    state,
    reason,
    warmupCount: Math.max(0, Number(info.warmupCount ?? 0) || 0),
    warmupNs: Math.max(0, Number(info.warmupNs ?? 0) || 0),
  };
}

export function nativePipelineCacheInfo(queue) {
  ensureLibrary();
  const nativeAddon = currentAddon();
  if (!nativeAddon || typeof nativeAddon.queuePipelineCacheInfo !== 'function') {
    return null;
  }
  const native = assertLiveResource(queue, 'nativePipelineCacheInfo', 'GPUQueue');
  return normalizePipelineCacheInfo(nativeAddon.queuePipelineCacheInfo(native));
}

export function packagePipelineCacheFlush(queue = null) {
  ensureLibrary();
  const nativeAddon = currentAddon();
  if (!nativeAddon || typeof nativeAddon.packagePipelineCacheFlush !== 'function') {
    return false;
  }
  if (queue == null) {
    nativeAddon.packagePipelineCacheFlush();
    return true;
  }
  const native = assertLiveResource(queue, 'packagePipelineCacheFlush', 'GPUQueue');
  nativeAddon.packagePipelineCacheFlush(native);
  return true;
}

/**
 * Create a Node or Bun runtime wrapper for Doe CLI execution.
 *
 * This exposes the package-side CLI bridge used for benchmark and command
 * stream execution workflows.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { createDoeRuntime } from "doe-gpu";
 *
 * const runtime = createDoeRuntime();
 * ```
 *
 * - This is package/runtime orchestration, not the in-process WebGPU device path.
 */
export const createDoeRuntime = createDoeRuntimeCli;

/**
 * Run the Dawn-vs-Doe compare harness from the full package surface.
 *
 * This forwards into the artifact-backed compare wrapper used by benchmark and
 * verification tooling.
 *
 * This example shows the API in its basic form.
 *
 * ```js
 * import { runDawnVsDoeCompare } from "doe-gpu";
 *
 * const result = runDawnVsDoeCompare({ configPath: "bench/config.json" });
 * ```
 *
 * - Requires an explicit compare config path either in options or forwarded CLI args.
 * - This is a tooling entrypoint, not the in-process `device` or `doe` helper path.
 */
export const runDawnVsDoeCompare = runDawnVsDoeCompareCli;
export { fastPathStats };
export {
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
  normalizeOrigin2D,
  normalizeCanvasConfiguration,
  createBrowserSurfaceClasses,
};

export default {
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
  create,
  createCanvasContext,
  createInstance,
  createNativeDirect,
  createBrowserSurfaceClasses,
  createNativeBrowserCanvasBackend: createNativeBrowserCanvasBackendImpl,
  globals,
  normalizeCanvasConfiguration,
  normalizeOrigin2D,
  setupGlobals,
  requestAdapter,
  requestDevice,
  providerInfo,
  nativeFastPathInfo,
  providerDiagnostics,
  prewarmPreparedDispatches,
  nativeQueueSyncInfo,
  nativePipelineCacheInfo,
  packagePipelineCacheFlush,
  fastPathStats,
  createDoeRuntime,
  runDawnVsDoeCompare,
};
