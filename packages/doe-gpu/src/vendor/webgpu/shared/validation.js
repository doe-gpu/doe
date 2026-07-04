import { globals } from '../webgpu-constants.js';
import { KNOWN_FEATURES } from './capabilities.js';
import {
  UINT32_MAX,
  failValidation,
  describeResourceLabel,
  assertObject,
  assertArray,
  assertBoolean,
  assertNonEmptyString,
  assertIntegerInRange,
  assertOptionalIntegerInRange,
  assertLiveResource,
} from './resource-lifecycle.js';

const SAMPLER_BINDING_TYPES = Object.freeze({
  filtering: 'filtering',
  'non-filtering': 'non-filtering',
  comparison: 'comparison',
});

const FILTER_MODES = Object.freeze({
  nearest: 'nearest',
  linear: 'linear',
});

const ADDRESS_MODES = Object.freeze({
  'clamp-to-edge': 'clamp-to-edge',
  repeat: 'repeat',
  'mirror-repeat': 'mirror-repeat',
});

const COMPARE_FUNCTIONS = Object.freeze({
  never: 'never',
  less: 'less',
  equal: 'equal',
  'less-equal': 'less-equal',
  greater: 'greater',
  'not-equal': 'not-equal',
  'greater-equal': 'greater-equal',
  always: 'always',
});

const FRONT_FACES = Object.freeze({
  ccw: 'ccw',
  cw: 'cw',
});

const INDEX_FORMATS = Object.freeze({
  uint16: 'uint16',
  uint32: 'uint32',
});

const MIPMAP_FILTER_MODES = Object.freeze({
  nearest: 'nearest',
  linear: 'linear',
});

const POWER_PREFERENCES = Object.freeze({
  'low-power': 'low-power',
  'high-performance': 'high-performance',
});

const PRIMITIVE_TOPOLOGIES = Object.freeze({
  'point-list': 'point-list',
  'line-list': 'line-list',
  'line-strip': 'line-strip',
  'triangle-list': 'triangle-list',
  'triangle-strip': 'triangle-strip',
});

const QUERY_TYPES = Object.freeze({
  occlusion: 'occlusion',
  timestamp: 'timestamp',
});

const STENCIL_OPERATIONS = Object.freeze({
  keep: 'keep',
  zero: 'zero',
  replace: 'replace',
  invert: 'invert',
  'increment-clamp': 'increment-clamp',
  'decrement-clamp': 'decrement-clamp',
  'increment-wrap': 'increment-wrap',
  'decrement-wrap': 'decrement-wrap',
});

const TEXTURE_ASPECTS = Object.freeze({
  all: 'all',
  'stencil-only': 'stencil-only',
  'depth-only': 'depth-only',
});

const VERTEX_STEP_MODES = Object.freeze({
  vertex: 'vertex',
  instance: 'instance',
});

const VERTEX_FORMATS = Object.freeze({
  uint8: 'uint8',
  uint8x2: 'uint8x2',
  uint8x4: 'uint8x4',
  sint8: 'sint8',
  sint8x2: 'sint8x2',
  sint8x4: 'sint8x4',
  unorm8: 'unorm8',
  unorm8x2: 'unorm8x2',
  unorm8x4: 'unorm8x4',
  snorm8: 'snorm8',
  snorm8x2: 'snorm8x2',
  snorm8x4: 'snorm8x4',
  uint16: 'uint16',
  uint16x2: 'uint16x2',
  uint16x4: 'uint16x4',
  sint16: 'sint16',
  sint16x2: 'sint16x2',
  sint16x4: 'sint16x4',
  unorm16: 'unorm16',
  unorm16x2: 'unorm16x2',
  unorm16x4: 'unorm16x4',
  snorm16: 'snorm16',
  snorm16x2: 'snorm16x2',
  snorm16x4: 'snorm16x4',
  float16: 'float16',
  float16x2: 'float16x2',
  float16x4: 'float16x4',
  float32: 'float32',
  float32x2: 'float32x2',
  float32x3: 'float32x3',
  float32x4: 'float32x4',
  uint32: 'uint32',
  uint32x2: 'uint32x2',
  uint32x3: 'uint32x3',
  uint32x4: 'uint32x4',
  sint32: 'sint32',
  sint32x2: 'sint32x2',
  sint32x3: 'sint32x3',
  sint32x4: 'sint32x4',
  'unorm10-10-10-2': 'unorm10-10-10-2',
  'unorm8x4-bgra': 'unorm8x4-bgra',
});

const TEXTURE_SAMPLE_TYPES = Object.freeze({
  float: 'float',
  'unfilterable-float': 'unfilterable-float',
  depth: 'depth',
  sint: 'sint',
  uint: 'uint',
});

const TEXTURE_VIEW_DIMENSIONS = Object.freeze({
  '1d': '1d',
  '2d': '2d',
  '2d-array': '2d-array',
  cube: 'cube',
  'cube-array': 'cube-array',
  '3d': '3d',
});

const TEXTURE_DIMENSIONS = Object.freeze({
  '1d': '1d',
  '2d': '2d',
  '3d': '3d',
});

const STORAGE_TEXTURE_ACCESS = Object.freeze({
  'write-only': 'write-only',
  'read-only': 'read-only',
  'read-write': 'read-write',
});

const KNOWN_TEXTURE_FORMATS = Object.freeze(new Set([
  'r8unorm', 'r8snorm', 'r8uint', 'r8sint',
  'r16unorm', 'r16snorm', 'r16uint', 'r16sint', 'r16float',
  'rg8unorm', 'rg8snorm', 'rg8uint', 'rg8sint',
  'r32uint', 'r32sint', 'r32float',
  'rg16unorm', 'rg16snorm', 'rg16uint', 'rg16sint', 'rg16float',
  'rgba8unorm', 'rgba8unorm-srgb', 'rgba8snorm', 'rgba8uint', 'rgba8sint',
  'bgra8unorm', 'bgra8unorm-srgb',
  'rgb9e5ufloat', 'rgb10a2uint', 'rgb10a2unorm', 'rg11b10ufloat',
  'rg32uint', 'rg32sint', 'rg32float',
  'rgba16unorm', 'rgba16snorm', 'rgba16uint', 'rgba16sint', 'rgba16float',
  'rgba32uint', 'rgba32sint', 'rgba32float',
  'stencil8', 'depth16unorm', 'depth24plus', 'depth24plus-stencil8', 'depth32float', 'depth32float-stencil8',
  'bc1-rgba-unorm', 'bc1-rgba-unorm-srgb',
  'bc2-rgba-unorm', 'bc2-rgba-unorm-srgb',
  'bc3-rgba-unorm', 'bc3-rgba-unorm-srgb',
  'bc4-r-unorm', 'bc4-r-snorm',
  'bc5-rg-unorm', 'bc5-rg-snorm',
  'bc6h-rgb-ufloat', 'bc6h-rgb-float',
  'bc7-rgba-unorm', 'bc7-rgba-unorm-srgb',
  'etc2-rgb8unorm', 'etc2-rgb8unorm-srgb',
  'etc2-rgb8a1unorm', 'etc2-rgb8a1unorm-srgb',
  'etc2-rgba8unorm', 'etc2-rgba8unorm-srgb',
  'eac-r11unorm', 'eac-r11snorm', 'eac-rg11unorm', 'eac-rg11snorm',
  'astc-4x4-unorm', 'astc-4x4-unorm-srgb',
  'astc-5x4-unorm', 'astc-5x4-unorm-srgb',
  'astc-5x5-unorm', 'astc-5x5-unorm-srgb',
  'astc-6x5-unorm', 'astc-6x5-unorm-srgb',
  'astc-6x6-unorm', 'astc-6x6-unorm-srgb',
  'astc-8x5-unorm', 'astc-8x5-unorm-srgb',
  'astc-8x6-unorm', 'astc-8x6-unorm-srgb',
  'astc-8x8-unorm', 'astc-8x8-unorm-srgb',
  'astc-10x5-unorm', 'astc-10x5-unorm-srgb',
  'astc-10x6-unorm', 'astc-10x6-unorm-srgb',
  'astc-10x8-unorm', 'astc-10x8-unorm-srgb',
  'astc-10x10-unorm', 'astc-10x10-unorm-srgb',
  'astc-12x10-unorm', 'astc-12x10-unorm-srgb',
  'astc-12x12-unorm', 'astc-12x12-unorm-srgb',
]));

const KNOWN_FEATURE_NAMES = Object.freeze(new Set(
  KNOWN_FEATURES.map(([name]) => name),
));

const ALL_BUFFER_USAGE_BITS = Object.values(globals.GPUBufferUsage)
  .reduce((mask, bit) => mask | bit, 0);

// ============================================================
// Texture format capability tables
// ============================================================

// Depth/stencil formats recognized without any feature gate
const DEPTH_STENCIL_FORMATS_BASE = Object.freeze(new Set([
  'stencil8',
  'depth16unorm',
  'depth24plus',
  'depth24plus-stencil8',
  'depth32float',
]));

// depth32float-stencil8 requires the depth32float-stencil8 feature
const DEPTH_STENCIL_FORMAT_DEPTH32FLOAT_STENCIL8 = 'depth32float-stencil8';

function isDepthStencilFormat(format, features) {
  if (DEPTH_STENCIL_FORMATS_BASE.has(format)) return true;
  if (format === DEPTH_STENCIL_FORMAT_DEPTH32FLOAT_STENCIL8) {
    return features != null && features.has('depth32float-stencil8');
  }
  return false;
}

// Formats that can have stencil aspect (stencilLoadOp / stencilStoreOp)
const STENCIL_FORMATS = Object.freeze(new Set([
  'stencil8',
  'depth24plus-stencil8',
  'depth32float-stencil8',
]));

function hasStencilAspect(format) {
  return STENCIL_FORMATS.has(format);
}

// Formats valid for STORAGE_BINDING usage (without any feature)
const STORAGE_TEXTURE_FORMATS_BASE = Object.freeze(new Set([
  'rgba8unorm',
  'rgba8snorm',
  'rgba8uint',
  'rgba8sint',
  'r16unorm',
  'r16snorm',
  'rgba16uint',
  'rgba16sint',
  'rgba16float',
  'rg16unorm',
  'rg16snorm',
  'rgba16unorm',
  'rgba16snorm',
  'r32float',
  'r32uint',
  'r32sint',
  'rg32float',
  'rg32uint',
  'rg32sint',
  'rgba32float',
  'rgba32uint',
  'rgba32sint',
]));

const STORAGE_TEXTURE_READ_WRITE_FORMATS_BASE = Object.freeze(new Set([
  'r32float',
  'r32uint',
  'r32sint',
]));

const STORAGE_TEXTURE_FORMATS_TIER1_READ_WRITE_ONLY = Object.freeze(new Set([
  'r8unorm',
  'r8snorm',
  'r8uint',
  'r8sint',
  'rg8unorm',
  'rg8snorm',
  'rg8uint',
  'rg8sint',
  'r16uint',
  'r16sint',
  'r16float',
  'rg16uint',
  'rg16sint',
  'rg16float',
  'rgb10a2uint',
  'rgb10a2unorm',
  'rg11b10ufloat',
]));

const STORAGE_TEXTURE_FORMATS_TIER2_READ_WRITE = Object.freeze(new Set([
  'r8unorm',
  'r8uint',
  'r8sint',
  'rgba8unorm',
  'rgba8uint',
  'rgba8sint',
  'r16uint',
  'r16sint',
  'r16float',
  'rgba16uint',
  'rgba16sint',
  'rgba16float',
  'rgba32uint',
  'rgba32sint',
  'rgba32float',
]));

function isWriteOnlyStorageTextureFormat(format, features) {
  if (STORAGE_TEXTURE_FORMATS_BASE.has(format)) return true;
  if (format === 'bgra8unorm') {
    return hasFeature(features, 'bgra8unorm-storage');
  }
  if (STORAGE_TEXTURE_FORMATS_TIER1_READ_WRITE_ONLY.has(format)) {
    return hasFeature(features, 'texture-formats-tier1');
  }
  return false;
}

function isReadOnlyStorageTextureFormat(format, features) {
  if (format === 'bgra8unorm') return false;
  return isWriteOnlyStorageTextureFormat(format, features);
}

function isReadWriteStorageTextureFormat(format, features) {
  if (STORAGE_TEXTURE_READ_WRITE_FORMATS_BASE.has(format)) return true;
  if (STORAGE_TEXTURE_FORMATS_TIER2_READ_WRITE.has(format)) {
    return hasFeature(features, 'texture-formats-tier2');
  }
  return false;
}

function isStorageTextureFormat(format, features, access = 'write-only') {
  switch (access) {
    case 'read-only':
      return isReadOnlyStorageTextureFormat(format, features);
    case 'read-write':
      return isReadWriteStorageTextureFormat(format, features);
    case 'write-only':
    default:
      return isWriteOnlyStorageTextureFormat(format, features);
  }
}

// Float32 formats: default sample type is unfilterable-float.
// With float32-filterable feature, they become filterable (sample type = float).
const FLOAT32_FORMATS = Object.freeze(new Set([
  'r32float',
  'rg32float',
  'rgba32float',
]));

function float32SampleType(format, features) {
  if (!FLOAT32_FORMATS.has(format)) return null;
  if (features != null && features.has('float32-filterable')) {
    return 'float';
  }
  return 'unfilterable-float';
}

function isFloat32Filterable(format, features) {
  return FLOAT32_FORMATS.has(format) && features != null && features.has('float32-filterable');
}

// Float32 formats: default is not blendable as render target.
// With float32-blendable feature, blend state is allowed on float32 color targets.
function isFloat32Blendable(format, features) {
  return FLOAT32_FORMATS.has(format) && features != null && features.has('float32-blendable');
}

// Formats that are always blendable (non-integer, non-depth, non-float32)
const ALWAYS_BLENDABLE_FORMATS = Object.freeze(new Set([
  'r8unorm', 'r8snorm',
  'r16float',
  'rg8unorm', 'rg8snorm',
  'rg16float',
  'rgba8unorm', 'rgba8unorm-srgb', 'rgba8snorm',
  'bgra8unorm', 'bgra8unorm-srgb',
  'rgb10a2unorm',
  'rgba16float',
]));

function isBlendableFormat(format, features) {
  if (ALWAYS_BLENDABLE_FORMATS.has(format)) return true;
  return isFloat32Blendable(format, features);
}

// BC (S3TC/DXT) compressed formats — require texture-compression-bc feature.
// Read-only compressed: valid for TEXTURE_BINDING and CopySrc/CopyDst,
// not valid for RENDER_ATTACHMENT or STORAGE_BINDING.
const BC_FORMATS = Object.freeze(new Set([
  'bc1-rgba-unorm', 'bc1-rgba-unorm-srgb',
  'bc2-rgba-unorm', 'bc2-rgba-unorm-srgb',
  'bc3-rgba-unorm', 'bc3-rgba-unorm-srgb',
  'bc4-r-unorm', 'bc4-r-snorm',
  'bc5-rg-unorm', 'bc5-rg-snorm',
  'bc6h-rgb-ufloat', 'bc6h-rgb-float',
  'bc7-rgba-unorm', 'bc7-rgba-unorm-srgb',
]));

function isBCFormat(format) {
  return BC_FORMATS.has(format);
}

// ASTC compressed formats — require texture-compression-astc feature.
// Read-only compressed: valid for TEXTURE_BINDING and CopySrc/CopyDst,
// not valid for RENDER_ATTACHMENT or STORAGE_BINDING.
const ASTC_FORMATS = Object.freeze(new Set([
  'astc-4x4-unorm', 'astc-4x4-unorm-srgb',
  'astc-5x4-unorm', 'astc-5x4-unorm-srgb',
  'astc-5x5-unorm', 'astc-5x5-unorm-srgb',
  'astc-6x5-unorm', 'astc-6x5-unorm-srgb',
  'astc-6x6-unorm', 'astc-6x6-unorm-srgb',
  'astc-8x5-unorm', 'astc-8x5-unorm-srgb',
  'astc-8x6-unorm', 'astc-8x6-unorm-srgb',
  'astc-8x8-unorm', 'astc-8x8-unorm-srgb',
  'astc-10x5-unorm', 'astc-10x5-unorm-srgb',
  'astc-10x6-unorm', 'astc-10x6-unorm-srgb',
  'astc-10x8-unorm', 'astc-10x8-unorm-srgb',
  'astc-10x10-unorm', 'astc-10x10-unorm-srgb',
  'astc-12x10-unorm', 'astc-12x10-unorm-srgb',
  'astc-12x12-unorm', 'astc-12x12-unorm-srgb',
]));

function isASTCFormat(format) {
  return ASTC_FORMATS.has(format);
}

// ETC2/EAC compressed formats — require texture-compression-etc2 feature.
// Read-only compressed: valid for TEXTURE_BINDING and CopySrc/CopyDst,
// not valid for RENDER_ATTACHMENT or STORAGE_BINDING.
const ETC2_FORMATS = Object.freeze(new Set([
  'etc2-rgb8unorm', 'etc2-rgb8unorm-srgb',
  'etc2-rgb8a1unorm', 'etc2-rgb8a1unorm-srgb',
  'etc2-rgba8unorm', 'etc2-rgba8unorm-srgb',
  'eac-r11unorm', 'eac-r11snorm',
  'eac-rg11unorm', 'eac-rg11snorm',
]));

function isETC2Format(format) {
  return ETC2_FORMATS.has(format);
}

// ASTC block sizes for validation (width, height) keyed by format prefix
const ASTC_BLOCK_SIZES = Object.freeze({
  'astc-4x4': [4, 4], 'astc-5x4': [5, 4], 'astc-5x5': [5, 5],
  'astc-6x5': [6, 5], 'astc-6x6': [6, 6], 'astc-8x5': [8, 5],
  'astc-8x6': [8, 6], 'astc-8x8': [8, 8], 'astc-10x5': [10, 5],
  'astc-10x6': [10, 6], 'astc-10x8': [10, 8], 'astc-10x10': [10, 10],
  'astc-12x10': [12, 10], 'astc-12x12': [12, 12],
});

function astcBlockSize(format) {
  const prefix = format.replace(/-unorm(-srgb)?$/, '');
  return ASTC_BLOCK_SIZES[prefix] ?? null;
}

function assertBufferDescriptor(descriptor, path) {
  assertObject(descriptor, path, 'descriptor');
  assertIntegerInRange(descriptor.size, path, 'descriptor.size', { min: 0 });
  const usage = assertIntegerInRange(descriptor.usage, path, 'descriptor.usage', { min: 1 });
  if ((usage & ~ALL_BUFFER_USAGE_BITS) !== 0) {
    failValidation(path, `descriptor.usage contains unknown flag bits (0x${(usage & ~ALL_BUFFER_USAGE_BITS).toString(16)})`);
  }
  if (
    (usage & globals.GPUBufferUsage.MAP_READ) !== 0
    && (usage & ~(globals.GPUBufferUsage.MAP_READ | globals.GPUBufferUsage.COPY_DST)) !== 0
  ) {
    failValidation(path, 'descriptor.usage with MAP_READ may only combine with COPY_DST');
  }
  if (
    (usage & globals.GPUBufferUsage.MAP_WRITE) !== 0
    && (usage & ~(globals.GPUBufferUsage.MAP_WRITE | globals.GPUBufferUsage.COPY_SRC)) !== 0
  ) {
    failValidation(path, 'descriptor.usage with MAP_WRITE may only combine with COPY_SRC');
  }
  if (descriptor.mappedAtCreation !== undefined) {
    assertBoolean(descriptor.mappedAtCreation, path, 'descriptor.mappedAtCreation');
    if (descriptor.mappedAtCreation && (descriptor.size % 4) !== 0) {
      throw new RangeError(`${path}: descriptor.size must be a multiple of 4 when mappedAtCreation is true`);
    }
  }
  return descriptor;
}

function normalizeEnumKey(value, path, label) {
  return assertNonEmptyString(value, path, label).trim().toLowerCase().replaceAll('_', '-');
}

function hasFeature(features, name) {
  return features != null && typeof features.has === 'function' && features.has(name);
}

function normalizeKnownEnum(value, defaultValue, values, path, label) {
  const normalized = normalizeEnumKey(value ?? defaultValue, path, label);
  if (!(normalized in values)) {
    failValidation(path, `${label} must be one of: ${Object.keys(values).join(', ')}`);
  }
  return normalized;
}

function normalizeFeatureName(value, path, label) {
  const name = normalizeEnumKey(value, path, label);
  if (!KNOWN_FEATURE_NAMES.has(name)) {
    failValidation(path, `${label} must be one of: ${[...KNOWN_FEATURE_NAMES].join(', ')}`);
  }
  return name;
}

function normalizePowerPreference(value, path, label = 'options.powerPreference') {
  return normalizeKnownEnum(value, 'low-power', POWER_PREFERENCES, path, label);
}

function normalizeFrontFace(value, path, label = 'descriptor.primitive.frontFace') {
  return normalizeKnownEnum(value, 'ccw', FRONT_FACES, path, label);
}

function normalizeIndexFormat(value, path, label) {
  return normalizeKnownEnum(value, 'uint16', INDEX_FORMATS, path, label);
}

function normalizePrimitiveTopology(value, path, label = 'descriptor.primitive.topology') {
  return normalizeKnownEnum(value, 'triangle-list', PRIMITIVE_TOPOLOGIES, path, label);
}

function normalizeQueryType(value, path, label = 'descriptor.type') {
  return normalizeKnownEnum(value, 'timestamp', QUERY_TYPES, path, label);
}

function normalizeMipmapFilterMode(value, path, label = 'descriptor.mipmapFilter') {
  return normalizeKnownEnum(value, 'nearest', MIPMAP_FILTER_MODES, path, label);
}

function normalizeAddressMode(value, path, label) {
  return normalizeKnownEnum(value, 'clamp-to-edge', ADDRESS_MODES, path, label);
}

function normalizeCompareFunction(value, path, label) {
  return normalizeKnownEnum(value, 'always', COMPARE_FUNCTIONS, path, label);
}

function normalizeFiniteNumber(value, path, label) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    failValidation(path, `${label} must be a finite number`);
  }
  return number;
}

function normalizeStencilOperation(value, path, label) {
  return normalizeKnownEnum(value, 'keep', STENCIL_OPERATIONS, path, label);
}

function normalizeTextureAspect(value, path, label = 'descriptor.aspect') {
  return normalizeKnownEnum(value, 'all', TEXTURE_ASPECTS, path, label);
}

function normalizeTextureViewDimension(value, path, label = 'descriptor.dimension') {
  return normalizeKnownEnum(value, '2d', TEXTURE_VIEW_DIMENSIONS, path, label);
}

function normalizeTextureSampleType(value, path, label = 'descriptor.sampleType') {
  return normalizeKnownEnum(value, 'float', TEXTURE_SAMPLE_TYPES, path, label);
}

function normalizeStorageTextureAccess(value, path, label = 'descriptor.access') {
  return normalizeKnownEnum(value, 'write-only', STORAGE_TEXTURE_ACCESS, path, label);
}

function normalizeVertexFormat(value, path, label) {
  return normalizeKnownEnum(value, 'float32', VERTEX_FORMATS, path, label);
}

function normalizeVertexStepMode(value, path, label = 'descriptor.stepMode') {
  return normalizeKnownEnum(value, 'vertex', VERTEX_STEP_MODES, path, label);
}

function normalizeTextureFormat(value, path, label, features = null) {
  const format = normalizeEnumKey(value, path, label);
  if (!KNOWN_TEXTURE_FORMATS.has(format)) {
    failValidation(path, `${label} must be a known GPUTextureFormat`);
  }
  if (isBCFormat(format) && !hasFeature(features, 'texture-compression-bc')) {
    failValidation(path, `${label} requires feature "texture-compression-bc"`);
  }
  if (isETC2Format(format) && !hasFeature(features, 'texture-compression-etc2')) {
    failValidation(path, `${label} requires feature "texture-compression-etc2"`);
  }
  if (isASTCFormat(format) && !hasFeature(features, 'texture-compression-astc')) {
    failValidation(path, `${label} requires feature "texture-compression-astc"`);
  }
  if (format === DEPTH_STENCIL_FORMAT_DEPTH32FLOAT_STENCIL8 && !hasFeature(features, 'depth32float-stencil8')) {
    failValidation(path, `${label} requires feature "depth32float-stencil8"`);
  }
  return format;
}

function normalizeSamplerLayout(binding, path, label) {
  const sampler = assertObject(binding, path, label);
  const type = normalizeEnumKey(sampler.type ?? 'filtering', path, `${label}.type`);
  if (!(type in SAMPLER_BINDING_TYPES)) {
    failValidation(path, `${label}.type must be one of: ${Object.keys(SAMPLER_BINDING_TYPES).join(', ')}`);
  }
  return { type };
}

function normalizeTextureLayout(binding, path, label) {
  const texture = assertObject(binding, path, label);
  const sampleType = normalizeTextureSampleType(texture.sampleType ?? 'float', path, `${label}.sampleType`);
  const viewDimension = normalizeTextureViewDimension(texture.viewDimension ?? '2d', path, `${label}.viewDimension`);
  const result = {
    sampleType,
    viewDimension,
    multisampled: texture.multisampled === undefined
      ? false
      : assertBoolean(texture.multisampled, path, `${label}.multisampled`),
  };
  if (texture.textureBindingViewDimension !== undefined) {
    const tbvd = normalizeEnumKey(texture.textureBindingViewDimension, path, `${label}.textureBindingViewDimension`);
    if (!(tbvd in TEXTURE_VIEW_DIMENSIONS)) {
      failValidation(path, `${label}.textureBindingViewDimension must be one of: ${Object.keys(TEXTURE_VIEW_DIMENSIONS).join(', ')}`);
    }
    result.textureBindingViewDimension = tbvd;
  }
  return result;
}

function normalizeStorageTextureLayout(binding, path, label, features = null) {
  const storageTexture = assertObject(binding, path, label);
  const access = normalizeStorageTextureAccess(storageTexture.access ?? 'write-only', path, `${label}.access`);
  const viewDimension = normalizeTextureViewDimension(storageTexture.viewDimension ?? '2d', path, `${label}.viewDimension`);
  const format = normalizeTextureFormat(storageTexture.format, path, `${label}.format`, features);
  if (!isStorageTextureFormat(format, features, access)) {
    failValidation(path, `${label}.format is not valid for storageTexture access ${access} on this device/package surface`);
  }
  return {
    access,
    format,
    viewDimension,
  };
}

function normalizeTextureDimension(value, path, label = 'descriptor.dimension') {
  return normalizeKnownEnum(value, '2d', TEXTURE_DIMENSIONS, path, label);
}

function normalizeRequestAdapterOptions(options, path = 'GPU.requestAdapter') {
  if (options === undefined) {
    return undefined;
  }
  const normalized = assertObject(options, path, 'options');
  const result = { ...normalized };
  if (normalized.powerPreference !== undefined) {
    result.powerPreference = normalizePowerPreference(normalized.powerPreference, path, 'options.powerPreference');
  }
  if (normalized.forceFallbackAdapter !== undefined) {
    result.forceFallbackAdapter = assertBoolean(normalized.forceFallbackAdapter, path, 'options.forceFallbackAdapter');
  }
  if (normalized.xrCompatible !== undefined) {
    result.xrCompatible = assertBoolean(normalized.xrCompatible, path, 'options.xrCompatible');
  }
  return result;
}

function normalizeRequestDeviceDescriptor(descriptor, path = 'GPUAdapter.requestDevice') {
  if (descriptor === undefined) {
    return undefined;
  }
  const normalized = assertObject(descriptor, path, 'descriptor');
  const result = { ...normalized };
  if (normalized.defaultQueue !== undefined) {
    const queue_descriptor = assertObject(normalized.defaultQueue, path, 'descriptor.defaultQueue');
    const queue_result = { ...queue_descriptor };
    if (queue_result.label === undefined) {
      queue_result.label = '';
    } else if (typeof queue_result.label !== 'string') {
      failValidation(path, 'descriptor.defaultQueue.label must be a string');
    }
    result.defaultQueue = queue_result;
  }
  if (normalized.requiredFeatures !== undefined) {
    const values = Array.isArray(normalized.requiredFeatures)
      ? normalized.requiredFeatures
      : Array.from(normalized.requiredFeatures ?? []);
    try {
      result.requiredFeatures = values.map((value, index) => normalizeFeatureName(
        value,
        path,
        `descriptor.requiredFeatures[${index}]`,
      ));
    } catch (error) {
      throw new TypeError(error?.message ?? String(error));
    }
  }
  if (normalized.requiredLimits !== undefined) {
    result.requiredLimits = assertObject(normalized.requiredLimits, path, 'descriptor.requiredLimits');
  }
  return result;
}

function normalizeSamplerDescriptor(descriptor, path = 'GPUDevice.createSampler') {
  const normalized = assertObject(descriptor, path, 'descriptor');
  const result = { ...normalized };
  if (normalized.addressModeU !== undefined) {
    result.addressModeU = normalizeAddressMode(normalized.addressModeU, path, 'descriptor.addressModeU');
  }
  if (normalized.addressModeV !== undefined) {
    result.addressModeV = normalizeAddressMode(normalized.addressModeV, path, 'descriptor.addressModeV');
  }
  if (normalized.addressModeW !== undefined) {
    result.addressModeW = normalizeAddressMode(normalized.addressModeW, path, 'descriptor.addressModeW');
  }
  if (normalized.magFilter !== undefined) {
    result.magFilter = normalizeKnownEnum(normalized.magFilter, 'nearest', FILTER_MODES, path, 'descriptor.magFilter');
  }
  if (normalized.minFilter !== undefined) {
    result.minFilter = normalizeKnownEnum(normalized.minFilter, 'nearest', FILTER_MODES, path, 'descriptor.minFilter');
  }
  if (normalized.mipmapFilter !== undefined) {
    result.mipmapFilter = normalizeMipmapFilterMode(normalized.mipmapFilter, path, 'descriptor.mipmapFilter');
  }
  if (normalized.lodMinClamp !== undefined) {
    result.lodMinClamp = normalizeFiniteNumber(normalized.lodMinClamp, path, 'descriptor.lodMinClamp');
  }
  if (normalized.lodMaxClamp !== undefined) {
    result.lodMaxClamp = normalizeFiniteNumber(normalized.lodMaxClamp, path, 'descriptor.lodMaxClamp');
  }
  if (normalized.compare !== undefined) {
    result.compare = normalizeCompareFunction(normalized.compare, path, 'descriptor.compare');
  }
  if (normalized.maxAnisotropy !== undefined) {
    result.maxAnisotropy = assertIntegerInRange(
      normalized.maxAnisotropy,
      path,
      'descriptor.maxAnisotropy',
      { min: 1, max: 65535 },
    );
  }
  if (
    result.lodMinClamp !== undefined
    && result.lodMaxClamp !== undefined
    && result.lodMinClamp > result.lodMaxClamp
  ) {
    failValidation(path, 'descriptor.lodMinClamp must be less than or equal to descriptor.lodMaxClamp');
  }
  return result;
}

function normalizeTextureViewDescriptor(descriptor, texture, features, path = 'GPUTexture.createView') {
  const normalized = descriptor === undefined ? {} : assertObject(descriptor, path, 'descriptor');
  const result = { ...normalized };
  if (normalized.dimension !== undefined) {
    result.dimension = normalizeTextureViewDimension(normalized.dimension, path, 'descriptor.dimension');
  }
  if (normalized.aspect !== undefined) {
    result.aspect = normalizeTextureAspect(normalized.aspect, path, 'descriptor.aspect');
  }
  if (normalized.format !== undefined) {
    result.format = normalizeTextureFormat(normalized.format, path, 'descriptor.format', features);
  } else if (texture?.format) {
    result.format = normalizeTextureFormat(texture.format, path, 'descriptor.format', features);
  }
  if (normalized.swizzle !== undefined && !hasFeature(features, 'texture-component-swizzle')) {
    failValidation(path, 'descriptor.swizzle requires the texture-component-swizzle feature');
  }
  return result;
}

function normalizeTextureDescriptor(descriptor, size, usage, features, path = 'GPUDevice.createTexture') {
  const normalized = assertObject(descriptor, path, 'descriptor');
  const result = {
    ...normalized,
    size,
    usage,
    dimension: normalizeTextureDimension(normalized.dimension, path),
    format: normalizeTextureFormat(normalized.format ?? 'rgba8unorm', path, 'descriptor.format', features),
  };
  if (normalized.viewFormats !== undefined) {
    result.viewFormats = assertArray(normalized.viewFormats, path, 'descriptor.viewFormats')
      .map((value, index) => normalizeTextureFormat(value, path, `descriptor.viewFormats[${index}]`, features));
  }
  return result;
}

function normalizeQuerySetDescriptor(descriptor, path = 'GPUDevice.createQuerySet') {
  const normalized = assertObject(descriptor, path, 'descriptor');
  return {
    ...normalized,
    type: normalizeQueryType(normalized.type, path, 'descriptor.type'),
  };
}

function normalizePrimitiveState(primitive, path = 'GPUDevice.createRenderPipeline') {
  if (primitive == null) {
    return null;
  }
  const normalized = assertObject(primitive, path, 'descriptor.primitive');
  const result = {
    ...normalized,
    topology: normalizePrimitiveTopology(normalized.topology, path, 'descriptor.primitive.topology'),
    frontFace: normalizeFrontFace(normalized.frontFace, path, 'descriptor.primitive.frontFace'),
  };
  if (normalized.stripIndexFormat !== undefined) {
    result.stripIndexFormat = normalizeIndexFormat(
      normalized.stripIndexFormat,
      path,
      'descriptor.primitive.stripIndexFormat',
    );
  }
  return result;
}

function normalizeStencilFaceState(face, path, label) {
  if (face == null) {
    return face;
  }
  const normalized = assertObject(face, path, label);
  const result = { ...normalized };
  if (normalized.compare !== undefined) {
    result.compare = normalizeCompareFunction(normalized.compare, path, `${label}.compare`);
  }
  if (normalized.failOp !== undefined) {
    result.failOp = normalizeStencilOperation(normalized.failOp, path, `${label}.failOp`);
  }
  if (normalized.depthFailOp !== undefined) {
    result.depthFailOp = normalizeStencilOperation(normalized.depthFailOp, path, `${label}.depthFailOp`);
  }
  if (normalized.passOp !== undefined) {
    result.passOp = normalizeStencilOperation(normalized.passOp, path, `${label}.passOp`);
  }
  return result;
}

function normalizeDepthStencilState(depthStencil, features, path = 'GPUDevice.createRenderPipeline') {
  if (depthStencil == null) {
    return null;
  }
  const normalized = assertObject(depthStencil, path, 'descriptor.depthStencil');
  const result = {
    ...normalized,
    format: normalizeTextureFormat(normalized.format, path, 'descriptor.depthStencil.format', features),
  };
  if (normalized.depthCompare !== undefined) {
    result.depthCompare = normalizeCompareFunction(normalized.depthCompare, path, 'descriptor.depthStencil.depthCompare');
  }
  if (normalized.stencilReadMask !== undefined) {
    result.stencilReadMask = assertIntegerInRange(
      normalized.stencilReadMask,
      path,
      'descriptor.depthStencil.stencilReadMask',
      { min: 0, max: UINT32_MAX },
    );
  }
  if (normalized.stencilWriteMask !== undefined) {
    result.stencilWriteMask = assertIntegerInRange(
      normalized.stencilWriteMask,
      path,
      'descriptor.depthStencil.stencilWriteMask',
      { min: 0, max: UINT32_MAX },
    );
  }
  if (normalized.depthBias !== undefined) {
    result.depthBias = assertIntegerInRange(
      normalized.depthBias,
      path,
      'descriptor.depthStencil.depthBias',
      { min: -2147483648, max: 2147483647 },
    );
  }
  if (normalized.depthBiasSlopeScale !== undefined) {
    result.depthBiasSlopeScale = normalizeFiniteNumber(
      normalized.depthBiasSlopeScale,
      path,
      'descriptor.depthStencil.depthBiasSlopeScale',
    );
  }
  if (normalized.depthBiasClamp !== undefined) {
    result.depthBiasClamp = normalizeFiniteNumber(
      normalized.depthBiasClamp,
      path,
      'descriptor.depthStencil.depthBiasClamp',
    );
  }
  if (normalized.stencilFront !== undefined) {
    result.stencilFront = normalizeStencilFaceState(
      normalized.stencilFront,
      path,
      'descriptor.depthStencil.stencilFront',
    );
  }
  if (normalized.stencilBack !== undefined) {
    result.stencilBack = normalizeStencilFaceState(
      normalized.stencilBack,
      path,
      'descriptor.depthStencil.stencilBack',
    );
  }
  return result;
}

function normalizeVertexBufferLayouts(layouts, path = 'GPUDevice.createRenderPipeline') {
  return assertArray(layouts, path, 'descriptor.vertex.buffers').map((layout, layoutIndex) => {
    const normalized = assertObject(layout, path, `descriptor.vertex.buffers[${layoutIndex}]`);
    return {
      ...normalized,
      arrayStride: assertIntegerInRange(
        normalized.arrayStride ?? 0,
        path,
        `descriptor.vertex.buffers[${layoutIndex}].arrayStride`,
        { min: 0, max: UINT32_MAX },
      ),
      stepMode: normalizeVertexStepMode(
        normalized.stepMode ?? 'vertex',
        path,
        `descriptor.vertex.buffers[${layoutIndex}].stepMode`,
      ),
      attributes: assertArray(
        normalized.attributes ?? [],
        path,
        `descriptor.vertex.buffers[${layoutIndex}].attributes`,
      ).map((attribute, attributeIndex) => {
        const item = assertObject(
          attribute,
          path,
          `descriptor.vertex.buffers[${layoutIndex}].attributes[${attributeIndex}]`,
        );
        return {
          ...item,
          format: normalizeVertexFormat(
            item.format,
            path,
            `descriptor.vertex.buffers[${layoutIndex}].attributes[${attributeIndex}].format`,
          ),
          offset: assertIntegerInRange(
            item.offset ?? 0,
            path,
            `descriptor.vertex.buffers[${layoutIndex}].attributes[${attributeIndex}].offset`,
            { min: 0, max: UINT32_MAX },
          ),
          shaderLocation: assertIntegerInRange(
            item.shaderLocation,
            path,
            `descriptor.vertex.buffers[${layoutIndex}].attributes[${attributeIndex}].shaderLocation`,
            { min: 0, max: UINT32_MAX },
          ),
        };
      }),
    };
  });
}

function assertTextureSize(size, path) {
  if (typeof size === 'number') {
    return {
      width: assertIntegerInRange(size, path, 'descriptor.size', { min: 1 }),
      height: 1,
      depthOrArrayLayers: 1,
    };
  }
  if (Array.isArray(size)) {
    if (size.length < 1 || size.length > 3) {
      failValidation(path, 'descriptor.size array must have 1 to 3 entries');
    }
    return {
      width: assertIntegerInRange(size[0], path, 'descriptor.size[0]', { min: 1, max: UINT32_MAX }),
      height: assertIntegerInRange(size[1] ?? 1, path, 'descriptor.size[1]', { min: 1, max: UINT32_MAX }),
      depthOrArrayLayers: assertIntegerInRange(size[2] ?? 1, path, 'descriptor.size[2]', { min: 1, max: UINT32_MAX }),
    };
  }
  const objectSize = assertObject(size, path, 'descriptor.size');
  return {
    width: assertIntegerInRange(objectSize.width ?? 1, path, 'descriptor.size.width', { min: 1, max: UINT32_MAX }),
    height: assertIntegerInRange(objectSize.height ?? 1, path, 'descriptor.size.height', { min: 1, max: UINT32_MAX }),
    depthOrArrayLayers: assertIntegerInRange(
      objectSize.depthOrArrayLayers ?? objectSize.depth ?? 1,
      path,
      objectSize.depthOrArrayLayers !== undefined ? 'descriptor.size.depthOrArrayLayers' : 'descriptor.size.depth',
      { min: 1, max: UINT32_MAX },
    ),
  };
}

function assertBindGroupResource(resource, path) {
  if (!resource || typeof resource !== 'object') {
    failValidation(path, 'entry.resource must be an object');
  }
  if ('buffer' in resource) {
    return {
      buffer: assertLiveResource(resource.buffer, path, 'GPUBuffer'),
      offset: assertOptionalIntegerInRange(resource.offset ?? 0, path, 'entry.resource.offset', { min: 0 }),
      size: resource.size === undefined
        ? undefined
        : assertIntegerInRange(resource.size, path, 'entry.resource.size', { min: 1 }),
    };
  }
  if ('_native' in resource) {
    if (describeResourceLabel(resource) === 'GPUSampler') {
      return { sampler: assertLiveResource(resource, path, 'GPUSampler') };
    }
    if (describeResourceLabel(resource) === 'GPUTextureView') {
      return { textureView: assertLiveResource(resource, path, 'GPUTextureView') };
    }
    if (describeResourceLabel(resource) === 'GPUExternalTexture') {
      return { externalTexture: assertLiveResource(resource, path, 'GPUExternalTexture') };
    }
    return {
      buffer: assertLiveResource(resource, path, 'GPUBuffer'),
      offset: 0,
      size: undefined,
    };
  }
  if ('sampler' in resource) {
    return { sampler: assertLiveResource(resource.sampler, path, 'GPUSampler') };
  }
  if ('textureView' in resource) {
    return { textureView: assertLiveResource(resource.textureView, path, 'GPUTextureView') };
  }
  if ('externalTexture' in resource) {
    return { externalTexture: assertLiveResource(resource.externalTexture, path, 'GPUExternalTexture') };
  }
  failValidation(
    path,
    'entry.resource must be a GPUBuffer, GPUTextureView, GPUSampler, GPUExternalTexture, or { buffer|textureView|sampler|externalTexture, ... }',
  );
}

function normalizeBindGroupLayoutEntry(entry, index, path, features = null) {
  const binding = assertObject(entry, path, `descriptor.entries[${index}]`);
  const normalized = {
    binding: assertIntegerInRange(binding.binding, path, `descriptor.entries[${index}].binding`, { min: 0, max: UINT32_MAX }),
    visibility: assertIntegerInRange(binding.visibility, path, `descriptor.entries[${index}].visibility`, { min: 0 }),
  };
  if (binding.buffer) {
    const buffer = assertObject(binding.buffer, path, `descriptor.entries[${index}].buffer`);
    normalized.buffer = {
      type: buffer.type || 'uniform',
      hasDynamicOffset: buffer.hasDynamicOffset === undefined
        ? false
        : assertBoolean(buffer.hasDynamicOffset, path, `descriptor.entries[${index}].buffer.hasDynamicOffset`),
      minBindingSize: assertOptionalIntegerInRange(
        buffer.minBindingSize ?? 0,
        path,
        `descriptor.entries[${index}].buffer.minBindingSize`,
        { min: 0 },
      ) ?? 0,
    };
  }
  if (binding.sampler) {
    normalized.sampler = normalizeSamplerLayout(binding.sampler, path, `descriptor.entries[${index}].sampler`);
  }
  if (binding.texture) {
    normalized.texture = normalizeTextureLayout(binding.texture, path, `descriptor.entries[${index}].texture`);
  }
  if (binding.storageTexture) {
    normalized.storageTexture = normalizeStorageTextureLayout(
      binding.storageTexture,
      path,
      `descriptor.entries[${index}].storageTexture`,
      features,
    );
  }
  if (binding.externalTexture) {
    assertObject(binding.externalTexture, path, `descriptor.entries[${index}].externalTexture`);
    normalized.externalTexture = {};
  }
  return normalized;
}

function autoLayoutEntriesFromNativeBindings(bindings, visibility) {
  const groups = new Map();
  for (const binding of bindings ?? []) {
    const entry = (() => {
      if (binding.type === 'buffer') {
        const type = binding.space === 'uniform'
          ? 'uniform'
          : binding.access === 'read'
            ? 'read-only-storage'
            : 'storage';
        return {
          binding: binding.binding,
          visibility,
          buffer: { type },
        };
      }
      if (binding.type === 'sampler') {
        return {
          binding: binding.binding,
          visibility,
          sampler: { type: 'filtering' },
        };
      }
      if (binding.type === 'texture') {
        return {
          binding: binding.binding,
          visibility,
          texture: { sampleType: 'float', viewDimension: '2d', multisampled: false },
        };
      }
      if (binding.type === 'storage_texture') {
        return {
          binding: binding.binding,
          visibility,
          storageTexture: {
            access: binding.access === 'read' ? 'read-only' : 'write-only',
            format: 'rgba8unorm',
            viewDimension: '2d',
          },
        };
      }
      return null;
    })();
    if (!entry) continue;
    const entries = groups.get(binding.group) ?? [];
    entries.push(entry);
    groups.set(binding.group, entries);
  }
  for (const entries of groups.values()) {
    entries.sort((left, right) => left.binding - right.binding);
  }
  return groups;
}

export {
  ALL_BUFFER_USAGE_BITS,
  SAMPLER_BINDING_TYPES,
  FILTER_MODES,
  FRONT_FACES,
  INDEX_FORMATS,
  MIPMAP_FILTER_MODES,
  POWER_PREFERENCES,
  PRIMITIVE_TOPOLOGIES,
  QUERY_TYPES,
  STENCIL_OPERATIONS,
  TEXTURE_ASPECTS,
  TEXTURE_SAMPLE_TYPES,
  TEXTURE_DIMENSIONS,
  TEXTURE_VIEW_DIMENSIONS,
  STORAGE_TEXTURE_ACCESS,
  VERTEX_STEP_MODES,
  VERTEX_FORMATS,
  KNOWN_TEXTURE_FORMATS,
  KNOWN_FEATURE_NAMES,
  DEPTH_STENCIL_FORMATS_BASE,
  STORAGE_TEXTURE_FORMATS_BASE,
  FLOAT32_FORMATS,
  ALWAYS_BLENDABLE_FORMATS,
  BC_FORMATS,
  ASTC_FORMATS,
  ASTC_BLOCK_SIZES,
  ETC2_FORMATS,
  isBCFormat,
  isETC2Format,
  isDepthStencilFormat,
  hasStencilAspect,
  isStorageTextureFormat,
  float32SampleType,
  isFloat32Filterable,
  isFloat32Blendable,
  isBlendableFormat,
  isASTCFormat,
  astcBlockSize,
  assertBufferDescriptor,
  normalizeEnumKey,
  normalizeFeatureName,
  normalizePowerPreference,
  normalizeFrontFace,
  normalizeIndexFormat,
  normalizePrimitiveTopology,
  normalizeQueryType,
  normalizeMipmapFilterMode,
  normalizeStencilOperation,
  normalizeTextureAspect,
  normalizeTextureViewDimension,
  normalizeTextureSampleType,
  normalizeStorageTextureAccess,
  normalizeVertexFormat,
  normalizeVertexStepMode,
  normalizeTextureFormat,
  normalizeTextureDimension,
  normalizeRequestAdapterOptions,
  normalizeRequestDeviceDescriptor,
  normalizeSamplerDescriptor,
  normalizeTextureViewDescriptor,
  normalizeTextureDescriptor,
  normalizeQuerySetDescriptor,
  normalizePrimitiveState,
  normalizeDepthStencilState,
  normalizeVertexBufferLayouts,
  normalizeSamplerLayout,
  normalizeTextureLayout,
  normalizeStorageTextureLayout,
  assertTextureSize,
  assertBindGroupResource,
  normalizeBindGroupLayoutEntry,
  autoLayoutEntriesFromNativeBindings,
};
