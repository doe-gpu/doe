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
} from './resource-lifecycle.js';
import {
  assertBufferDescriptor,
  assertTextureSize,
  assertBindGroupResource,
  normalizeRequestAdapterOptions,
  normalizeRequestDeviceDescriptor,
  normalizeSamplerDescriptor,
  normalizeTextureViewDescriptor,
  normalizeTextureDescriptor,
  normalizeTextureDimension,
  normalizeQuerySetDescriptor,
  normalizePrimitiveState,
  normalizeDepthStencilState,
  normalizeVertexBufferLayouts,
  normalizeBindGroupLayoutEntry,
} from './validation.js';
import {
  shaderCheckFailure,
} from './compiler-errors.js';
import {
  WEBGPU_DEFAULT_LIMITS,
} from './capabilities.js';

function validateWriteBufferInput(data, dataOffset, size, path) {
  const isSharedArrayBuffer = typeof SharedArrayBuffer !== 'undefined' && data instanceof SharedArrayBuffer;
  assertIntegerInRange(dataOffset, path, 'dataOffset', { min: 0 });
  if (
    !ArrayBuffer.isView(data)
    && !(data instanceof ArrayBuffer)
    && !isSharedArrayBuffer
    && !Buffer.isBuffer(data)
  ) {
    failValidation(path, 'data must be a TypedArray, DataView, ArrayBuffer, SharedArrayBuffer, or Buffer');
  }
  if (size !== undefined) {
    assertIntegerInRange(size, path, 'size', { min: 0 });
  }
  const byteSource = ArrayBuffer.isView(data)
    ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    : new Uint8Array(data);
  if (dataOffset === 0 && size === undefined) {
    return byteSource;
  }
  const elementSize = ArrayBuffer.isView(data) && typeof data.BYTES_PER_ELEMENT === 'number'
    ? data.BYTES_PER_ELEMENT
    : 1;
  const start = dataOffset * elementSize;
  const end = size !== undefined
    ? start + size * elementSize
    : byteSource.byteLength;
  if (end > byteSource.byteLength) {
    failValidation(path, `data range ${dataOffset}+${size ?? ((byteSource.byteLength - start) / elementSize)} exceeds source byteLength ${byteSource.byteLength}`);
  }
  return byteSource.subarray(start, end);
}

function fastDefaultWriteBufferView(data, dataOffset, size) {
  if (dataOffset !== 0 || size !== undefined || !ArrayBuffer.isView(data)) {
    return null;
  }
  if (typeof data.BYTES_PER_ELEMENT !== 'number') {
    return null;
  }
  return data;
}

function normalizeWriteBufferBatchEntry(entry, index) {
  const path = `GPUQueue.__doeWriteBufferBatch.entries[${index}]`;
  const object = assertObject(entry, path, 'entry');
  const bufferOffset = object.offset ?? object.bufferOffset ?? 0;
  assertIntegerInRange(bufferOffset, path, 'offset', { min: 0 });
  const dataOffset = object.dataOffset ?? 0;
  const view = validateWriteBufferInput(object.data, dataOffset, object.size, path);
  return {
    buffer: object.buffer,
    bufferOffset,
    view,
  };
}

function escapeRegexLiteral(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeOrigin2DForExternalCopy(origin, path) {
  if (origin === undefined || origin === null) {
    return { x: 0, y: 0 };
  }
  if (Array.isArray(origin)) {
    return { x: origin[0] ?? 0, y: origin[1] ?? 0 };
  }
  const object = assertObject(origin, path, 'origin');
  return {
    x: object.x ?? 0,
    y: object.y ?? 0,
  };
}

function normalizeOrigin3DForExternalCopy(origin, path) {
  if (origin === undefined || origin === null) {
    return { x: 0, y: 0, z: 0 };
  }
  if (Array.isArray(origin)) {
    return { x: origin[0] ?? 0, y: origin[1] ?? 0, z: origin[2] ?? 0 };
  }
  const object = assertObject(origin, path, 'origin');
  return {
    x: object.x ?? 0,
    y: object.y ?? 0,
    z: object.z ?? 0,
  };
}

function assertShaderEntryPoint(shader, entryPoint, path) {
  const code = shader?._code;
  if (typeof code !== 'string' || code.length === 0) {
    return;
  }
  const pattern = new RegExp(`\\bfn\\s+${escapeRegexLiteral(entryPoint)}\\s*\\(`);
  if (!pattern.test(code)) {
    failValidation(path, `entry point "${entryPoint}" not found in shader module`);
  }
}

function inferShaderEntryPoint(shader, explicitEntryPoint, stage, path, label) {
  if (explicitEntryPoint !== undefined && explicitEntryPoint !== null) {
    return assertNonEmptyString(explicitEntryPoint, path, label);
  }
  const code = shader?._code;
  if (typeof code === 'string' && code.length > 0) {
    const names = [];
    const pattern = new RegExp(
      `@${escapeRegexLiteral(stage)}\\b(?:\\s+@\\w+(?:\\([^)]*\\))?)*\\s+fn\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(`,
      'g',
    );
    let match;
    while ((match = pattern.exec(code)) !== null) {
      names.push(match[1]);
    }
    if (names.length === 1) {
      return names[0];
    }
  }
  return 'main';
}

const FAST_PATH_NOT_APPLIED = Symbol('fastPathNotApplied');

function operationError(message) {
  if (typeof DOMException === 'function') {
    return new DOMException(message, 'OperationError');
  }
  const error = new Error(message);
  error.name = 'OperationError';
  return error;
}

function createDeviceLostState(device) {
  if (device._lost instanceof Promise) {
    return;
  }
  device._lostInfo = null;
  device._resolveLost = null;
  device._lost = new Promise((resolve) => {
    device._resolveLost = resolve;
  });
}

function resolveDeviceLost(device, reason = 'unknown', message = '') {
  createDeviceLostState(device);
  if (device._lostInfo !== null) {
    return device._lostInfo;
  }
  const info = new GPUDeviceLostInfo(reason, message);
  device._lostInfo = info;
  device._resolveLost?.(info);
  return info;
}

function shouldRouteDeviceError(device) {
  if (Array.isArray(device._errorScopes) && device._errorScopes.length > 0) {
    return true;
  }
  if (typeof device._onuncapturederror === 'function') {
    return true;
  }
  const listeners = device._eventListeners;
  const uncapturedListeners = listeners instanceof Map ? listeners.get('uncapturederror') : null;
  return uncapturedListeners instanceof Set && uncapturedListeners.size > 0;
}

function captureDeviceError(device, filter, error) {
  const scopes = Array.isArray(device._errorScopes) ? device._errorScopes : [];
  for (let index = scopes.length - 1; index >= 0; index -= 1) {
    const scope = scopes[index];
    if (scope.filter !== filter) {
      continue;
    }
    if (scope.error === null) {
      scope.error = error;
    }
    return true;
  }

  const event = new GPUUncapturedErrorEvent('uncapturederror', { error });
  if (typeof device._onuncapturederror === 'function') {
    device._onuncapturederror.call(device, event);
  }
  dispatchDeviceEvent(device, 'uncapturederror', event);
  return false;
}

function gpuErrorFromCreationFailure(filter, error) {
  const message = error?.message ?? String(error);
  if (filter === 'out-of-memory') {
    return new GPUOutOfMemoryError(message);
  }
  if (filter === 'internal') {
    return new GPUInternalError(message);
  }
  return new GPUValidationError(message);
}

function isObjectRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasActiveNonBufferLayoutMember(entry) {
  return Boolean(entry.sampler || entry.texture || entry.storageTexture || entry.externalTexture);
}

function tryCreateBufferBindGroupLayoutFast4(backend, device, layoutDescriptor) {
  if (typeof backend.deviceCreateBufferBindGroupLayoutFlat4 !== 'function') {
    return FAST_PATH_NOT_APPLIED;
  }
  if (layoutDescriptor.label !== undefined && layoutDescriptor.label !== '') {
    return FAST_PATH_NOT_APPLIED;
  }
  const path = 'GPUDevice.createBindGroupLayout';
  const entries = layoutDescriptor.entries ?? [];
  if (!Array.isArray(entries) || entries.length > 4) {
    return FAST_PATH_NOT_APPLIED;
  }
  let b0 = 0;
  let b1 = 0;
  let b2 = 0;
  let b3 = 0;
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    if (!isObjectRecord(entry) || !entry.buffer || hasActiveNonBufferLayoutMember(entry)) {
      return FAST_PATH_NOT_APPLIED;
    }
    const buffer = assertObject(entry.buffer, path, `descriptor.entries[${index}].buffer`);
    const hasDynamicOffset = buffer.hasDynamicOffset === undefined
      ? false
      : assertBoolean(buffer.hasDynamicOffset, path, `descriptor.entries[${index}].buffer.hasDynamicOffset`);
    if (hasDynamicOffset) {
      return FAST_PATH_NOT_APPLIED;
    }
    assertOptionalIntegerInRange(
      buffer.minBindingSize ?? 0,
      path,
      `descriptor.entries[${index}].buffer.minBindingSize`,
      { min: 0 },
    );
    assertIntegerInRange(entry.visibility, path, `descriptor.entries[${index}].visibility`, { min: 0 });
    const binding = assertIntegerInRange(entry.binding, path, `descriptor.entries[${index}].binding`, { min: 0, max: UINT32_MAX });
    if (index === 0) b0 = binding;
    else if (index === 1) b1 = binding;
    else if (index === 2) b2 = binding;
    else b3 = binding;
  }
  const native = backend.deviceCreateBufferBindGroupLayoutFlat4(
    device,
    entries.length,
    b0,
    b1,
    b2,
    b3,
    layoutDescriptor.label || undefined,
  );
  return native === undefined ? FAST_PATH_NOT_APPLIED : native;
}

function resolveFastBufferBindingResource(resource, path, index) {
  if (!isObjectRecord(resource)) {
    return null;
  }
  if ('buffer' in resource) {
    const buffer = assertLiveResource(resource.buffer, path, 'GPUBuffer');
    const offset = assertOptionalIntegerInRange(
      resource.offset ?? 0,
      path,
      `descriptor.entries[${index}].resource.offset`,
      { min: 0 },
    );
    if (resource.size !== undefined) {
      assertIntegerInRange(resource.size, path, `descriptor.entries[${index}].resource.size`, { min: 1 });
      return null;
    }
    return { buffer, offset: offset ?? 0 };
  }
  if ('_native' in resource) {
    const label = describeResourceLabel(resource);
    if (label === 'GPUSampler' || label === 'GPUTextureView' || label === 'GPUExternalTexture') {
      return null;
    }
    return {
      buffer: assertLiveResource(resource, path, 'GPUBuffer'),
      offset: 0,
    };
  }
  return null;
}

function tryCreateBufferBindGroupFast4(backend, device, layoutNative, bindGroupDescriptor) {
  if (typeof backend.deviceCreateBufferBindGroupFlat4 !== 'function') {
    return FAST_PATH_NOT_APPLIED;
  }
  if (bindGroupDescriptor.label !== undefined && bindGroupDescriptor.label !== '') {
    return FAST_PATH_NOT_APPLIED;
  }
  const path = 'GPUDevice.createBindGroup';
  const entries = bindGroupDescriptor.entries ?? [];
  if (!Array.isArray(entries) || entries.length > 4) {
    return FAST_PATH_NOT_APPLIED;
  }
  let b0 = 0;
  let b1 = 0;
  let b2 = 0;
  let b3 = 0;
  let buffer0 = null;
  let buffer1 = null;
  let buffer2 = null;
  let buffer3 = null;
  let offset0 = 0;
  let offset1 = 0;
  let offset2 = 0;
  let offset3 = 0;
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    if (!isObjectRecord(entry)) {
      return FAST_PATH_NOT_APPLIED;
    }
    const resource = resolveFastBufferBindingResource(entry.resource, path, index);
    if (resource === null) {
      return FAST_PATH_NOT_APPLIED;
    }
    const binding = assertIntegerInRange(entry.binding, path, `descriptor.entries[${index}].binding`, { min: 0, max: UINT32_MAX });
    if (index === 0) {
      b0 = binding;
      buffer0 = resource.buffer;
      offset0 = resource.offset;
    } else if (index === 1) {
      b1 = binding;
      buffer1 = resource.buffer;
      offset1 = resource.offset;
    } else if (index === 2) {
      b2 = binding;
      buffer2 = resource.buffer;
      offset2 = resource.offset;
    } else {
      b3 = binding;
      buffer3 = resource.buffer;
      offset3 = resource.offset;
    }
  }
  const native = backend.deviceCreateBufferBindGroupFlat4(
    device,
    layoutNative,
    entries.length,
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
    bindGroupDescriptor.label || undefined,
  );
  return native === undefined ? FAST_PATH_NOT_APPLIED : native;
}

class GPUError extends Error {
  constructor(message) { super(message); this.name = 'GPUError'; }
}
class GPUValidationError extends GPUError {
  constructor(message) { super(message); this.name = 'GPUValidationError'; }
}
class GPUOutOfMemoryError extends GPUError {
  constructor(message) { super(message ?? ''); this.name = 'GPUOutOfMemoryError'; }
}
class GPUInternalError extends GPUError {
  constructor(message) { super(message ?? ''); this.name = 'GPUInternalError'; }
}
class GPUPipelineError extends DOMException {
  constructor(message, options) {
    super(message, 'GPUPipelineError');
    this.reason = options?.reason ?? 'internal';
  }
}

function wrapPipelineError(error) {
  if (error instanceof Error) {
    const message = error.message ?? '';
    const reason = error.reason
      ?? (error.name === 'GPUValidationError'
        || message.startsWith('GPUDevice.createComputePipeline')
        || message.startsWith('GPUDevice.createComputePipelineAsync')
        || message.startsWith('GPUDevice.createRenderPipeline')
        || message.startsWith('GPUDevice.createRenderPipelineAsync')
        || message.startsWith('createComputePipeline requires')
        || message.startsWith('createRenderPipeline requires')
        || message.startsWith('createComputePipeline:')
        || message.startsWith('createRenderPipeline:')
        ? 'validation'
        : 'internal');
    return new GPUPipelineError(message, { reason });
  }
  return error;
}
class GPUDeviceLostInfo {
  constructor(reason, message) {
    this.reason = reason ?? 'unknown';
    this.message = message ?? '';
  }
}
class GPUUncapturedErrorEvent extends Event {
  constructor(type, init) {
    super(type);
    this.error = init?.error ?? null;
  }
}

function ensureDeviceEventListeners(device) {
  if (!(device._eventListeners instanceof Map)) {
    device._eventListeners = new Map();
  }
  return device._eventListeners;
}

function addDeviceEventListener(device, type, listener) {
  if (typeof listener !== 'function') {
    return;
  }
  const listeners = ensureDeviceEventListeners(device);
  const typeListeners = listeners.get(type) ?? new Set();
  typeListeners.add(listener);
  listeners.set(type, typeListeners);
}

function removeDeviceEventListener(device, type, listener) {
  const listeners = device._eventListeners;
  if (!(listeners instanceof Map)) {
    return;
  }
  const typeListeners = listeners.get(type);
  if (!(typeListeners instanceof Set)) {
    return;
  }
  typeListeners.delete(listener);
  if (typeListeners.size === 0) {
    listeners.delete(type);
  }
}

function dispatchDeviceEvent(device, type, event) {
  const listeners = device._eventListeners;
  if (!(listeners instanceof Map)) {
    return;
  }
  const typeListeners = listeners.get(type);
  if (!(typeListeners instanceof Set)) {
    return;
  }
  for (const listener of [...typeListeners]) {
    listener.call(device, event);
  }
}

const EMPTY_ADAPTER_INFO = Object.freeze({
  vendor: '',
  architecture: '',
  device: '',
  description: '',
  subgroupMinSize: 0,
  subgroupMaxSize: 0,
});

const CORE_FEATURES_AND_LIMITS = 'core-features-and-limits';
const ALIGNMENT_LIMIT_NAMES = Object.freeze(new Set([
  'minUniformBufferOffsetAlignment',
  'minStorageBufferOffsetAlignment',
]));
const MAX_ALIGNMENT_LIMIT = 2 ** 31;

function isPowerOfTwo(value) {
  return Number.isInteger(value) && value > 0 && (value & (value - 1)) === 0;
}

function createFullSurfaceClasses({
  globals,
  backend,
  encoderClasses,
}) {
  let classes = null;
  const ERROR_FILTER_MAP = Object.freeze({
    validation: 0x00000001,
    'out-of-memory': 0x00000002,
    internal: 0x00000003,
  });

  function normalizeErrorFilter(filter, path) {
    const encoded = ERROR_FILTER_MAP[filter];
    if (encoded === undefined) {
      failValidation(path, `invalid filter "${filter}"; must be "validation", "out-of-memory", or "internal"`);
    }
    return encoded;
  }

  function resolveDeviceFeatures(adapter, descriptor) {
    const requiredFeatures = descriptor?.requiredFeatures ?? [];
    const adapterFeatures = adapter.features;
    for (const feature of requiredFeatures) {
      if (!adapterFeatures.has(feature)) {
        throw new TypeError(`GPUAdapter.requestDevice: required feature "${feature}" is not supported by this adapter`);
      }
    }
    if (requiredFeatures.length > 0) {
      return Object.freeze(new Set(requiredFeatures));
    }
    if (adapterFeatures.has(CORE_FEATURES_AND_LIMITS)) {
      return Object.freeze(new Set([CORE_FEATURES_AND_LIMITS]));
    }
    return Object.freeze(new Set());
  }

  function validateRequiredLimitValue(name, value, adapterLimits) {
    if (!(name in WEBGPU_DEFAULT_LIMITS)) {
      throw operationError(`GPUAdapter.requestDevice: requiredLimits.${name} is not a supported limit`);
    }
    if (!Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
      throw new TypeError(`GPUAdapter.requestDevice: requiredLimits.${name} must be a non-negative safe integer`);
    }
    if (!Number.isInteger(value)) {
      throw operationError(`GPUAdapter.requestDevice: requiredLimits.${name} must be an integer`);
    }
    const adapterValue = adapterLimits[name] ?? WEBGPU_DEFAULT_LIMITS[name];
    if (ALIGNMENT_LIMIT_NAMES.has(name)) {
      if (value > MAX_ALIGNMENT_LIMIT || !isPowerOfTwo(value) || value < adapterValue) {
        throw operationError(`GPUAdapter.requestDevice: requiredLimits.${name} is not supported by this adapter`);
      }
      return;
    }
    if (value > adapterValue) {
      throw operationError(`GPUAdapter.requestDevice: requiredLimits.${name} is not supported by this adapter`);
    }
  }

  function resolveDeviceLimits(adapter, descriptor) {
    const limits = { ...WEBGPU_DEFAULT_LIMITS };
    const requiredLimits = descriptor?.requiredLimits;
    if (requiredLimits === undefined) {
      return Object.freeze(limits);
    }
    const adapterLimits = adapter.limits;
    for (const [name, value] of Object.entries(requiredLimits)) {
      if (value === undefined) {
        continue;
      }
      validateRequiredLimitValue(name, value, adapterLimits);
      if (ALIGNMENT_LIMIT_NAMES.has(name)) {
        limits[name] = Math.min(WEBGPU_DEFAULT_LIMITS[name], value);
      } else {
        limits[name] = Math.max(WEBGPU_DEFAULT_LIMITS[name], value);
      }
    }
    return Object.freeze(limits);
  }

  function autoLayoutEntryKind(entry) {
    if (entry.buffer) return 'buffer';
    if (entry.sampler) return 'sampler';
    if (entry.texture) return 'texture';
    if (entry.storageTexture) return 'storageTexture';
    if (entry.externalTexture) return 'externalTexture';
    return 'unknown';
  }

  function autoLayoutEntriesCompatible(left, right) {
    const kind = autoLayoutEntryKind(left);
    if (kind !== autoLayoutEntryKind(right)) {
      return false;
    }
    switch (kind) {
      case 'buffer':
        return left.buffer.type === right.buffer.type;
      case 'sampler':
        return left.sampler.type === right.sampler.type;
      case 'texture':
        return left.texture.sampleType === right.texture.sampleType
          && left.texture.viewDimension === right.texture.viewDimension
          && left.texture.multisampled === right.texture.multisampled;
      case 'storageTexture':
        return left.storageTexture.access === right.storageTexture.access
          && left.storageTexture.format === right.storageTexture.format
          && left.storageTexture.viewDimension === right.storageTexture.viewDimension;
      case 'externalTexture':
        return true;
      default:
        return false;
    }
  }

  function mergeAutoLayoutEntriesByGroup(target, source, path) {
    if (!(source instanceof Map)) {
      return target;
    }
    for (const [group, entries] of source) {
      const merged = target.get(group) ?? [];
      const bindingToIndex = new Map(merged.map((entry, index) => [entry.binding, index]));
      for (const entry of entries) {
        const existingIndex = bindingToIndex.get(entry.binding);
        if (existingIndex === undefined) {
          const copy = { ...entry };
          merged.push(copy);
          bindingToIndex.set(copy.binding, merged.length - 1);
          continue;
        }
        const existing = merged[existingIndex];
        if (!autoLayoutEntriesCompatible(existing, entry)) {
          failValidation(path, `layout: "auto" resolves binding ${entry.binding} in group ${group} to incompatible declarations across shader stages`);
        }
        existing.visibility |= entry.visibility;
      }
      merged.sort((left, right) => left.binding - right.binding);
      target.set(group, merged);
    }
    return target;
  }

  function renderAutoLayoutEntriesByGroup(renderDescriptor, path) {
    if (typeof backend.requireAutoLayoutEntriesFromNative !== 'function') {
      return null;
    }
    const layout = renderDescriptor.layout;
    if (layout !== 'auto' && layout !== undefined && layout !== null) {
      return null;
    }
    const vertexEntries = backend.requireAutoLayoutEntriesFromNative(
      renderDescriptor.vertexModule,
      globals.GPUShaderStage.VERTEX,
      path,
    );
    const fragmentEntries = backend.requireAutoLayoutEntriesFromNative(
      renderDescriptor.fragmentModule,
      globals.GPUShaderStage.FRAGMENT,
      path,
    );
    if (!vertexEntries && !fragmentEntries) {
      return null;
    }
    const merged = new Map();
    mergeAutoLayoutEntriesByGroup(merged, vertexEntries, path);
    mergeAutoLayoutEntriesByGroup(merged, fragmentEntries, path);
    return merged;
  }

  class DoeGPUBuffer {
    constructor(native, instance, size, usage, queue, owner) {
      this._native = native;
      this._instance = instance;
      this._queue = queue;
      this.size = size;
      this.usage = usage;
      this.label = '';
      this._mapState = 'unmapped';
      initResource(this, 'GPUBuffer', owner);
      if (backend.initBufferState) {
        backend.initBufferState(this);
      }
    }

    get mapState() {
      if (typeof backend.bufferGetMapState === 'function' && this._native != null) {
        const nativeState = backend.bufferGetMapState(this, this._native);
        if (typeof nativeState === 'string') {
          this._mapState = nativeState;
        }
      }
      return this._mapState ?? 'unmapped';
    }

    async mapAsync(mode, offset = 0, size = Math.max(0, this.size - offset)) {
      const native = assertLiveResource(this, 'GPUBuffer.mapAsync', 'GPUBuffer');
      assertIntegerInRange(mode, 'GPUBuffer.mapAsync', 'mode', { min: 0, max: UINT32_MAX });
      assertIntegerInRange(offset, 'GPUBuffer.mapAsync', 'offset', { min: 0 });
      assertIntegerInRange(size, 'GPUBuffer.mapAsync', 'size', { min: 0 });
      if (offset + size > this.size) {
        failValidation('GPUBuffer.mapAsync', `mapped range ${offset}+${size} exceeds buffer size ${this.size}`);
      }
      const rejectValidationAsync = (message, finalState) => {
        const error = new GPUValidationError(`GPUBuffer.mapAsync: ${message}`);
        captureDeviceError(this._resourceOwner, 'validation', error);
        return Promise.resolve().then(() => {
          this._mapState = finalState;
          throw error;
        });
      };
      if (this._mapState === 'mapped' || this._mapState === 'pending') {
        return rejectValidationAsync('buffer is already mapped or mapping is pending', this._mapState);
      }
      this._mapState = 'pending';
      try {
        if (this._creationValidationError) {
          return rejectValidationAsync('buffer was created as a validation-error fallback object', 'unmapped');
        }
        if (mode === globals.GPUMapMode.READ) {
          if ((this.usage & globals.GPUBufferUsage.MAP_READ) === 0) {
            return rejectValidationAsync('buffer usage does not include MAP_READ', 'unmapped');
          }
        } else if (mode === globals.GPUMapMode.WRITE) {
          if ((this.usage & globals.GPUBufferUsage.MAP_WRITE) === 0) {
            return rejectValidationAsync('buffer usage does not include MAP_WRITE', 'unmapped');
          }
        } else {
          return rejectValidationAsync('mode must be GPUMapMode.READ or GPUMapMode.WRITE', 'unmapped');
        }
        await backend.bufferMapAsync(this, native, mode, offset, size);
        if (this._destroyed || this._mapState !== 'pending') {
          this._mapState = 'unmapped';
          throw operationError('GPUBuffer.mapAsync: mapping was cancelled before it resolved');
        }
        this._mapState = 'mapped';
      } catch (error) {
        this._mapState = 'unmapped';
        throw error;
      }
    }

    getMappedRange(offset = 0, size = Math.max(0, this.size - offset)) {
      const native = assertLiveResource(this, 'GPUBuffer.getMappedRange', 'GPUBuffer');
      assertIntegerInRange(offset, 'GPUBuffer.getMappedRange', 'offset', { min: 0 });
      assertIntegerInRange(size, 'GPUBuffer.getMappedRange', 'size', { min: 0 });
      if (offset + size > this.size) {
        failValidation('GPUBuffer.getMappedRange', `mapped range ${offset}+${size} exceeds buffer size ${this.size}`);
      }
      return backend.bufferGetMappedRange(this, native, offset, size);
    }

    _readCopy(offset = 0, size = Math.max(0, this.size - offset)) {
      const native = assertLiveResource(this, 'GPUBuffer._readCopy', 'GPUBuffer');
      assertIntegerInRange(offset, 'GPUBuffer._readCopy', 'offset', { min: 0 });
      assertIntegerInRange(size, 'GPUBuffer._readCopy', 'size', { min: 0 });
      if (offset + size > this.size) {
        failValidation('GPUBuffer._readCopy', `mapped range ${offset}+${size} exceeds buffer size ${this.size}`);
      }
      if (typeof backend.bufferReadCopy === 'function') {
        return backend.bufferReadCopy(this, native, offset, size);
      }
      return backend.bufferGetMappedRange(this, native, offset, size).slice(0);
    }

    assertMappedPrefixF32(expected, count) {
      const native = assertLiveResource(this, 'GPUBuffer.assertMappedPrefixF32', 'GPUBuffer');
      assertIntegerInRange(count, 'GPUBuffer.assertMappedPrefixF32', 'count', { min: 0, max: UINT32_MAX });
      if (Array.isArray(expected)) {
        if (expected.length < count) {
          failValidation('GPUBuffer.assertMappedPrefixF32', `expected array must contain at least ${count} values`);
        }
        const actual = new Float32Array(this.getMappedRange(0, count * Float32Array.BYTES_PER_ELEMENT));
        for (let index = 0; index < count; index += 1) {
          if (actual[index] !== expected[index]) {
            failValidation(
              'GPUBuffer.assertMappedPrefixF32',
              `expected readback[${index}] === ${expected[index]}, got ${actual[index]}`,
            );
          }
        }
        return;
      }
      if (typeof expected !== 'number') {
        failValidation('GPUBuffer.assertMappedPrefixF32', 'expected must be a number or array of numbers');
      }
      if (typeof backend.bufferAssertMappedPrefixF32 === 'function') {
        return backend.bufferAssertMappedPrefixF32(this, native, expected, count);
      }
      const actual = new Float32Array(this.getMappedRange(0, count * Float32Array.BYTES_PER_ELEMENT));
      for (let index = 0; index < count; index += 1) {
        if (actual[index] !== expected) {
          failValidation(
            'GPUBuffer.assertMappedPrefixF32',
            `expected readback[${index}] === ${expected}, got ${actual[index]}`,
          );
        }
      }
    }

    _mapReadCopyUnmap(mode, offset = 0, size = Math.max(0, this.size - offset)) {
      const native = assertLiveResource(this, 'GPUBuffer._mapReadCopyUnmap', 'GPUBuffer');
      if (typeof backend.bufferMapReadCopyUnmap === 'function') {
        return backend.bufferMapReadCopyUnmap(this, native, mode, offset, size);
      }
      return null;
    }

    unmap() {
      if (this._destroyed || this._native == null) {
        this._mapState = 'unmapped';
        return;
      }
      backend.bufferUnmap(assertLiveResource(this, 'GPUBuffer.unmap', 'GPUBuffer'), this);
      this._mapState = 'unmapped';
    }

    destroy() {
      destroyResource(this, (native) => backend.bufferDestroy(native, this));
      this._mapState = 'unmapped';
    }
  }

  class DoeGPUQueue {
    constructor(native, instance, device) {
      this._native = native;
      this._instance = instance;
      this._device = device;
      this.label = '';
      initResource(this, 'GPUQueue', device);
      if (backend.initQueueState) {
        backend.initQueueState(this);
      }
      if (typeof backend.queueWriteBufferBatch === 'function') {
        Object.defineProperty(this, '__doeWriteBufferBatch', {
          value: (entries) => {
            const queueNative = assertLiveResource(this, 'GPUQueue.__doeWriteBufferBatch', 'GPUQueue');
            const normalized = assertArray(entries, 'GPUQueue.__doeWriteBufferBatch', 'entries')
              .map((entry, index) => {
                const item = normalizeWriteBufferBatchEntry(entry, index);
                return {
                  bufferNative: assertLiveResource(
                    item.buffer,
                    `GPUQueue.__doeWriteBufferBatch.entries[${index}]`,
                    'GPUBuffer',
                  ),
                  bufferOffset: item.bufferOffset,
                  view: item.view,
                };
              });
            return backend.queueWriteBufferBatch(this, queueNative, normalized);
          },
        });
      }
    }

    hasPendingSubmissions() {
      assertLiveResource(this, 'GPUQueue.hasPendingSubmissions', 'GPUQueue');
      return backend.queueHasPendingSubmissions(this);
    }

    markSubmittedWorkDone() {
      assertLiveResource(this, 'GPUQueue.markSubmittedWorkDone', 'GPUQueue');
      backend.queueMarkSubmittedWorkDone(this);
    }

    submit(commandBuffers) {
      const native = assertLiveResource(this, 'GPUQueue.submit', 'GPUQueue');
      const buffers = assertArray(commandBuffers, 'GPUQueue.submit', 'commandBuffers');
      if (buffers.length === 0) {
        return;
      }
      return backend.queueSubmit(this, native, buffers);
    }

    writeBuffer(buffer, bufferOffset, data, dataOffset = 0, size) {
      const native = assertLiveResource(this, 'GPUQueue.writeBuffer', 'GPUQueue');
      const bufferNative = assertLiveResource(buffer, 'GPUQueue.writeBuffer', 'GPUBuffer');
      assertIntegerInRange(bufferOffset, 'GPUQueue.writeBuffer', 'bufferOffset', { min: 0 });
      const view = fastDefaultWriteBufferView(data, dataOffset, size)
        ?? validateWriteBufferInput(data, dataOffset, size, 'GPUQueue.writeBuffer');
      if (bufferOffset + view.byteLength > buffer.size) {
        failValidation('GPUQueue.writeBuffer', `write range ${bufferOffset}+${view.byteLength} exceeds buffer size ${buffer.size}`);
      }
      return backend.queueWriteBuffer(this, native, bufferNative, bufferOffset, view);
    }

    writeTexture(destination, data, dataLayout, size) {
      const native = assertLiveResource(this, 'GPUQueue.writeTexture', 'GPUQueue');
      const destinationObject = assertObject(destination, 'GPUQueue.writeTexture', 'destination');
      const layoutObject = assertObject(dataLayout, 'GPUQueue.writeTexture', 'dataLayout');
      const sizeObject = assertObject(size, 'GPUQueue.writeTexture', 'size');
      const view = validateWriteBufferInput(data, 0, undefined, 'GPUQueue.writeTexture');
      return backend.queueWriteTexture(
        this,
        native,
        {
          texture: assertLiveResource(destinationObject.texture, 'GPUQueue.writeTexture', 'GPUTexture'),
          mipLevel: destinationObject.mipLevel ?? 0,
          origin: {
            x: destinationObject.origin?.x ?? 0,
            y: destinationObject.origin?.y ?? 0,
            z: destinationObject.origin?.z ?? 0,
          },
          aspect: destinationObject.aspect,
        },
        view,
        {
          offset: layoutObject.offset ?? 0,
          bytesPerRow: layoutObject.bytesPerRow ?? 0,
          rowsPerImage: layoutObject.rowsPerImage ?? 0,
        },
        {
          width: sizeObject.width,
          height: sizeObject.height,
          depthOrArrayLayers: sizeObject.depthOrArrayLayers ?? 1,
        },
      );
    }

    async onSubmittedWorkDone() {
      const native = assertLiveResource(this, 'GPUQueue.onSubmittedWorkDone', 'GPUQueue');
      if (!this.hasPendingSubmissions()) {
        return;
      }
      await backend.queueOnSubmittedWorkDone(this, native);
      this.markSubmittedWorkDone();
    }

    copyExternalImageToTexture(source, destination, copySize) {
      const native = assertLiveResource(this, 'GPUQueue.copyExternalImageToTexture', 'GPUQueue');
      const sourceObject = assertObject(source, 'GPUQueue.copyExternalImageToTexture', 'source');
      const destinationObject = assertObject(destination, 'GPUQueue.copyExternalImageToTexture', 'destination');
      const sizeObject = assertObject(copySize, 'GPUQueue.copyExternalImageToTexture', 'copySize');
      if (typeof backend.queueCopyExternalImageToTexture !== 'function') {
        failValidation(
          'GPUQueue.copyExternalImageToTexture',
          'copyExternalImageToTexture is not supported on this package surface',
        );
      }
      if (sourceObject.source == null) {
        failValidation('GPUQueue.copyExternalImageToTexture', 'source.source is required');
      }
      const texture = assertLiveResource(
        destinationObject.texture,
        'GPUQueue.copyExternalImageToTexture',
        'GPUTexture',
      );
      const normalizedSource = {
        ...sourceObject,
        origin: normalizeOrigin2DForExternalCopy(
          sourceObject.origin,
          'GPUQueue.copyExternalImageToTexture(source.origin)',
        ),
      };
      const normalizedDestination = {
        ...destinationObject,
        texture,
        mipLevel: assertIntegerInRange(
          destinationObject.mipLevel ?? 0,
          'GPUQueue.copyExternalImageToTexture',
          'destination.mipLevel',
          { min: 0, max: UINT32_MAX },
        ),
        origin: normalizeOrigin3DForExternalCopy(
          destinationObject.origin,
          'GPUQueue.copyExternalImageToTexture(destination.origin)',
        ),
      };
      if (sourceObject.flipY !== undefined) {
        normalizedSource.flipY = assertBoolean(
          sourceObject.flipY,
          'GPUQueue.copyExternalImageToTexture',
          'source.flipY',
        );
      }
      if (destinationObject.premultipliedAlpha !== undefined) {
        normalizedDestination.premultipliedAlpha = assertBoolean(
          destinationObject.premultipliedAlpha,
          'GPUQueue.copyExternalImageToTexture',
          'destination.premultipliedAlpha',
        );
      }
      if (destinationObject.colorSpace !== undefined) {
        assertNonEmptyString(
          destinationObject.colorSpace,
          'GPUQueue.copyExternalImageToTexture',
          'destination.colorSpace',
        );
      }
      const normalizedSize = {
        width: assertIntegerInRange(sizeObject.width, 'GPUQueue.copyExternalImageToTexture', 'copySize.width', { min: 1, max: UINT32_MAX }),
        height: assertIntegerInRange(sizeObject.height, 'GPUQueue.copyExternalImageToTexture', 'copySize.height', { min: 1, max: UINT32_MAX }),
        depthOrArrayLayers: assertIntegerInRange(
          sizeObject.depthOrArrayLayers ?? 1,
          'GPUQueue.copyExternalImageToTexture',
          'copySize.depthOrArrayLayers',
          { min: 1, max: UINT32_MAX },
        ),
      };
      return backend.queueCopyExternalImageToTexture(
        this,
        native,
        normalizedSource,
        normalizedDestination,
        normalizedSize,
      );
    }
  }

  class DoeGPUTexture {
    constructor(native, owner, meta) {
      this._native = native;
      this.width = meta?.width ?? 1;
      this.height = meta?.height ?? 1;
      this.depthOrArrayLayers = meta?.depthOrArrayLayers ?? 1;
      this.mipLevelCount = meta?.mipLevelCount ?? 1;
      this.sampleCount = meta?.sampleCount ?? 1;
      this.dimension = meta?.dimension ?? '2d';
      this.format = meta?.format ?? 'rgba8unorm';
      this.usage = meta?.usage ?? 0;
      this.textureBindingViewDimension = meta?.textureBindingViewDimension;
      this.viewFormats = Array.isArray(meta?.viewFormats) ? meta.viewFormats : [];
      this._externallyOwned = meta?.externallyOwned === true;
      this.label = '';
      initResource(this, 'GPUTexture', owner);
      if (backend.initTextureState) {
        backend.initTextureState(this);
      }
    }

    createView(descriptor) {
      const texture = assertLiveResource(this, 'GPUTexture.createView', 'GPUTexture');
      const features = this._resourceOwner?.features ?? this._features ?? null;
      const viewDescriptor = descriptor == null ? {} : assertObject(descriptor, 'GPUTexture.createView', 'descriptor');
      const baseMipLevel = assertIntegerInRange(viewDescriptor.baseMipLevel ?? 0, 'GPUTexture.createView', 'descriptor.baseMipLevel', { min: 0, max: UINT32_MAX });
      const baseArrayLayer = assertIntegerInRange(viewDescriptor.baseArrayLayer ?? 0, 'GPUTexture.createView', 'descriptor.baseArrayLayer', { min: 0, max: UINT32_MAX });
      const mipLevelCount = assertIntegerInRange(viewDescriptor.mipLevelCount ?? Math.max(1, this.mipLevelCount - baseMipLevel), 'GPUTexture.createView', 'descriptor.mipLevelCount', { min: 1, max: UINT32_MAX });
      const arrayLayerCount = assertIntegerInRange(viewDescriptor.arrayLayerCount ?? Math.max(1, this.depthOrArrayLayers - baseArrayLayer), 'GPUTexture.createView', 'descriptor.arrayLayerCount', { min: 1, max: UINT32_MAX });
      const format = viewDescriptor.format ?? this.format;
      if (format !== this.format && !this.viewFormats.includes(format)) {
        failValidation('GPUTexture.createView', 'descriptor.format must match texture.format or one of texture.viewFormats');
      }
      if (viewDescriptor.swizzle !== undefined && (typeof viewDescriptor.swizzle !== 'string' || !/^[rgba01]{4}$/.test(viewDescriptor.swizzle))) {
        failValidation('GPUTexture.createView', 'descriptor.swizzle must be a 4-character string using r, g, b, a, 0, or 1');
      }
      const normalizedDescriptor = normalizeTextureViewDescriptor({
        ...viewDescriptor,
        format,
        dimension: viewDescriptor.dimension ?? this.textureBindingViewDimension ?? this.dimension,
        baseMipLevel,
        mipLevelCount,
        baseArrayLayer,
        arrayLayerCount,
        aspect: viewDescriptor.aspect ?? 'all',
        usage: viewDescriptor.usage ?? this.usage,
      }, this, features, 'GPUTexture.createView');
      const view = backend.textureCreateView(this, texture, normalizedDescriptor);
      const tv = new DoeGPUTextureView(view, this);
      if (!this._childViews) {
        this._childViews = new Set();
      }
      this._childViews.add(tv);
      tv.label = normalizedDescriptor.label ?? '';
      return tv;
    }

    destroy() {
      destroyResource(this, (native) => backend.textureDestroy(native, this));
    }
  }

  class DoeGPUTextureView {
    constructor(native, owner) {
      this._native = native;
      this.label = '';
      initResource(this, 'GPUTextureView', owner);
    }
  }

  class DoeGPUSampler {
    constructor(native, owner) {
      this._native = native;
      this.label = '';
      initResource(this, 'GPUSampler', owner);
    }
  }

  class DoeGPURenderPipeline {
    constructor(native, owner, explicitLayout, autoLayoutEntriesByGroup) {
      this._native = native;
      this._device = owner;
      this._explicitLayout = explicitLayout;
      this._autoLayoutEntriesByGroup = autoLayoutEntriesByGroup;
      this._cachedLayouts = new Map();
      this.label = '';
      initResource(this, 'GPURenderPipeline', owner);
    }

    getBindGroupLayout(index) {
      assertLiveResource(this, 'GPURenderPipeline.getBindGroupLayout', 'GPURenderPipeline');
      assertIntegerInRange(index, 'GPURenderPipeline.getBindGroupLayout', 'index', { min: 0, max: UINT32_MAX });
      if (this._explicitLayout) {
        return this._explicitLayout;
      }
      if (this._cachedLayouts.has(index)) {
        return this._cachedLayouts.get(index);
      }
      if (this._autoLayoutEntriesByGroup) {
        const entries = this._autoLayoutEntriesByGroup.get(index) ?? [];
        const layout = this._device.createBindGroupLayout({ entries });
        this._cachedLayouts.set(index, layout);
        return layout;
      }
      const layout = backend.renderPipelineGetBindGroupLayout(this, index, classes);
      this._cachedLayouts.set(index, layout);
      return layout;
    }
  }

  class DoeGPUShaderModule {
    constructor(native, code, owner) {
      this._native = native;
      this._code = code;
      this.label = '';
      initResource(this, 'GPUShaderModule', owner);
    }

    async getCompilationInfo() {
      const native = assertLiveResource(this, 'GPUShaderModule.getCompilationInfo', 'GPUShaderModule');
      if (typeof backend.shaderModuleGetCompilationInfo === 'function') {
        return backend.shaderModuleGetCompilationInfo(this, native);
      }
      return { messages: [] };
    }

    destroy() {
      if (typeof backend.shaderModuleDestroy !== 'function') {
        return;
      }
      destroyResource(this, (native) => backend.shaderModuleDestroy(native, this));
    }
  }

  class DoeGPUComputePipeline {
    constructor(native, device, explicitLayout, autoLayoutEntriesByGroup) {
      this._native = native;
      this._device = device;
      this._explicitLayout = explicitLayout;
      this._autoLayoutEntriesByGroup = autoLayoutEntriesByGroup;
      this._cachedLayouts = new Map();
      this.label = '';
      initResource(this, 'GPUComputePipeline', device);
    }

    getBindGroupLayout(index) {
      assertLiveResource(this, 'GPUComputePipeline.getBindGroupLayout', 'GPUComputePipeline');
      assertIntegerInRange(index, 'GPUComputePipeline.getBindGroupLayout', 'index', { min: 0, max: UINT32_MAX });
      if (this._explicitLayout) {
        return this._explicitLayout;
      }
      if (this._cachedLayouts.has(index)) {
        return this._cachedLayouts.get(index);
      }
      const layout = backend.computePipelineGetBindGroupLayout(this, index, classes);
      this._cachedLayouts.set(index, layout);
      return layout;
    }
  }

  class DoeGPUBindGroupLayout {
    constructor(native, owner) {
      this._native = native;
      this.label = '';
      initResource(this, 'GPUBindGroupLayout', owner);
    }
  }

  class DoeGPUBindGroup {
    constructor(native, owner) {
      this._native = native;
      this.label = '';
      initResource(this, 'GPUBindGroup', owner);
    }
  }

  class DoeGPUPipelineLayout {
    constructor(native, owner) {
      this._native = native;
      this.label = '';
      initResource(this, 'GPUPipelineLayout', owner);
    }
  }

  class DoeGPUQuerySet {
    constructor(native, type, count, owner) {
      this._native = native;
      this.type = type;
      this.count = count;
      this.label = '';
      initResource(this, 'GPUQuerySet', owner);
    }

    destroy() {
      destroyResource(this, (native) => backend.querySetDestroy(native));
    }
  }

  class DoeGPUDevice {
    constructor(native, instance, inheritedLimits = null, inheritedFeatures = null) {
      this._native = native;
      this._instance = instance;
      this._adapter = null;
      this._adapterInfo = null;
      this._features = inheritedFeatures ?? null;
      this._limits = inheritedLimits ?? null;
      this._onuncapturederror = null;
      this._eventListeners = new Map();
      this._errorScopes = [];
      this._errorScopeDepth = 0;
      this.label = '';
      initResource(this, 'GPUDevice');
      createDeviceLostState(this);
      if (typeof backend.initDeviceState === 'function') {
        backend.initDeviceState(this);
      }
      this.queue = new DoeGPUQueue(backend.deviceGetQueue(native), instance, this);
    }

    get limits() {
      if (this._limits === null) {
        this._limits = backend.deviceLimits(assertLiveResource(this, 'GPUDevice.limits', 'GPUDevice'));
      }
      return this._limits;
    }

    get features() {
      if (this._features === null) {
        this._features = backend.deviceFeatures(assertLiveResource(this, 'GPUDevice.features', 'GPUDevice'));
      }
      return this._features;
    }

    addEventListener(type, listener) {
      addDeviceEventListener(this, type, listener);
    }

    removeEventListener(type, listener) {
      removeDeviceEventListener(this, type, listener);
    }

    get lost() {
      if (typeof backend.deviceGetLost === 'function' && !this._destroyed) {
        const native = assertLiveResource(this, 'GPUDevice.lost', 'GPUDevice');
        return backend.deviceGetLost(this, native);
      }
      createDeviceLostState(this);
      return this._lost;
    }

    get adapterInfo() {
      if (this._adapterInfo != null) {
        return this._adapterInfo;
      }
      if (this._adapter?.info) {
        this._adapterInfo = this._adapter.info;
        return this._adapterInfo;
      }
      if (typeof backend.deviceGetAdapterInfo === 'function') {
        const native = assertLiveResource(this, 'GPUDevice.adapterInfo', 'GPUDevice');
        this._adapterInfo = backend.deviceGetAdapterInfo(this, native);
        return this._adapterInfo;
      }
      this._adapterInfo = EMPTY_ADAPTER_INFO;
      return this._adapterInfo;
    }

    pushErrorScope(filter) {
      const native = assertLiveResource(this, 'GPUDevice.pushErrorScope', 'GPUDevice');
      const encodedFilter = normalizeErrorFilter(filter, 'GPUDevice.pushErrorScope');
      if (typeof backend.devicePushErrorScope === 'function') {
        backend.devicePushErrorScope(this, native, filter, encodedFilter);
      }
      this._errorScopes.push({ filter, error: null });
      this._errorScopeDepth = this._errorScopes.length;
    }

    popErrorScope() {
      const native = assertLiveResource(this, 'GPUDevice.popErrorScope', 'GPUDevice');
      if (!Array.isArray(this._errorScopes) || this._errorScopes.length <= 0) {
        return Promise.reject(operationError('GPUDevice.popErrorScope: no active error scope'));
      }
      const scope = this._errorScopes.pop();
      this._errorScopeDepth = this._errorScopes.length;
      const nativePop = typeof backend.devicePopErrorScope === 'function'
        ? backend.devicePopErrorScope(this, native)
        : Promise.resolve(null);
      return Promise.resolve(nativePop).then(nativeError => scope.error ?? nativeError ?? null);
    }

    get onuncapturederror() {
      if (typeof backend.deviceGetOnUncapturedError === 'function') {
        const native = assertLiveResource(this, 'GPUDevice.onuncapturederror', 'GPUDevice');
        return backend.deviceGetOnUncapturedError(this, native);
      }
      return this._onuncapturederror;
    }

    set onuncapturederror(handler) {
      if (handler !== null && handler !== undefined && typeof handler !== 'function') {
        failValidation('GPUDevice.onuncapturederror', 'handler must be a function or null');
      }
      this._onuncapturederror = handler ?? null;
      if (typeof backend.deviceSetOnUncapturedError === 'function') {
        const native = assertLiveResource(this, 'GPUDevice.onuncapturederror', 'GPUDevice');
        backend.deviceSetOnUncapturedError(this, native, handler ?? null);
        return;
      }
    }

    createBuffer(descriptor) {
      let validated;
      try {
        validated = assertBufferDescriptor(descriptor, 'GPUDevice.createBuffer');
      } catch (error) {
        if (error instanceof RangeError) {
          throw error;
        }
        if (!shouldRouteDeviceError(this)) {
          throw error;
        }
        captureDeviceError(this, 'validation', gpuErrorFromCreationFailure('validation', error));
        return this._createErrorScopeFallbackBuffer(
          descriptor?.label ?? '',
          descriptor?.size,
          Boolean(descriptor?.mappedAtCreation),
        );
      }
      if (validated.size > (this.limits?.maxBufferSize ?? WEBGPU_DEFAULT_LIMITS.maxBufferSize)) {
        const error = new Error('GPUDevice.createBuffer: descriptor.size exceeds device.limits.maxBufferSize');
        if (!shouldRouteDeviceError(this)) {
          throw error;
        }
        captureDeviceError(this, 'validation', gpuErrorFromCreationFailure('validation', error));
        return this._createErrorScopeFallbackBuffer(
          descriptor?.label ?? '',
          descriptor?.size,
          Boolean(descriptor?.mappedAtCreation),
        );
      }
      const native = backend.deviceCreateBuffer(this, validated);
      const buffer = new DoeGPUBuffer(native, this._instance, validated.size, validated.usage, this.queue, this);
      buffer.label = descriptor?.label ?? '';
      if (validated.mappedAtCreation && typeof backend.bufferMarkMappedAtCreation === 'function') {
        backend.bufferMarkMappedAtCreation(buffer);
        buffer._mapState = 'mapped';
      }
      return buffer;
    }

    _createErrorScopeFallbackBuffer(label = '', requestedSize = 4, mappedAtCreation = false) {
      const fallbackSize = Number.isSafeInteger(requestedSize)
        && requestedSize >= 0
        && requestedSize <= (this.limits?.maxBufferSize ?? WEBGPU_DEFAULT_LIMITS.maxBufferSize)
        ? requestedSize
        : 4;
      const descriptor = {
        label,
        size: fallbackSize,
        usage: globals.GPUBufferUsage.COPY_SRC | globals.GPUBufferUsage.MAP_WRITE,
        mappedAtCreation,
      };
      const native = backend.deviceCreateBuffer(this, descriptor);
      const buffer = new DoeGPUBuffer(native, this._instance, descriptor.size, descriptor.usage, this.queue, this);
      buffer.label = label;
      buffer._creationValidationError = true;
      if (mappedAtCreation && typeof backend.bufferMarkMappedAtCreation === 'function') {
        backend.bufferMarkMappedAtCreation(buffer);
        buffer._mapState = 'mapped';
      }
      return buffer;
    }

    createShaderModule(descriptor) {
      const objectDescriptor = assertObject(descriptor, 'GPUDevice.createShaderModule', 'descriptor');
      const code = objectDescriptor.code ?? objectDescriptor.source;
      assertNonEmptyString(code, 'GPUDevice.createShaderModule', 'descriptor.code');
      if (backend.preflightShaderSourceOnCreate !== false) {
        const preflight = backend.preflightShaderSource(code);
        if (!preflight.ok) {
          shaderCheckFailure('GPUDevice.createShaderModule', preflight);
        }
      }
      const hints = objectDescriptor.compilationHints ?? null;
      const native = backend.deviceCreateShaderModule(this, code, hints, objectDescriptor.label ?? null);
      const module = new DoeGPUShaderModule(native, code, this);
      module.label = objectDescriptor.label ?? '';
      return module;
    }

    createComputePipeline(descriptor) {
      try {
        const pipelineDescriptor = assertObject(descriptor, 'GPUDevice.createComputePipeline', 'descriptor');
        const compute = assertObject(pipelineDescriptor.compute, 'GPUDevice.createComputePipeline', 'descriptor.compute');
        const shader = compute.module;
        const shaderNative = assertLiveResource(shader, 'GPUDevice.createComputePipeline', 'GPUShaderModule');
        const entryPoint = inferShaderEntryPoint(shader, compute.entryPoint, 'compute', 'GPUDevice.createComputePipeline', 'descriptor.compute.entryPoint');
        assertShaderEntryPoint(shader, entryPoint, 'GPUDevice.createComputePipeline');
        const layout = pipelineDescriptor.layout === 'auto' || pipelineDescriptor.layout === undefined
          ? null
          : pipelineDescriptor.layout;
        if (layout !== null) {
          assertLiveResource(layout, 'GPUDevice.createComputePipeline', 'GPUPipelineLayout');
        }
        const autoLayoutEntriesByGroup = layout
          ? null
          : backend.requireAutoLayoutEntriesFromNative(
            shader,
            globals.GPUShaderStage.COMPUTE,
            'GPUDevice.createComputePipeline',
            entryPoint,
          );
        const constants = compute.constants ?? null;
        const label = pipelineDescriptor.label || undefined;
        const native = backend.deviceCreateComputePipeline(this, shaderNative, entryPoint, layout?._native ?? null, constants, label);
        const pipeline = new DoeGPUComputePipeline(native, this, layout, autoLayoutEntriesByGroup);
        pipeline.label = pipelineDescriptor.label ?? '';
        return pipeline;
      } catch (error) {
        throw wrapPipelineError(error);
      }
    }

    async createComputePipelineAsync(descriptor) {
      try {
        const pipelineDescriptor = assertObject(descriptor, 'GPUDevice.createComputePipelineAsync', 'descriptor');
        const compute = assertObject(pipelineDescriptor.compute, 'GPUDevice.createComputePipelineAsync', 'descriptor.compute');
        const shader = compute.module;
        const shaderNative = assertLiveResource(shader, 'GPUDevice.createComputePipelineAsync', 'GPUShaderModule');
        const entryPoint = inferShaderEntryPoint(shader, compute.entryPoint, 'compute', 'GPUDevice.createComputePipelineAsync', 'descriptor.compute.entryPoint');
        assertShaderEntryPoint(shader, entryPoint, 'GPUDevice.createComputePipelineAsync');
        const layout = pipelineDescriptor.layout === 'auto' || pipelineDescriptor.layout === undefined
          ? null
          : pipelineDescriptor.layout;
        if (layout !== null) {
          assertLiveResource(layout, 'GPUDevice.createComputePipelineAsync', 'GPUPipelineLayout');
        }
        const autoLayoutEntriesByGroup = layout
          ? null
          : backend.requireAutoLayoutEntriesFromNative(
            shader,
            globals.GPUShaderStage.COMPUTE,
            'GPUDevice.createComputePipelineAsync',
            entryPoint,
          );
        const constants = compute.constants ?? null;
        const label = pipelineDescriptor.label || undefined;
        const native = typeof backend.deviceCreateComputePipelineAsync === 'function'
          ? await backend.deviceCreateComputePipelineAsync(this, shaderNative, entryPoint, layout?._native ?? null, constants, label)
          : backend.deviceCreateComputePipeline(this, shaderNative, entryPoint, layout?._native ?? null, constants, label);
        const pipeline = new DoeGPUComputePipeline(native, this, layout, autoLayoutEntriesByGroup);
        pipeline.label = pipelineDescriptor.label ?? '';
        return pipeline;
      } catch (error) {
        throw wrapPipelineError(error);
      }
    }

    createBindGroupLayout(descriptor) {
      const layoutDescriptor = assertObject(descriptor, 'GPUDevice.createBindGroupLayout', 'descriptor');
      const fastNative = tryCreateBufferBindGroupLayoutFast4(backend, this, layoutDescriptor);
      if (fastNative !== FAST_PATH_NOT_APPLIED) {
        const bgl = new DoeGPUBindGroupLayout(fastNative, this);
        bgl.label = layoutDescriptor.label ?? '';
        return bgl;
      }
      const entries = assertArray(layoutDescriptor.entries ?? [], 'GPUDevice.createBindGroupLayout', 'descriptor.entries')
        .map((entry, index) => normalizeBindGroupLayoutEntry(entry, index, 'GPUDevice.createBindGroupLayout', this.features));
      const native = backend.deviceCreateBindGroupLayout(this, entries, layoutDescriptor.label || undefined);
      const bgl = new DoeGPUBindGroupLayout(native, this);
      bgl.label = layoutDescriptor.label ?? '';
      return bgl;
    }

    createBindGroup(descriptor) {
      const bindGroupDescriptor = assertObject(descriptor, 'GPUDevice.createBindGroup', 'descriptor');
      const layoutNative = assertLiveResource(bindGroupDescriptor.layout, 'GPUDevice.createBindGroup', 'GPUBindGroupLayout');
      const fastNative = tryCreateBufferBindGroupFast4(backend, this, layoutNative, bindGroupDescriptor);
      if (fastNative !== FAST_PATH_NOT_APPLIED) {
        const bg = new DoeGPUBindGroup(fastNative, this);
        bg.label = bindGroupDescriptor.label ?? '';
        return bg;
      }
      const entries = assertArray(bindGroupDescriptor.entries ?? [], 'GPUDevice.createBindGroup', 'descriptor.entries')
        .map((entry, index) => {
          const binding = assertObject(entry, 'GPUDevice.createBindGroup', `descriptor.entries[${index}]`);
          const resource = assertBindGroupResource(binding.resource, 'GPUDevice.createBindGroup');
          const normalized = {
            binding: assertIntegerInRange(binding.binding, 'GPUDevice.createBindGroup', `descriptor.entries[${index}].binding`, { min: 0, max: UINT32_MAX }),
            buffer: resource.buffer,
            sampler: resource.sampler,
            textureView: resource.textureView,
            externalTexture: resource.externalTexture,
            offset: resource.offset ?? 0,
          };
          if (resource.size !== undefined) {
            normalized.size = resource.size;
          }
          return normalized;
        });
      const native = backend.deviceCreateBindGroup(this, layoutNative, entries, bindGroupDescriptor.label || undefined);
      const bg = new DoeGPUBindGroup(native, this);
      bg.label = bindGroupDescriptor.label ?? '';
      return bg;
    }

    createPipelineLayout(descriptor) {
      const layoutDescriptor = assertObject(descriptor, 'GPUDevice.createPipelineLayout', 'descriptor');
      const layouts = assertArray(layoutDescriptor.bindGroupLayouts ?? [], 'GPUDevice.createPipelineLayout', 'descriptor.bindGroupLayouts')
        .map((layout, index) => assertLiveResource(layout, 'GPUDevice.createPipelineLayout', `descriptor.bindGroupLayouts[${index}]`));
      const immediateSize = assertIntegerInRange(
        layoutDescriptor.immediateSize ?? 0,
        'GPUDevice.createPipelineLayout',
        'descriptor.immediateSize',
        { min: 0, max: UINT32_MAX },
      );
      const native = backend.deviceCreatePipelineLayout(this, layouts, layoutDescriptor.label || undefined, immediateSize);
      const pl = new DoeGPUPipelineLayout(native, this);
      pl.label = layoutDescriptor.label ?? '';
      return pl;
    }

    createTexture(descriptor) {
      try {
        const textureDescriptor = assertObject(descriptor, 'GPUDevice.createTexture', 'descriptor');
        const size = assertTextureSize(textureDescriptor.size, 'GPUDevice.createTexture');
        const usage = assertIntegerInRange(textureDescriptor.usage, 'GPUDevice.createTexture', 'descriptor.usage', { min: 1 });
        const normalizedDescriptor = normalizeTextureDescriptor(
          textureDescriptor,
          size,
          usage,
          this.features,
          'GPUDevice.createTexture',
        );
        return this._createTextureFromNormalizedDescriptor(textureDescriptor, normalizedDescriptor, size, usage);
      } catch (error) {
        if (!shouldRouteDeviceError(this)) {
          throw error;
        }
        captureDeviceError(this, 'out-of-memory', gpuErrorFromCreationFailure('out-of-memory', error));
        return this._createErrorScopeFallbackTexture(descriptor?.label ?? '');
      }
    }

    _createTextureFromNormalizedDescriptor(textureDescriptor, normalizedDescriptor, size, usage) {
      const native = backend.deviceCreateTexture(this, normalizedDescriptor, size, usage);
      const texture = new DoeGPUTexture(native, this, {
        width: size.width,
        height: size.height,
        depthOrArrayLayers: size.depthOrArrayLayers,
        mipLevelCount: normalizedDescriptor.mipLevelCount ?? 1,
        sampleCount: normalizedDescriptor.sampleCount ?? 1,
        dimension: normalizedDescriptor.dimension,
        format: normalizedDescriptor.format ?? 'rgba8unorm',
        usage,
        textureBindingViewDimension: textureDescriptor.textureBindingViewDimension ?? undefined,
        viewFormats: Array.isArray(textureDescriptor.viewFormats) ? textureDescriptor.viewFormats : [],
      });
      texture.label = normalizedDescriptor.label ?? '';
      texture._features = this.features;
      return texture;
    }

    _createErrorScopeFallbackTexture(label = '') {
      const size = { width: 1, height: 1, depthOrArrayLayers: 1 };
      const usage = globals.GPUTextureUsage.COPY_DST;
      const descriptor = {
        label,
        size,
        usage,
        dimension: '2d',
        format: 'rgba8unorm',
        mipLevelCount: 1,
        sampleCount: 1,
        viewFormats: [],
      };
      return this._createTextureFromNormalizedDescriptor(descriptor, descriptor, size, usage);
    }

    createSampler(descriptor = {}) {
      const normalizedDescriptor = normalizeSamplerDescriptor(descriptor, 'GPUDevice.createSampler');
      const native = backend.deviceCreateSampler(this, normalizedDescriptor);
      const sampler = new DoeGPUSampler(native, this);
      sampler.label = normalizedDescriptor?.label ?? '';
      return sampler;
    }

    createRenderPipeline(descriptor) {
      try {
        const renderDescriptor = assertObject(descriptor, 'GPUDevice.createRenderPipeline', 'descriptor');
        const vertex = assertObject(renderDescriptor.vertex, 'GPUDevice.createRenderPipeline', 'descriptor.vertex');
        const fragment = assertObject(renderDescriptor.fragment, 'GPUDevice.createRenderPipeline', 'descriptor.fragment');
        const vertexModule = assertLiveResource(vertex.module, 'GPUDevice.createRenderPipeline', 'GPUShaderModule');
        const fragmentModule = assertLiveResource(fragment.module, 'GPUDevice.createRenderPipeline', 'GPUShaderModule');
        const targets = assertArray(fragment.targets ?? [], 'GPUDevice.createRenderPipeline', 'descriptor.fragment.targets');
        if (targets.length === 0) {
          failValidation('GPUDevice.createRenderPipeline', 'descriptor.fragment.targets must contain at least one target');
        }
        const vertexBuffers = vertex.buffers === undefined
          ? []
          : normalizeVertexBufferLayouts(vertex.buffers, 'GPUDevice.createRenderPipeline');
        const layout = renderDescriptor.layout === 'auto' || renderDescriptor.layout === undefined
          ? null
          : renderDescriptor.layout;
        if (layout !== null) {
          assertLiveResource(layout, 'GPUDevice.createRenderPipeline', 'GPUPipelineLayout');
        }
        const pipelineDescriptor = {
          layout: layout?._native ?? null,
          vertexModule,
          vertexEntryPoint: inferShaderEntryPoint(vertex.module, vertex.entryPoint, 'vertex', 'GPUDevice.createRenderPipeline', 'descriptor.vertex.entryPoint'),
          vertexBuffers,
          vertexConstants: vertex.constants ?? null,
          fragmentModule,
          fragmentEntryPoint: inferShaderEntryPoint(fragment.module, fragment.entryPoint, 'fragment', 'GPUDevice.createRenderPipeline', 'descriptor.fragment.entryPoint'),
          fragmentConstants: fragment.constants ?? null,
          fragmentTarget: {
            ...targets[0],
            format: normalizeTextureViewDescriptor(
              { format: assertNonEmptyString(targets[0].format, 'GPUDevice.createRenderPipeline', 'descriptor.fragment.targets[0].format') },
              null,
              this.features,
              'GPUDevice.createRenderPipeline',
            ).format,
          },
          primitive: normalizePrimitiveState(renderDescriptor.primitive ?? null, 'GPUDevice.createRenderPipeline'),
          depthStencil: normalizeDepthStencilState(renderDescriptor.depthStencil ?? null, this.features, 'GPUDevice.createRenderPipeline'),
          multisample: renderDescriptor.multisample ?? null,
        };
        const native = backend.deviceCreateRenderPipeline(this, pipelineDescriptor);
        const autoLayoutEntriesByGroup = layout
          ? null
          : renderAutoLayoutEntriesByGroup({
            layout: renderDescriptor.layout,
            vertexModule: vertex.module,
            fragmentModule: fragment.module,
          }, 'GPUDevice.createRenderPipeline');
        const rp = new DoeGPURenderPipeline(native, this, layout, autoLayoutEntriesByGroup);
        rp.label = renderDescriptor.label ?? '';
        return rp;
      } catch (error) {
        throw wrapPipelineError(error);
      }
    }

    async createRenderPipelineAsync(descriptor) {
      try {
        const renderDescriptor = assertObject(descriptor, 'GPUDevice.createRenderPipelineAsync', 'descriptor');
        const vertex = assertObject(renderDescriptor.vertex, 'GPUDevice.createRenderPipelineAsync', 'descriptor.vertex');
        const fragment = assertObject(renderDescriptor.fragment, 'GPUDevice.createRenderPipelineAsync', 'descriptor.fragment');
        const vertexModule = assertLiveResource(vertex.module, 'GPUDevice.createRenderPipelineAsync', 'GPUShaderModule');
        const fragmentModule = assertLiveResource(fragment.module, 'GPUDevice.createRenderPipelineAsync', 'GPUShaderModule');
        const targets = assertArray(fragment.targets ?? [], 'GPUDevice.createRenderPipelineAsync', 'descriptor.fragment.targets');
        if (targets.length === 0) {
          failValidation('GPUDevice.createRenderPipelineAsync', 'descriptor.fragment.targets must contain at least one target');
        }
        const vertexBuffers = vertex.buffers === undefined
          ? []
          : normalizeVertexBufferLayouts(vertex.buffers, 'GPUDevice.createRenderPipelineAsync');
        const layout = renderDescriptor.layout === 'auto' || renderDescriptor.layout === undefined
          ? null
          : renderDescriptor.layout;
        if (layout !== null) {
          assertLiveResource(layout, 'GPUDevice.createRenderPipelineAsync', 'GPUPipelineLayout');
        }
        const pipelineDescriptor = {
          layout: layout?._native ?? null,
          vertexModule,
          vertexEntryPoint: inferShaderEntryPoint(vertex.module, vertex.entryPoint, 'vertex', 'GPUDevice.createRenderPipelineAsync', 'descriptor.vertex.entryPoint'),
          vertexBuffers,
          vertexConstants: vertex.constants ?? null,
          fragmentModule,
          fragmentEntryPoint: inferShaderEntryPoint(fragment.module, fragment.entryPoint, 'fragment', 'GPUDevice.createRenderPipelineAsync', 'descriptor.fragment.entryPoint'),
          fragmentConstants: fragment.constants ?? null,
          fragmentTarget: {
            ...targets[0],
            format: normalizeTextureViewDescriptor(
              { format: assertNonEmptyString(targets[0].format, 'GPUDevice.createRenderPipelineAsync', 'descriptor.fragment.targets[0].format') },
              null,
              this.features,
              'GPUDevice.createRenderPipelineAsync',
            ).format,
          },
          primitive: normalizePrimitiveState(renderDescriptor.primitive ?? null, 'GPUDevice.createRenderPipelineAsync'),
          depthStencil: normalizeDepthStencilState(renderDescriptor.depthStencil ?? null, this.features, 'GPUDevice.createRenderPipelineAsync'),
          multisample: renderDescriptor.multisample ?? null,
        };
        const native = typeof backend.deviceCreateRenderPipelineAsync === 'function'
          ? await backend.deviceCreateRenderPipelineAsync(this, pipelineDescriptor)
          : backend.deviceCreateRenderPipeline(this, pipelineDescriptor);
        const autoLayoutEntriesByGroup = layout
          ? null
          : renderAutoLayoutEntriesByGroup({
            layout: renderDescriptor.layout,
            vertexModule: vertex.module,
            fragmentModule: fragment.module,
          }, 'GPUDevice.createRenderPipelineAsync');
        const rp = new DoeGPURenderPipeline(native, this, layout, autoLayoutEntriesByGroup);
        rp.label = renderDescriptor.label ?? '';
        return rp;
      } catch (error) {
        throw wrapPipelineError(error);
      }
    }

    createRenderBundleEncoder(descriptor) {
      const bundleDescriptor = assertObject(descriptor, 'GPUDevice.createRenderBundleEncoder', 'descriptor');
      assertLiveResource(this, 'GPUDevice.createRenderBundleEncoder', 'GPUDevice');
      if (!encoderClasses?.DoeGPURenderBundleEncoder) {
        failValidation('GPUDevice.createRenderBundleEncoder', 'render bundle encoder surface unavailable on this package build');
      }
      const rbe = backend.deviceCreateRenderBundleEncoder(this, bundleDescriptor, encoderClasses);
      rbe.label = bundleDescriptor.label ?? '';
      return rbe;
    }

    createQuerySet(descriptor) {
      assertLiveResource(this, 'GPUDevice.createQuerySet', 'GPUDevice');
      const queryDescriptor = normalizeQuerySetDescriptor(descriptor, 'GPUDevice.createQuerySet');
      assertIntegerInRange(queryDescriptor.count, 'GPUDevice.createQuerySet', 'descriptor.count', { min: 1, max: UINT32_MAX });
      const native = backend.deviceCreateQuerySet(this, queryDescriptor);
      if (native == null) {
        failValidation('GPUDevice.createQuerySet', 'query sets are not supported on this backend/device');
      }
      const qs = new DoeGPUQuerySet(native, queryDescriptor.type, queryDescriptor.count, this);
      qs.label = queryDescriptor.label ?? '';
      return qs;
    }

    createCommandEncoder(descriptor) {
      if (descriptor !== undefined) {
        assertObject(descriptor, 'GPUDevice.createCommandEncoder', 'descriptor');
      }
      assertLiveResource(this, 'GPUDevice.createCommandEncoder', 'GPUDevice');
      const encoder = backend.deviceCreateCommandEncoder(this, descriptor, classes);
      encoder.label = descriptor?.label ?? '';
      return encoder;
    }

    importExternalTexture(descriptor) {
      const native = assertLiveResource(this, 'GPUDevice.importExternalTexture', 'GPUDevice');
      const textureDescriptor = assertObject(descriptor, 'GPUDevice.importExternalTexture', 'descriptor');
      if (typeof backend.deviceImportExternalTexture !== 'function') {
        failValidation(
          'GPUDevice.importExternalTexture',
          'importExternalTexture is not supported on this package surface',
        );
      }
      if (textureDescriptor.source == null) {
        failValidation('GPUDevice.importExternalTexture', 'descriptor.source is required');
      }
      if (textureDescriptor.colorSpace !== undefined) {
        assertNonEmptyString(
          textureDescriptor.colorSpace,
          'GPUDevice.importExternalTexture',
          'descriptor.colorSpace',
        );
      }
      if (textureDescriptor.label !== undefined && typeof textureDescriptor.label !== 'string') {
        failValidation('GPUDevice.importExternalTexture', 'descriptor.label must be a string');
      }
      return backend.deviceImportExternalTexture(this, native, textureDescriptor, classes);
    }

    destroy() {
      resolveDeviceLost(this, 'destroyed', 'GPUDevice.destroy() was called');
      destroyResource(this, (native) => backend.deviceDestroy(native));
    }
  }

  class DoeGPUAdapter {
    constructor(native, instance, requestOptions = null) {
      this._native = native;
      this._instance = instance;
      this._requestOptions = requestOptions;
      this._features = null;
      this._limits = null;
      this._info = null;
      this._consumed = false;
      this.label = '';
      initResource(this, 'GPUAdapter');
    }

    get features() {
      if (this._features === null) {
        this._features = backend.adapterFeatures(assertLiveResource(this, 'GPUAdapter.features', 'GPUAdapter'));
      }
      return this._features;
    }

    get limits() {
      if (this._limits === null) {
        this._limits = backend.adapterLimits(assertLiveResource(this, 'GPUAdapter.limits', 'GPUAdapter'));
      }
      return this._limits;
    }

    get info() {
      if (this._info !== null) {
        return this._info;
      }
      if (typeof backend.adapterGetInfo === 'function') {
        this._info = backend.adapterGetInfo(this, this._native);
        return this._info;
      }
      this._info = Object.freeze({
        vendor: '',
        architecture: '',
        device: '',
        description: '',
        subgroupMinSize: 0,
        subgroupMaxSize: 0,
      });
      return this._info;
    }

    async requestDevice(descriptor) {
      assertLiveResource(this, 'GPUAdapter.requestDevice', 'GPUAdapter');
      if (this._consumed) {
        throw operationError('GPUAdapter.requestDevice: adapter has already produced a device');
      }
      const normalized = normalizeRequestDeviceDescriptor(descriptor, 'GPUAdapter.requestDevice');
      const resolvedFeatures = resolveDeviceFeatures(this, normalized);
      const resolvedLimits = resolveDeviceLimits(this, normalized);
      const deviceResult = backend.adapterRequestDevice(this, normalized, classes);
      this._consumed = true;
      const device = await deviceResult;
      device._features = resolvedFeatures;
      device._limits = resolvedLimits;
      return device;
    }

    destroy() {
      destroyResource(this, (native) => backend.adapterDestroy(native));
    }
  }

  const WGSL_LANGUAGE_FEATURES = Object.freeze(new Set([
    'readonly-and-readwrite-storage-textures',
  ]));

  class DoeGPU {
    constructor(instance) {
      this._instance = instance;
    }

    get wgslLanguageFeatures() {
      return WGSL_LANGUAGE_FEATURES;
    }

    getPreferredCanvasFormat() {
      return 'bgra8unorm';
    }

    async requestAdapter(options) {
      const normalized = normalizeRequestAdapterOptions(options, 'GPU.requestAdapter');
      if (normalized?.forceFallbackAdapter === true) {
        return null;
      }
      if (
        normalized?.featureLevel !== undefined
        && normalized.featureLevel !== 'core'
        && normalized.featureLevel !== 'compatibility'
      ) {
        return null;
      }
      return backend.gpuRequestAdapter(
        this,
        normalized,
        classes,
      );
    }
  }

  classes = {
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
    DoeGPUQuerySet,
    DoeGPUDevice,
    DoeGPUAdapter,
    DoeGPU,
  };
  return classes;
}

export {
  createFullSurfaceClasses,
  addDeviceEventListener,
  removeDeviceEventListener,
  dispatchDeviceEvent,
  operationError,
  createDeviceLostState,
  resolveDeviceLost,
  GPUError,
  GPUValidationError,
  GPUOutOfMemoryError,
  GPUInternalError,
  GPUPipelineError,
  GPUDeviceLostInfo,
  GPUUncapturedErrorEvent,
};
